import AppKit

/// Optional sprite sheet (only GPT龙娘 has one: github.com/tqlearning/ai-girl-chatgpt-pets, see
/// ChatGPTPet/Assets/gpt-dragon/pet.json); the other pets use the v3 expressions only.
/// 1536 × 2288 px, 8 columns × 11 rows of 192 × 208 cells.
/// Rows 0–8 are animations, rows 9–10 are 16 look directions (0° = up, clockwise).
enum Anim: String, CaseIterable {
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

    /// Per-frame durations in milliseconds, from FORMAT.md.
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

enum Sprite {
    static let cellW = 192, cellH = 208

    private static let sheet: CGImage? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("spritesheet.png"),
              let img = NSImage(contentsOf: url) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()
    private static var cache: [Int: NSImage] = [:]

    /// False for pets without a sprite sheet (they use the v3 expressions).
    static var available: Bool { sheet != nil }

    static func cell(row: Int, col: Int) -> NSImage? {
        let key = row * 8 + col
        if let i = cache[key] { return i }
        guard let sheet, let cg = sheet.cropping(to: CGRect(x: col * cellW, y: row * cellH, width: cellW, height: cellH)) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cellW, height: cellH))
        cache[key] = img
        return img
    }

    static func frame(_ a: Anim, _ i: Int) -> NSImage? { cell(row: a.row, col: i % a.durations.count) }

    /// Pose looking toward `degrees` (0 = up, clockwise), snapped to the nearest of 16.
    static func look(_ degrees: Double) -> NSImage? {
        let idx = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 22.5).rounded()) % 16
        return cell(row: 9 + idx / 8, col: idx % 8)
    }
}

/// Which animation / expression fits the situation (the Claude pet's "moods").
enum Mood: String {
    case breezy, calm, strained, crushed, noData, working, needsYou, night
    case taskStarted, taskDone, clicked, greet, farewell, oops
    case petted, hop, care

    var anim: Anim {
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

    var v3State: V3State {
        switch self {
        case .needsYou: return .waiting
        case .working, .taskStarted: return .working
        case .strained: return .strained
        case .crushed: return .crushed
        case .night: return .sleepy
        default: return .idle
        }
    }

    var v3Action: V3Action {
        switch self {
        case .taskDone, .hop: return .jump
        case .petted: return .shy
        case .oops, .crushed: return .oops
        case .needsYou: return .surprise
        case .taskStarted, .working: return .start
        case .care, .night: return .care
        case .farewell: return .farewell
        default: return .wave
        }
    }

    /// Something to say now and then (pet-specific lines come from Spec.lines).
    var lines: [String] {
        switch self {
        case .working: return ["认真思考中…", "让我想想～", "马上就好"]
        case .night: return ["这么晚了还不睡吗？", "呼啊…好困…"]
        case .petted: return ["诶嘿嘿…", "别、别摸了啦…", "头发要乱掉了啦！", "好、好舒服…才没有！"]
        case .hop: return ["嘿咻～", "跳起来啦！"]
        default: return Spec.lines(self)
        }
    }
}
