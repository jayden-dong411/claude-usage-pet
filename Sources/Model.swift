import AppKit
import Foundation
import WebKit

enum Doro {
    static let levelNames = ["暂无数据", "活力满满", "状态良好", "注意压力", "压力山大"]

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

    static let attribution = "素材：Claude大小姐的日记本（github.com/opsCar/claude-daxiaojie-assets）· 角色设定：ZipZipPipe（胖次狐）· 设定图：lmy414/ai-chan-sheets · CC BY-NC-SA 4.0"
}

@MainActor
final class AppModel: ObservableObject {
    // Current account (Claude desktop login, else Claude Code token, else Doro's own login).
    @Published var usage: UsageSnapshot?
    @Published var usageError: String?
    @Published var needsLogin = false
    @Published var loadingUsage = false
    @Published var lastUsageUpdate: Date?

    // Optional second account, logged in inside the app with its own cookie store.
    @Published var hasSecondary = UserDefaults.standard.bool(forKey: "hasSecondaryAccount")
    @Published var secondary: UsageSnapshot?
    @Published var secondaryError: String?

    @Published var sessions: [SessionInfo] = []
    @Published var now = Date()
    @Published var face = "hi"

    var onChange: (() -> Void)?
    var onTaskFinished: ((SessionInfo) -> Void)?
    var onTaskStarted: ((SessionInfo) -> Void)?
    var onTaskWaiting: ((SessionInfo) -> Void)?
    var onUsageLoaded: ((UsageSnapshot) -> Void)?
    var onSecondaryLoaded: ((UsageSnapshot) -> Void)?

    let web = WebUsageFetcher()
    let history = UsageHistory()
    private var secondaryWeb: WebUsageFetcher?
    private var prevStatus: [String: String] = [:]
    private let tracker = ProgressTracker()
    private var timers: [Timer] = []

    static let secondaryStoreID = UUID(uuidString: "6D0C1A2E-5B7F-4C1E-9A3D-2F8E7B6C5D40")!

    var level: Int { Doro.level(for: usage) }
    var busyCount: Int { sessions.filter(\.isBusy).count }
    var waitingSessions: [SessionInfo] { sessions.filter(\.isWaiting) }

    func start() {
        refreshSessions(notify: false)
        Task { await refreshUsage() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSessions(notify: true) }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshUsage() }
        })
    }

    // MARK: Sessions

    func refreshSessions(notify: Bool) {
        var list = SessionStore.load()
        for i in list.indices { list[i].progress = tracker.progress(for: list[i].id) }
        tracker.prune(keeping: Set(list.map(\.id)))
        if notify && !prevStatus.isEmpty {
            for s in list {
                let prev = prevStatus[s.id]
                if prev == "busy" && (s.status == "idle" || s.status == "shell") { onTaskFinished?(s) }
                if s.isWaiting && prev != "waiting" { onTaskWaiting?(s) }
            }
            // Idle -> busy, or a brand-new session that is already working (not a resume after approval).
            if let s = list.first(where: { $0.isBusy && prevStatus[$0.id] != "busy" && prevStatus[$0.id] != "waiting" }) {
                onTaskStarted?(s)
            }
        }
        prevStatus = Dictionary(list.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        sessions = list
        now = Date()
        onChange?()
    }

    // MARK: Usage — current account

    func refreshUsage() async {
        if loadingUsage { return }
        loadingUsage = true
        defer { loadingUsage = false }
        await refreshPrimary()
        await refreshSecondary()
    }

    private func refreshPrimary() async {
        var errors: [String] = []

        // 1) The Claude desktop app's claude.ai login (read-only; follows its current account).
        let desktop = await Task.detached { () -> Result<[DesktopCookie], Error> in
            Result(catching: { try DesktopLogin.readCookies() })
        }.value
        var importedDesktop = false
        switch desktop {
        case .success(let cookies):
            await web.importCookies(cookies)
            importedDesktop = true
            let org = cookies.first(where: { $0.name == "lastActiveOrg" })?.value
            do {
                var snap = try await web.fetch(preferOrg: org)
                snap.source = "Claude 桌面版登录"
                apply(snap)
                return
            } catch {
                errors.append("桌面版登录：\(error.localizedDescription)")
            }
        case .failure(let error):
            errors.append("桌面版登录：\(error.localizedDescription)")
        }

        // 2) Claude Code's own login (read-only, never refreshed or rewritten here).
        let cred = await Task.detached { KeychainOAuth.read() }.value
        if let cred {
            if cred.expiresAt > Date().addingTimeInterval(30) {
                do {
                    apply(try await OAuthUsageAPI.fetch(cred))
                    return
                } catch {
                    errors.append("Claude Code 令牌：\(error.localizedDescription)")
                }
            } else {
                errors.append("Claude Code 令牌已过期")
            }
        }

        // 3) claude.ai session inside the app's own web view (only if the desktop login wasn't used).
        if importedDesktop {
            usageError = errors.joined(separator: "；")
            onChange?()
            return
        }
        do {
            apply(try await web.fetch())
            return
        } catch UsageError.notLoggedIn {
            needsLogin = true
            errors.append("claude.ai 未登录")
        } catch {
            errors.append("claude.ai：\(error.localizedDescription)")
        }
        usageError = errors.joined(separator: "；")
        onChange?()
    }

    private func apply(_ snap: UsageSnapshot) {
        usage = snap
        usageError = nil
        needsLogin = false
        lastUsageUpdate = Date()
        history.record(snap)
        onChange?()
        onUsageLoaded?(snap)
    }

    func logoutWeb() async {
        await WebUsageFetcher.logout()
        web.reset()
        if usage?.source.hasPrefix("claude.ai") == true { usage = nil }
        await refreshUsage()
    }

    // MARK: Usage — second account

    var secondaryStore: WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: Self.secondaryStoreID) }

    func enableSecondary() {
        hasSecondary = true
        UserDefaults.standard.set(true, forKey: "hasSecondaryAccount")
    }

    func refreshSecondary() async {
        guard hasSecondary else { return }
        if secondaryWeb == nil { secondaryWeb = WebUsageFetcher(store: secondaryStore) }
        do {
            var snap = try await secondaryWeb!.fetch()
            snap.source = "另一个账号"
            secondary = snap
            secondaryError = nil
            history.record(snap)
            onSecondaryLoaded?(snap)
        } catch UsageError.notLoggedIn {
            secondary = nil
            secondaryError = "还没登录"
        } catch {
            secondaryError = error.localizedDescription
        }
        onChange?()
    }

    func removeSecondary() async {
        secondaryWeb = nil
        secondary = nil
        secondaryError = nil
        hasSecondary = false
        UserDefaults.standard.set(false, forKey: "hasSecondaryAccount")
        try? await WKWebsiteDataStore.remove(forIdentifier: Self.secondaryStoreID)
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
        guard let date else { return "尚未开始计时" }
        return "\(duration(date.timeIntervalSince(now)))后重置 · \(when(date))"
    }

    /// "18:30" today, "明天 09:00", or "11月11日 周三 19:25".
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) { f.dateFormat = "HH:mm"; return f.string(from: date) }
        if cal.isDateInTomorrow(date) { f.dateFormat = "HH:mm"; return "明天 " + f.string(from: date) }
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
