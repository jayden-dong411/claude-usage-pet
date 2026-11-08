import AppKit
import ServiceManagement
import SwiftUI

// The app shell shared by GPT龙娘, Grok娘 and DeepSeek娘 (the Claude pet has its own, larger one).
// Everything pet-specific comes from each app's `Spec` (Spec.swift) and its own AppModel /
// SessionInfo / PanelView / Settings / Theme types, which this file uses by name:
//   AppModel: sessions, busyCount, waitingSessions, level, now, frame, peers, onChange,
//             onTaskStarted/Finished/Waiting, start(), refresh(notify:), refreshPeers()
//   SessionInfo: id, name, isBusy, isWaiting, waitingLabel, statusSince, progress
// Shared with the Claude pet: PetChrome.swift (pet view), V3Figure.swift, Peers.swift, PetHub.swift.

@main
struct CompanionMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
        app.run()
    }
}

/// Buttons inside the pet's panel.
struct PanelActions {
    var openSession: (SessionInfo) -> Void = { _ in }
    var openDashboard: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
}

/// An optional statistics window.
@MainActor
struct DashboardHook {
    var title: String
    var start: () -> Void
    var refresh: () -> Void
    var view: () -> AnyView
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, PetHubClient {
    let model = AppModel()
    let settings = Settings.shared
    private let hub = PetHub.shared

    private var panel: NSPanel!
    private var petView: PetView!
    private var imageView: NSImageView!
    private var pill: Chip!
    private var taskChip: Chip!
    private var bubble: Chip!
    private var popover: NSPopover?
    private var bubbleHide: DispatchWorkItem?
    private var windows: [String: NSWindow] = [:]
    private var snapshotMode = false
    private var forceShowUntil = Date.distantPast

    // Sprite animation (only when Spec has a sprite sheet and the v3 look is off).
    private var anim: Anim = .idle
    private var frameIndex = 0
    private var frameTimer: Timer?
    private var reactionUntil = Date.distantPast
    private var reactionLoops = 0
    private var moodKey = ""
    private var lastNudge = Date.distantPast
    private var nextChatter = Date().addingTimeInterval(12)
    private var dragAnim: Anim?
    private var lastMouse = NSPoint.zero
    private var mouseMovedAt = Date.distantPast
    private var tick: Timer?
    private var isLooking = false
    // v3 expressions
    private var v3: V3Figure?
    private var forceV3 = false                 // `--snapshot … --v3`
    private var v3Mode: Bool { (Spec.prefersV3 || forceV3 || !Spec.hasSprite) && V3Assets.available }
    private var v3Home: NSRect { NSRect(x: 22, y: imgY, width: 176, height: 188) }
    private var statusIcons: [ObjectIdentifier: NSImage] = [:]

    // Layout in base units (scaled by Settings.scale), top-down: bubble, figure, tasks, usage pill.
    private var baseSize: NSSize { v3Mode ? NSSize(width: 220, height: 336) : NSSize(width: 220, height: 320) }
    private let imgSize = NSSize(width: 150, height: 162)    // 192 × 208 sprite cells, scaled
    private let imgY: CGFloat = 118
    private var belowHead: CGFloat { imgY + 6 }
    private var spriteRect: NSRect { NSRect(x: (baseSize.width - imgSize.width) / 2, y: imgY, width: imgSize.width, height: imgSize.height) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        snapshotMode = CommandLine.arguments.contains("--snapshot")
        forceV3 = snapshotMode && CommandLine.arguments.contains("--v3")
        buildPanel()
        model.onChange = { [weak self] in self?.refreshPet() }
        model.onTaskFinished = { [weak self] s in
            guard let self else { return }
            if !self.panel.isVisible { self.hub.notify(title: Banter.name(Spec.petID), body: "「\(s.name)」这一轮处理结束了") }
            self.react(.taskDone, loops: 2, say: "「\(s.name)」这一轮处理结束啦～")
        }
        model.onTaskStarted = { [weak self] s in self?.react(.taskStarted, loops: 1, say: "「\(s.name)」开工！") }
        model.onTaskWaiting = { [weak self] s in
            guard let self, self.settings.alertWaiting else { return }
            self.lastNudge = Date()
            if !self.panel.isVisible {
                self.hub.notify(title: Banter.name(Spec.petID), body: "「\(s.name)」\(s.waitingLabel)")
                self.forceShowUntil = Date().addingTimeInterval(8)
                self.updateVisibility()
            }
            self.react(.needsYou, loops: 3, say: "「\(s.name)」\(s.waitingLabel)～")
        }
        settings.onChange = { [weak self] in self?.applySettings() }
        model.start()
        Spec.dashboard?.start()
        if !snapshotMode { hub.start(me: Spec.petID, client: self) }
        react(.greet, loops: 2, say: Spec.greeting)
        startFrame()
        tick = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        updateVisibility()

        // Debug: `<binary> --snapshot <dir> [--demo] [--v3] [--focus] [--wait s]` writes PNGs and quits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            let wait = args.firstIndex(of: "--wait").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                if args.contains("--demo") {
                    Spec.loadDemo(self.model)
                    self.anim = .waving; self.frameIndex = 1
                    self.showFrame()
                    self.say(Spec.greeting)
                }
                if args.contains("--focus") { self.hub.setDemoFocus(23 * 60 + 12) }
                self.refreshPet()
                self.writeSnapshots(to: dir)
                NSApp.terminate(nil)
            }
        }
    }

    private var actions: PanelActions {
        PanelActions(openSession: { [weak self] s in self?.popover?.performClose(nil); Spec.open(s) },
                     openDashboard: { [weak self] in self?.openDashboard() },
                     openSettings: { [weak self] in self?.openSettings() },
                     quit: { [weak self] in self?.farewell() })
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
        var views: [(String, AnyView, NSSize?)] = [
            ("panel.png", Spec.panel(model, PanelActions()), nil),
            ("settings.png", AnyView(SettingsView()), nil),
        ]
        if let d = Spec.dashboard { views.append(("dashboard.png", d.view(), NSSize(width: 800, height: 1400))) }
        for (name, view, size) in views {
            for (suffix, look) in [("", NSAppearance.Name.darkAqua), ("-light", .aqua)] {
                let h = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                h.appearance = NSAppearance(named: look)
                h.frame = NSRect(origin: .zero, size: size ?? h.fittingSize)
                h.layoutSubtreeIfNeeded()
                png(h, name.replacingOccurrences(of: ".png", with: "\(suffix).png"))
            }
        }
        let info = "pet=\(Spec.petID) v3=\(v3 != nil) peers=\(model.peers.map(\.provider)) sessions=\(model.sessions.count) busy=\(model.busyCount) level=\(model.level) pill=\(pill.label.stringValue)"
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
            if self.popover?.isShown != true { self.react(.clicked, loops: 1) }
            self.togglePopover()
        }
        petView.onDoubleClick = { [weak self] in self?.hop() }
        petView.onPet = { [weak self] in self?.react(.petted, loops: 3, seconds: 3.5, say: Banter.line(Spec.petID, "petted") ?? Mood.petted.lines.randomElement()) }
        petView.petRect = { [weak self] in self?.imageView.frame ?? .zero }
        petView.onDragStart = { [weak self] in self?.popover?.performClose(nil) }
        petView.onDragMove = { [weak self] dx in
            guard let self, abs(dx) > 0.5 else { return }
            self.v3?.drag(dx)
            let next: Anim = dx > 0 ? .runningRight : .runningLeft
            if self.dragAnim != next { self.dragAnim = next; self.setAnim(next) }
        }
        petView.onDragEnd = { [weak self] in
            guard let self else { return }
            self.dragAnim = nil
            self.v3?.endDrag()
            self.saveOrigin()
            self.moodKey = ""            // pick the base animation again
            self.tickMood()
        }
        petView.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }

        imageView = NSImageView(frame: spriteRect)
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
        applyMode()
        updateVisibility()
    }

    /// Switches between the sprite and the v3 expressions.
    private func applyMode() {
        if v3Mode && v3 == nil {
            let f = V3Figure(imageView: imageView, home: v3Home) { [weak self] img in self?.model.frame = img }
            v3 = f
            f.start()
            moodKey = ""
            tickMood()
        } else if !v3Mode, let f = v3 {
            f.stop()
            v3 = nil
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.frame = spriteRect
            showFrame()
        }
        refreshPet()
    }

    // MARK: Only over the host app

    @objc private func appActivated(_ note: Notification) {
        Task { @MainActor in self.updateVisibility() }
    }

    private func hostIsFullscreen() -> Bool {
        let pids = Set(NSWorkspace.shared.runningApplications.filter { Spec.hosts.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
        guard !pids.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        for w in info where pids.contains(w[kCGWindowOwnerPID as String] as? Int32 ?? -1) && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let size = CGSize(width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if screens.contains(where: { abs($0.width - size.width) < 2 && abs($0.height - size.height) < 2 }) { return true }
        }
        return false
    }

    private func updateVisibility() {
        var show = !snapshotMode
        if !snapshotMode {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let isHost = Spec.hosts.contains(front)
            if settings.onlyWithClaude { show = isHost || front == Bundle.main.bundleIdentifier }
            if show && settings.hideInFullscreen && isHost && hostIsFullscreen() { show = false }
            if Date() < forceShowUntil { show = true }
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
        tickMood()
        let text = hub.pillText ?? Spec.pill(model)
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

    private func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

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

    // MARK: Animation

    private func baseMood() -> Mood {
        if settings.alertWaiting && !model.waitingSessions.isEmpty { return .needsYou }
        if model.busyCount > 0 || hub.focusing { return .working }
        guard Spec.hasUsage(model) else { return .noData }
        switch model.level {
        case 4: return .crushed
        case 3: return .strained
        default:
            let hour = Calendar.current.component(.hour, from: Date())
            return (1..<6).contains(hour) ? .night : (model.level <= 1 ? .breezy : .calm)
        }
    }

    private func setAnim(_ a: Anim) {
        anim = a
        frameIndex = 0
        showFrame()
        startFrame()
    }

    private func showFrame() {
        guard v3 == nil else { return }
        let img = Sprite.frame(anim, frameIndex)
        imageView.image = img
        model.frame = img
    }

    private func startFrame() {
        frameTimer?.invalidate()
        let ms = anim.durations[frameIndex % anim.durations.count]
        frameTimer = Timer.scheduledTimer(withTimeInterval: Double(ms) / 1000, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.advanceFrame() }
        }
    }

    private func advanceFrame() {
        frameIndex += 1
        if frameIndex >= anim.durations.count {
            frameIndex = 0
            if reactionLoops > 0 { reactionLoops -= 1 }
            if reactionLoops == 0 && Date() >= reactionUntil && dragAnim == nil {
                let base = baseMood().anim
                if base != anim { moodKey = ""; tickMood(); return }
            }
        }
        if !isLooking { showFrame() }
        startFrame()
    }

    /// Chooses the base animation when the mood changes.
    private func tickMood() {
        guard dragAnim == nil, Date() >= reactionUntil, reactionLoops == 0 else { return }
        let now = Date()
        if settings.alertWaiting, let w = model.waitingSessions.first, now.timeIntervalSince(lastNudge) > 180 {
            lastNudge = now
            react(.needsYou, loops: 3, say: "「\(w.name)」还在\(w.waitingLabel)哦")
            return
        }
        let mood = baseMood()
        v3?.setState(mood.v3State)
        if mood.rawValue != moodKey {
            moodKey = mood.rawValue
            if anim != mood.anim { setAnim(mood.anim) }
        }
        if now >= nextChatter {
            let base = hub.settings.chatterSeconds
            nextChatter = now.addingTimeInterval(.random(in: base * 0.7...base * 1.3))
            var moods = [mood.rawValue]
            if (1..<6).contains(Calendar.current.component(.hour, from: now)) { moods.append("night") }
            if settings.chatter, !hub.focusing, bubble.isHidden,
               let line = Banter.chatter(Spec.petID, moods: moods, vars: Spec.banterVars(model)) ?? mood.lines.randomElement() {
                say(line, seconds: 4.5)
            }
        }
    }

    /// Plays a reaction `loops` times, then returns to the base animation.
    private func react(_ mood: Mood, loops: Int, seconds: Double = 0, say text: String? = nil) {
        reactionLoops = max(1, loops)
        reactionUntil = Date().addingTimeInterval(seconds)
        setAnim(mood.anim)
        v3?.react(mood.v3Action, seconds: max(1.4, min(4, max(seconds, Double(loops) * 1.1))))
        moodKey = ""
        if let text { say(text) }
    }

    /// Double-click: a jump.
    private func hop() {
        popover?.performClose(nil)
        react(.hop, loops: 2, seconds: 2.2)
        if Int.random(in: 0..<2) == 0, let line = Banter.line(Spec.petID, "hop") ?? Mood.hop.lines.randomElement() { say(line, seconds: 2.5) }
    }

    // MARK: Look toward the mouse while idle (sprite only)

    private func onTick() {
        updateVisibility()
        let m = NSEvent.mouseLocation
        if m != lastMouse { lastMouse = m; mouseMovedAt = Date() }
        let idle = anim == .idle && reactionLoops == 0 && dragAnim == nil && v3 == nil
        guard idle, panel.isVisible else {
            if isLooking { isLooking = false; showFrame() }
            return
        }
        let f = panel.frame
        let s = CGFloat(settings.scale)
        let c = NSPoint(x: f.minX + (imageView.frame.midX) * s, y: f.minY + (imageView.frame.midY) * s)
        let dx = m.x - c.x, dy = m.y - c.y
        let dist = hypot(dx, dy)
        let recent = Date().timeIntervalSince(mouseMovedAt) < 2.5
        if recent && dist > 60 * s && dist < 700, let img = Sprite.look(atan2(dx, dy) * 180 / .pi) {
            imageView.image = img
            isLooking = true
        } else if isLooking {
            isLooking = false
            showFrame()
        }
    }

    private func farewell() {
        popover?.performClose(nil)
        react(.farewell, loops: 2, say: "下次见～")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { NSApp.terminate(nil) }
    }

    private func say(_ text: String, seconds: Double = 5) {
        bubble.set(text, centerX: baseSize.width / 2, y: v3Mode ? v3Home.maxY - 2 : imgY + imgSize.height - 4,
                   maxWidth: baseSize.width - 8, radius: 12)
        bubble.keepBelow(baseSize.height - 2)
        if let v3 { v3.show(v3.face, seconds: seconds) }
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
        model.refresh(notify: false)
        let host = NSHostingController(rootView: Spec.panel(model, actions))
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

    // MARK: Shared hub (menu bar, focus timer, reminders)

    func hubStateChanged() { refreshPet() }

    func hubShowReminder(_ e: HubEvent) {
        let mood: Mood = e.kind == "focusDone" ? .taskDone : e.kind == "restDone" ? .greet : e.kind == "night" ? .night : .care
        if e.kind == "focusDone" { NSSound(named: "Glass")?.play() }
        if e.kind == "restDone" { NSSound(named: "Tink")?.play() }
        forceShowUntil = Date().addingTimeInterval(12)
        updateVisibility()
        react(mood, loops: 4, seconds: 12)
        say(e.text, seconds: 12)
    }

    func hubDuet(_ lines: [DuetLine], total: Double) {
        forceShowUntil = Date().addingTimeInterval(total)
        updateVisibility()
        for l in lines {
            DispatchQueue.main.asyncAfter(deadline: .now() + l.delay) { [weak self] in
                guard let self else { return }
                self.react(.clicked, loops: 1, seconds: 3.4)
                self.say(l.text, seconds: 3.4)
            }
        }
        nextChatter = Date().addingTimeInterval(total + 10)
    }

    func hubShowPanel() {
        forceShowUntil = Date().addingTimeInterval(20)
        updateVisibility()
        if popover?.isShown != true { togglePopover() }
    }

    func hubStatusIcon() -> NSImage? {
        guard let src = model.frame else { return nil }
        let key = ObjectIdentifier(src)
        if let i = statusIcons[key] { return i }
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let s = src.size, scale = min(r.width / s.width, r.height / s.height)
            let w = s.width * scale, h = s.height * scale
            src.draw(in: NSRect(x: (r.width - w) / 2, y: (r.height - h) / 2, width: w, height: h),
                     from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        if statusIcons.count > 40 { statusIcons.removeAll() }
        statusIcons[key] = img
        return img
    }

    func hubStatusMenu() -> NSMenu { buildMenu() }

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
        guard let d = Spec.dashboard else { return }
        d.refresh()
        showWindow("dashboard", title: d.title, size: NSSize(width: 800, height: 800), resizable: true, d.view())
    }

    private func openSettings() {
        showWindow("settings", title: "\(Pet.name) 设置", size: .zero, resizable: false, SettingsView())
    }

    // MARK: Right-click menu

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        func item(_ title: String, _ sel: Selector) { m.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self }
        if let fig = Spec.figureMenuTitle, V3Assets.available {
            item(fig, #selector(menuToggleFigure))
            m.addItem(.separator())
        }
        item("查看额度和任务", #selector(menuShow))
        if Spec.dashboard != nil { item("用量统计…", #selector(menuDashboard)) }
        item("立即刷新", #selector(menuRefresh))
        item("打开 \(Spec.hostName)", #selector(menuOpenHost))
        m.addItem(.separator())
        hub.addFocusItems(to: m)
        m.addItem(.separator())
        item("设置…", #selector(menuSettings))
        let login = m.addItem(withTitle: "开机自动启动", action: #selector(menuLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item("回到屏幕右下角", #selector(menuResetPosition))
        m.addItem(.separator())
        item("素材来源…", #selector(menuCredits))
        item("退出 \(Pet.name)", #selector(menuQuit))
        return m
    }

    @objc private func menuShow() { togglePopover() }
    @objc private func menuDashboard() { openDashboard() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuRefresh() {
        model.refresh(notify: false); model.refreshPeers(); Spec.dashboard?.refresh(); say("刷新好啦")
    }
    @objc private func menuQuit() { farewell() }
    @objc private func menuToggleFigure() {
        Spec.toggleFigure()
        react(.greet, loops: 2, say: "换好形象啦～")
    }

    @objc private func menuOpenHost() {
        for id in Spec.hosts {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init()); return
            }
        }
    }

    @objc private func menuResetPosition() {
        UserDefaults.standard.removeObject(forKey: "petOrigin")
        var f = panel.frame
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        f.origin = NSPoint(x: vf.maxX - f.width - 24, y: vf.minY + 24)
        panel.setFrame(f, display: true)
    }

    @objc private func menuCredits() {
        let a = NSAlert()
        a.messageText = "素材来源"
        a.informativeText = Spec.credits
        a.addButton(withTitle: "好")
        a.addButton(withTitle: "打开素材仓库")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn, let url = URL(string: Spec.creditsURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                say("不再开机启动")
            } else {
                try SMAppService.mainApp.register()
                say("下次开机我会自己出现～")
            }
        } catch {
            react(.oops, loops: 2, say: "设置失败：\(error.localizedDescription)")
        }
    }
}
