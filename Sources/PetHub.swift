import AppKit
import Combine
import SwiftUI

// Coordination between the four local pets (Claude大小姐, GPT龙娘, Grok娘, DeepSeek娘), which run as
// separate apps but should behave like one:
// - One menu-bar item: only the "leader" (the first running pet in `PetHub.registry` order) shows it,
//   with every provider's usage; clicking it opens an overview.
// - One focus timer: its state lives in ~/Library/Application Support/AIPets/hub.json, so starting or
//   stopping it from any pet shows the countdown on all of them.
// - One set of reminders (focus over, rest over, continuous use, late night): the leader decides when;
//   the pet whose host app is in front shows it (or the leader when none is).
// - Shared settings (focus length, reminders, menu-bar item) in the "local.aipets.shared" defaults.
// - "Open that pet's panel" requests travel as distributed notifications.
// Compiled into all four apps.

struct PetInfo {
    let id: String              // provider id: "claude" | "codex" | "grok" | "deepseek"
    let name: String
    let bundleID: String        // the pet app
    let hosts: [String]         // the AI app it sits on
}

struct HubEvent: Codable, Equatable {
    var id: Int
    var kind: String            // focusDone | restDone | sit | night
    var text: String
    var note: String            // short text for the menu bar
    var at: Date
}

struct HubState: Codable, Equatable {
    var focusEnd: Date?
    var restEnd: Date?
    var event: HubEvent?
}

/// Settings shared by all pets.
@MainActor
final class HubSettings: ObservableObject {
    static let shared = HubSettings()
    let d = UserDefaults(suiteName: "local.aipets.shared") ?? .standard

    @Published var focusMinutes: Double { didSet { d.set(focusMinutes, forKey: "focusMinutes") } }
    @Published var sitReminder: Bool { didSet { d.set(sitReminder, forKey: "sitReminder") } }
    @Published var nightReminder: Bool { didSet { d.set(nightReminder, forKey: "nightReminder") } }
    @Published var menuBarIcon: Bool { didSet { d.set(menuBarIcon, forKey: "menuBarIcon") } }

    private init() {
        let d = UserDefaults(suiteName: "local.aipets.shared") ?? .standard
        focusMinutes = d.object(forKey: "focusMinutes") == nil ? 25 : d.double(forKey: "focusMinutes")
        sitReminder = d.object(forKey: "sitReminder") == nil ? true : d.bool(forKey: "sitReminder")
        nightReminder = d.object(forKey: "nightReminder") == nil ? true : d.bool(forKey: "nightReminder")
        menuBarIcon = d.object(forKey: "menuBarIcon") == nil ? true : d.bool(forKey: "menuBarIcon")
    }

    /// Picks up changes made in another pet's settings window.
    func reload() {
        let fm = d.object(forKey: "focusMinutes") == nil ? 25 : d.double(forKey: "focusMinutes")
        if fm != focusMinutes { focusMinutes = fm }
        for (key, path) in [("sitReminder", \HubSettings.sitReminder), ("nightReminder", \.nightReminder), ("menuBarIcon", \.menuBarIcon)] {
            let v = d.object(forKey: key) == nil ? true : d.bool(forKey: key)
            if self[keyPath: path] != v { self[keyPath: path] = v }
        }
    }
}

/// Section for each pet's settings window.
struct HubSettingsSection: View {
    @ObservedObject var s = HubSettings.shared

