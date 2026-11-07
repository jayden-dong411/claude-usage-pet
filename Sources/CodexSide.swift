import Darwin
import Foundation

// Codex side (ChatGPT desktop / Codex CLI), read from the local logs in ~/.codex:
// - CodexUsageIndexer: daily tokens and active time from ~/.codex/sessions
//   (a reply counts when token_count's running total moves; input = uncached input).
// - CodexLimits: the latest 5-hour / weekly rate limits Codex reported.
// - SharedUsage: Claude limits written to a small JSON file that other local apps (e.g. a
//   ChatGPT/Codex companion pet) can read.

private struct CodexFileState: Codable {
    var offset: UInt64 = 0
    var lastTs: Double = 0
    var project = ""
    var projectFromCwd = false
    var lastTotal = 0
    var model = "unknown"
}

private struct CodexIndexCache: Codable {
    var version = 1
    var files: [String: CodexFileState] = [:]
    var days: [String: DayStats] = [:]
    var seen: Set<String> = []
}

final class CodexUsageIndexer: @unchecked Sendable {
    static let shared = CodexUsageIndexer()

    private let queue = DispatchQueue(label: "claude.daxiaojie.codex-index", qos: .utility)
    private var cache = CodexIndexCache()
    private var loaded = false
    private let cacheURL = AppSupport.dir.appendingPathComponent("codex-usage-index.json")
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    private var dayKeyCache: [Int: String] = [:]

    /// Indexes new transcript lines in the background, then reports all days on the main queue.
    func run(progress: @escaping @Sendable (Double) -> Void, done: @escaping @Sendable ([String: DayStats]) -> Void) {
        queue.async { [self] in
            if !loaded { load(); loaded = true }
            scan(progress: progress)
            save()
            let days = cache.days
            DispatchQueue.main.async { done(days) }
        }
    }

    private func load() {
        guard let d = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder().decode(CodexIndexCache.self, from: d), c.version == CodexIndexCache().version else { return }
        cache = c
    }

