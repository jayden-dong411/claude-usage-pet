import AppKit
import SwiftUI

// MARK: - Colours that follow light / dark mode

enum Theme {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static let pillFill = dynamic(rgb(1, 0.96, 0.90, 0.95), rgb(0.17, 0.15, 0.13, 0.92))
    static let pillText = dynamic(rgb(0.45, 0.25, 0.10), rgb(0.99, 0.80, 0.58))
    static let pillBorder = dynamic(rgb(0.95, 0.62, 0.30, 0.9), rgb(0.95, 0.55, 0.20, 0.55))

    static let chipFill = dynamic(rgb(1, 1, 1, 0.95), rgb(0.15, 0.15, 0.15, 0.92))
    static let chipText = dynamic(rgb(0.15, 0.15, 0.15), rgb(0.93, 0.93, 0.93))
    static let chipBorder = dynamic(rgb(1, 0.58, 0, 0.8), rgb(1, 0.58, 0, 0.5))
    static let chipAlertBorder = dynamic(rgb(0.90, 0.25, 0.25, 0.9), rgb(1, 0.38, 0.35, 0.8))

    static let bubbleFill = dynamic(rgb(1, 1, 1), rgb(0.20, 0.18, 0.17, 0.97))
    static let bubbleText = dynamic(rgb(0.15, 0.15, 0.15), rgb(0.96, 0.96, 0.96))
}

// MARK: - User settings (UserDefaults backed)

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// Called after any change so the pet can re-layout.
    var onChange: (() -> Void)?

    @Published var scale: Double { didSet { save("scale", scale) } }
    @Published var opacity: Double { didSet { save("opacity", opacity) } }
    @Published var rotateSeconds: Double { didSet { save("rotateSeconds", rotateSeconds) } }
    @Published var onlyWithClaude: Bool { didSet { save("onlyWithClaude", onlyWithClaude) } }
    @Published var hideInFullscreen: Bool { didSet { save("hideInFullscreen", hideInFullscreen) } }
    @Published var chatter: Bool { didSet { save("chatter", chatter) } }
    @Published var alertWaiting: Bool { didSet { save("alertWaiting", alertWaiting) } }

    private init() {
        let d = UserDefaults.standard
        func num(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        func flag(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        scale = num("scale", 1.0)
        opacity = num("opacity", 1.0)
        rotateSeconds = num("rotateSeconds", 35)
        onlyWithClaude = flag("onlyWithClaude", true)
        hideInFullscreen = flag("hideInFullscreen", false)
        chatter = flag("chatter", true)
        alertWaiting = flag("alertWaiting", true)
    }

    private func save(_ key: String, _ value: Any) {
        d.set(value, forKey: key)
        onChange?()
    }

    func reset() {
        scale = 1.0; opacity = 1.0; rotateSeconds = 35
        onlyWithClaude = true; hideInFullscreen = false; chatter = true; alertWaiting = true
    }
}

struct SettingsView: View {
    @ObservedObject var s = Settings.shared

    var body: some View {
        Form {
            Section("外观") {
                LabeledContent("大小") {
                    HStack {
                        Slider(value: $s.scale, in: 0.6...1.6, step: 0.05)
                        Text("\(Int(s.scale * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("透明度") {
                    HStack {
                        Slider(value: $s.opacity, in: 0.3...1.0, step: 0.05)
                        Text("\(Int(s.opacity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("表情轮换间隔") {
                    HStack {
                        Slider(value: $s.rotateSeconds, in: 10...180, step: 5)
                        Text("约 \(Int(s.rotateSeconds)) 秒").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                Toggle("偶尔说句话", isOn: $s.chatter)
            }
            Section("什么时候出现") {
                Toggle("只在 Claude 在前台时显示", isOn: $s.onlyWithClaude)
                Toggle("Claude 全屏时隐藏", isOn: $s.hideInFullscreen)
            }
            Section("提醒") {
                Toggle("会话等你批准或回复时提醒", isOn: $s.alertWaiting)
            }
            HStack {
                Spacer()
                Button("恢复默认") { s.reset() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
