import Foundation

// What the pets say, from Assets/banter.json (bundled as Resources/banter.json; the Windows apps read the
// same file). Each pet has pools by mood, by time of day / day of week, and an "idle" pool of anytime
// chatter; duets are short two-pet exchanges started by PetHub. Lines are never repeated until a dozen
// others were said, and {five} {week} {time} {balance} {today} {A} {B} {Apct} {Bpct} are filled in.
// Compiled into all four apps.

struct BanterDuet {
    var pair: [String]?          // fixed roles A, B; nil = any two pets
    var when: String
    var lines: [(role: String, text: String)]
}

@MainActor
enum Banter {
    private struct PetLines: Decodable {
        var name: String
        var moods: [String: [String]]
        var time: [String: [String]]
        var idle: [String]
        var foods: [[String]]?
    }

    private static var pets: [String: PetLines] = [:]
    private(set) static var duets: [BanterDuet] = []
    private static var loaded = false
    private static var recent: [String] = []

    private static func load() {
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "banter", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let p = root["pets"], let d = try? JSONSerialization.data(withJSONObject: p) {
            pets = (try? JSONDecoder().decode([String: PetLines].self, from: d)) ?? [:]
        }
        for case let o as [String: Any] in root["duets"] as? [Any] ?? [] {
            let lines = (o["lines"] as? [[String]] ?? []).compactMap { $0.count == 2 ? (role: $0[0], text: $0[1]) : nil }
            guard !lines.isEmpty else { continue }
            duets.append(BanterDuet(pair: o["pair"] as? [String], when: o["when"] as? String ?? "any", lines: lines))
        }
    }

    static var available: Bool { load(); return !pets.isEmpty }

    /// Snacks for 「投喂」: name, emoji and whether it is her favourite.
    static func foods(_ pet: String) -> [(name: String, emoji: String, fav: Bool)] {
        load()
        return (pets[pet]?.foods ?? []).compactMap { $0.count >= 2 ? (name: $0[0], emoji: $0[1], fav: $0.count > 2 && $0[2] == "fav") : nil }
    }

    static func name(_ pet: String) -> String {
        load()
        return pets[pet]?.name ?? PetHub.registry.first(where: { $0.id == pet })?.name ?? pet
    }

    /// Fills `{key}`; nil when a value is missing.
    static func fill(_ line: String, _ vars: [String: String]) -> String? {
        var out = line
        var all = vars
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        all["time"] = all["time"] ?? f.string(from: Date())
        for (k, v) in all { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
        return out.contains("{") ? nil : out
    }

    private static func pickFresh(_ pool: [String], _ vars: [String: String]) -> String? {
        let ready = pool.compactMap { fill($0, vars) }
        let fresh = ready.filter { !recent.contains($0) }
        guard let line = (fresh.isEmpty ? ready : fresh).randomElement() else { return nil }
        recent.append(line)
        if recent.count > 14 { recent.removeFirst(recent.count - 14) }
        return line
    }

    /// A line from one pool (e.g. "petted", "hop", "needsYou").
    static func line(_ pet: String, _ mood: String, vars: [String: String] = [:]) -> String? {
        load()
        return pickFresh(pets[pet]?.moods[mood] ?? [], vars)
    }

    /// Time-of-day and day-of-week pools that apply now.
    static func timeKeys(_ date: Date = Date()) -> [String] {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date), wd = cal.component(.weekday, from: date)
        var keys: [String] = []
        switch h {
        case 5..<11: keys.append("morning")
        case 11..<14: keys.append("noon")
        case 14..<18: keys.append("afternoon")
        case 18..<23: keys.append("evening")
        case 23, 0: keys.append("late")
        default: break
        }
        if wd == 2 { keys.append("monday") }
        if wd == 6 && h >= 12 { keys.append("friday") }
        if wd == 1 || wd == 7 { keys.append("weekend") }
        return keys
    }

    /// Something to say now and then: mostly about the current mood, sometimes about the time, sometimes anything.
    static func chatter(_ pet: String, moods: [String], vars: [String: String] = [:]) -> String? {
        load()
        guard let p = pets[pet] else { return nil }
        let roll = Double.random(in: 0..<1)
        let timePool = timeKeys().flatMap { p.time[$0] ?? [] }
        let moodPool = moods.flatMap { p.moods[$0] ?? [] }
        var order: [[String]]
        if roll < 0.5 { order = [moodPool, p.idle, timePool] }
        else if roll < 0.72 && !timePool.isEmpty { order = [timePool, moodPool, p.idle] }
        else { order = [p.idle, moodPool, timePool] }
        for pool in order where !pool.isEmpty {
            if let l = pickFresh(pool, vars) { return l }
        }
        return nil
    }
}