    private func save() {
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: cacheURL, options: .atomic) }
    }

    private func scan(progress: (Double) -> Void) {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return }
        var files: [(URL, UInt64)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            files.append((url, size))
        }
        let todo = files.reduce(UInt64(0)) { acc, f in
            let off = cache.files[f.0.path]?.offset ?? 0
            return acc + (f.1 > off ? f.1 - off : 0)
        }
        var doneBytes: UInt64 = 0
        var lastReport = -1.0
        for (url, size) in files {
            var st = cache.files[url.path] ?? CodexFileState()
            if size < st.offset { st = CodexFileState() }      // file was rewritten
            guard size > st.offset else { continue }
            if st.project.isEmpty { st.project = Self.projectName(fromFolder: url) }
            let isSub = false
            let session = url.deletingPathExtension().lastPathComponent
            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            try? fh.seek(toOffset: st.offset)
            var carry = Data()
            while let chunk = try? fh.read(upToCount: 8 << 20), !chunk.isEmpty {
                var buf = carry
                buf.append(chunk)
                let used = buf.withUnsafeBytes { raw -> Int in
                    processLines(raw, state: &st, session: session, isSubagent: isSub)
                }
                st.offset += UInt64(used)
                carry = used < buf.count ? buf.subdata(in: used..<buf.count) : Data()
                doneBytes += UInt64(chunk.count)
                let p = todo == 0 ? 1 : Double(doneBytes) / Double(todo)
                if p - lastReport > 0.01 { lastReport = p; progress(min(1, p)) }
            }
            try? fh.close()
            cache.files[url.path] = st
        }
        progress(1)
    }

    // MARK: Line scanning (byte level, no full JSON parse)

    private static let kTimestamp = Array("\"timestamp\":\"".utf8)
    private static let kCwd = Array("\"cwd\":\"".utf8)
    private static let kTurnContext = Array("\"type\":\"turn_context\"".utf8)
    private static let kTokenCount = Array("\"type\":\"token_count\"".utf8)
    private static let kModel = Array("\"model\":\"".utf8)
    private static let kTotalUsage = Array("\"total_token_usage\":{".utf8)
    private static let kLastUsage = Array("\"last_token_usage\":{".utf8)
    private static let kTotalTokens = Array("\"total_tokens\":".utf8)
    private static let kInput = Array("\"input_tokens\":".utf8)
    private static let kCached = Array("\"cached_input_tokens\":".utf8)
    private static let kCacheWrite = Array("\"cache_write_input_tokens\":".utf8)
    private static let kOutput = Array("\"output_tokens\":".utf8)

    /// Returns the number of bytes consumed (complete lines only).
    private func processLines(_ raw: UnsafeRawBufferPointer, state st: inout CodexFileState, session: String, isSubagent: Bool) -> Int {
        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let n = raw.count
        var start = 0
        while start < n {
            guard let nl = memchr(base + start, 0x0A, n - start) else { break }
            let end = UnsafeRawPointer(nl).assumingMemoryBound(to: UInt8.self) - base
            handleLine(base + start, end - start, &st, session, isSubagent)
            start = end + 1
        }
        return start
    }

    private func find(_ p: UnsafePointer<UInt8>, _ len: Int, _ needle: [UInt8]) -> Int? {
        guard len >= needle.count else { return nil }
        return needle.withUnsafeBufferPointer { nb -> Int? in
            guard let r = memmem(p, len, nb.baseAddress, nb.count) else { return nil }
            return UnsafeRawPointer(r).assumingMemoryBound(to: UInt8.self) - p
        }
    }

    private func string(_ p: UnsafePointer<UInt8>, _ len: Int, after needle: [UInt8], from: Int = 0) -> String? {
        guard let i = find(p + from, len - from, needle) else { return nil }
        let s = from + i + needle.count
        var e = s
        while e < len && p[e] != 0x22 { if p[e] == 0x5C { e += 1 }; e += 1 }
        guard e <= len else { return nil }
        return String(decoding: UnsafeBufferPointer(start: p + s, count: e - s), as: UTF8.self)
    }

    private func int(_ p: UnsafePointer<UInt8>, _ len: Int, after needle: [UInt8], from: Int) -> Int {
        guard let i = find(p + from, len - from, needle) else { return 0 }
        var k = from + i + needle.count, v = 0
        while k < len, p[k] >= 48, p[k] <= 57 { v = v * 10 + Int(p[k] - 48); k += 1 }
        return v
    }

    private func timestamp(_ q: UnsafePointer<UInt8>, _ avail: Int) -> Double? {
        guard avail >= 19, q[10] == 0x54 else { return nil }   // 'T'
        func num(_ i: Int, _ c: Int) -> Int32? {
            var v: Int32 = 0
            for k in 0..<c { let ch = q[i + k]; guard ch >= 48, ch <= 57 else { return nil }; v = v * 10 + Int32(ch - 48) }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let s = num(17, 2) else { return nil }
        var t = tm()
        t.tm_year = y - 1900; t.tm_mon = mo - 1; t.tm_mday = d
        t.tm_hour = h; t.tm_min = mi; t.tm_sec = s
        return Double(timegm(&t))
    }

    private func dayKey(_ t: Double) -> String {
        let bucket = Int(t / 3600)
        if let k = dayKeyCache[bucket] { return k }
        var tt = time_t(t), lt = tm()
        localtime_r(&tt, &lt)
        let k = String(format: "%04d-%02d-%02d", lt.tm_year + 1900, lt.tm_mon + 1, lt.tm_mday)
        dayKeyCache[bucket] = k
        return k
    }

    private func handleLine(_ p: UnsafePointer<UInt8>, _ len: Int, _ st: inout CodexFileState, _ session: String, _ isSub: Bool) {
        guard len > 30, let ti = find(p, len, Self.kTimestamp) else { return }
        let tsStart = ti + Self.kTimestamp.count
        guard let t = timestamp(p + tsStart, len - tsStart) else { return }
        let day = dayKey(t)

        if !st.projectFromCwd, let cwd = string(p, len, after: Self.kCwd), !cwd.isEmpty {
            st.project = (cwd as NSString).lastPathComponent
            st.projectFromCwd = true
        }

        if !isSub {
            if st.lastTs > 0 {
                let gap = t - st.lastTs
                if gap > 0 && gap <= 300 {
                    cache.days[day, default: DayStats()].activeSeconds += gap
                    cache.days[day, default: DayStats()].projects[st.project, default: ProjectStat()].activeSeconds += gap
                }
            }
            if t > st.lastTs { st.lastTs = t }
            cache.days[day, default: DayStats()].sessions.insert(session)
        }

        if find(p, len, Self.kTurnContext) != nil, let m = string(p, len, after: Self.kModel), !m.isEmpty {
            st.model = m
            return
        }
        guard find(p, len, Self.kTokenCount) != nil,
              let ti2 = find(p, len, Self.kTotalUsage), let li = find(p, len, Self.kLastUsage) else { return }
        let total = int(p, len, after: Self.kTotalTokens, from: ti2)
        guard total != st.lastTotal else { return }          // same reply reported again
        st.lastTotal = total
        let input = int(p, len, after: Self.kInput, from: li)
        let cached = int(p, len, after: Self.kCached, from: li)
        let tk = TokenCounts(input: max(0, input - cached),
                             output: int(p, len, after: Self.kOutput, from: li),
                             cacheWrite: int(p, len, after: Self.kCacheWrite, from: li),
                             cacheRead: cached)
        guard tk.total > 0 else { return }
        let model = st.model
        var ds = cache.days[day, default: DayStats()]
        ds.messages += 1
        ds.tokens.add(tk)
        ds.models[model, default: TokenCounts()].add(tk)
        ds.projects[st.project, default: ProjectStat()].tokens.add(tk)
        ds.projects[st.project, default: ProjectStat()].messages += 1
        cache.days[day] = ds
    }

    private static func projectName(fromFolder url: URL) -> String {
        // Codex files live in date folders; the real project comes from the cwd in session_meta.
        "未知项目"
    }
}


