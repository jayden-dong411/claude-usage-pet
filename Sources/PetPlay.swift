import AppKit

// Small interactions shared by all four pets (Claude大小姐, GPT龙娘, Grok娘, DeepSeek娘):
// - picked up / put down, shaken while dragged (dizzy), poked (double-clicked again and again),
//   the pointer resting on her (curious);
// - right-click 「投喂」 (each pet has her own snacks and a favourite) and 「陪我聊聊」;
// - "thanks" when a session you approved carries on, "welcome back" after 10+ minutes away;
// - dropping one pet onto another starts a short exchange between the two (PetHub duet "bump").
// The lines come from Assets/banter.json (Banter.swift). Compiled into all four apps.

@MainActor
final class PetPlay: NSObject {
    let me: String
    /// Says a line for this many seconds.
    var say: (String, Double) -> Void = { _, _ in }
    /// Plays a reaction by mood name (Mood raw values: "oops", "hop", "petted", "clicked", "greet", "taskDone").
    var react: (String, Double) -> Void = { _, _ in }
    /// True when nothing else is being said, so small talk doesn't cut into reminders.
    var quiet: () -> Bool = { true }
    /// Values for {five} {week} … in chatter.
    var vars: () -> [String: String] = { [:] }
    /// Moods for 「说句话」.
    var moods: () -> [String] = { [] }

    private var hops: [Date] = []
    private var lastHover = Date.distantPast
    private var meals: [Date] = []
    private var away = false

    init(me: String) { self.me = me }

    private func line(_ pool: String, _ v: [String: String] = [:]) -> String? { Banter.line(me, pool, vars: v) }

    // MARK: Pointer

    func dragStarted() {
        if Double.random(in: 0..<1) < 0.35, let l = line("dragStart") { say(l, 2.5) }
    }

    /// After a drag: bump into another pet, or say something about the new spot now and then.
    func dragEnded(frame: NSRect) {
        if let other = Self.pet(near: frame, excluding: me) {
            PetHub.shared.startDuet(only: "bump", a: me, b: other)
            return
        }
        if Double.random(in: 0..<1) < 0.4, let l = line("dropped") { say(l, 3) }
    }

    func shaken() {
        react("oops", 3)
        if let l = line("dizzy") { say(l, 3) }
    }

    /// True when this double-click was one too many (3 within 8 s): she complains instead of jumping.
    func doubleClicked() -> Bool {
        let now = Date()
        hops = hops.filter { now.timeIntervalSince($0) < 8 } + [now]
        guard hops.count >= 3 else { return false }
        hops.removeAll()
        react("oops", 3)
        if let l = line("poked") { say(l, 3) }
        return true
    }

    func hovered() {
        guard Date().timeIntervalSince(lastHover) > 45, quiet() else { return }
        lastHover = Date()
        react("clicked", 2.5)
        if let l = line("hover") { say(l, 3) }
    }

    // MARK: Sessions and you

    /// A session that was waiting for you is working again.
    func resumed(_ name: String) {
        if let l = line("thanks") { say(l, 3.5) }
    }

    /// Call every couple of seconds: notices you coming back after 10+ minutes away.
    func tick() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= 600 { away = true; return }
        if away && idle < 3 {
            away = false
            react("greet", 3)
            if let l = line("welcomeBack") { say(l, 4) }
        }
    }

    // MARK: Menu

    /// 「投喂」 and 「陪我聊聊」 submenus for the right-click menu.
    func addItems(to m: NSMenu) {
        let foods = Banter.foods(me)
        if !foods.isEmpty {
            let feed = NSMenu()
            for (i, f) in foods.enumerated() {
                let it = feed.addItem(withTitle: "\(f.emoji) \(f.name)", action: #selector(feedItem(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
            }
            m.addItem(withTitle: "投喂", action: nil, keyEquivalent: "").submenu = feed
        }
        let talk = NSMenu()
        for (title, sel) in [("说句话", #selector(talkNow)), ("讲个冷知识 / 笑话", #selector(talkIdle))] {
            talk.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self
        }
        m.addItem(withTitle: "陪我聊聊", action: nil, keyEquivalent: "").submenu = talk
    }

    @objc private func feedItem(_ sender: NSMenuItem) {
        let foods = Banter.foods(me)
        guard foods.indices.contains(sender.tag) else { return }
        let f = foods[sender.tag]
        let now = Date()
        meals = meals.filter { now.timeIntervalSince($0) < 3600 } + [now]
        if meals.count > 5 {
            react("oops", 3)
            if let l = line("full") { say(l, 3) }
            return
        }
        react(f.fav ? "taskDone" : "petted", 3)
        if let l = line(f.fav ? "favFed" : "fed", ["food": f.name]) { say(l, 3.5) }
    }

    @objc private func talkNow() {
        if let l = Banter.chatter(me, moods: moods(), vars: vars()) { react("clicked", 2.5); say(l, 4.5) }
    }

    @objc private func talkIdle() {
        if let l = Banter.chatter(me, moods: [], vars: vars()) { react("clicked", 2.5); say(l, 4.5) }
    }

    // MARK: Other pets on screen

    /// The pet whose window overlaps `frame` (a pet window just dropped there), if any.
    static func pet(near frame: NSRect, excluding me: String) -> String? {
        var pids: [pid_t: String] = [:]
        for p in PetHub.registry where p.id != me {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID) { pids[app.processIdentifier] = p.id }
        }
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Window bounds are top-left based; flip ours to match.
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let mine = NSRect(x: frame.minX, y: screenH - frame.maxY, width: frame.width, height: frame.height).insetBy(dx: 30, dy: 40)
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, let id = pids[pid],
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let bw = b["Width"], let bh = b["Height"], bh > 150 else { continue }   // the pet, not a menu or popover
            let r = NSRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: bw, height: bh).insetBy(dx: 30, dy: 40)
            if r.intersects(mine) { return id }
        }
        return nil
    }
}
