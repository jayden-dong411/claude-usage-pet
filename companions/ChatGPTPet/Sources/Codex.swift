import Foundation

// Everything comes from the local Codex logs written by the ChatGPT app / Codex CLI:
//   ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl   (one file per thread)
//   ~/.codex/session_index.jsonl                   (thread titles)
// No login, token or network access is needed.

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
    var source: String
    /// When Codex last reported these numbers.
    var observedAt: Date
}

struct TaskProgress {
    var done: Int
    var total: Int
    var current: String?
    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    var isFinished: Bool { total > 0 && done >= total }
}

struct SessionInfo: Identifiable {
    let id: String
    var name: String
    var status: String          // "busy" | "waiting" | "idle"
    var cwd: String
    var model: String?
    var statusSince: Date
    var progress: TaskProgress?

    var isBusy: Bool { status == "busy" }
    var isWaiting: Bool { status == "waiting" }
    var waitingLabel: String { "等你回复" }
    var statusLabel: String { isBusy ? "进行中" : isWaiting ? waitingLabel : "空闲" }
    var folderName: String { cwd.isEmpty ? "—" : (cwd as NSString).lastPathComponent }
    var entryLabel: String { model ?? "Codex" }
}

enum CodexPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    static let sessions = root.appendingPathComponent("sessions")
    static let index = root.appendingPathComponent("session_index.jsonl")
}

/// Incrementally follows recent rollout files.
final class CodexReader {
    private struct ThreadState {
        var offset: UInt64 = 0
        var id = ""
        var cwd = ""
        var threadSource: String?
        var model: String?
        var lastStarted: Date?
        var lastFinished: Date?
        var lastEvent: Date?
        var pendingInputCalls: Set<String> = []
        var plan: [(String, String)] = []
        var limits: [String: Any]?
        var limitsAt: Date?
    }

