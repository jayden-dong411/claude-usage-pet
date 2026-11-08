import Foundation

// Everything comes from DeepSeek Harness's local files (bundle com.deepseek.dsh):
//   ~/.dsh/.dshw-usage.json                                   balance, today's spend, spend per day
//                                                             (read by DeepSeekPeer in Peers.swift)
//   ~/.dsh/storages/session_projcache/sessions/session-*.json  each session's title, running turn,
//                                                             open questions and todos
// No API key or network access is needed.

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
    var detail: String          // project folder
    var model: String? = nil
    var statusSince: Date
    var progress: TaskProgress?

    var isBusy: Bool { status == "busy" }
    var isWaiting: Bool { status == "waiting" }
    var waitingLabel: String { "等你回答" }
    var statusLabel: String { isBusy ? "进行中" : isWaiting ? waitingLabel : "空闲" }
    var folderName: String { detail.isEmpty ? "—" : detail }
    var entryLabel: String { model ?? "DeepSeek" }
}

enum DSReader {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dsh/storages/session_projcache/sessions")

    private static func val(_ rows: [String: Any], _ key: String) -> Any? {
        (rows[key] as? [String: Any])?["val"]
    }

    private static func progress(_ todos: Any?) -> TaskProgress? {
        var items: [[String: Any]] = []
        if let a = todos as? [[String: Any]] { items = a }
        if let m = todos as? [String: Any] {
            if let a = m["items"] as? [[String: Any]] { items = a }
            else if let a = m["todos"] as? [[String: Any]] { items = a }
        }
        guard !items.isEmpty else { return nil }
        func st(_ i: [String: Any]) -> String { ((i["status"] ?? i["state"]) as? String)?.lowercased() ?? "" }
        let done = items.filter { ["completed", "done"].contains(st($0)) }.count
        let cur = items.first { ["in_progress", "active", "running"].contains(st($0)) }
        let title = cur.flatMap { ($0["content"] ?? $0["title"] ?? $0["text"]) as? String }
        return TaskProgress(done: done, total: items.count, current: title)
    }

    /// Titled top-level sessions active within `window` seconds (or waiting / running), newest first.
    static func sessions(window: TimeInterval = 6 * 3600) -> [SessionInfo] {
        let fm = FileManager.default
        let now = Date()
        var out: [SessionInfo] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("session-") && name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(mtime) < max(window, 24 * 3600) else { continue }
            guard let d = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let rows = (o["record"] as? [String: Any])?["rows"] as? [String: Any],
                  let title = val(rows, "title") as? String, !title.isEmpty else { continue }
            let running = ((val(rows, "turnBoundary") as? [String: Any])?["openTurnStartSeq"]).map { !($0 is NSNull) } ?? false
            let questions = ((val(rows, "userQuestions") as? [String: Any])?["questions"] as? [String: Any])?["active"] as? [Any] ?? []
            let lastMs = ((val(rows, "timeContext") as? [String: Any])?["lastMessageTime"] as? NSNumber)?.doubleValue
            let last = lastMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? mtime
            let waiting = !questions.isEmpty
            guard running || waiting || now.timeIntervalSince(last) < window else { continue }
            let cwd = (val(rows, "workingDirectory") as? String) ?? ""
            let model = ((val(rows, "modelSelection") as? [String: Any])?["lastUsed"] as? [String: Any])?["model"] as? String
            let folder = cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
            out.append(SessionInfo(id: String(name.dropLast(5)), name: title,
                                   status: waiting ? "waiting" : running ? "busy" : "idle",
                                   detail: folder, model: model,
                                   statusSince: last, progress: progress(val(rows, "todos"))))
        }
        return out.sorted {
            if $0.isWaiting != $1.isWaiting { return $0.isWaiting }
            if $0.isBusy != $1.isBusy { return $0.isBusy }
            return $0.statusSince > $1.statusSince
        }
    }
}
