import AppKit
import SwiftUI

// Pet-specific settings for the shared app shell in ../Companion/CompanionApp.swift.
@MainActor
enum Spec {
    static let petID = "gemini"
    static let hosts = ["com.google.antigravity"]
    static let hostName = "Antigravity"
    static let greeting = "我是 Gemini娘～ 点我看 Gemini 额度"
    static let credits = Pet.attribution + "\n\n形象是 ai-chan-sheets 仓库里 Gemini娘设定图的表情：8 种原表情由 AI（Codex 生图）重画成完整的半身像，补全了被裁掉的头发，另外 8 种是同样画风新画的；本应用去掉了白底并缩小了尺寸。按 CC BY-NC-SA 4.0 署名、非商业使用。"
    static let creditsURL = "https://github.com/lmy414/ai-chan-sheets"

    static let hasSprite = false
    static let prefersV3 = true
    static let figureMenuTitle: String? = nil
    static func toggleFigure() {}

    /// Gemini, Claude Code and Codex statistics in one window (the shared DashboardView).
    static let stats = DashboardModel()
    static var dashboard: DashboardHook? {
        DashboardHook(title: "Gemini 用量统计", start: { stats.start() }, refresh: { stats.refresh() },
                      view: { AnyView(DashboardView(dm: stats, source: .gemini).background(Color(nsColor: .windowBackgroundColor))) })
    }

    nonisolated static func lines(_ m: Mood) -> [String] {
        switch m {
        case .breezy: return ["额度还很充足，想问什么都行～", "星星都在为你闪～", "今天也一起探索吧！"]
        case .calm: return ["Gemini 额度用了一些啦", "节奏刚刚好", "我在帮你盯着额度呢"]
        case .strained: return ["Gemini 额度有点紧张了…", "要不要先歇一会儿？"]
        case .crushed: return ["Gemini 额度快用完了！", "呜…星星要熄灭了…"]
        case .noData: return ["还没读到 Antigravity 的额度", "打开一次 Antigravity 我就知道啦"]
        case .needsYou: return ["有对话在等你哦", "快来看看嘛！"]
        default: return []
        }
    }

    static func pill(_ m: AppModel) -> String {
        guard let w = m.gemini else { return "Gemini —" }
        return "Gemini \(Int(w.utilization.rounded()))%" + (m.week.map { " · 周 \(Int($0.utilization.rounded()))%" } ?? "")
    }

    static func hasUsage(_ m: AppModel) -> Bool { m.usage != nil }

    static func banterVars(_ m: AppModel) -> [String: String] {
        guard let w = m.gemini else { return [:] }
        var v = ["quota": "\(Int(w.utilization.rounded()))%"]
        if let wk = m.week { v["week"] = "\(Int(wk.utilization.rounded()))%" }
        return v
    }

    static func panel(_ m: AppModel, _ a: PanelActions) -> AnyView {
        AnyView(PanelView(model: m, stats: stats, openClaude: a.openSession, openDashboard: a.openDashboard,
                          openSettings: a.openSettings, quit: a.quit))
    }

    /// Antigravity has no per-conversation deep link; bring the app forward.
    static func open(_ s: SessionInfo) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    static func loadDemo(_ m: AppModel) {
        let now = Date()
        m.usage = PeerUsage(provider: "gemini", title: "Gemini", plan: "Google AI Ultra",
                            windows: [PeerWindow(label: "5 小时", utilization: 35, resetsAt: now.addingTimeInterval(4800)),
                                      PeerWindow(label: "每周", utilization: 12, resetsAt: now.addingTimeInterval(520000)),
                                      PeerWindow(label: "Claude 等 · 5 小时", utilization: 8, resetsAt: now.addingTimeInterval(14000)),
                                      PeerWindow(label: "Claude 等 · 每周", utilization: 3, resetsAt: now.addingTimeInterval(530000))],
                            observedAt: now.addingTimeInterval(-30), short: "Gemini 35% · 周 12%")
        m.connected = true
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
        func s(_ n: String, _ st: String, _ detail: String, _ steps: Int, _ ago: Double) -> SessionInfo {
            SessionInfo(id: UUID().uuidString, name: n, status: st, detail: detail, steps: steps,
                        statusSince: now.addingTimeInterval(-ago), progress: nil)
        }
        m.sessions = [
            s("WebGPU 果冻岛模拟", "busy", "jelly-island", 64, 30),
            s("主题补丁安装", "idle", "antigravity default", 28, 1500),
            s("整理论文图表", "idle", "papers", 41, 7200),
        ]
    }
}