    private var threads: [String: ThreadState] = [:]      // by file path
    private var titles: [String: String] = [:]
    private var indexOffset: UInt64 = 0
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// Threads touched within `window` seconds, plus the latest rate limits seen anywhere.
    func refresh(window: TimeInterval = 6 * 3600) -> (sessions: [SessionInfo], usage: UsageSnapshot?) {
        readIndex()
        let now = Date()
        var files: [(URL, Date)] = []
        if let en = FileManager.default.enumerator(at: CodexPaths.sessions, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(m) < max(window, 8 * 86400) { files.append((url, m)) }
            }
        }
        var sessions: [SessionInfo] = []
        var newest: (Date, [String: Any])?
        for (url, mtime) in files {
            var st = threads[url.path] ?? ThreadState()
            read(url, into: &st)
            threads[url.path] = st
            if let l = st.limits, let at = st.limitsAt, newest == nil || at > newest!.0 { newest = (at, l) }
            guard now.timeIntervalSince(mtime) < window, !st.id.isEmpty else { continue }
            // Skip imported / background threads: keep ones with a title or started by the user.
            let titled = !(titles[st.id] ?? "").isEmpty
            guard titled || st.threadSource == "user" else { continue }
            let running = (st.lastStarted ?? .distantPast) > (st.lastFinished ?? .distantPast)
                && now.timeIntervalSince(st.lastEvent ?? mtime) < 30 * 60          // stale turns count as idle
            let status = running ? (st.pendingInputCalls.isEmpty ? "busy" : "waiting") : "idle"
            let since = running ? (st.lastStarted ?? mtime) : (st.lastFinished ?? st.lastEvent ?? mtime)
            var progress: TaskProgress?
            if !st.plan.isEmpty {
                let done = st.plan.filter { $0.1 == "completed" }.count
                let cur = st.plan.first(where: { $0.1 == "in_progress" })?.0 ?? st.plan.first(where: { $0.1 == "pending" })?.0
                progress = TaskProgress(done: done, total: st.plan.count, current: done >= st.plan.count ? nil : cur)
            }
            let title = titles[st.id].flatMap { $0.isEmpty ? nil : $0 } ?? ((st.cwd as NSString).lastPathComponent.isEmpty ? "未命名线程" : (st.cwd as NSString).lastPathComponent)
            sessions.append(SessionInfo(id: st.id, name: title, status: status, cwd: st.cwd, model: st.model,
                                        statusSince: since, progress: progress))
        }
        sessions.sort {
            if $0.isWaiting != $1.isWaiting { return $0.isWaiting }
            if $0.isBusy != $1.isBusy { return $0.isBusy }
            return $0.statusSince > $1.statusSince
        }
        return (sessions, newest.map { Self.snapshot($0.1, at: $0.0) })
    }

    private static func snapshot(_ rl: [String: Any], at: Date) -> UsageSnapshot {
        func win(_ any: Any?) -> LimitWindow? {
            guard let d = any as? [String: Any], let u = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (d["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            // Once the window has reset, nothing has been used in the new one yet.
            if let reset, reset < Date() { return LimitWindow(utilization: 0, resetsAt: nil) }
            return LimitWindow(utilization: max(0, u), resetsAt: reset)
        }
        var s = UsageSnapshot(fiveHour: win(rl["primary"]), sevenDay: win(rl["secondary"]), source: "Codex 日志", observedAt: at)
        if let p = rl["plan_type"] as? String, !p.isEmpty { s.plan = p.prefix(1).uppercased() + p.dropFirst() }
        return s
    }

    private func readIndex() {
        guard let h = try? FileHandle(forReadingFrom: CodexPaths.index) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < indexOffset { indexOffset = 0; titles = [:] }
        guard size > indexOffset else { return }
        try? h.seek(toOffset: indexOffset)
        guard let data = try? h.readToEnd(), let last = data.lastIndex(of: 0x0A) else { return }
        let chunk = data[data.startIndex...last]
        indexOffset += UInt64(chunk.count)
        for line in chunk.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = o["id"] as? String, let name = o["thread_name"] as? String else { continue }
            titles[id] = name
        }
    }

    private func read(_ url: URL, into st: inout ThreadState) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < st.offset { st = ThreadState() }
        guard size > st.offset else { return }
        try? h.seek(toOffset: st.offset)
        guard let data = try? h.readToEnd(), let last = data.lastIndex(of: 0x0A) else { return }
        let chunk = data[data.startIndex...last]
        st.offset += UInt64(chunk.count)
        let wanted = ["\"session_meta\"", "\"turn_context\"", "\"task_started\"", "\"task_complete\"", "\"turn_aborted\"",
                      "\"token_count\"", "\"function_call\"", "\"function_call_output\"", "\"custom_tool_call\"",
                      "\"custom_tool_call_output\""].map { Data($0.utf8) }
        for line in chunk.split(separator: 0x0A) {
            guard wanted.contains(where: { line.range(of: $0) != nil }),
                  let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let ts = (o["timestamp"] as? String).flatMap { iso.date(from: $0) }
            if let ts { st.lastEvent = max(st.lastEvent ?? ts, ts) }
            let p = o["payload"] as? [String: Any] ?? [:]
            switch (o["type"] as? String, p["type"] as? String) {
            case ("session_meta", _):
                st.id = p["id"] as? String ?? p["session_id"] as? String ?? st.id
                st.cwd = p["cwd"] as? String ?? st.cwd
                st.threadSource = p["thread_source"] as? String
            case ("turn_context", _):
                st.model = p["model"] as? String ?? st.model
                st.cwd = p["cwd"] as? String ?? st.cwd
            case ("event_msg", "task_started"):
                st.lastStarted = ts; st.pendingInputCalls = []
            case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
                st.lastFinished = ts; st.pendingInputCalls = []
            case ("event_msg", "token_count"):
                if let rl = p["rate_limits"] as? [String: Any], rl["primary"] != nil { st.limits = rl; st.limitsAt = ts }
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                let name = p["name"] as? String ?? ""
                let call = p["call_id"] as? String ?? ""
                if name.contains("request_user_input") && !call.isEmpty { st.pendingInputCalls.insert(call) }
                if name == "update_plan", let args = p["arguments"] as? String,
                   let a = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any],
                   let plan = a["plan"] as? [[String: Any]] {
                    st.plan = plan.map { ($0["step"] as? String ?? "", $0["status"] as? String ?? "pending") }
                }
            case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
                if let call = p["call_id"] as? String { st.pendingInputCalls.remove(call) }
            default:
                break
            }
        }
    }
}
