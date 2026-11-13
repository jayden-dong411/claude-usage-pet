import Foundation

// Gemini side of the usage statistics (Antigravity, see GeminiLink.swift): daily tokens and active time from each
// conversation's model calls (GetCascadeTrajectory → generatorMetadata[].chatModel.usage; the time is that of the
// call's first step). Input = uncached input, cache read = cacheReadTokens, output includes thinking.
// Antigravity only answers while it is open, so every conversation's result is cached here and kept after
// Antigravity forgets it; a conversation is read again only when its last change moves.

private struct GeminiConvCache: Codable {
    var modified: String
    var days: [String: DayStats]
}

private struct GeminiIndexCache: Codable {
    var version = 1
    var convs: [String: GeminiConvCache] = [:]
}

final class GeminiUsageIndexer: @unchecked Sendable {
    static let shared = GeminiUsageIndexer()

    private let queue = DispatchQueue(label: "aipets.gemini-index", qos: .utility)
    private var cache = GeminiIndexCache()
    private var loaded = false
    private let cacheURL = AppSupport.dir.appendingPathComponent("gemini-usage-index.json")

    /// Reads new or changed conversations in the background, then reports all days on the main queue.
    func run(progress: @escaping @Sendable (Double) -> Void = { _ in }, done: @escaping @Sendable ([String: DayStats]) -> Void) {
        queue.async { [self] in
            if !loaded { load(); loaded = true }
            scan(progress: progress)
            var days: [String: DayStats] = [:]
            for c in cache.convs.values { for (k, v) in c.days { days[k, default: DayStats()].merge(v) } }
            DispatchQueue.main.async { done(days) }
        }
    }

    private func load() {
        guard let d = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder().decode(GeminiIndexCache.self, from: d), c.version == GeminiIndexCache().version else { return }
        cache = c
    }

    private func save() {
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: cacheURL, options: .atomic) }
    }

    private func scan(progress: (Double) -> Void) {
        guard let all = GeminiLS.call("GetAllCascadeTrajectories")?["trajectorySummaries"] as? [String: Any] else { return }
        _ = GeminiPeer.live()                        // fills the model names
        let names = GeminiPeer.modelNames
        let todo = all.compactMap { id, any -> (String, [String: Any], String)? in
            guard let s = any as? [String: Any], let m = s["lastModifiedTime"] as? String,
                  cache.convs[id]?.modified != m else { return nil }
            return (id, s, m)
        }
        for (i, (id, summary, modified)) in todo.enumerated() {
            guard let t = GeminiLS.call("GetCascadeTrajectory", ["cascadeId": id], timeout: 30)?["trajectory"] as? [String: Any] else { continue }
            cache.convs[id] = GeminiConvCache(modified: modified, days: Self.days(of: t, id: id, summary: summary, names: names))
            progress(Double(i + 1) / Double(todo.count))
            if i % 5 == 4 { save() }
        }
        if !todo.isEmpty { save() }
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func days(of t: [String: Any], id: String, summary: [String: Any], names: [String: String]) -> [String: DayStats] {
        let steps = (t["steps"] as? [[String: Any]]) ?? []
        let times: [Date?] = steps.map { GeminiLS.date(($0["metadata"] as? [String: Any])?["createdAt"]) }
        let fallback = GeminiLS.date(summary["lastModifiedTime"]) ?? Date()
        var project = GeminiConversations.workspaceName(summary)
        if project.isEmpty { project = "Antigravity" }
        var out: [String: DayStats] = [:]

        for g in (t["generatorMetadata"] as? [[String: Any]]) ?? [] {
            guard let u = (g["chatModel"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
            func n(_ k: String) -> Int { Int((u[k] as? String) ?? "") ?? (u[k] as? NSNumber)?.intValue ?? 0 }
            let idx = (g["stepIndices"] as? [NSNumber])?.first?.intValue ?? -1
            let at = (idx >= 0 && idx < times.count ? times[idx] : nil) ?? fallback
            let tok = TokenCounts(input: n("inputTokens"), output: n("outputTokens"), cacheWrite: 0, cacheRead: n("cacheReadTokens"))
            let raw = (u["model"] as? String) ?? "unknown"
            let model = names[raw] ?? (raw.hasPrefix("MODEL_") ? "Gemini" : raw)
            var d = out[dayKey(at)] ?? DayStats()
            d.tokens.add(tok)
            d.messages += 1
            d.sessions.insert(id)
            d.models[model, default: TokenCounts()].add(tok)
            d.projects[project, default: ProjectStat()].tokens.add(tok)
            d.projects[project, default: ProjectStat()].messages += 1
            out[dayKey(at)] = d
        }
        // Active time: gaps of at most 5 minutes between consecutive steps.
        let sorted = times.compactMap { $0 }.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let gap = b.timeIntervalSince(a)
            guard gap > 0, gap <= 300 else { continue }
            let k = dayKey(b)
            out[k, default: DayStats()].activeSeconds += gap
            out[k, default: DayStats()].sessions.insert(id)
            out[k, default: DayStats()].projects[project, default: ProjectStat()].activeSeconds += gap
        }
        return out
    }
}
