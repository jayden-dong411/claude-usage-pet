import AppKit
import Foundation
import WebKit

// MARK: - Models

struct LimitWindow {
    var utilization: Double      // 0...100
    var resetsAt: Date?
}

struct UsageSnapshot {
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    var extras: [(label: String, window: LimitWindow)] = []
    var account: String?
    var plan: String?
    var orgName: String?
    var source: String
}

struct SessionInfo: Identifiable {
    let id: String
    let pid: Int32
    let name: String
    let status: String
    let cwd: String
    let entrypoint: String
    let startedAt: Date
    let statusSince: Date
    var waitingFor: String? = nil
    /// The desktop app's own id for the session ("local_…"), used by its deep links.
    var hostSessionId: String? = nil
    /// Remote-control id ("session_…"), when the session has one.
    var bridgeSessionId: String? = nil
    var progress: TaskProgress? = nil

    var isBusy: Bool { status == "busy" }
    /// Blocked on the user: a permission prompt, a question, or an open dialog.
    var isWaiting: Bool { status == "waiting" }
    var waitingLabel: String {
        switch waitingFor {
        case "permission prompt": return "等你批准"
        case "input needed": return "等你回复"
        case "dialog open": return "等你操作"
        default: return "等你处理"
        }
    }
    var statusLabel: String {
        if isBusy { return "进行中" }
        if isWaiting { return waitingLabel }
        if status == "idle" || status == "shell" { return "空闲" }
        return status
    }
    var folderName: String { (cwd as NSString).lastPathComponent }
    var entryLabel: String {
        if entrypoint.contains("desktop") { return "桌面版" }
        if entrypoint.contains("cli") { return "终端" }
        if entrypoint.contains("vscode") || entrypoint.contains("ide") { return "IDE" }
        return entrypoint.isEmpty ? "Claude Code" : entrypoint
    }
}

enum UsageError: LocalizedError {
    case http(Int)
    case notLoggedIn
    case noOrganization
    case badResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .http(let c): return c == 401 ? "登录已失效 (401)" : "请求失败 (HTTP \(c))"
        case .notLoggedIn: return "未登录"
        case .noOrganization: return "没有找到组织"
        case .badResponse: return "返回数据无法解析"
        case .timeout: return "连接超时"
        }
    }
}

// MARK: - Parsing helpers

enum UsageParser {
    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    static func window(_ any: Any?) -> LimitWindow? {
        guard let d = any as? [String: Any],
              let u = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return LimitWindow(utilization: max(0, u), resetsAt: date(d["resets_at"]))
    }

    static func apply(_ obj: [String: Any], to snap: inout UsageSnapshot) {
        snap.fiveHour = window(obj["five_hour"])
        snap.sevenDay = window(obj["seven_day"])
        var extras: [(String, LimitWindow)] = []
        if let w = window(obj["seven_day_opus"]) { extras.append(("7 天 · Opus", w)) }
        if let w = window(obj["seven_day_sonnet"]) { extras.append(("7 天 · Sonnet", w)) }
        snap.extras = extras.map { (label: $0.0, window: $0.1) }
    }
}

// MARK: - Source 1: Claude Code OAuth token in the macOS keychain (read only)

struct OAuthCred {
    let token: String
    let expiresAt: Date
    let plan: String?
}

enum KeychainOAuth {
    static func read() -> OAuthCred? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = obj["claudeAiOauth"] as? [String: Any],
              let token = o["accessToken"] as? String else { return nil }
        let exp = (o["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        return OAuthCred(token: token,
                         expiresAt: Date(timeIntervalSince1970: exp / 1000),
                         plan: o["subscriptionType"] as? String)
    }
}

enum OAuthUsageAPI {
    private static func get(_ path: String, token: String) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        r.setValue("DoroPet/1.0", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 15
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw UsageError.http(code) }
        guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw UsageError.badResponse }
        return obj
    }

    static func fetch(_ c: OAuthCred) async throws -> UsageSnapshot {
        let usage = try await get("/api/oauth/usage", token: c.token)
        var snap = UsageSnapshot(source: "Claude Code 登录")
        UsageParser.apply(usage, to: &snap)
        snap.plan = c.plan.map { $0.capitalized }
        if let p = try? await get("/api/oauth/profile", token: c.token) {
            snap.account = (p["account"] as? [String: Any])?["email"] as? String
        }
        return snap
    }
}

// MARK: - Source 2: claude.ai web session (logged in inside Doro's own web view)

@MainActor
final class WebUsageFetcher: NSObject, WKNavigationDelegate {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private let webView: WKWebView
    private var loaded = false
    private var loadCont: CheckedContinuation<Void, Error>?

