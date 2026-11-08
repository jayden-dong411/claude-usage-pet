import AppKit
import SwiftUI

// Pet-specific settings for the shared app shell in ../Companion/CompanionApp.swift.
@MainActor
enum Spec {
    static let petID = "codex"
    static let hosts = ["com.openai.codex", "com.openai.chat"]
    static let hostName = "ChatGPT"
    static let greeting = "我是 GPT龙娘～ 点我看额度"
    static let credits = Pet.attribution + "\n\n素材仓库说明：美术资源目前没有开放授权，请勿再分发或商用。本应用只在你自己的电脑上使用这些图片。"
        + (V3Assets.available ? "\n\nv3 小人：GPT娘（白龙娘）设定图里的 8 种表情，来自 github.com/lmy414/ai-chan-sheets，角色设定 ZipZipPipe，CC BY-NC-SA 4.0；去掉了白底并缩小了尺寸。" : "")
    static let creditsURL = "https://github.com/tqlearning/ai-girl-chatgpt-pets"

    // Look: the GPT龙娘 sprite sheet, or the v3 expressions.
    static var hasSprite: Bool { Sprite.available }
    static var prefersV3: Bool { Settings.shared.useV3 }
    static var figureMenuTitle: String? { Settings.shared.useV3 ? "形象：换回 GPT龙娘" : "形象：换成 v3 小人" }
    static func toggleFigure() { Settings.shared.useV3.toggle() }

    static let stats = DashboardModel()
    static var dashboard: DashboardHook? {
        DashboardHook(title: "Codex 用量统计", start: { stats.start() }, refresh: { stats.refresh() },
                      view: { AnyView(DashboardView(dm: stats)) })
    }

    nonisolated static func lines(_ m: Mood) -> [String] {
        switch m {
        case .breezy: return ["额度还很充足，交给我吧～", "今天也要一起加油", "要不要再开一个任务？"]
        case .calm: return ["用了一些，还很从容", "我在旁边看着呢", "节奏刚刚好"]
        case .strained: return ["额度有点紧张了…", "要不要歇一会儿？", "我再检查一下"]
        case .crushed: return ["额度快见底了！", "呜…要用完了…", "让我缓一缓…"]
        case .noData: return ["还没读到 Codex 的用量", "用一次 Codex 我就知道啦"]
        case .needsYou: return ["有线程在等你回复哦", "快来看看嘛！"]
        default: return []
        }
    }

    static func pill(_ m: AppModel) -> String {
        guard let u = m.usage else { return "5h —  ·  周 —" }
        let f = { (w: LimitWindow?) in w.map { "\(Int($0.utilization.rounded()))%" } ?? "—" }
        return "5h \(f(u.fiveHour))  ·  周 \(f(u.sevenDay))"
    }

    static func hasUsage(_ m: AppModel) -> Bool { m.usage != nil }

    static func banterVars(_ m: AppModel) -> [String: String] {
        var v: [String: String] = [:]
        if let w = m.usage?.fiveHour { v["five"] = "\(Int(w.utilization.rounded()))%" }
        if let w = m.usage?.sevenDay { v["week"] = "\(Int(w.utilization.rounded()))%" }
        return v
    }

    static func panel(_ m: AppModel, _ a: PanelActions) -> AnyView {
        AnyView(PanelView(model: m, dashboard: stats, openClaude: a.openSession, openDashboard: a.openDashboard,
                          openSettings: a.openSettings, quit: a.quit))
    }

    /// Opens the thread in the ChatGPT app (codex://threads/<id>).
    static func open(_ s: SessionInfo) {
        if let url = URL(string: "codex://threads/\(s.id)"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: s.cwd))
    }

    static func loadDemo(_ m: AppModel) {
        let now = Date()
        m.usage = UsageSnapshot(fiveHour: LimitWindow(utilization: 47, resetsAt: now.addingTimeInterval(9000)),
                                sevenDay: LimitWindow(utilization: 22, resetsAt: now.addingTimeInterval(400000)),
                                plan: "Plus", source: "演示数据", observedAt: now)
        m.lastUsageUpdate = now
        m.history.loadDemo(account: "unknown", fiveHourNow: 47)
        func s(_ n: String, _ st: String, _ folder: String, _ ago: Double, _ p: TaskProgress?) -> SessionInfo {
            SessionInfo(id: UUID().uuidString, name: n, status: st, cwd: "/Users/demo/\(folder)", model: "gpt-6.1",
                        statusSince: now.addingTimeInterval(-ago), progress: p)
        }
        m.sessions = [
            s("整理会议纪要", "waiting", "notes", 60, nil),
            s("重构支付模块", "busy", "shop", 240, TaskProgress(done: 2, total: 5, current: "补充单元测试")),
            s("翻译产品文档", "idle", "docs", 2400, nil),
        ]
        stats.days = demoDays()
        stats.lastIndexed = now
    }

    static func demoDays() -> [String: DayStats] {
        var out: [String: DayStats] = [:]
        let cal = Calendar.current
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        for i in 0..<160 {
            guard let d = cal.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let wd = cal.component(.weekday, from: d)
            let busyDay = wd != 1 && wd != 7
            if rnd() < (busyDay ? 0.2 : 0.6) { continue }
            let sc = (busyDay ? 1.0 : 0.4) * (0.3 + rnd() * 1.4)
            var ds = DayStats()
            ds.tokens = TokenCounts(input: Int(300_000 * sc), output: Int(40_000 * sc), cacheWrite: 0, cacheRead: Int(3_000_000 * sc))
            ds.messages = Int(60 * sc)
            ds.activeSeconds = 3600 * 1.8 * sc
            ds.sessions = Set((0..<max(1, Int(3 * sc))).map { "s\(i)-\($0)" })
            ds.models = ["gpt-6.1": ds.tokens]
            for (p, share) in [("shop", 0.5), ("docs", 0.3), ("notes", 0.2)] {
                var ps = ProjectStat()
                ps.tokens = TokenCounts(input: Int(Double(ds.tokens.input) * share), output: Int(Double(ds.tokens.output) * share),
                                        cacheRead: Int(Double(ds.tokens.cacheRead) * share))
                ps.activeSeconds = ds.activeSeconds * share
                ds.projects[p] = ps
            }
            out[DashboardModel.key(d)] = ds
        }
        return out
    }
}
