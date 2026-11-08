import Foundation

// Daily DeepSeek statistics from DeepSeek Harness's ~/.dsh/.dshw-usage.json:
// - Spend / top-ups / closing balance: accounting.books[active].days[day] in units of 1e-8
//   (debitUnits, creditUnits, lastUnits) — the real balance movements, so they match the balance.
//   Falls back to history[day] (spend only) for days missing there.
// - Tokens and calls: events[] {ts, day, model, cost, tokens}. Harness also routes calls to other
//   providers (gpt-…, mimo-…, GLM-…); only models whose name contains "deepseek" count as DeepSeek,
//   the others are kept apart as "other".

struct DSModelStat {
    var tokens = 0
    var cost = 0.0
    var calls = 0
}

struct DSDay {
    var spend = 0.0
    var topUp = 0.0
    var balance: Double?
    var tokens = 0              // DeepSeek models
    var calls = 0               // DeepSeek models
    var otherTokens = 0         // other providers via Harness
    var models: [String: DSModelStat] = [:]

    mutating func merge(_ o: DSDay) {
        spend += o.spend; topUp += o.topUp; tokens += o.tokens; calls += o.calls; otherTokens += o.otherTokens
        if let b = o.balance { balance = b }
        for (k, v) in o.models {
            models[k, default: DSModelStat()].tokens += v.tokens
            models[k, default: DSModelStat()].cost += v.cost
            models[k, default: DSModelStat()].calls += v.calls
        }
    }
}

enum DSStats {
    static func isDeepSeek(_ model: String) -> Bool { model.lowercased().contains("deepseek") }

    static func load() -> (days: [String: DSDay], currency: String) {
        guard let d = try? Data(contentsOf: DeepSeekPeer.url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return ([:], "CNY") }
        var days: [String: DSDay] = [:]
        var currency = "CNY"
        if let acc = o["accounting"] as? [String: Any], let active = acc["active"] as? String,
           let book = (acc["books"] as? [String: Any])?[active] as? [String: Any] {
            currency = (book["currency"] as? String) ?? currency
            for (k, v) in (book["days"] as? [String: Any]) ?? [:] {
                guard let x = v as? [String: Any] else { continue }
                func u(_ key: String) -> Double { ((x[key] as? NSNumber)?.doubleValue ?? 0) / 1e8 }
                var day = DSDay()
                day.spend = u("debitUnits")
                day.topUp = u("creditUnits")
                day.balance = x["lastUnits"] == nil ? nil : u("lastUnits")
                days[k] = day
            }
        }
        for (k, v) in (o["history"] as? [String: Any]) ?? [:] where days[k] == nil {
            days[k] = DSDay(spend: (v as? NSNumber)?.doubleValue ?? 0)
        }
        for case let e as [String: Any] in (o["events"] as? [Any]) ?? [] {
            guard let day = e["day"] as? String else { continue }
            let model = (e["model"] as? String) ?? "unknown"
            let tokens = (e["tokens"] as? NSNumber)?.intValue ?? 0
            let cost = (e["cost"] as? NSNumber)?.doubleValue ?? 0
            var dd = days[day] ?? DSDay()
            if isDeepSeek(model) { dd.tokens += tokens; dd.calls += 1 } else { dd.otherTokens += tokens }
            dd.models[model, default: DSModelStat()].tokens += tokens
            dd.models[model, default: DSModelStat()].cost += cost
            dd.models[model, default: DSModelStat()].calls += 1
            days[day] = dd
        }
        return (days, currency)
    }
}

@MainActor
final class DSDashboardModel: ObservableObject {
    @Published var days: [String: DSDay] = [:]
    @Published var currency = "CNY"
    @Published var lastIndexed: Date?
    @Published var loading = false
    private var timer: Timer?

    var symbol: String { currency == "USD" ? "$" : "¥" }
    func money(_ v: Double) -> String { symbol + String(format: v >= 100 ? "%.0f" : "%.2f", v) }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached {
            let r = DSStats.load()
            await MainActor.run {
                self.days = r.days
                self.currency = r.currency
                self.lastIndexed = Date()
                self.loading = false
            }
        }
    }

    nonisolated static func key(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The last `n` days ending today, oldest first (empty days included).
    func series(_ n: Int) -> [(date: Date, day: DSDay)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<n).reversed().compactMap { i in
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { return nil }
            return (d, days[Self.key(d)] ?? DSDay())
        }
    }

    func total(_ n: Int) -> DSDay { series(n).reduce(into: DSDay()) { $0.merge($1.day) } }

    var today: DSDay { days[Self.key(Date())] ?? DSDay() }

    /// Closing balance per day for the last `n` days, carried forward over days without a record.
    func balanceSeries(_ n: Int) -> [(date: Date, balance: Double)] {
        let keys = days.keys.sorted()
        var last: Double?
        // Seed with the newest balance before the window.
        let start = series(n).first.map { Self.key($0.date) } ?? ""
        for k in keys where k < start { if let b = days[k]?.balance { last = b } }
        return series(n).compactMap { s in
            if let b = s.day.balance { last = b }
            return last.map { (s.date, $0) }
        }
    }
}
