import AppKit

// Animated figure mode: Claude大小姐 full-body sprite sheet from github.com/houn1u/claude-lady-pets-v2
// (ChatGPT Pets v2 layout: 1536 × 2288 px, 8 × 11 cells of 192 × 208; rows 0–8 animations,
// rows 9–10 = 16 look directions, 0° = up, clockwise). The artwork has no open license, so it is
// only bundled in local builds (Assets/claude-lady is git-ignored and left out of package.sh).

enum LadyAnim: String {
    case idle, runningRight = "running-right", runningLeft = "running-left", waving, jumping, failed, waiting, running, review

    var row: Int {
        switch self {
        case .idle: return 0
        case .runningRight: return 1
        case .runningLeft: return 2
        case .waving: return 3
        case .jumping: return 4
        case .failed: return 5
        case .waiting: return 6
        case .running: return 7
        case .review: return 8
        }
    }

    var durations: [Int] {
        switch self {
        case .idle: return [280, 110, 110, 140, 140, 320]
        case .runningRight, .runningLeft: return [120, 120, 120, 120, 120, 120, 120, 220]
        case .waving: return [140, 140, 140, 280]
        case .jumping: return [140, 140, 140, 140, 280]
        case .failed: return [140, 140, 140, 140, 140, 140, 140, 240]
        case .waiting: return [150, 150, 150, 150, 150, 260]
        case .running: return [120, 120, 120, 120, 120, 220]
        case .review: return [150, 150, 150, 150, 150, 280]
        }
    }
}

enum LadySprite {
    private static let sheet: CGImage? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("lady-spritesheet.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()
    private static var cache: [Int: NSImage] = [:]

    /// False when the app was built without the (local-only) sprite sheet.
    static var available: Bool { sheet != nil }

    static func cell(row: Int, col: Int) -> NSImage? {
        let key = row * 8 + col
        if let i = cache[key] { return i }
        guard let sheet, let cg = sheet.cropping(to: CGRect(x: col * 192, y: row * 208, width: 192, height: 208)) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: 192, height: 208))
        cache[key] = img
        return img
    }

    static func frame(_ a: LadyAnim, _ i: Int) -> NSImage? { cell(row: a.row, col: i % a.durations.count) }

    static func look(_ degrees: Double) -> NSImage? {
        let norm = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let idx = Int((norm / 22.5).rounded()) % 16
        return cell(row: 9 + idx / 8, col: idx % 8)
    }
}

extension Mood {
    /// The animation that plays for this mood in animated-figure mode.
    var ladyAnim: LadyAnim {
        switch self {
        case .breezy, .calm, .noData, .night: return .idle
        case .strained: return .review
        case .crushed, .oops: return .failed
        case .working, .taskStarted: return .running
        case .needsYou: return .waiting
        case .taskDone, .hop: return .jumping
        case .clicked, .greet, .farewell, .petted, .care: return .waving
        }
    }
}

/// Plays sprite animations into an image view: a base loop, reactions played N times on top,
/// running while dragged, and look-toward-the-mouse poses while idle.
@MainActor
final class SpriteAnimator {
    private weak var imageView: NSImageView?
    private let onFrame: (NSImage?) -> Void
    private(set) var base: LadyAnim = .idle
    private(set) var current: LadyAnim = .idle
    private var frameIndex = 0
    private var loopsLeft = 0
    private var timer: Timer?
    private var dragAnim: LadyAnim?
    private var looking = false

    init(imageView: NSImageView, onFrame: @escaping (NSImage?) -> Void) {
        self.imageView = imageView
        self.onFrame = onFrame
    }

    var isIdle: Bool { current == .idle && loopsLeft == 0 && dragAnim == nil }

    func start() { play(base) }

    func stop() {
        timer?.invalidate()
        timer = nil
        onFrame(nil)
    }

    func setBase(_ a: LadyAnim) {
        base = a
        if loopsLeft == 0 && dragAnim == nil && current != a { play(a) }
    }

    func react(_ a: LadyAnim, loops: Int) {
        loopsLeft = max(1, loops)
        play(a)
    }

    func drag(_ dx: CGFloat) {
        guard abs(dx) > 0.5 else { return }
        let next: LadyAnim = dx > 0 ? .runningRight : .runningLeft
        if dragAnim != next { dragAnim = next; play(next) }
    }

    func endDrag() {
        dragAnim = nil
        loopsLeft = 0
        play(base)
    }

    /// Pose toward `degrees` (0 = up, clockwise), or back to the animation with nil.
    func look(_ degrees: Double?) {
        guard isIdle else { if looking { looking = false; show() }; return }
        if let degrees {
            looking = true
            imageView?.image = LadySprite.look(degrees)
        } else if looking {
            looking = false
            show()
        }
    }

    private func play(_ a: LadyAnim) {
        current = a
        frameIndex = 0
        looking = false
        show()
        schedule()
    }

    private func show() {
        let img = LadySprite.frame(current, frameIndex)
        if !looking { imageView?.image = img }
        onFrame(img)
    }

    private func schedule() {
        timer?.invalidate()
        let ms = current.durations[frameIndex % current.durations.count]
        timer = Timer.scheduledTimer(withTimeInterval: Double(ms) / 1000, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }

    private func advance() {
        frameIndex += 1
        if frameIndex >= current.durations.count {
            frameIndex = 0
            if loopsLeft > 0 { loopsLeft -= 1 }
            if loopsLeft == 0 && dragAnim == nil && current != base { play(base); return }
        }
        show()
        schedule()
    }
}
