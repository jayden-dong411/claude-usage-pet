import AppKit
import ServiceManagement
import SwiftUI
import WebKit

@main
struct DoroPetMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
        app.run()
    }
}

let claudeBundleID = "com.anthropic.claudefordesktop"

// MARK: - Pet view (click = panel, drag = move, right click = menu)

final class PetView: NSView {
    var onClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - startMouse.x, dy = p.y - startMouse.y
        if !dragging && hypot(dx, dy) > 3 { dragging = true; onDragStart?() }
        if dragging { window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { onDragEnd?() } else { onClick?() }
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        if let m = menuProvider?() { NSMenu.popUpContextMenu(m, with: event, for: self) }
    }
}

/// Small rounded label whose colours follow light / dark mode.
final class Chip: NSView {
    let label = NSTextField(labelWithString: "")
    var padding = NSSize(width: 8, height: 3)
    var fill: NSColor { didSet { applyColors() } }
    var border: NSColor? { didSet { applyColors() } }
    var borderWidth: CGFloat = 1 { didSet { applyColors() } }

    init(fill: NSColor, text: NSColor, border: NSColor? = nil, font: NSFont) {
        self.fill = fill
        self.border = border
        super.init(frame: .zero)
        wantsLayer = true
        label.font = font
        label.textColor = text
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        addSubview(label)
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = border?.cgColor
            layer?.borderWidth = border == nil ? 0 : borderWidth
        }
    }

    /// Lays the chip out centred horizontally at `y`, wrapping at `maxWidth`.
    func set(_ text: String, centerX: CGFloat, y: CGFloat, maxWidth: CGFloat, radius: CGFloat? = nil) {
        label.stringValue = text
        label.preferredMaxLayoutWidth = maxWidth - padding.width * 2
        let s = label.sizeThatFits(NSSize(width: maxWidth - padding.width * 2, height: 200))
        let w = ceil(min(maxWidth, s.width + padding.width * 2))
        let h = ceil(s.height + padding.height * 2)
        frame = NSRect(x: round(centerX - w / 2), y: y, width: w, height: h)
        label.frame = NSRect(x: padding.width, y: padding.height, width: w - padding.width * 2, height: s.height)
        layer?.cornerRadius = radius ?? h / 2
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let model = AppModel()
    let dashboard = DashboardModel()
    let settings = Settings.shared

    private var panel: NSPanel!
    private var petView: PetView!
    private var imageView: NSImageView!
    private var pill: Chip!
    private var taskChip: Chip!
    private var bubble: Chip!
    private var popover: NSPopover?
    private var loginWC: LoginWindowController?
    private var loginIsSecondary = false
    private var loginPoll: Timer?
    private var bubbleHide: DispatchWorkItem?
    private var windows: [String: NSWindow] = [:]
    private var snapshotMode = false

    // Expression rotation: a base face from the current moods, swapped every few tens of
    // seconds, with short "reactions" (click, task done, ...) on top.
    private var face: String?
    private var reactionUntil = Date.distantPast
    private var nextRotate = Date.distantPast
    private var moodKey = ""
    private var faceTimer: Timer?
    private var lastNudge = Date.distantPast

    // Layout in base units (scaled by Settings.scale), top-down: bubble, head, tasks, usage pill.
    private let baseSize = NSSize(width: 220, height: 300)
    private let imgSize: CGFloat = 140
    private let imgY: CGFloat = 116
    private var belowHead: CGFloat { imgY + 4 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        snapshotMode = CommandLine.arguments.contains("--snapshot")
        buildPanel()
        model.onChange = { [weak self] in self?.refreshPet() }
        model.onTaskFinished = { [weak self] s in self?.react(.taskDone, say: "「\(s.name)」完成了哦～") }
        model.onTaskStarted = { [weak self] s in self?.react(.taskStarted, say: "「\(s.name)」开工！") }
        model.onTaskWaiting = { [weak self] s in
            guard let self, self.settings.alertWaiting else { return }
            self.lastNudge = Date()
            self.react(.needsYou, seconds: 8, say: "「\(s.name)」\(s.waitingLabel)～")
        }
        model.onUsageLoaded = { [weak self] _ in
            guard let self, self.loginWC != nil, !self.loginIsSecondary else { return }
            self.closeLogin()
            self.react(.greet, say: "登录成功，本小姐看到用量了～")
        }
        model.onSecondaryLoaded = { [weak self] s in
            guard let self, self.loginWC != nil, self.loginIsSecondary else { return }
            self.closeLogin()
            self.react(.greet, say: "另一个账号（\(s.account ?? "")）也接上啦～")
        }
        settings.onChange = { [weak self] in self?.applySettings() }
        model.start()
        dashboard.start()
        react(.greet, say: "本小姐驾到～ 点我看用量")
        faceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickFace()
                self?.updateVisibility()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        updateVisibility()

        // Debug: `DoroPet --snapshot <dir> [--demo] [--wait s]` writes pet.png / panel.png / dashboard.png and quits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            let wait = args.firstIndex(of: "--wait").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 10
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                if args.contains("--demo"), let self {
                    let f = ISO8601DateFormatter()
                    var snap = UsageSnapshot(source: "演示数据")
                    UsageParser.apply([
                        "five_hour": ["utilization": 63.0, "resets_at": f.string(from: Date().addingTimeInterval(7800))],
                        "seven_day": ["utilization": 28.0, "resets_at": f.string(from: Date().addingTimeInterval(340000))],
                    ], to: &snap)
                    snap.account = "demo@example.com"; snap.plan = "Max"
                    self.model.usage = snap; self.model.needsLogin = false; self.model.lastUsageUpdate = Date()
                    var s2 = snap; s2.account = "other@example.com"; s2.plan = "Pro"
                    UsageParser.apply([
                        "five_hour": ["utilization": 18.0, "resets_at": f.string(from: Date().addingTimeInterval(12000))],
                        "seven_day": ["utilization": 41.0, "resets_at": f.string(from: Date().addingTimeInterval(200000))],
                    ], to: &s2)
                    self.model.hasSecondary = true; self.model.secondary = s2; self.model.secondaryError = nil
                    self.model.history.loadDemo(account: "demo@example.com", fiveHourNow: 63)
                    self.model.sessions = Self.demoSessions()
                    self.dashboard.days = Self.demoDays()
                    self.dashboard.lastIndexed = Date()
                    self.refreshPet()
                    self.setFace("ojou_laugh")
                    self.say("本小姐驾到～ 点我看用量")
                }
                self?.writeSnapshots(to: dir)
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Demo data for README screenshots (no real sessions or accounts)

    static func demoSessions() -> [SessionInfo] {
        let now = Date()
        func s(_ name: String, _ status: String, _ folder: String, ago: Double, wait: String? = nil,
               _ done: Int, _ total: Int, _ step: String?) -> SessionInfo {
            var x = SessionInfo(id: UUID().uuidString, pid: 1, name: name, status: status, cwd: "/Users/demo/\(folder)",
                                entrypoint: "claude-desktop", startedAt: now.addingTimeInterval(-ago - 600),
                                statusSince: now.addingTimeInterval(-ago), waitingFor: wait)
            x.progress = TaskProgress(done: done, total: total, current: step)
            return x
        }
        return [
            s("重构登录模块", "waiting", "web-app", ago: 90, wait: "permission prompt", 2, 5, "运行数据库迁移"),
            s("写周报", "busy", "notes", ago: 320, 3, 4, "整理本周完成的事项"),
            s("修复图表显示问题", "idle", "dashboard", ago: 1500, 4, 4, nil),
            s("翻译 README", "idle", "docs", ago: 5400, 2, 2, nil),
        ]
    }

    static func demoDays() -> [String: DayStats] {
        var out: [String: DayStats] = [:]
        let cal = Calendar.current
        var seed: UInt64 = 42
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        for i in 0..<200 {
            guard let d = cal.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let weekday = cal.component(.weekday, from: d)
            let busyDay = weekday != 1 && weekday != 7
            if rnd() < (busyDay ? 0.15 : 0.55) { continue }
            let scale = (busyDay ? 1.0 : 0.4) * (0.3 + rnd() * 1.4) * (i < 60 ? 1.0 : 0.6)
            var ds = DayStats()
            ds.tokens = TokenCounts(input: Int(2_000 * scale), output: Int(180_000 * scale),
                                    cacheWrite: Int(1_800_000 * scale), cacheRead: Int(60_000_000 * scale))
            ds.messages = Int(120 * scale)
            ds.activeSeconds = 3600 * 2.5 * scale
            ds.sessions = Set((0..<max(1, Int(4 * scale))).map { "s\(i)-\($0)" })
            ds.models = ["claude-opus-5-5": ds.tokens, "claude-haiku-5-5": TokenCounts(output: Int(9_000 * scale), cacheRead: Int(900_000 * scale))]
            for (p, share) in [("web-app", 0.45), ("dashboard", 0.25), ("notes", 0.18), ("docs", 0.12)] {
                var ps = ProjectStat()
                ps.tokens = TokenCounts(output: Int(Double(ds.tokens.output) * share), cacheWrite: Int(Double(ds.tokens.cacheWrite) * share),
                                        cacheRead: Int(Double(ds.tokens.cacheRead) * share))
                ps.activeSeconds = ds.activeSeconds * share
                ds.projects[p] = ps
            }
            out[DashboardModel.key(d)] = ds
        }
        return out
    }

    private func writeSnapshots(to dir: URL) {
        func png(_ v: NSView, _ name: String) {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
        for (name, look) in [("pet.png", NSAppearance.Name.aqua), ("pet-dark.png", .darkAqua)] {
            petView.appearance = NSAppearance(named: look)
            petView.layoutSubtreeIfNeeded()
            png(petView, name)
        }
        petView.appearance = nil
        // Light-mode copies of the panel and dashboard too.
        for (name, view) in [("panel-light.png", AnyView(PanelView(model: model, dashboard: dashboard, openLogin: {}, openClaude: { _ in }, quit: {}))),
                             ("dashboard-light.png", AnyView(DashboardView(dm: dashboard)))] {
            let h = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            h.appearance = NSAppearance(named: .aqua)
            h.frame = NSRect(origin: .zero, size: name.hasPrefix("dash") ? NSSize(width: 800, height: 1100) : h.fittingSize)
            h.layoutSubtreeIfNeeded()
            png(h, name)
        }
        let host = NSHostingView(rootView: PanelView(model: model, dashboard: dashboard, openLogin: {}, openClaude: { _ in }, quit: {})
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        png(host, "panel.png")
        let dash = NSHostingView(rootView: DashboardView(dm: dashboard).background(Color(nsColor: .windowBackgroundColor)))
        dash.frame = NSRect(x: 0, y: 0, width: 800, height: 1100)
        dash.layoutSubtreeIfNeeded()
        png(dash, "dashboard.png")
        let set = NSHostingView(rootView: SettingsView().background(Color(nsColor: .windowBackgroundColor)))
        set.frame = NSRect(origin: .zero, size: set.fittingSize)
        set.layoutSubtreeIfNeeded()
        png(set, "settings.png")
        let t = dashboard.today
        let info = "face=\(model.face) moods=\(moodKey) level=\(model.level) usage=\(model.usage != nil) sessions=\(model.sessions.count) waiting=\(model.waitingSessions.count) indexedDays=\(dashboard.days.count) today: active=\(Int(t.activeSeconds))s tokens=\(t.tokens.total) msgs=\(t.messages) sessions=\(t.sessions.count)"
        try? info.write(to: dir.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Pet window

    private func buildPanel() {
        panel = NSPanel(contentRect: NSRect(origin: savedOrigin(), size: baseSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        petView = PetView(frame: NSRect(origin: .zero, size: baseSize))
        petView.onClick = { [weak self] in
            guard let self else { return }
            if self.popover?.isShown != true { self.react(.clicked, seconds: 4) }
            self.togglePopover()
        }
        petView.onDragStart = { [weak self] in self?.popover?.performClose(nil) }
        petView.onDragEnd = { [weak self] in self?.saveOrigin() }
        petView.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }

        imageView = NSImageView(frame: NSRect(x: (baseSize.width - imgSize) / 2, y: imgY, width: imgSize, height: imgSize))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        petView.addSubview(imageView)

        pill = Chip(fill: Theme.pillFill, text: Theme.pillText, border: Theme.pillBorder,
                    font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold))
        petView.addSubview(pill)

        taskChip = Chip(fill: Theme.chipFill, text: Theme.chipText, border: Theme.chipBorder,
                        font: .systemFont(ofSize: 11, weight: .medium))
        taskChip.padding = NSSize(width: 9, height: 5)
        taskChip.label.alignment = .left
        taskChip.label.maximumNumberOfLines = 6
        petView.addSubview(taskChip)

        bubble = Chip(fill: Theme.bubbleFill, text: Theme.bubbleText, border: Theme.pillBorder,
                      font: .systemFont(ofSize: 12, weight: .medium))
        bubble.borderWidth = 1.5
        bubble.padding = NSSize(width: 10, height: 6)
        bubble.isHidden = true
        petView.addSubview(bubble)

        panel.contentView = petView
        applySettings()
        refreshPet()
    }

    /// Size, opacity; keeps the top edge of the pet where it is.
    private func applySettings() {
        let s = CGFloat(settings.scale)
        let size = NSSize(width: round(baseSize.width * s), height: round(baseSize.height * s))
        var f = panel.frame
        if f.size != size {
            let top = f.maxY
            f.size = size
            f.origin.y = top - size.height
            panel.setFrame(f, display: true)
        }
        petView.frame = NSRect(origin: .zero, size: size)
        petView.bounds = NSRect(origin: .zero, size: baseSize)
        panel.alphaValue = CGFloat(settings.opacity)
        updateVisibility()
    }

    // MARK: Only over Claude

    @objc private func appActivated(_ note: Notification) {
        Task { @MainActor in self.updateVisibility() }
    }

    private func claudeIsFullscreen() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        for w in info where (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
            && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let size = CGSize(width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if screens.contains(where: { abs($0.width - size.width) < 2 && abs($0.height - size.height) < 2 }) { return true }
        }
        return false
    }

    private func updateVisibility() {
        var show = !snapshotMode            // snapshots render off screen
        if !snapshotMode {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if settings.onlyWithClaude {
                show = front == claudeBundleID || front == Bundle.main.bundleIdentifier
            }
            if show && settings.hideInFullscreen && front == claudeBundleID && claudeIsFullscreen() { show = false }
        }
        if show && !panel.isVisible {
            panel.orderFrontRegardless()
        } else if !show && panel.isVisible {
            popover?.performClose(nil)
            panel.orderOut(nil)
        }
    }

    // MARK: Pet contents

    private func refreshPet() {
        tickFace()

        var text = "5h —  ·  7d —"
        if let u = model.usage {
            let f = { (w: LimitWindow?) in w.map { "\(Int($0.utilization.rounded()))%" } ?? "—" }
            text = "5h \(f(u.fiveHour))  ·  7d \(f(u.sevenDay))"
        } else if model.needsLogin {
            text = "点我登录看用量"
        }
        // Task progress sits right under the head, the usage pill under that.
        var top = belowHead
        if let t = taskText() {
            taskChip.border = model.waitingSessions.isEmpty ? Theme.chipBorder : Theme.chipAlertBorder
            taskChip.borderWidth = model.waitingSessions.isEmpty ? 1 : 1.5
            taskChip.set(t, centerX: baseSize.width / 2, y: 0, maxWidth: baseSize.width - 8, radius: 10)
            taskChip.setFrameOrigin(NSPoint(x: taskChip.frame.minX, y: top - taskChip.frame.height))
            taskChip.isHidden = false
            top = taskChip.frame.minY - 4
        } else {
            taskChip.isHidden = true
        }
        pill.set(text, centerX: baseSize.width / 2, y: 0, maxWidth: baseSize.width)
        pill.setFrameOrigin(NSPoint(x: pill.frame.minX, y: top - pill.frame.height))
    }

    private func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    /// Sessions waiting for the user first, then working ones (name + step count).
    private func taskText() -> String? {
        let waiting = model.waitingSessions
        let busy = model.sessions.filter(\.isBusy)
        guard !waiting.isEmpty || !busy.isEmpty else { return nil }
        func line(_ s: SessionInfo) -> String {
            if s.isWaiting { return "⏳ \(clip(s.name, 10)) · \(s.waitingLabel)" }
            if let p = s.progress { return "⚡ \(clip(s.name, 11)) · \(p.done)/\(p.total)" }
            return "⚡ \(clip(s.name, 11)) · \(Fmt.duration(model.now.timeIntervalSince(s.statusSince)))"
        }
        let all = waiting + busy
        if all.count == 1 {
            let s = all[0]
            if let step = s.progress?.current { return line(s) + "\n▸ " + clip(step, 16) }
            return line(s)
        }
        var lines = all.prefix(3).map(line)
        if all.count > 3 { lines.append("还有 \(all.count - 3) 个任务…") }
        return lines.joined(separator: "\n")
    }

    // MARK: Expressions

    private func baseMoods() -> [Mood] {
        var moods: [Mood]
        if model.usage == nil {
            moods = [.noData]
        } else {
            switch model.level {
            case 1: moods = [.breezy]
            case 2: moods = [.calm]
            case 3: moods = [.strained]
            default: moods = [.crushed]
            }
        }
        if model.busyCount > 0 { moods.append(.working) }
        if settings.alertWaiting && !model.waitingSessions.isEmpty { moods.append(.needsYou) }
        let hour = Calendar.current.component(.hour, from: Date())
        if (1..<6).contains(hour) { moods.append(.night) }
        return moods
    }

    private func setFace(_ name: String) {
        face = name
        imageView.image = Faces.image(name)
        model.face = name
    }

    /// Picks a new base face when the mood changes or the rotation is due.
    private func tickFace() {
        let now = Date()
        guard now >= reactionUntil else { return }
        // Keep nudging every 3 minutes while a session waits for the user.
        if settings.alertWaiting, let w = model.waitingSessions.first, now.timeIntervalSince(lastNudge) > 180 {
            lastNudge = now
            react(.needsYou, seconds: 6, say: "「\(w.name)」还在\(w.waitingLabel)哦")
            return
        }
        let moods = baseMoods()
        let key = moods.map(\.rawValue).joined(separator: ",")
        let moodChanged = key != moodKey
        guard moodChanged || now >= nextRotate || face == nil else { return }
        moodKey = key
        setFace(Faces.pick(from: moods, avoiding: face))
        let base = settings.rotateSeconds
        nextRotate = now.addingTimeInterval(.random(in: base * 0.7...base * 1.3))
        if settings.chatter, !moodChanged, bubble.isHidden, Int.random(in: 0..<4) == 0,
           let line = moods.randomElement()?.lines.randomElement() {
            say(line, seconds: 4)
        }
    }

    /// Shows a face from `mood` for a few seconds, then goes back to rotating.
    private func react(_ mood: Mood, seconds: Double = 5, say text: String? = nil) {
        setFace(Faces.pick(from: [mood], avoiding: face))
        reactionUntil = Date().addingTimeInterval(seconds)
        nextRotate = reactionUntil
        if let text { say(text) }
    }

    private func farewell() {
        popover?.performClose(nil)
        react(.farewell, say: "下次见～")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { NSApp.terminate(nil) }
    }

    private func say(_ text: String, seconds: Double = 5) {
        bubble.set(text, centerX: baseSize.width / 2, y: imgY + imgSize - 18, maxWidth: baseSize.width - 8, radius: 12)
        bubble.isHidden = false
        bubbleHide?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.bubble.isHidden = true }
        bubbleHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func savedOrigin() -> NSPoint {
        if let s = UserDefaults.standard.string(forKey: "petOrigin") {
            let p = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -40, dy: -40).contains(p) }) { return p }
        }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.maxX - baseSize.width - 24, y: vf.minY + 24)
    }

    private func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "petOrigin")
    }

    // MARK: Popover

    private func togglePopover() {
        if let p = popover, p.isShown { p.performClose(nil); return }
        model.refreshSessions(notify: false)
        if let last = model.lastUsageUpdate, Date().timeIntervalSince(last) < 30 {} else {
            Task { await model.refreshUsage() }
        }
        let host = NSHostingController(rootView: PanelView(
            model: model,
            dashboard: dashboard,
            openLogin: { [weak self] in self?.openLogin(secondary: false) },
            openSecondaryLogin: { [weak self] in self?.openLogin(secondary: true) },
            openClaude: { [weak self] s in self?.openSession(s) },
            openDashboard: { [weak self] in self?.openDashboard() },
            openSettings: { [weak self] in self?.openSettings() },
            quit: { [weak self] in self?.farewell() }))
        host.sizingOptions = .preferredContentSize
        let p = NSPopover()
        p.contentViewController = host
        p.behavior = .transient
        p.animates = true
        p.delegate = self
        popover = p
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: imageView.bounds, of: imageView, preferredEdge: .minX)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.popover = nil }
    }

    /// Claude deep link that opens this session, if it has an id Claude accepts:
    /// `claude://code/continue?session=local_…` (desktop sessions) or `claude://code/session_…`.
    static func sessionLink(_ s: SessionInfo) -> URL? {
        if let local = s.hostSessionId, local.hasPrefix("local_"),
           var c = URLComponents(string: "claude://code/continue") {
            c.queryItems = [URLQueryItem(name: "session", value: local), URLQueryItem(name: "source", value: "desktop_action")]
            return c.url
        }
        if let bridge = s.bridgeSessionId, bridge.hasPrefix("session_") || bridge.hasPrefix("cse_") {
            return URL(string: "claude://code/\(bridge)")
        }
        return nil
    }

    /// Desktop sessions open straight in Claude; terminal sessions show their folder.
    private func openSession(_ s: SessionInfo) {
        popover?.performClose(nil)
        if let url = Self.sessionLink(s), NSWorkspace.shared.open(url) { return }
        if s.entrypoint.contains("desktop"),
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: s.cwd))
        }
    }

    // MARK: Windows (dashboard, settings)

    private func showWindow<V: View>(_ id: String, title: String, size: NSSize, resizable: Bool, _ view: V) {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let w = windows[id] { w.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
        if resizable { w.setContentSize(size) }
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.identifier = NSUserInterfaceItemIdentifier(id)
        w.center()
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if let w = notification.object as? NSWindow, let id = w.identifier?.rawValue { self.windows[id] = nil }
        }
    }

    private func openDashboard() {
        dashboard.refresh()
        showWindow("dashboard", title: "Claude Code 用量统计", size: NSSize(width: 800, height: 760), resizable: true,
                   DashboardView(dm: dashboard))
    }

    private func openSettings() {
        showWindow("settings", title: "Claude大小姐 设置", size: .zero, resizable: false, SettingsView())
    }

    // MARK: Login window

    private func openLogin(secondary: Bool) {
        popover?.performClose(nil)
        if loginWC != nil && loginIsSecondary != secondary { closeLogin() }
        if loginWC == nil {
            if secondary { model.enableSecondary() }
            let wc = LoginWindowController(
                store: secondary ? model.secondaryStore : .default(),
                title: secondary ? "登录另一个 claude.ai 账号 —— 只读取用量" : "登录 claude.ai —— 大小姐只读取用量")
            wc.onClose = { [weak self] in self?.closeLogin() }
            loginWC = wc
            loginIsSecondary = secondary
            loginPoll = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.loginIsSecondary { await self.model.refreshSecondary() } else { await self.model.refreshUsage() }
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        loginWC?.showWindow(nil)
        loginWC?.window?.makeKeyAndOrderFront(nil)
    }

    private func closeLogin() {
        loginPoll?.invalidate()
        loginPoll = nil
        let wc = loginWC
        loginWC = nil
        wc?.onClose = nil
        wc?.close()
    }

    // MARK: Right-click menu

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        func item(_ title: String, _ sel: Selector) { m.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self }
        item("查看用量和任务", #selector(menuShow))
        item("用量统计…", #selector(menuDashboard))
        item("立即刷新", #selector(menuRefresh))
        m.addItem(.separator())
        item("重新读取桌面版登录", #selector(menuDesktopLogin))
        item("登录 / 切换 claude.ai 账号…", #selector(menuLogin))
        item("退出 claude.ai 登录", #selector(menuLogout))
        item(model.hasSecondary ? "重新登录另一个账号…" : "添加另一个账号…", #selector(menuSecondary))
        if model.hasSecondary { item("移除另一个账号", #selector(menuRemoveSecondary)) }
        m.addItem(.separator())
        item("设置…", #selector(menuSettings))
        let login = m.addItem(withTitle: "开机自动启动", action: #selector(menuLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item("回到屏幕右下角", #selector(menuResetPosition))
        m.addItem(.separator())
        item("素材署名…", #selector(menuCredits))
        item("退出大小姐", #selector(menuQuit))
        return m
    }

    @objc private func menuShow() { togglePopover() }
    @objc private func menuDashboard() { openDashboard() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuRefresh() { Task { await model.refreshUsage(); say("刷新好啦") } }
    @objc private func menuLogin() { openLogin(secondary: false) }
    @objc private func menuSecondary() { openLogin(secondary: true) }
    @objc private func menuRemoveSecondary() { Task { await model.removeSecondary(); say("已移除另一个账号") } }
    @objc private func menuDesktopLogin() {
        DesktopLogin.resetDenied()
        Task {
            await model.refreshUsage()
            if model.usage?.source == "Claude 桌面版登录" { react(.greet, say: "已用桌面版的登录～") }
            else { react(.oops, say: "没读到桌面版登录") }
        }
    }
    @objc private func menuLogout() { Task { await model.logoutWeb(); say("已退出 claude.ai 登录") } }
    @objc private func menuQuit() { farewell() }

    @objc private func menuResetPosition() {
        UserDefaults.standard.removeObject(forKey: "petOrigin")
        var f = panel.frame
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        f.origin = NSPoint(x: vf.maxX - f.width - 24, y: vf.minY + 24)
        panel.setFrame(f, display: true)
    }

    @objc private func menuCredits() {
        let a = NSAlert()
        a.messageText = "素材署名"
        a.informativeText = Doro.attribution + "\n\n形象图片是该仓库 head/ 目录的全部 80 张，缩小了尺寸并去掉了白色外框，按 CC BY-NC-SA 4.0 非商业使用。"
        a.addButton(withTitle: "好")
        a.addButton(withTitle: "打开素材仓库")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/opsCar/claude-daxiaojie-assets")!)
        }
    }

    @objc private func menuLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                say("不再开机启动")
            } else {
                try SMAppService.mainApp.register()
                say("下次开机本小姐会自己出现～")
            }
        } catch {
            react(.oops, seconds: 8, say: "设置失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - claude.ai login window

@MainActor
final class LoginWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let webView: WKWebView

    init(store: WKWebsiteDataStore, title: String) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 720), configuration: cfg)
        webView.customUserAgent = WebUsageFetcher.userAgent
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = title
        win.contentView = webView
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        win.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    required init?(coder: NSCoder) { fatalError() }

    // Open window.open() targets (e.g. Google sign-in) in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
