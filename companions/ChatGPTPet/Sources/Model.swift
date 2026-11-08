import AppKit
import Foundation

enum Pet {
    static let levelNames = ["暂无数据", "活力满满", "状态良好", "注意额度", "额度告急"]
    static let name = "GPT龙娘"

    static func level(for u: UsageSnapshot?) -> Int {
        guard let u else { return 0 }
        let vals = [u.fiveHour?.utilization, u.sevenDay?.utilization].compactMap { $0 }
        guard let m = vals.max() else { return 0 }
        switch m {
        case ..<40: return 1
        case ..<70: return 2
        case ..<90: return 3
        default: return 4
        }
    }

    static let attribution = "形象：GPT龙娘（github.com/tqlearning/ai-girl-chatgpt-pets，AI 辅助生成的二创素材）· 角色设定：ZipZipPipe · 美术资源未开放授权，仅限本机个人使用"
}

@MainActor
final class AppModel: ObservableObject {
    @Published var usage: UsageSnapshot?
    @Published var usageError: String?
    @Published var sessions: [SessionInfo] = []
    @Published var lastUsageUpdate: Date?
    @Published var now = Date()
    /// Image currently on screen (shown in the panel header too).
    @Published var frame: NSImage?
    /// Claude and Grok usage shown alongside Codex (see Peers.swift).
    @Published var peers: [PeerUsage] = []
    private var lastShared: Date?

    var onChange: (() -> Void)?
    var onTaskFinished: ((SessionInfo) -> Void)?
    var onTaskStarted: ((SessionInfo) -> Void)?
    var onTaskWaiting: ((SessionInfo) -> Void)?

    let history = UsageHistory()
    private let reader = CodexReader()
    /// Live limits from the ChatGPT account (preferred over the local logs while fresh).
    private var live: UsageSnapshot?
    /// Why the live query failed, if it did.
    @Published var liveError: String?
    private var prevStatus: [String: String] = [:]
    private var timer: Timer?
    private var busyReading = false

    var level: Int { Pet.level(for: usage) }
    var busyCount: Int { sessions.filter(\.isBusy).count }
    var waitingSessions: [SessionInfo] { sessions.filter(\.isWaiting) }

    func refreshPeers() {
        Task.detached {
            let p = PeerStore.peers(excluding: "codex")
            await MainActor.run { self.peers = p; self.onChange?() }
        }
    }

    /// Asks the ChatGPT account for the current limits (CodexLive in Peers.swift).
    func refreshLive() {
        Task.detached {
            let l = CodexLive.fetch(maxAge: 50)
            let err = CodexLive.error
            await MainActor.run {
                self.liveError = l == nil ? err : nil
                guard let l else { return }
                var s = UsageSnapshot(fiveHour: LimitWindow(utilization: l.fiveHour, resetsAt: l.fiveReset),
                                      sevenDay: LimitWindow(utilization: l.week, resetsAt: l.weekReset),
                                      source: "ChatGPT 账号", observedAt: l.at)
                s.plan = l.plan
                s.account = "live"          // separate history series from the log readings
                self.live = s
                PeerStore.write(PeerUsage(          // let the other pets show it too
                    provider: "codex", title: "ChatGPT · Codex", plan: s.plan,
                    windows: [PeerWindow(label: "5 小时", utilization: l.fiveHour, resetsAt: l.fiveReset),
                              PeerWindow(label: "每周", utilization: l.week, resetsAt: l.weekReset)],
                    observedAt: l.at))
                self.refresh(notify: false)
            }
        }
    }

    func start() {
        refresh(notify: false)
        refreshLive()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLive() }
        }
        refreshPeers()
        Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPeers() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(notify: true) }
        }
    }

    /// Reads new log lines off the main thread, then publishes.
    func refresh(notify: Bool) {
        guard !busyReading else { return }
        busyReading = true
        let reader = self.reader
        Task.detached {
            let r = reader.refresh()
            await MainActor.run { self.apply(r.sessions, r.usage, notify: notify) }
        }
    }

    private func apply(_ list: [SessionInfo], _ snap: UsageSnapshot?, notify: Bool) {
        busyReading = false
        if notify && !prevStatus.isEmpty {
            for s in list {
                let prev = prevStatus[s.id]
                if prev == "busy" && s.status == "idle" { onTaskFinished?(s) }
                if s.isWaiting && prev != "waiting" { onTaskWaiting?(s) }
            }
            if let s = list.first(where: { $0.isBusy && prevStatus[$0.id] != "busy" && prevStatus[$0.id] != "waiting" }) {
                onTaskStarted?(s)
            }
        }
        prevStatus = Dictionary(list.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        sessions = list
        // Live account data wins while it is less than 10 minutes old; the logs are the fallback.
        let liveFresh = live.flatMap { Date().timeIntervalSince($0.observedAt) < 600 ? $0 : nil }
        if let snap = liveFresh ?? snap {
            if liveFresh == nil, lastShared != snap.observedAt {      // logs only: still share them
                lastShared = snap.observedAt
                PeerStore.write(PeerUsage(
                    provider: "codex", title: "ChatGPT · Codex", plan: snap.plan,
                    windows: [snap.fiveHour.map { PeerWindow(label: "5 小时", utilization: $0.utilization, resetsAt: $0.resetsAt) },
                              snap.sevenDay.map { PeerWindow(label: "每周", utilization: $0.utilization, resetsAt: $0.resetsAt) }].compactMap { $0 },
                    observedAt: snap.observedAt))
            }
            usage = snap
            usageError = nil
            lastUsageUpdate = snap.observedAt
            history.record(snap)
        } else {
            usageError = "还没在 Codex 日志里找到额度记录。用 ChatGPT 里的 Codex 发一条消息后就会出现。"
        }
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

    static func resetText(_ date: Date?, now: Date) -> String {
        guard let date else { return "新窗口还没开始计时（下次使用时开始）" }
        return "\(duration(date.timeIntervalSince(now)))后重置 · \(when(date))"
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

    static func pct(_ v: Double) -> String {
        v >= 10 ? "\(Int(v.rounded()))%" : String(format: "%.1f%%", v)
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