    var body: some View {
        Section {
            Toggle("在菜单栏显示各家额度（四只桌宠共用一个）", isOn: $s.menuBarIcon)
            Toggle("连续使用 2 小时提醒起来活动（之后每 30 分钟）", isOn: $s.sitReminder)
            Toggle("凌晨 0–5 点还在用时提醒睡觉", isOn: $s.nightReminder)
            LabeledContent("专注时长") {
                HStack {
                    Slider(value: $s.focusMinutes, in: 10...60, step: 5)
                    Text("\(Int(s.focusMinutes)) 分钟").monospacedDigit().frame(width: 56, alignment: .trailing)
                }
            }
        } header: {
            Text("四只桌宠共用")
        } footer: {
            Text("专注番茄钟和提醒在四只桌宠之间同步：哪只桌宠在前台就由谁提醒你。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
protocol PetHubClient: AnyObject {
    /// Focus / rest state changed or ticked; refresh the pill.
    func hubStateChanged()
    /// This pet should show a reminder.
    func hubShowReminder(_ e: HubEvent)
    /// Another pet (or the menu-bar overview) asked to open this pet's panel.
    func hubShowPanel()
    /// Icon for the menu-bar item while this pet leads.
    func hubStatusIcon() -> NSImage?
    /// Right-click menu of the menu-bar item while this pet leads.
    func hubStatusMenu() -> NSMenu
}

@MainActor
final class PetHub: NSObject {
    static let shared = PetHub()

    static let registry: [PetInfo] = [
        PetInfo(id: "claude", name: "Claude大小姐", bundleID: "com.djh.doropet", hosts: ["com.anthropic.claudefordesktop"]),
        PetInfo(id: "codex", name: "GPT龙娘", bundleID: "local.gptdragon.pet", hosts: ["com.openai.codex", "com.openai.chat"]),
        PetInfo(id: "grok", name: "Grok娘", bundleID: "local.grokchan.pet", hosts: ["com.anysphere.sand"]),
        PetInfo(id: "deepseek", name: "DeepSeek娘", bundleID: "local.deepseekchan.pet", hosts: ["com.deepseek.dsh"]),
    ]
    static let fileURL = PeerStore.dir.appendingPathComponent("hub.json")
    private static let showPanelNote = Notification.Name("local.aipets.showPanel")

    private(set) var me = ""
    weak var client: PetHubClient?
    private(set) var state = HubState()
    let settings = HubSettings.shared

    private var timer: Timer?
    private var fileStamp: Date?
    private var lastSeenEvent = 0
    private var peers: [PeerUsage] = []
    private var peersAt = Date.distantPast
    private var statusItem: NSStatusItem?
    private var overview: NSPopover?
    // Wellness (leader only)
    private var streakStart: Date?
    private var nextSit = Date.distantFuture
    private var lastActive = Date.distantPast
    private var lastNight = Date.distantPast
    private var tickCount = 0

    var focusing: Bool { (state.focusEnd ?? .distantPast) > Date() }
    var resting: Bool { (state.restEnd ?? .distantPast) > Date() }

    // MARK: Start

    func start(me: String, client: PetHubClient) {
        self.me = me
        self.client = client
        load()
        lastSeenEvent = state.event?.id ?? 0
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showPanelRequested(_:)), name: Self.showPanelNote, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    // MARK: Roles

    static func isRunning(_ p: PetInfo) -> Bool {
        p.bundleID == Bundle.main.bundleIdentifier || !NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID).isEmpty
    }

    var leaderID: String { Self.registry.first(where: Self.isRunning)?.id ?? me }
    var isLeader: Bool { leaderID == me }

    /// The pet that should show a reminder now: the one sitting on the app in front, else the leader.
    var displayerID: String {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if let p = Self.registry.first(where: { ($0.hosts.contains(front) || $0.bundleID == front) && Self.isRunning($0) }) {
            return p.id
        }
        return leaderID
    }

    /// True while any of the four AI apps (or a pet) is in front.
    static var aiAppInFront: Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return registry.contains { $0.hosts.contains(front) || $0.bundleID == front }
    }

    // MARK: Focus timer

    func startFocus() {
        load()
        state.restEnd = nil
        state.focusEnd = Date().addingTimeInterval(settings.focusMinutes * 60)
        streakStart = nil
        save()
        client?.hubStateChanged()
    }

    func stopFocus() {
        load()
        state.focusEnd = nil
        state.restEnd = nil
        save()
        client?.hubStateChanged()
    }

    static func mmss(_ secs: TimeInterval) -> String {
        let s = max(0, Int(secs.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "🍅 专注 23:12" / "☕ 休息 4:59" while the timer runs.
    var pillText: String? {
        if let f = state.focusEnd, f > Date() { return "🍅 专注 \(Self.mmss(f.timeIntervalSinceNow))" }
        if let r = state.restEnd, r > Date() { return "☕ 休息 \(Self.mmss(r.timeIntervalSinceNow))" }
        return nil
    }

    /// Focus items for a pet's right-click menu.
    func addFocusItems(to m: NSMenu) {
        func add(_ title: String, _ sel: Selector) {
            let it = m.addItem(withTitle: title, action: sel, keyEquivalent: "")
            it.target = self
        }
        if let f = state.focusEnd, f > Date() {
            add("结束专注（还剩 \(Self.mmss(f.timeIntervalSinceNow))）", #selector(menuStop))
        } else if let r = state.restEnd, r > Date() {
            add("跳过休息（还剩 \(Self.mmss(r.timeIntervalSinceNow))）", #selector(menuStop))
            add("再专注 \(Int(settings.focusMinutes)) 分钟", #selector(menuStart))
        } else {
            add("🍅 开始专注 \(Int(settings.focusMinutes)) 分钟", #selector(menuStart))
        }
    }

    @objc private func menuStart() { startFocus() }

    /// Reads the shared state once (snapshot mode, where the hub isn't started).
    func peek() { load() }

    /// `--snapshot … --focus`: show a running timer without touching the shared file.
    func setDemoFocus(_ seconds: TimeInterval) { state.focusEnd = Date().addingTimeInterval(seconds) }
    @objc private func menuStop() { stopFocus() }

    // MARK: State file

    private func load() {
        let url = Self.fileURL
        guard let d = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let s = try? dec.decode(HubState.self, from: d) { state = s }
        fileStamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(state) { try? d.write(to: Self.fileURL, options: .atomic) }
        fileStamp = (try? Self.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    private func emit(_ kind: String, _ text: String, note: String) {
        load()
        state.event = HubEvent(id: (state.event?.id ?? 0) + 1, kind: kind, text: text, note: note, at: Date())
        save()
    }

    // MARK: Tick

    private func tick() {
        tickCount += 1
        let stamp = try? Self.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let before = state
        if stamp != fileStamp { load() }
        if tickCount % 5 == 0 { settings.reload() }
        if isLeader { lead() }
        if let e = state.event, e.id > lastSeenEvent {
            lastSeenEvent = e.id
            if Date().timeIntervalSince(e.at) < 30 && displayerID == me { client?.hubShowReminder(e) }
        }
        if state != before || focusing || resting { client?.hubStateChanged() }
        updateStatusItem()
        // `defaults write local.aipets.shared hubDebug -bool YES` → AIPets/hub-debug-<pet>.txt
        if tickCount % 5 == 0, settings.d.bool(forKey: "hubDebug") {
            let line = "me=\(me) leader=\(leaderID) displayer=\(displayerID) statusItem=\(statusItem != nil) " +
                "title=\(statusItem?.button?.attributedTitle.string ?? "-") focusing=\(focusing) resting=\(resting)"
            try? line.write(to: PeerStore.dir.appendingPathComponent("hub-debug-\(me).txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Leader: runs the focus clock and the wellness reminders.
    private func lead() {
        let now = Date()
        if let f = state.focusEnd, now >= f {
            load()
            if let f2 = state.focusEnd, now >= f2 {
                state.focusEnd = nil
                state.restEnd = now.addingTimeInterval(5 * 60)
                save()
                emit("focusDone", "专注 \(Int(settings.focusMinutes)) 分钟完成！起来活动 5 分钟、喝口水吧～", note: "🍅 完成！")
            }
        } else if let r = state.restEnd, now >= r {
            load()
            if let r2 = state.restEnd, now >= r2 {
                state.restEnd = nil
                save()
                streakStart = nil
                emit("restDone", "休息结束～ 要再来一轮专注的话右键我哦", note: "☕ 休息结束")
            }
        }
        guard tickCount % 2 == 0 else { return }
        // Continuous use: reset by 5 min away from the keyboard or 10 min without an AI app in front.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle < 120 && Self.aiAppInFront { lastActive = now }
        if idle >= 300 || now.timeIntervalSince(lastActive) > 600 || focusing || resting {
            streakStart = nil
        } else if streakStart == nil {
            streakStart = now
            nextSit = now.addingTimeInterval(2 * 3600)
        }
        if settings.sitReminder, let start = streakStart, now >= nextSit {
            nextSit = now.addingTimeInterval(30 * 60)
            let mins = Int(now.timeIntervalSince(start) / 60)
            let span = mins >= 60 ? "\(mins / 60) 小时\(mins % 60 > 0 ? " \(mins % 60) 分" : "")" : "\(mins) 分钟"
            emit("sit", "已经连续用了 \(span)啦，站起来走走、喝口水吧～", note: "🧋 该活动啦")
        }
        let hour = Calendar.current.component(.hour, from: now)
        if settings.nightReminder, (0..<5).contains(hour), now.timeIntervalSince(lastActive) < 120,
           now.timeIntervalSince(lastNight) > 3600 {
            lastNight = now
            let line = ["已经 \(hour == 0 ? "12" : "\(hour)") 点多了，早点休息吧～", "熬夜伤身体，存个档明天再继续吧",
                        "这么晚还在忙？快去睡觉！"].randomElement()!
            emit("night", line, note: "🌙 该睡啦")
        }
    }

    // MARK: Panels of other pets

    /// Opens `id`'s panel (launching that pet if it isn't running).
    static func openPanel(of id: String) {
        guard let p = registry.first(where: { $0.id == id }) else { return }
        if isRunning(p) {
            DistributedNotificationCenter.default().postNotificationName(showPanelNote, object: id, userInfo: nil, deliverImmediately: true)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    @objc private nonisolated func showPanelRequested(_ note: Notification) {
        let target = note.object as? String
        Task { @MainActor in
            if target == self.me { self.client?.hubShowPanel() }
        }
    }

    // MARK: Menu-bar item (leader only)

    private func refreshPeers() {
        guard Date().timeIntervalSince(peersAt) > 30 else { return }
        peersAt = Date()
        Task.detached {
            let p = PeerStore.peers(excluding: "")
            await MainActor.run { self.peers = p; self.updateStatusItem() }
        }
    }

    private func updateStatusItem() {
        let show = isLeader && settings.menuBarIcon && !CommandLine.arguments.contains("--snapshot")
        guard show else {
            if let s = statusItem { NSStatusBar.system.removeStatusItem(s); statusItem = nil }
            overview?.performClose(nil)
            return
        }
        refreshPeers()
        if statusItem == nil {
            let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            s.button?.target = self
            s.button?.action = #selector(statusClicked(_:))
            s.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            s.button?.imagePosition = .imageLeft
            statusItem = s
        }
        guard let button = statusItem?.button else { return }
        if let img = client?.hubStatusIcon(), button.image !== img { button.image = img }
        let title = statusTitle()
        if button.attributedTitle != title { button.attributedTitle = title }
        button.toolTip = (["AI 额度总览"] + peers.map { $0.summary }).joined(separator: "\n") + "\n左键看总览 · 右键菜单"
    }

    private func statusTitle() -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let out = NSMutableAttributedString(string: " ", attributes: [.font: font])
        if let e = state.event, Date().timeIntervalSince(e.at) < 12 {
            out.append(NSAttributedString(string: e.note, attributes: [.font: font]))
            return out
        }
        if let p = pillText {
            out.append(NSAttributedString(string: p.replacingOccurrences(of: "专注 ", with: "").replacingOccurrences(of: "休息 ", with: ""),
                                          attributes: [.font: font]))
            return out
        }
        if peers.isEmpty {
            out.append(NSAttributedString(string: "—", attributes: [.font: font]))
            return out
        }
        for (i, p) in peers.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            let symbol = PeerCard.symbol(p.provider)
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: p.title)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
                img.isTemplate = true
                let a = NSTextAttachment()
                a.image = img
                a.bounds = NSRect(x: 0, y: -1, width: img.size.width, height: img.size.height)
                out.append(NSAttributedString(attachment: a))
            }
            let value = p.provider == "deepseek" ? (p.short ?? "").replacingOccurrences(of: "DeepSeek ", with: "")
                : (p.windows.first.map { "\(Int($0.utilization.rounded()))%" } ?? "—")
            out.append(NSAttributedString(string: " " + value, attributes: [.font: font]))
        }
        return out
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            overview?.performClose(nil)
            client?.hubStatusMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
            return
        }
        if let o = overview, o.isShown { o.performClose(nil); return }
        peersAt = .distantPast
        refreshPeers()
        let host = NSHostingController(rootView: HubOverview(hub: self))
        host.sizingOptions = .preferredContentSize
        let p = NSPopover()
        p.contentViewController = host
        p.behavior = .transient
        overview = p
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    fileprivate var overviewPeers: [PeerUsage] { peers }
}

/// The menu-bar overview: every provider's usage, the focus timer and a button per pet.
struct HubOverview: View {
    let hub: PetHub
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = now      // redraw every second for the countdown
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 额度总览").font(.headline)
                Spacer()
                if let p = hub.pillText {
                    Text(p).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if hub.overviewPeers.isEmpty {
                Text("还没读到任何额度。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(hub.overviewPeers) { PeerCard(usage: $0) }
            Divider()
            HStack(spacing: 10) {
                if hub.focusing || hub.resting {
                    Button(hub.focusing ? "结束专注" : "跳过休息") { hub.stopFocus() }
                } else {
                    Button("🍅 开始专注 \(Int(HubSettings.shared.focusMinutes)) 分钟") { hub.startFocus() }
                }
                Spacer()
            }
            .font(.callout)
            Text("打开桌宠面板").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(PetHub.registry, id: \.id) { p in
                    let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleID) != nil
                    Button(p.name) { PetHub.openPanel(of: p.id) }
                        .disabled(!installed)
                        .help(PetHub.isRunning(p) ? "打开\(p.name)的面板" : installed ? "启动\(p.name)" : "这台电脑上没有\(p.name)")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 360)
        .onReceive(tick) { now = $0 }
    }
}