// MARK: - Codex rate limits (latest token_count event in recent logs)

struct CodexLimits {
    var fiveHour: LimitWindow?
    var weekly: LimitWindow?
    var plan: String?
    var observedAt: Date
}

enum CodexLimitsReader {
    private static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")

    /// Reads only the tail of files touched in the last 8 days; returns the newest reading.
    static func read() -> CodexLimits? {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(m) < 8 * 86400 { files.append((url, m)) }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var best: (Date, [String: Any])?
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(12) {
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
            let data = (try? h.readToEnd()) ?? Data()
            try? h.close()
            for line in data.split(separator: 0x0A).reversed() where line.range(of: Data("\"rate_limits\"".utf8)) != nil {
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let p = o["payload"] as? [String: Any], let rl = p["rate_limits"] as? [String: Any], rl["primary"] != nil,
                      let ts = (o["timestamp"] as? String).flatMap({ iso.date(from: $0) }) else { continue }
                if best == nil || ts > best!.0 { best = (ts, rl) }
                break
            }
        }
        guard let (at, rl) = best else { return nil }
        func win(_ any: Any?) -> LimitWindow? {
            guard let d = any as? [String: Any], let u = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (d["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if let reset, reset < Date() { return LimitWindow(utilization: 0, resetsAt: nil) }
            return LimitWindow(utilization: max(0, u), resetsAt: reset)
        }
        let plan = (rl["plan_type"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return CodexLimits(fiveHour: win(rl["primary"]), weekly: win(rl["secondary"]), plan: plan, observedAt: at)
    }
}

// MARK: - Claude limits shared with other local apps

enum SharedUsage {
    /// ~/Library/Application Support/ClaudeDaxiaojie/latest-claude-usage.json
    static let url = AppSupport.dir.appendingPathComponent("latest-claude-usage.json")

    static func write(_ s: UsageSnapshot) {
        func w(_ x: LimitWindow?) -> Any { x.map { ["utilization": $0.utilization, "resetsAt": $0.resetsAt?.timeIntervalSince1970 ?? 0] } ?? NSNull() }
        let obj: [String: Any] = ["fiveHour": w(s.fiveHour), "sevenDay": w(s.sevenDay), "plan": s.plan ?? "",
                                  "observedAt": Date().timeIntervalSince1970]
        if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: url, options: .atomic) }
    }
}
