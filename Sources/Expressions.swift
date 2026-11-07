import AppKit
import Foundation

/// All 80 Claude大小姐 head stickers, grouped by situation. Every sticker belongs to at
/// least one pool; build.sh checks that against Assets/daxiaojie/head.
enum Mood: String, CaseIterable {
    case breezy      // usage < 40%
    case calm        // usage < 70%
    case strained    // usage < 90%
    case crushed     // usage >= 90%
    case noData      // no usage yet
    case working     // a session is busy
    case night       // 1:00 – 6:00
    case taskStarted
    case taskDone
    case clicked
    case greet
    case farewell
    case oops
    case needsYou    // a session is waiting for approval / an answer
    case petted      // mouse rubbed back and forth over her
    case hop         // double-clicked
    case care        // sedentary / late-night / focus-break reminders

    var faces: [String] {
        switch self {
        case .breezy:
            return ["happy", "starry", "giggle", "laugh", "ojou_laugh", "love", "kawaii_pose", "cat", "peace",
                    "wink", "smug", "proud", "heart_hands", "sparkle_eyes_food", "nom", "watermelon", "popcorn",
                    "tea_sip", "drool", "mic", "glowstick", "coin", "lol_roll", "star_fav"]
        case .calm:
            return ["tea_sip", "nod", "ok", "diary", "think", "idea", "smug", "side_eye", "stare", "shh",
                    "giggle", "confident", "blush", "shy_peek", "peek_corner", "popcorn", "nom"]
        case .strained:
            return ["nervous_laugh", "sweat", "gasp", "shock", "cringe", "facepalm", "dizzy", "eye_roll", "hmph",
                    "pout", "thumbs_down_pout", "tears_hold", "sneeze", "speechless", "angry"]
        case .crushed:
            return ["soul_leave", "melt", "broken", "cry", "sob_cute", "scream", "mind_blown", "sulk_corner",
                    "ghost_scared", "dizzy", "speechless", "tears_hold"]
        case .noData:
            return ["question", "stare", "peek_corner", "shy_peek", "loading", "side_eye", "think"]
        case .working:
            return ["think", "loading", "diary", "fight", "fire", "idea", "nod", "coin", "mic"]
        case .night:
            return ["sleepy", "yawn", "good_night"]
        case .taskStarted:
            return ["fight", "fire", "salute", "confident", "idea"]
        case .taskDone:
            return ["clap", "thumbsup", "like", "ok", "proud", "star_fav", "wave_flag", "glowstick", "peace",
                    "ojou_laugh", "grateful_cry", "thanks", "happy"]
        case .clicked:
            return ["hi", "wink", "kiss", "headpat", "pat_viewer", "shy_peek", "blush", "heart_hands", "love",
                    "cat", "kawaii_pose", "giggle", "smug"]
        case .greet:
            return ["hi", "ojou_laugh", "salute"]
        case .farewell:
            return ["bye", "good_night"]
        case .oops:
            return ["sorry", "thumbs_down_pout", "question", "facepalm"]
        case .needsYou:
            return ["pat_viewer", "peek_corner", "wave_flag", "question", "shy_peek", "mic", "stare"]
        case .petted:
            return ["blush", "shy_peek", "headpat", "love", "heart_hands", "kiss", "giggle"]
        case .hop:
            return ["starry", "peace", "kawaii_pose", "happy", "laugh", "wink"]
        case .care:
            return ["tea_sip", "pat_viewer", "headpat", "nod", "yawn", "good_night"]
        }
    }

    /// Something to say now and then while this mood is showing.
    var lines: [String] {
        switch self {
        case .breezy: return ["额度还很充足，尽管使唤本小姐～", "今天也是优雅的一天", "要来块蛋糕吗？"]
        case .calm: return ["用了一半左右，还算从容", "本小姐正在喝茶观察中", "节奏刚刚好"]
        case .strained: return ["额度有点紧张了…", "要不要歇一会儿？", "本、本小姐才没有慌！"]
        case .crushed: return ["额度快见底了！", "灵魂…要飘走了…", "让本小姐缓一缓…"]
        case .noData: return ["还没拿到用量数据呢", "点我看看？"]
        case .working: return ["认真工作中，请勿打扰～", "思考中…", "看本小姐的！"]
        case .night: return ["这么晚了还不睡吗？", "呼啊…好困…", "熬夜对皮肤不好哦"]
        case .needsYou: return ["有会话在等你哦～", "快来看看嘛！", "本小姐在这里等你呢"]
        case .petted: return ["诶嘿嘿…", "别、别摸了啦…", "头发要乱掉了啦！", "哼，就让你摸一下下", "好、好舒服…才没有！"]
        case .hop: return ["嘿咻～", "跳起来啦！", "看本小姐的弹跳力！"]
        default: return []
        }
    }

    static var allFaces: Set<String> { Set(allCases.flatMap(\.faces)) }
}

enum Faces {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("head/\(name).png"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }

    /// Random face from the pools, avoiding the one on screen.
    static func pick(from moods: [Mood], avoiding current: String?) -> String {
        let all = moods.flatMap(\.faces)
        let choices = all.filter { $0 != current }
        return (choices.isEmpty ? all : choices).randomElement() ?? "happy"
    }
}
