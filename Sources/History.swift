import Foundation

enum AppSupport {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeDaxiaojie")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
}

/// One usage reading, kept so the panel can show a trend and estimate when a limit runs out.
struct UsageSample: Codable {
    let t: Date
    let account: String
    let fiveHour: Double?
    let fiveReset: Date?
    let sevenDay: Double?
    let sevenReset: Date?
}

enum Forecast {
    case collecting                  // not enough readings in this window yet
    case flat                        // no growth lately
    case safe(perHour: Double)       // at this pace the window resets first
    case runsOut(at: Date, perHour: Double)

    var text: String {
        switch self {
        case .collecting: return "正在收集数据，稍后给出预测"
        case .flat: return "最近没有增长"
        case .safe(let r): return "每小时约 +\(Fmt.pct(r))，重置前用不完"
        case .runsOut(let t, let r):
            return "每小时约 +\(Fmt.pct(r))，按这个速度约 \(Fmt.when(t)) 用完"
        }
    }
    var isWarning: Bool { if case .runsOut = self { return true }; return false }
}

@MainActor
final class UsageHistory {
    private(set) var samples: [UsageSample] = []
    private let url = AppSupport.dir.appendingPathComponent("usage-history.jsonl")
    private let keep: TimeInterval = 8 * 86400

    init() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let cutoff = Date().addingTimeInterval(-keep)
        samples = text.split(separator: "\n").compactMap { try? dec.decode(UsageSample.self, from: Data($0.utf8)) }
            .filter { $0.t > cutoff }
        // Rewrite the file without old lines now and then.
        if text.count > 2_000_000 { rewrite() }
    }

    /// Fake readings for screenshots: a steady climb to `fiveHourNow` over the last hour.
    func loadDemo(account: String, fiveHourNow: Double) {
        let now = Date()
        let reset = now.addingTimeInterval(7800)
        samples = (0...12).map { i in
            let t = now.addingTimeInterval(Double(i - 12) * 300)
            return UsageSample(t: t, account: account, fiveHour: fiveHourNow - Double(12 - i) * 2.2, fiveReset: reset,
                               sevenDay: 28, sevenReset: now.addingTimeInterval(340000))
        }
    }

    func record(_ snap: UsageSnapshot) {
        let account = snap.account ?? "unknown"
        let s = UsageSample(t: Date(), account: account,
                            fiveHour: snap.fiveHour?.utilization, fiveReset: snap.fiveHour?.resetsAt,
                            sevenDay: snap.sevenDay?.utilization, sevenReset: snap.sevenDay?.resetsAt)
        if let last = samples.last(where: { $0.account == account }),
           last.fiveHour == s.fiveHour, last.sevenDay == s.sevenDay,
           s.t.timeIntervalSince(last.t) < 600 { return }
        samples.append(s)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard var line = try? enc.encode(s) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    private func rewrite() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let data = samples.compactMap { try? enc.encode($0) }.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        try? data.write(to: url)
    }

    /// Readings of the current 5-hour window, oldest first.
    func fiveHourSeries(account: String?, window: LimitWindow?) -> [(Date, Double)] {
        guard let window, let reset = window.resetsAt else { return [] }
        return samples.filter {
            $0.account == (account ?? "unknown") && sameWindow($0.fiveReset, reset) && $0.fiveHour != nil
        }.map { ($0.t, $0.fiveHour!) }
    }

    func forecast(account: String?, fiveHour: Bool, window: LimitWindow?) -> Forecast? {
        guard let window, let reset = window.resetsAt else { return nil }
        let acct = account ?? "unknown"
        let lookback: TimeInterval = fiveHour ? 90 * 60 : 24 * 3600
        let minSpan: TimeInterval = fiveHour ? 10 * 60 : 2 * 3600
        let now = Date()
        let pts = samples.filter {
            $0.account == acct && $0.t > now.addingTimeInterval(-lookback)
                && sameWindow(fiveHour ? $0.fiveReset : $0.sevenReset, reset)
        }.compactMap { s -> (Date, Double)? in
            guard let v = fiveHour ? s.fiveHour : s.sevenDay else { return nil }
            return (s.t, v)
        }
        guard let first = pts.first, now.timeIntervalSince(first.0) >= minSpan else { return .collecting }
        let rise = window.utilization - first.1
        let hours = now.timeIntervalSince(first.0) / 3600
        guard rise > 0.5 else { return .flat }
        let perHour = rise / hours
        let left = max(0, 100 - window.utilization)
        let eta = now.addingTimeInterval(left / perHour * 3600)
        return eta < reset ? .runsOut(at: eta, perHour: perHour) : .safe(perHour: perHour)
    }

    private func sameWindow(_ a: Date?, _ b: Date) -> Bool {
        guard let a else { return false }
        return abs(a.timeIntervalSince(b)) < 180
    }
}
