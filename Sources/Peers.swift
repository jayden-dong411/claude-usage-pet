import AppKit
import SwiftUI

// Limits shared between the three local pets (Claude大小姐, GPT龙娘, Grok娘), so each panel can show the
// others':
// - Claude limits can only be fetched by the Claude pet (it holds the claude.ai login), so it writes
//   ~/Library/Application Support/AIPets/claude.json for the others.
// - Codex limits: live from the ChatGPT account (CodexLive, using the Codex CLI login in
//   ~/.codex/auth.json — the user approved this on 2026-11-08), shared via codex.json; the local
//   ~/.codex/sessions logs (CodexPeer.read) are only a fallback, since they miss usage from the
//   web, phone or cloud tasks and stop updating when Codex isn't used on this Mac.
// - Grok Bot's weekly usage comes from the Grok Bot desktop app's own cache (GrokBotPeer.read) — the
//   Grok Bot app, not the Grok Build CLI.
// - DeepSeek has no rate limits but a prepaid balance, which DeepSeek Harness keeps in
//   ~/.dsh/.dshw-usage.json (DeepSeekPeer.read).
// Compiled into all three apps, so every type here carries a Peer prefix.

struct PeerWindow: Codable {
    var label: String
    var utilization: Double
    var resetsAt: Date?
}

struct PeerUsage: Codable, Identifiable {
    var provider: String           // "claude" | "codex" | "grok"
    var title: String
    var plan: String?
    var windows: [PeerWindow] = []
    var lines: [String] = []
    var observedAt: Date
    /// One-line summary for the collapsed "其他额度" header (defaults to the first window's percent).
    var short: String? = nil
    var id: String { provider }

    var summary: String {
        if let short { return short }
        let name = provider == "codex" ? "Codex" : title
        return "\(name) " + (windows.first.map { "\(Int($0.utilization.rounded()))%" } ?? "—")
    }
}

enum PeerStore {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIPets")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func write(_ u: PeerUsage) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(u) { try? d.write(to: dir.appendingPathComponent("\(u.provider).json"), options: .atomic) }
    }

    /// Ignores readings older than `maxAge` (the writer is probably not running any more).
    static func read(_ provider: String, maxAge: TimeInterval = 24 * 3600) -> PeerUsage? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(provider).json")),
              let u = try? dec.decode(PeerUsage.self, from: d),
              Date().timeIntervalSince(u.observedAt) < maxAge else { return nil }
        return u
    }

    /// The two other providers for `me`, freshest source first. Call off the main thread.
    static func peers(excluding me: String) -> [PeerUsage] {
        var out: [PeerUsage] = []
        if me != "claude", let c = read("claude") { out.append(c) }
        if me != "codex", let c = read("codex", maxAge: 300)
            ?? CodexLive.peer().map({ u -> PeerUsage in write(u); return u })
            ?? CodexPeer.read() ?? read("codex") {
            out.append(c)
        }
        if me != "grok", let g = GrokBotPeer.read() { out.append(g) }
        if me != "deepseek", let d = DeepSeekPeer.read() { out.append(d) }
        return out
    }
}

// MARK: - Codex limits, live from the ChatGPT account

/// The same request the Codex CLI makes for `/status`: GET chatgpt.com/backend-api/wham/usage with the
/// CLI's own login (~/.codex/auth.json, read-only; Codex refreshes the token itself when it runs).
enum CodexLive {
    struct Limits {
        var fiveHour: Double?          // nil: the account reported no such window (shown as "—", not 0%)
        var fiveReset: Date?
        var week: Double?
        var weekReset: Date?
        var plan: String?
        var at: Date
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (Date, Limits?) = (.distantPast, nil)
    nonisolated(unsafe) private static var lastError: String?

    /// Why the last request failed (nil after a success).
    static var error: String? { lock.lock(); defer { lock.unlock() }; return lastError }

    /// Blocking; call off the main thread. Results are reused for `maxAge` seconds.
    static func fetch(maxAge: TimeInterval = 90) -> Limits? {
        lock.lock()
        if Date().timeIntervalSince(cache.0) < maxAge { let c = cache.1; lock.unlock(); return c }
        lock.unlock()
        let r = request()
        lock.lock()
        cache = (Date(), r)
        lock.unlock()
        return r
    }

