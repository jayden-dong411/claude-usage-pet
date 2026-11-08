import Darwin
import Foundation

// Daily Codex statistics built from the local logs (~/.codex/sessions/**/*.jsonl).
// - Tokens: each `token_count` event carries the thread's running total and the last reply's usage;
//   a reply is counted when the running total moves (so repeated events are not double counted).
//   input = uncached input, cacheRead = cached input, output = output (incl. reasoning).
// - Active time: gaps of at most 5 minutes between consecutive lines of the same thread.
// Files are read incrementally; the result is cached in Application Support.

struct TokenCounts: Codable, Equatable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var total: Int { input + output + cacheWrite + cacheRead }
    mutating func add(_ o: TokenCounts) {
        input += o.input; output += o.output; cacheWrite += o.cacheWrite; cacheRead += o.cacheRead
    }
}

struct ProjectStat: Codable {
    var tokens = TokenCounts()
    var activeSeconds: Double = 0
    var messages = 0
}

struct DayStats: Codable {
    var tokens = TokenCounts()
    var messages = 0
    var activeSeconds: Double = 0
    var sessions: Set<String> = []
    var models: [String: TokenCounts] = [:]
    var projects: [String: ProjectStat] = [:]

    mutating func merge(_ o: DayStats) {
        tokens.add(o.tokens); messages += o.messages; activeSeconds += o.activeSeconds
        sessions.formUnion(o.sessions)
        for (k, v) in o.models { models[k, default: TokenCounts()].add(v) }
        for (k, v) in o.projects {
            projects[k, default: ProjectStat()].tokens.add(v.tokens)
            projects[k, default: ProjectStat()].activeSeconds += v.activeSeconds
            projects[k, default: ProjectStat()].messages += v.messages
        }
    }
}

private struct FileState: Codable {
    var offset: UInt64 = 0
    var lastTs: Double = 0
    var project = ""
    var projectFromCwd = false
    var lastTotal = 0
    var model = "unknown"
}

private struct IndexCache: Codable {
    var version = 1
    var files: [String: FileState] = [:]
    var days: [String: DayStats] = [:]
    var seen: Set<String> = []
}

final class UsageIndexer: @unchecked Sendable {
    static let shared = UsageIndexer()

    private let queue = DispatchQueue(label: "gpt.dragon.usage-index", qos: .utility)
    private var cache = IndexCache()
    private var loaded = false
    private let cacheURL = AppSupport.dir.appendingPathComponent("usage-index.json")
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
              let c = try? JSONDecoder().decode(IndexCache.self, from: d), c.version == IndexCache().version else { return }
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
            var st = cache.files[url.path] ?? FileState()
            if size < st.offset { st = FileState() }      // file was rewritten
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
    private func processLines(_ raw: UnsafeRawBufferPointer, state st: inout FileState, session: String, isSubagent: Bool) -> Int {
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

    private func handleLine(_ p: UnsafePointer<UInt8>, _ len: Int, _ st: inout FileState, _ session: String, _ isSub: Bool) {
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

// MARK: - Main-thread model for the dashboard

@MainActor
final class DashboardModel: ObservableObject {
    @Published var days: [String: DayStats] = [:]
    @Published var indexing = false
    @Published var progress: Double = 0
    @Published var lastIndexed: Date?
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !indexing else { return }
        indexing = true
        UsageIndexer.shared.run(progress: { [weak self] p in
            Task { @MainActor in self?.progress = p }
        }, done: { [weak self] days in
            Task { @MainActor in
                self?.days = days
                self?.indexing = false
                self?.lastIndexed = Date()
            }
        })
    }

    static func key(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The last `n` days ending today, oldest first (empty days included).
    func series(_ n: Int) -> [(date: Date, stats: DayStats)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<n).reversed().compactMap { i in
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { return nil }
            return (d, days[Self.key(d)] ?? DayStats())
        }
    }

    func total(_ n: Int) -> DayStats {
        series(n).reduce(into: DayStats()) { $0.merge($1.stats) }
    }

    var today: DayStats { days[Self.key(Date())] ?? DayStats() }
}
