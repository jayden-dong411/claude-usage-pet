import AppKit
import Foundation

enum Pet {
    static let levelNames = ["暂无数据", "额度充足", "状态良好", "注意额度", "额度告急"]
    static let name = "Gemini娘"

    static let attribution = "形象：Gemini娘设定图 · github.com/lmy414/ai-chan-sheets 第 10 条 · 角色设定：ZipZipPipe · CC BY-NC-SA 4.0（非商业使用）"
}

@MainActor
final class AppModel: ObservableObject {
    /// Antigravity's quotas (Gemini models first).
    @Published var usage: PeerUsage?
    @Published var sessions: [SessionInfo] = []
    /// False while Antigravity is closed (the conversation list can't be read then).
    @Published var connected = false
    @Published var now = Date()
    /// Current expression (shown in the panel header).
    @Published var frame: NSImage?
    /// Claude / Codex / Grok Bot / DeepSeek usage shown alongside Gemini's (see Peers.swift).
    @Published var peers: [PeerUsage] = []

    var onChange: (() -> Void)?
    var onTaskFinished: ((SessionInfo) -> Void)?
    var onTaskStarted: ((SessionInfo) -> Void)?
    var onTaskWaiting: ((SessionInfo) -> Void)?
    var onTaskResumed: ((SessionInfo) -> Void)?

    private var prevStatus: [String: String] = [:]
    private var busyReading = false

    /// The Gemini models' quota (the first window).
    var gemini: PeerWindow? { usage?.windows.first }

    var level: Int {
        guard let u = gemini?.utilization else { return 0 }
        switch u {
        case ..<40: return 1
        case ..<70: return 2
        case ..<90: return 3
        default: return 4
        }
    }
    var busyCount: Int { sessions.filter(\.isBusy).count }
    var waitingSessions: [SessionInfo] { sessions.filter(\.isWaiting) }

    func start() {
        refresh(notify: false)
        refreshPeers()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(notify: true) }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPeers() }
        }
    }

    func refresh(notify: Bool) {
        guard !busyReading else { return }
        busyReading = true
        Task.detached {
            let list = GeminiReader.sessions()
            await MainActor.run { self.apply(list, notify: notify) }
        }
    }

    func refreshPeers() {
        Task.detached {
            let p = PeerStore.peers(excluding: "gemini")
            let u = GeminiPeer.read()
            await MainActor.run { self.peers = p; self.usage = u; self.onChange?() }
        }
    }

    private func apply(_ list: [SessionInfo]?, notify: Bool) {
        busyReading = false
        connected = list != nil
        let list = list ?? []
        if notify && !prevStatus.isEmpty {
            for s in list where prevStatus[s.id] == "busy" && s.status == "idle" { onTaskFinished?(s) }
            if let s = list.first(where: { $0.isBusy && prevStatus[$0.id] != "busy" }) { onTaskStarted?(s) }
        }
        prevStatus = Dictionary(list.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        sessions = list
        now = Date()
        onChange?()
    }
}

// MARK: - Formatting

enum Fmt {
    static func duration(_ secs: TimeInterval) -> String {
        let s = max(0, Int(secs))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)天\(h)小时" }
        if h > 0 { return "\(h)小时\(m)分" }
        if m > 0 { return "\(m)分钟" }
        return "不到1分钟"
    }

    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) { f.dateFormat = "HH:mm"; return f.string(from: date) }
        if cal.isDateInTomorrow(date) { f.dateFormat = "HH:mm"; return "明天 " + f.string(from: date) }
        if cal.isDateInYesterday(date) { f.dateFormat = "HH:mm"; return "昨天 " + f.string(from: date) }
        f.dateFormat = "M月d日 EEE HH:mm"
        return f.string(from: date)
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
