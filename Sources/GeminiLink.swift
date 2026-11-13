import Foundation

// Gemini (Google Antigravity, bundle com.google.antigravity). Everything comes from Antigravity's own local
// language server, which only runs while Antigravity is open:
// - ~/.gemini/antigravity/daemon/hub_<port>.json  {pid, httpPort, csrfToken} — where the server listens
// - POST http://127.0.0.1:<httpPort>/exa.language_server_pb.LanguageServerService/<Method> (Connect JSON,
//   header X-Codeium-Csrf-Token), the same calls Antigravity's own window makes:
//   GetUserStatus              plan + every model's quota (remainingFraction, resetTime)
//   GetAllCascadeTrajectories  the conversations: title, status (RUNNING / BUSY / IDLE), last change, workspace
//   GetCascadeTrajectory       one conversation's steps with token usage per model call (GeminiSide.swift)
// Read-only; nothing leaves this Mac. The latest quota is kept in AIPets/gemini.json so the other pets can show
// it while Antigravity is closed. Compiled into every pet.

enum GeminiLS {
    struct Endpoint { var port: Int; var token: String; var pid: Int32 }

    static let daemonDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/daemon")

    /// The running server, from the newest hub file whose process is alive.
    static func endpoint() -> Endpoint? {
        let fm = FileManager.default
        var best: (Date, Endpoint)?
        for name in (try? fm.contentsOfDirectory(atPath: daemonDir.path)) ?? [] where name.hasPrefix("hub_") && name.hasSuffix(".json") {
            let url = daemonDir.appendingPathComponent(name)
            guard let d = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let port = (o["httpPort"] as? NSNumber)?.intValue, let token = o["csrfToken"] as? String,
                  let pid = (o["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0 else { continue }
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || m > best!.0 { best = (m, Endpoint(port: port, token: token, pid: pid)) }
        }
        return best?.1
    }

    static var isRunning: Bool { endpoint() != nil }

    /// Blocking; call off the main thread. nil when Antigravity isn't running or the call fails.
    static func call(_ method: String, _ body: [String: Any] = [:], timeout: TimeInterval = 10) -> [String: Any]? {
        guard let ep = endpoint(),
              let url = URL(string: "http://127.0.0.1:\(ep.port)/exa.language_server_pb.LanguageServerService/\(method)")
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(ep.token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        var out: Data?, status = 0
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: req) { data, resp, _ in
            out = data
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        session.invalidateAndCancel()
        guard status == 200, let out else { return nil }
        return try? JSONSerialization.jsonObject(with: out) as? [String: Any]
    }

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Quota

enum GeminiPeer {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (Date, PeerUsage?) = (.distantPast, nil)
    nonisolated(unsafe) private static var names: [String: String] = [:]

    /// Model id ("MODEL_PLACEHOLDER_M437") → display name ("Gemini 4 Carbon"), from the last GetUserStatus.
    static var modelNames: [String: String] { lock.lock(); defer { lock.unlock() }; return names }

    /// Live from Antigravity (reused for `maxAge` seconds), else nil. Writes gemini.json for the other pets.
    static func live(maxAge: TimeInterval = 60) -> PeerUsage? {
        lock.lock()
        if Date().timeIntervalSince(cache.0) < maxAge { let c = cache.1; lock.unlock(); return c }
        lock.unlock()
        let u = request()
        lock.lock(); cache = (Date(), u); lock.unlock()
        if let u { PeerStore.write(u) }
        return u
    }

    /// Live when Antigravity runs, else the last reading (up to 24 h old).
    static func read() -> PeerUsage? { live() ?? PeerStore.read("gemini") }

    private static func request() -> PeerUsage? {
        guard let us = GeminiLS.call("GetUserStatus")?["userStatus"] as? [String: Any] else { return nil }
        let configs = ((us["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]]) ?? []
        // Models share quota pools: one for Gemini models, one for the others (Claude, GPT-OSS).
        var gemini: (Double, Date?)?, other: (Double, Date?)?
        var n: [String: String] = [:]
        for c in configs {
            guard let label = c["label"] as? String else { continue }
            if let id = (c["modelOrAlias"] as? [String: Any])?["model"] as? String {
                n[id] = label.replacingOccurrences(of: #" \((Low|Medium|High|XHigh)\)$"#, with: "", options: .regularExpression)
            }
            guard let q = c["quotaInfo"] as? [String: Any] else { continue }
            let left = (q["remainingFraction"] as? NSNumber)?.doubleValue ?? 0     // missing = none left
            let reset = GeminiLS.date(q["resetTime"])
            let isGemini = label.hasPrefix("Gemini") || label.hasPrefix("Orchestrator")
            let cur = isGemini ? gemini : other
            if cur == nil || left < cur!.0 {
                if isGemini { gemini = (left, reset) } else { other = (left, reset) }
            }
        }
        lock.lock(); if !n.isEmpty { names = n }; lock.unlock()
        func win(_ label: String, _ v: (Double, Date?)?) -> PeerWindow? {
            guard let (left, reset) = v else { return nil }
            if let reset, reset < Date() { return PeerWindow(label: label, utilization: 0, resetsAt: nil) }
            return PeerWindow(label: label, utilization: max(0, min(100, (1 - left) * 100)), resetsAt: reset)
        }
        let windows = [win("Gemini 模型", gemini), win("Claude 等模型", other)].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        let plan = ((us["userTier"] as? [String: Any])?["name"] as? String)
            ?? (((us["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String)
        return PeerUsage(provider: "gemini", title: "Antigravity · Gemini", plan: plan, windows: windows, observedAt: Date(),
                         short: "Gemini " + (windows.first.map { "\(Int($0.utilization.rounded()))%" } ?? "—"))
    }
}

// MARK: - Conversations

struct GeminiConversation {
    var id: String
    var title: String
    var status: String          // "busy" | "idle"
    var workspace: String       // folder name
    var lastChange: Date
    var lastInput: Date?
    var steps: Int
}

enum GeminiConversations {
    /// All conversations Antigravity knows, or nil when it isn't running.
    static func list() -> [GeminiConversation]? {
        guard let all = GeminiLS.call("GetAllCascadeTrajectories")?["trajectorySummaries"] as? [String: Any] else { return nil }
        return all.compactMap { id, any in
            guard let s = any as? [String: Any] else { return nil }
            let st = (s["status"] as? String) ?? ""
            let busy = st.hasSuffix("RUNNING") || st.hasSuffix("BUSY") || st.hasSuffix("CANCELING")
            let title = ((s["annotations"] as? [String: Any])?["title"] as? String) ?? (s["summary"] as? String) ?? "Antigravity 对话"
            return GeminiConversation(id: id, title: title, status: busy ? "busy" : "idle",
                                      workspace: workspaceName(s), lastChange: GeminiLS.date(s["lastModifiedTime"]) ?? .distantPast,
                                      lastInput: GeminiLS.date(s["lastUserInputTime"]),
                                      steps: (s["stepCount"] as? NSNumber)?.intValue ?? 0)
        }
    }

    static func workspaceName(_ summary: [String: Any]) -> String {
        guard let w = (summary["workspaces"] as? [[String: Any]])?.first,
              let uri = w["workspaceFolderAbsoluteUri"] as? String, let url = URL(string: uri) else { return "" }
        return url.lastPathComponent
    }
}