    init(store: WKWebsiteDataStore = .default()) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
        webView.customUserAgent = WebUsageFetcher.userAgent
        super.init()
        webView.navigationDelegate = self
    }

    func reset() { loaded = false }

    /// Copies the desktop app's claude.ai cookies into Doro's web store.
    func importCookies(_ cookies: [DesktopCookie]) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for c in cookies {
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: c.domain, .path: c.path.isEmpty ? "/" : c.path,
                .name: c.name, .value: c.value,
            ]
            if c.secure { props[.secure] = "TRUE" }
            if let e = c.expires { props[.expires] = e }
            if c.httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let cookie = HTTPCookie(properties: props) { await store.setCookie(cookie) }
        }
    }

    private func ensureLoaded() async throws {
        if loaded { return }
        webView.load(URLRequest(url: URL(string: "https://claude.ai/api/account")!))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadCont = c
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                if let c = self?.loadCont { self?.loadCont = nil; c.resume(throwing: UsageError.timeout) }
            }
        }
        loaded = true
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            if let c = self.loadCont { self.loadCont = nil; c.resume() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            if let c = self.loadCont { self.loadCont = nil; c.resume(throwing: error) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            if let c = self.loadCont { self.loadCont = nil; c.resume(throwing: error) }
        }
    }

    private static let script = """
    const acc = await fetch('/api/account', {credentials: 'include', headers: {accept: 'application/json'}});
    if (!acc.ok) return JSON.stringify({error: 'auth', status: acc.status});
    const a = await acc.json();
    const ms = a.memberships || [];
    let org = null;
    for (const m of ms) {
      if (preferOrg && m.organization && m.organization.uuid === preferOrg) { org = m.organization; break; }
    }
    for (const m of ms) {
      if (org && preferOrg && org.uuid === preferOrg) break;
      const o = m.organization || {};
      const caps = o.capabilities || [];
      if (!caps.includes('chat')) continue;
      const paid = caps.some(c => c.startsWith('claude_max') || c.startsWith('claude_pro') || c === 'raven');
      if (!org || paid) org = o;
    }
    if (!org && ms.length) org = ms[0].organization;
    if (!org) return JSON.stringify({error: 'noorg'});
    const u = await fetch('/api/organizations/' + org.uuid + '/usage', {credentials: 'include', headers: {accept: 'application/json'}});
    if (!u.ok) return JSON.stringify({error: 'usage', status: u.status});
    return JSON.stringify({email: a.email_address, org: org.name, caps: org.capabilities || [], usage: await u.json()});
    """

    func fetch(preferOrg: String? = nil) async throws -> UsageSnapshot {
        do { try await ensureLoaded() } catch { loaded = false; throw error }
        let raw = try await webView.callAsyncJavaScript(Self.script, arguments: ["preferOrg": preferOrg ?? ""],
                                                        in: nil, contentWorld: .page)
        guard let s = raw as? String, let d = s.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw UsageError.badResponse }
        if let err = obj["error"] as? String {
            let status = (obj["status"] as? NSNumber)?.intValue ?? -1
            if err == "auth" { throw UsageError.notLoggedIn }
            if err == "noorg" { throw UsageError.noOrganization }
            throw UsageError.http(status)
        }
        var snap = UsageSnapshot(source: "claude.ai 网页登录")
        snap.orgName = obj["org"] as? String
        if let u = obj["usage"] as? [String: Any] { UsageParser.apply(u, to: &snap) }
        snap.account = obj["email"] as? String
        let caps = (obj["caps"] as? [String]) ?? []
        if caps.contains(where: { $0.hasPrefix("claude_max") }) { snap.plan = "Max" }
        else if caps.contains(where: { $0.hasPrefix("claude_pro") }) { snap.plan = "Pro" }
        else if caps.contains("raven") { snap.plan = "Team" }
        else { snap.plan = "Free" }
        return snap
    }

    static func logout() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

// MARK: - Running Claude Code sessions (~/.claude/sessions/*.json)

enum SessionStore {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")

    static func load() -> [SessionInfo] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [SessionInfo] = []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.int32Value else { continue }
            // Skip stale files whose process is gone.
            if kill(pid, 0) != 0 && errno != EPERM { continue }
            let cwd = o["cwd"] as? String ?? ""
            let ms = { (k: String) -> Date in
                Date(timeIntervalSince1970: ((o[k] as? NSNumber)?.doubleValue ?? 0) / 1000)
            }
            let rawName = (o["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            out.append(SessionInfo(
                id: o["sessionId"] as? String ?? "\(pid)",
                pid: pid,
                name: rawName.isEmpty ? (cwd as NSString).lastPathComponent : rawName,
                status: o["status"] as? String ?? "unknown",
                cwd: cwd,
                entrypoint: o["entrypoint"] as? String ?? "",
                startedAt: ms("startedAt"),
                statusSince: ms("statusUpdatedAt"),
                waitingFor: o["waitingFor"] as? String,
                hostSessionId: o["hostSessionId"] as? String,
                bridgeSessionId: o["bridgeSessionId"] as? String))
        }
        return out.sorted {
            if $0.isWaiting != $1.isWaiting { return $0.isWaiting }
            if $0.isBusy != $1.isBusy { return $0.isBusy }
            return $0.statusSince > $1.statusSince
        }
    }
}
