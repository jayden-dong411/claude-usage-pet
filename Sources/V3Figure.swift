import AppKit

// "v3" look shared by the Claude大小姐, GPT龙娘 and Grok娘 pets: the 8 expression portraits from
// github.com/lmy414/ai-chan-sheets (CC BY-NC-SA 4.0, character designs by ZipZipPipe), with the white
// background removed by ../Tools/make_v3_assets.py. The pet shows the expression that fits her mood
// and swaps it on reactions; only short reactions move (a hop, a shake) — no constant bobbing.
//
// Resources: <app>/Contents/Resources/v3/face_<expression>.png.
// This file is compiled into all three apps, so every type here carries a V3 prefix.

enum V3Face: String, CaseIterable {
    case smile, calm, surprised, shy, pout, giggle, serious, aggrieved
}

/// Long-running state, from the app's mood.
enum V3State: Equatable {
    case idle, working, waiting, strained, crushed, sleepy
}

/// One-off reactions.
enum V3Action {
    case wave, jump, shy, oops, surprise, start, care, farewell
}

enum V3Assets {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        // Decoded up front (a bitmap rep), so it draws right away in any context.
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("v3/\(name).png"),
              let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { return nil }
        let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        img.addRepresentation(rep)
        cache[name] = img
        return img
    }

    /// False when the app was built without the v3 pictures.
    static var available: Bool { face(.smile) != nil }

    static func face(_ f: V3Face) -> NSImage? { image("face_\(f.rawValue)") }
}

@MainActor
final class V3Figure {
    private weak var view: NSImageView?
    /// Area the portrait sits in, in the host view's coordinates.
    var home: NSRect
    private let onFace: (NSImage?) -> Void

    private var state: V3State = .idle
    private var action: V3Action?
    private var actionStart = Date()
    private var actionLength: Double = 0
    private(set) var face: V3Face = .calm
    private var holdUntil = Date.distantPast
    private var idleFaceAt = Date.distantPast
    private var timer: Timer?
    private var lastFrame = NSRect.zero

    init(imageView: NSImageView, home: NSRect, onFace: @escaping (NSImage?) -> Void) {
        self.view = imageView
        self.home = home
        self.onFace = onFace
    }

    func start() {
        view?.imageScaling = .scaleProportionallyUpOrDown
        setFace(baseFace(), force: true)
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onFace(nil)
    }

    func setState(_ s: V3State) {
        guard s != state else { return }
        state = s
        if action == nil && Date() >= holdUntil { setFace(baseFace()) }
    }

    /// Plays a reaction for `seconds` with its expression.
    func react(_ a: V3Action, seconds: Double) {
        action = a
        actionStart = Date()
        actionLength = max(0.6, seconds)
        setFace(Self.face(for: a))
    }

    /// Holds an expression for a while (e.g. while a speech bubble is up).
    func show(_ f: V3Face, seconds: Double) {
        setFace(f)
        holdUntil = Date().addingTimeInterval(seconds)
    }

    // Dragging only moves the window; the portrait stays as it is.
    func drag(_ dx: CGFloat) {}
    func endDrag() {}

    // MARK: Faces

    static func face(for a: V3Action) -> V3Face {
        switch a {
        case .wave, .care, .farewell: return .smile
        case .jump: return .giggle
        case .shy: return .shy
        case .oops: return .aggrieved
        case .surprise: return .surprised
        case .start: return .serious
        }
    }

    /// Expressions to rotate through in each state — mostly cheerful (the user found her too serious).
    private var pool: [V3Face] {
        switch state {
        case .idle: return [.smile, .giggle, .smile, .shy, .giggle, .calm]
        case .working: return [.smile, .giggle, .serious, .smile, .calm]
        case .waiting: return [.surprised, .smile, .shy]
        case .strained: return [.pout, .smile, .surprised]
        case .crushed: return [.aggrieved, .pout, .surprised]
        case .sleepy: return [.giggle, .calm, .shy]
        }
    }

    private func baseFace() -> V3Face {
        pool.filter { $0 != face }.randomElement() ?? .smile
    }

    private func setFace(_ f: V3Face, force: Bool = false) {
        guard force || f != face else { return }
        face = f
        let img = V3Assets.face(f)
        view?.image = img
        onFace(img)
    }

    // MARK: Motion (reactions only)

    private func tick() {
        guard let view else { return }
        let now = Date()
        if action != nil, now.timeIntervalSince(actionStart) >= actionLength {
            action = nil
            setFace(baseFace())
        }
        // Swap to another expression of the current state every 6–12 seconds.
        if action == nil && now >= holdUntil && now >= idleFaceAt {
            if idleFaceAt != .distantPast { setFace(baseFace()) }
            idleFaceAt = now.addingTimeInterval(.random(in: 6...12))
        }

        var dx: CGFloat = 0, dy: CGFloat = 0
        if let a = action {
            let el = now.timeIntervalSince(actionStart)
            let p = CGFloat(min(1, el / actionLength))
            switch a {
            case .jump:
                if el < 1.1 { dy = 26 * CGFloat(abs(sin(.pi * el / 0.55))) }
            case .wave, .care, .start, .surprise:
                if el < 0.42 { dy = 12 * CGFloat(sin(.pi * el / 0.42)) }
            case .shy:
                if el < 1.2 { dx = 3 * CGFloat(sin(2 * .pi * el * 5)) * (1 - p) }
            case .oops:
                if el < 1.0 { dx = 5 * CGFloat(sin(2 * .pi * el * 9)) * (1 - p) }
            case .farewell:
                break
            }
        }
        let f = home.offsetBy(dx: dx.rounded(), dy: dy.rounded())
        if f != lastFrame { view.frame = f; lastFrame = f }
    }
}
