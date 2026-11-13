import Foundation

// Everything comes from Google Antigravity's local language server (see ../../Sources/GeminiLink.swift):
//   GetUserStatus              the quota of the Gemini models and of the other models (GeminiPeer)
//   GetAllCascadeTrajectories  the conversations: title, running or idle, last change, workspace folder
//   GetCascadeTrajectory       token usage per model call, for the statistics window (GeminiSide.swift)
// It only answers while Antigravity is open; the last quota reading is kept in AIPets/gemini.json.

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
    var detail: String          // workspace folder
    var steps: Int = 0
    var statusSince: Date
    var progress: TaskProgress?

    var isBusy: Bool { status == "busy" }
    var isWaiting: Bool { status == "waiting" }
    var waitingLabel: String { "等你回复" }
    var statusLabel: String { isBusy ? "进行中" : isWaiting ? waitingLabel : "空闲" }
    var folderName: String { detail.isEmpty ? "—" : detail }
    var entryLabel: String { steps > 0 ? "\(steps) 步" : "Antigravity" }
}

enum GeminiReader {
    /// Conversations changed within `window` seconds (or running), newest first; nil while Antigravity is closed.
    static func sessions(window: TimeInterval = 6 * 3600) -> [SessionInfo]? {
        guard let all = GeminiConversations.list() else { return nil }
        let now = Date()
        return all.filter { $0.status == "busy" || now.timeIntervalSince($0.lastChange) < window }
            .map { c in
                SessionInfo(id: c.id, name: c.title, status: c.status, detail: c.workspace, steps: c.steps,
                            statusSince: c.lastChange, progress: nil)
            }
            .sorted {
                if $0.isBusy != $1.isBusy { return $0.isBusy }
                return $0.statusSince > $1.statusSince
            }
    }
}

/// Where the Gemini pet keeps its caches: the same folder as Claude大小姐, so the Claude Code and Codex
/// statistics it already built are reused instead of being read again.
enum AppSupport {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeDaxiaojie")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
}
