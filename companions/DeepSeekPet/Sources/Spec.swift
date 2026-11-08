import AppKit
import SwiftUI

// Pet-specific settings for the shared app shell in ../Companion/CompanionApp.swift.
@MainActor
enum Spec {
    static let petID = "deepseek"
    static let hosts = ["com.deepseek.dsh"]
    static let hostName = "DeepSeek Harness"
    static let greeting = "我是 DeepSeek娘～ 点我看余额"
    static let credits = Pet.attribution + "\n\n形象是 ai-chan-sheets 仓库第 12 条「DeepSeek娘 Q版冬装」里第 2 套「冬装小肥鱼2」设定图的 8 种表情，本应用去掉了白底并缩小了尺寸。设定图补全部分按 CC BY-NC-SA 4.0 授权（署名、非商业使用）；该条来源图的作者未标注。"
    static let creditsURL = "https://github.com/lmy414/ai-chan-sheets"

    static let hasSprite = false
    static let prefersV3 = true
    static let figureMenuTitle: String? = nil
    static func toggleFigure() {}

    static let stats = DSDashboardModel()
    static var dashboard: DashboardHook? {
        DashboardHook(title: "DeepSeek 用量统计", start: { stats.start() }, refresh: { stats.refresh() },
                      view: { AnyView(DSDashboardView(dm: stats)) })
    }

    nonisolated static func lines(_ m: Mood) -> [String] {
        switch m {
        case .breezy: return ["余额还很充足，放心用吧～", "今天也一起加油！", "鲸鱼游来游去～"]
        case .calm: return ["余额还行，省着点花哦", "我在帮你盯着账单呢", "节奏刚刚好"]
        case .strained: return ["余额不多了，记得充值…", "要不要换个便宜点的模型？"]
        case .crushed: return ["余额快见底了！", "呜…要没钱了…"]
        case .noData: return ["还没读到 DeepSeek 余额", "打开一次 DeepSeek Harness 我就知道啦"]
        case .needsYou: return ["有会话在等你回答哦", "快来看看嘛！"]
        default: return []
        }
    }

    static func pill(_ m: AppModel) -> String {
        guard let u = m.usage else { return "余额 —" }
        return "余额 \(u.money(u.balance)) · 今天 \(u.money(u.today))"
    }

    static func hasUsage(_ m: AppModel) -> Bool { m.usage != nil }

    static func panel(_ m: AppModel, _ a: PanelActions) -> AnyView {
        AnyView(PanelView(model: m, stats: stats, openClaude: a.openSession, openDashboard: a.openDashboard,
                          openSettings: a.openSettings, quit: a.quit))
    }

    /// DeepSeek Harness has no session deep link; bring the app forward.
    static func open(_ s: SessionInfo) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.deepseek.dsh") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    static func loadDemo(_ m: AppModel) {
        let now = Date()
        m.usage = DeepSeekBalance(balance: 16.96, today: 1.04, week: 18.7, currency: "CNY",
                                  observedAt: now.addingTimeInterval(-120), history: [:])
        func s(_ n: String, _ st: String, _ detail: String, _ ago: Double) -> SessionInfo {
            SessionInfo(id: UUID().uuidString, name: n, status: st, detail: detail,
                        statusSince: now.addingTimeInterval(-ago), progress: nil)
        }
        m.sessions = [
            s("整理实验数据", "busy", "research", 40),
            s("修改 dsh 壁纸", "waiting", "default-workspace", 300),
            s("翻译论文摘要", "idle", "papers", 4800),
        ]
    }
}