    private static func request() -> Limits? {
        func fail(_ s: String) -> Limits? { lock.lock(); lastError = s; lock.unlock(); return nil }
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let d = try? Data(contentsOf: authURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["tokens"] as? [String: Any], let token = t["access_token"] as? String, !token.isEmpty
        else { return fail("没有找到 Codex 登录（~/.codex/auth.json）") }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let acct = t["account_id"] as? String { req.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var body: Data?, status = 0
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            body = data
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 25)
        guard status == 200, let body, let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rl = j["rate_limit"] as? [String: Any] else {
            return fail(status == 401 || status == 403 ? "Codex 登录已过期，打开一次 ChatGPT 里的 Codex 就会自动续上"
                        : status == 0 ? "连不上 chatgpt.com" : "查询失败（HTTP \(status)）")
        }
        func win(_ any: Any?) -> (Double?, Date?) {
            guard let w = any as? [String: Any] else { return (nil, nil) }
            let used = (w["used_percent"] as? NSNumber)?.doubleValue ?? 0
            let reset = (w["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let after = (w["reset_after_seconds"] as? NSNumber)?.doubleValue ?? 0
            let length = (w["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 0
            // An unused window reports a reset a full window away: it hasn't started yet.
            if used == 0 && length > 0 && after >= length - 60 { return (0, nil) }
            return (max(0, used), reset)
        }
        let f = win(rl["primary_window"]), w = win(rl["secondary_window"])
        let plan = (j["plan_type"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        lock.lock(); lastError = nil; lock.unlock()
        return Limits(fiveHour: f.0, fiveReset: f.1, week: w.0, weekReset: w.1, plan: plan, at: Date())
    }

    static func peer() -> PeerUsage? {
        guard let l = fetch() else { return nil }
        return PeerUsage(provider: "codex", title: "ChatGPT · Codex", plan: l.plan,
                         windows: [l.fiveHour.map { PeerWindow(label: "5 小时", utilization: $0, resetsAt: l.fiveReset) },
                                   l.week.map { PeerWindow(label: "每周", utilization: $0, resetsAt: l.weekReset) }].compactMap { $0 },
                         observedAt: l.at)
    }
}

// MARK: - Codex limits from the local logs (fallback: latest token_count event in recent rollouts)

enum CodexPeer {
    private static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")

    static func read() -> PeerUsage? {
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
        func win(_ label: String, _ any: Any?) -> PeerWindow? {
            guard let d = any as? [String: Any], let u = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (d["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if let reset, reset < Date() { return PeerWindow(label: label, utilization: 0, resetsAt: nil) }
            return PeerWindow(label: label, utilization: max(0, u), resetsAt: reset)
        }
        let plan = (rl["plan_type"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return PeerUsage(provider: "codex", title: "ChatGPT · Codex", plan: plan,
                         windows: [win("5 小时", rl["primary"]), win("每周", rl["secondary"])].compactMap { $0 },
                         observedAt: at)
    }
}

// MARK: - Grok Bot (desktop app, bundle com.anysphere.sand)

/// Grok Bot keeps its client state as JSON blobs in
/// ~/Library/Application Support/Grok Bot/sand-client-persistence/<base32(key)>.blob, e.g.
/// key "sand.client.slice.account.<user>.weekly-usage.cache" holds the plan's weekly usage.
enum GrokBotStore {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Grok Bot/sand-client-persistence")

    static func decodeKey(_ fileName: String) -> String? {
        guard fileName.hasSuffix(".blob") else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for ch in fileName.dropLast(5).uppercased() {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | i
            bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((value >> bits) & 0xff)) }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// The newest blob whose key ends with `suffix`, decoded as JSON ({"schemaVersion", "value"}).
    static func value(suffix: String) -> [String: Any]? {
        let fm = FileManager.default
        var best: (Date, URL)?
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            guard let key = decodeKey(name), key.hasSuffix(suffix) else { continue }
            let url = dir.appendingPathComponent(name)
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || m > best!.0 { best = (m, url) }
        }
        guard let url = best?.1, let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["value"] as? [String: Any]
    }
}

enum GrokBotPeer {
    /// Weekly usage as Grok Bot last read it from its server (refreshed while the app is open).
    static func read() -> PeerUsage? {
        guard let v = GrokBotStore.value(suffix: ".weekly-usage.cache"),
              let reading = v["reading"] as? [String: Any],
              let usage = reading["usage"] as? [String: Any],
              let pct = (usage["percentUsed"] as? NSNumber)?.doubleValue else { return nil }
        let at = (reading["readAtMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
        var reset = (usage["nextResetMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        var used = max(0, pct)
        if let r = reset, r < Date() { used = 0; reset = nil }
        let plan = (usage["unifiedPlanName"] as? String) ?? (usage["grokPlanLabel"] as? String)
        return PeerUsage(provider: "grok", title: "Grok Bot", plan: plan,
                         windows: [PeerWindow(label: "每周", utilization: used, resetsAt: reset)],
                         observedAt: at)
    }
}

// MARK: - DeepSeek balance (DeepSeek Harness, ~/.dsh/.dshw-usage.json)

struct DeepSeekBalance {
    var balance: Double
    var today: Double
    var week: Double
    var currency: String
    var observedAt: Date
    /// Spend per day, "yyyy-MM-dd" → amount.
    var history: [String: Double]

    var symbol: String { currency == "USD" ? "$" : "¥" }
    func money(_ v: Double) -> String { symbol + String(format: "%.2f", v) }

    /// Days the balance lasts at the average spend of the last 7 days.
    var daysLeft: Double? {
        let perDay = week / 7
        return perDay > 0.01 ? balance / perDay : nil
    }
}

enum DeepSeekPeer {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/.dshw-usage.json")

    static func balance() -> DeepSeekBalance? {
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let bal = (o["lastBalance"] as? NSNumber)?.doubleValue else { return nil }
        let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        var history: [String: Double] = [:]
        for (k, v) in (o["history"] as? [String: Any]) ?? [:] { history[k] = (v as? NSNumber)?.doubleValue ?? 0 }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let todayKey = fmt.string(from: Date())
        let today = (o["date"] as? String) == todayKey ? ((o["todayUsage"] as? NSNumber)?.doubleValue ?? 0) : 0
        history[todayKey] = max(history[todayKey] ?? 0, today)
        let week = (0..<7).reduce(0.0) { sum, i in
            let day = Calendar.current.date(byAdding: .day, value: -i, to: Date()) ?? Date()
            return sum + (history[fmt.string(from: day)] ?? 0)
        }
        var currency = "CNY"
        if let acc = o["accounting"] as? [String: Any], let active = acc["active"] as? String,
           let book = (acc["books"] as? [String: Any])?[active] as? [String: Any], let c = book["currency"] as? String {
            currency = c
        }
        return DeepSeekBalance(balance: bal, today: today, week: week, currency: currency, observedAt: at, history: history)
    }

    static func read() -> PeerUsage? {
        guard let b = balance() else { return nil }
        var lines = ["余额 \(b.money(b.balance))", "今天花了 \(b.money(b.today)) · 近 7 天 \(b.money(b.week))"]
        if let d = b.daysLeft { lines.append("按近 7 天的速度约还能用 \(Int(d)) 天") }
        return PeerUsage(provider: "deepseek", title: "DeepSeek", windows: [], lines: lines,
                         observedAt: b.observedAt, short: "DeepSeek \(b.money(b.balance))")
    }
}

// MARK: - Formatting

enum PeerFmt {
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) { f.dateFormat = "HH:mm"; return f.string(from: date) }
        if cal.isDateInTomorrow(date) { f.dateFormat = "HH:mm"; return "明天 " + f.string(from: date) }
        if cal.isDateInYesterday(date) { f.dateFormat = "HH:mm"; return "昨天 " + f.string(from: date) }
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Panel card

struct PeerCard: View {
    let usage: PeerUsage

    private var tint: Color {
        switch usage.provider {
        case "claude": return Color(red: 0.85, green: 0.42, blue: 0.20)
        case "codex": return Color(red: 0.43, green: 0.36, blue: 0.86)
        case "deepseek": return Color(red: 0.30, green: 0.42, blue: 0.99)
        default: return Color(red: 0.78, green: 0.62, blue: 0.20)
        }
    }

    static func symbol(_ provider: String) -> String {
        switch provider {
        case "claude": return "asterisk"
        case "codex": return "sparkles"
        case "deepseek": return "fish.fill"
        default: return "bolt.fill"
        }
    }

    private var icon: String { Self.symbol(usage.provider) }

    private var appIDs: [String] {
        switch usage.provider {
        case "claude": return ["com.anthropic.claudefordesktop"]
        case "codex": return ["com.openai.codex", "com.openai.chat"]
        case "deepseek": return ["com.deepseek.dsh"]
        default: return ["com.anysphere.sand"]
        }
    }

    private func barColor(_ v: Double) -> Color {
        v < 70 ? Color(red: 0.24, green: 0.70, blue: 0.48) : v < 90 ? .orange : .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(usage.provider == "deepseek" ? "\(usage.title) 余额" : "\(usage.title) 额度").font(.subheadline.weight(.semibold))
                if let plan = usage.plan, !plan.isEmpty { Text(plan).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("\(PeerFmt.when(usage.observedAt)) 的数据").font(.caption2).foregroundStyle(.tertiary)
            }
            if !usage.windows.isEmpty {
                HStack(spacing: 14) {
                    ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, w in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(w.label).font(.caption)
                                Spacer()
                                Text("\(Int(w.utilization.rounded()))%").font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(barColor(w.utilization))
                            }
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.15))
                                GeometryReader { g in
                                    Capsule().fill(barColor(w.utilization))
                                        .frame(width: g.size.width * CGFloat(min(w.utilization, 100)) / 100)
                                }
                            }
                            .frame(height: 5)
                            Text(w.resetsAt.map { "\(PeerFmt.when($0)) 重置" } ?? "已重置").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(usage.lines, id: \.self) { l in
                Text(l).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.09)))
        .contentShape(Rectangle())
        .onTapGesture {
            for id in appIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init()); break
                }
            }
        }
        .help("点击打开 \(usage.title)")
    }
}

// MARK: - Collapsed "其他额度" section

/// The other tools' cards (and anything extra, e.g. a second account) behind one row that shows a
/// short summary; click to expand. Remembers whether it was open.
struct PeerSection<Extra: View>: View {
    let peers: [PeerUsage]
    var extraSummary: String? = nil
    @ViewBuilder var extra: () -> Extra
    @AppStorage("peerSectionExpanded") private var expanded = false

    var body: some View {
        let parts = [extraSummary].compactMap { $0 } + peers.map(\.summary)
        if !parts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text("其他额度").font(.subheadline.weight(.semibold))
                        Text(parts.joined(separator: " · "))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "收起" : "展开查看详情")
                if expanded {
                    extra()
                    ForEach(peers) { PeerCard(usage: $0) }
                }
            }
        }
    }
}
