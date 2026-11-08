import AppKit
import SwiftUI

// Pet-specific settings for the shared app shell in ../Companion/CompanionApp.swift.
@MainActor
enum Spec {
    static let petID = "grok"
    static let hosts = ["com.anysphere.sand"]
    static let hostName = "Grok Bot"
    static let greeting = "我是 Grok娘～ 点我看 Grok Bot 额度"
    static let credits = Pet.attribution + "\n\n形象是 ai-chan-sheets 仓库里 Grok娘设定图的 8 种表情，本应用去掉了白底并缩小了尺寸。按 CC BY-NC-SA 4.0 署名、非商业使用。"
    static let creditsURL = "https://github.com/lmy414/ai-chan-sheets"

    static let hasSprite = false
    static let prefersV3 = true
    static let figureMenuTitle: String? = nil
    static func toggleFigure() {}
    /// Grok Bot keeps only a weekly percentage, no daily history to chart.
    static let dashboard: DashboardHook? = nil

    nonisolated static func lines(_ m: Mood) -> [String] {
        switch m {
        case .breezy: return ["额度还很充足，尽管来问吧～", "有什么想问的尽管来！", "嘿嘿，要不要来点刺激的问题？"]
        case .calm: return ["这周已经用了不少啦", "本小姐火力全开中～", "节奏刚刚好"]
        case .strained: return ["这周额度有点紧张了…", "要不要歇一会儿？"]
        case .crushed: return ["这周额度快用完了！", "让我缓一缓…"]
        case .noData: return ["还没读到 Grok Bot 的额度", "打开一次 Grok Bot 我就知道啦"]
        case .needsYou: return ["有机器人在等你回复哦", "快来看看嘛！"]
        default: return []
        }
    }

    static func pill(_ m: AppModel) -> String {
        guard let w = m.usage?.windows.first else { return "本周 —" }
        return "本周 \(Int(w.utilization.rounded()))%"
    }

    static func hasUsage(_ m: AppModel) -> Bool { m.usage != nil }

    static func banterVars(_ m: AppModel) -> [String: String] {
        guard let w = m.usage?.windows.first else { return [:] }
        return ["week": "\(Int(w.utilization.rounded()))%"]
    }

    static func panel(_ m: AppModel, _ a: PanelActions) -> AnyView {
        AnyView(PanelView(model: m, openClaude: a.openSession, openSettings: a.openSettings, quit: a.quit))
    }

    /// Grok Bot has no per-bot deep link; bring the app forward.
    static func open(_ s: SessionInfo) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anysphere.sand") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    static func loadDemo(_ m: AppModel) {
        let now = Date()
        m.usage = PeerUsage(provider: "grok", title: "Grok Bot", plan: "Premium",
                            windows: [PeerWindow(label: "每周", utilization: 43, resetsAt: now.addingTimeInterval(370000))],
                            observedAt: now.addingTimeInterval(-60))
        m.peers = [
            PeerUsage(provider: "claude", title: "Claude", plan: "Max",
                      windows: [PeerWindow(label: "5 小时", utilization: 63, resetsAt: now.addingTimeInterval(7800)),
                                PeerWindow(label: "每周", utilization: 28, resetsAt: now.addingTimeInterval(340000))],
                      observedAt: now.addingTimeInterval(-120)),
            PeerUsage(provider: "codex", title: "ChatGPT · Codex", plan: "Plus",
                      windows: [PeerWindow(label: "5 小时", utilization: 22, resetsAt: now.addingTimeInterval(9000)),
                                PeerWindow(label: "每周", utilization: 47, resetsAt: now.addingTimeInterval(300000))],
                      observedAt: now.addingTimeInterval(-600)),
        ]
        func s(_ n: String, _ st: String, _ detail: String, _ ago: Double) -> SessionInfo {
            SessionInfo(id: UUID().uuidString, name: n, status: st, detail: detail,
                        statusSince: now.addingTimeInterval(-ago), progress: nil)
        }
        m.sessions = [
            s("行程规划", "busy", "正在查东京到札幌的航班…", 40),
            s("邮件助手", "waiting", "有 3 封邮件需要你确认回复方式", 300),
            s("读书笔记", "idle", "第 6 章的要点已经整理好了", 4800),
        ]
    }
}
