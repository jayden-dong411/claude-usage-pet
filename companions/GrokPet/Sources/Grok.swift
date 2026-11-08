import Foundation

// Everything comes from the Grok Bot desktop app's local client cache
// (~/Library/Application Support/Grok Bot/sand-client-persistence, see GrokBotStore in Peers.swift):
//   ...weekly-usage.cache   the plan's weekly usage (percent used, next reset)
//   ...roster.last-roster   the user's bots: name, last activity, last message, awaiting a reply
// Not the Grok Build CLI (~/.grok), which the user does not mean by "Grok".

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
    var detail: String          // last message, shortened
    var statusSince: Date
    var progress: TaskProgress?

    var isBusy: Bool { status == "busy" }
    var isWaiting: Bool { status == "waiting" }
    var waitingLabel: String { "等你回复" }
    var statusLabel: String { isBusy ? "进行中" : isWaiting ? waitingLabel : "空闲" }
    var folderName: String { detail.isEmpty ? "—" : detail }
    var entryLabel: String { "Grok Bot" }
}

enum GrokReader {
    /// Bots active within `window` seconds (or waiting for the user), newest first.
    static func sessions(window: TimeInterval = 6 * 3600) -> [SessionInfo] {
        guard let rows = GrokBotStore.value(suffix: ".roster.last-roster")?["rows"] as? [[String: Any]] else { return [] }
        let now = Date()
        var out: [SessionInfo] = []
        for r in rows {
            if (r["isHiddenFromSidebar"] as? Bool) == true || (r["isRemovedFromSidebar"] as? Bool) == true { continue }
            guard let id = r["id"] as? String else { continue }
            let ms = (r["lastActivityAt"] as? NSNumber)?.doubleValue ?? (r["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            let at = Date(timeIntervalSince1970: ms / 1000)
            let waiting = r["awaitingUserResponse"] != nil && !(r["awaitingUserResponse"] is NSNull)
            let busy = !waiting && now.timeIntervalSince(at) < 90
            guard waiting || now.timeIntervalSince(at) < window else { continue }
            var detail = ((r["lastEntry"] as? [String: Any])?["text"] as? String) ?? ""
            detail = detail.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            if detail.count > 40 { detail = String(detail.prefix(39)) + "…" }
            out.append(SessionInfo(id: id, name: (r["name"] as? String) ?? "Grok Bot",
                                   status: waiting ? "waiting" : busy ? "busy" : "idle",
                                   detail: detail, statusSince: at, progress: nil))
        }
        return out.sorted {
            if $0.isWaiting != $1.isWaiting { return $0.isWaiting }
            if $0.isBusy != $1.isBusy { return $0.isBusy }
            return $0.statusSince > $1.statusSince
        }
    }
}
