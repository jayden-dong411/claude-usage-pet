import AppKit
import Charts
import SwiftUI

/// Chart colours (DeepSeek blue), following light / dark mode.
enum DSColor {
    private static func c(_ light: UInt32, _ dark: UInt32) -> Color {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                    blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        return Color(nsColor: Theme.dynamic(ns(light), ns(dark)))
    }
    static let spend = c(0x4d6bfe, 0x6f88ff)
    static let tokens = c(0x1baf7a, 0x199e70)
    static let other = c(0xa3a7b3, 0x6b6f7a)
    static let balance = c(0xeb6834, 0xd95926)
    static let empty = c(0xe3e6ef, 0x34363f)
    /// Heat steps 1...4, low to high.
    static let heat = [c(0xb3c2ff, 0x233070), c(0x7f97ff, 0x324bb0), c(0x4d6bfe, 0x4d6bfe), c(0x2a43b8, 0x9aabff)]
    static let card = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.07)
}

enum DSNum {
    static func cn(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e8 { return String(format: "%.2f亿", d / 1e8) }
        if d >= 1e4 { return String(format: d >= 1e7 ? "%.0f万" : "%.1f万", d / 1e4) }
        return "\(n)"
    }
}

/// GitHub-style calendar of daily spend: one column per week (Mon–Sun), darker = more.
struct SpendHeatmap: View {
    @ObservedObject var dm: DSDashboardModel
    var weeks = 22
    var cell: CGFloat = 10
    var gap: CGFloat = 3
    @State private var hovered: Date?

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.locale = Locale(identifier: "zh_CN")
        return c
    }

    private struct Cell: Identifiable { let id: Date; let spend: Double; let future: Bool }

    private var columns: [[Cell]] {
        let today = cal.startOfDay(for: Date())
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)?.start,
              let first = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) else { return [] }
        return (0..<weeks).map { w in
            (0..<7).compactMap { d -> Cell? in
                guard let date = cal.date(byAdding: .day, value: w * 7 + d, to: first) else { return nil }
                return Cell(id: date, spend: dm.days[DSDashboardModel.key(date)]?.spend ?? 0, future: date > today)
            }
        }
    }

    private func level(_ v: Double, _ t: [Double]) -> Int {
        if v <= 0.005 { return 0 }
        if v < t[0] { return 1 }
        if v < t[1] { return 2 }
        if v < t[2] { return 3 }
        return 4
    }

    private func color(_ l: Int) -> Color { l == 0 ? DSColor.empty : DSColor.heat[l - 1] }

    private func describe(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        let day = dm.days[DSDashboardModel.key(d)] ?? DSDay()
        if day.spend <= 0.005 && day.tokens == 0 { return "\(f.string(from: d)) · 没有花费" }
        return "\(f.string(from: d)) · 花了 \(dm.money(day.spend)) · \(DSNum.cn(day.tokens)) token · \(day.calls) 次调用"
    }

    var body: some View {
        let cols = columns
        let vals = cols.flatMap { $0 }.map(\.spend).filter { $0 > 0.005 }.sorted()
        let t: [Double] = vals.isEmpty ? [1, 2, 3] : [0.25, 0.5, 0.75].map { vals[min(vals.count - 1, Int(Double(vals.count) * $0))] }
        let past = cols.flatMap { $0 }.filter { !$0.future }
        let total = past.reduce(0) { $0 + $1.spend }
        let active = past.filter { $0.spend > 0.005 }.count
        let labelW = cell * 1.6
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: gap) {
                Color.clear.frame(width: labelW, height: 1)
                ForEach(Array(cols.enumerated()), id: \.offset) { i, col in
                    let first = col.first(where: { cal.component(.day, from: $0.id) == 1 })
                    Text(first.map { "\(cal.component(.month, from: $0.id))月" } ?? "")
                        .font(.system(size: max(8, cell - 1))).foregroundStyle(.secondary)
                        .fixedSize().frame(width: cell, alignment: .leading)
                }
            }
            HStack(alignment: .top, spacing: gap) {
                VStack(alignment: .trailing, spacing: gap) {
                    ForEach(0..<7, id: \.self) { r in
                        Text(r == 0 ? "一" : r == 2 ? "三" : r == 4 ? "五" : "")
                            .font(.system(size: max(8, cell - 1))).foregroundStyle(.secondary)
                            .frame(width: labelW, height: cell, alignment: .trailing)
                    }
                }
                ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                    VStack(spacing: gap) {
                        ForEach(col) { c in
                            RoundedRectangle(cornerRadius: cell * 0.22)
                                .fill(c.future ? Color.clear : color(level(c.spend, t)))
                                .overlay(RoundedRectangle(cornerRadius: cell * 0.22)
                                    .strokeBorder(hovered == c.id ? Color.primary.opacity(0.6) : .clear, lineWidth: 1))
                                .frame(width: cell, height: cell)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside && !c.future { hovered = c.id } else if hovered == c.id { hovered = nil }
                                }
                                .help(c.future ? "" : describe(c.id))
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text(hovered.map(describe) ?? "近 \(weeks) 周花了 \(dm.money(total)) · 用了 \(active) 天")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Text("少").font(.caption2).foregroundStyle(.tertiary)
                ForEach(0..<5, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 2).fill(color(l)).frame(width: cell * 0.9, height: cell * 0.9)
                }
                Text("多").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct DSDashboardView: View {
    @ObservedObject var dm: DSDashboardModel
    @State private var range = 14
    @State private var pickedSpend: Date?
    @State private var pickedTokens: Date?

    private var series: [(date: Date, day: DSDay)] { dm.series(range) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("每日花费").font(.headline)
                        SpendHeatmap(dm: dm, weeks: 38, cell: 13, gap: 4)
                    }
                }
                todayTiles
                HStack {
                    Text("趋势").font(.headline)
                    Spacer()
                    Picker("", selection: $range) {
                        Text("7 天").tag(7); Text("14 天").tag(14); Text("30 天").tag(30)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                card { spendChart }
                card { tokenChart }
                card { balanceChart }
                card { modelBreakdown }
                Text("数据来自这台 Mac 上 DeepSeek Harness 的 ~/.dsh/.dshw-usage.json。花费和充值按账户余额的实际变化计算，和余额对得上；token 和调用次数只算 DeepSeek 自己的模型，Harness 通过其他服务调用的模型（gpt、mimo、GLM 等）单独列在模型表里，它们的费用是 Harness 的估算，不从 DeepSeek 余额里扣。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 600)
    }

    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(DSColor.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DSColor.cardStroke))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DeepSeek 用量统计").font(.title2.weight(.bold))
                let tot = dm.total(range)
                Text("最近 \(range) 天 · 花了 \(dm.money(tot.spend)) · \(DSNum.cn(tot.tokens)) token · \(tot.calls) 次调用"
                     + (tot.topUp > 0 ? " · 充值 \(dm.money(tot.topUp))" : ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let t = dm.lastIndexed {
                Text("更新于 \(Fmt.clock(t))").font(.caption).foregroundStyle(.secondary)
            }
            Button { dm.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(dm.loading).help("重新读取")
        }
    }

    private func tile(_ title: String, _ value: String, _ sub: String, _ icon: String, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
                .frame(width: 30, height: 30).background(Circle().fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold).monospacedDigit())
                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(DSColor.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DSColor.cardStroke))
    }

    private var todayTiles: some View {
        let t = dm.today
        let bal = dm.balanceSeries(1).last?.balance
        return VStack(alignment: .leading, spacing: 8) {
            Text("今天").font(.headline)
            HStack(spacing: 10) {
                tile("花费", dm.money(t.spend), t.topUp > 0 ? "充值 \(dm.money(t.topUp))" : "从余额扣除", "yensign.circle", DSColor.spend)
                tile("Token", DSNum.cn(t.tokens), "DeepSeek 模型", "text.word.spacing", DSColor.tokens)
                tile("调用", "\(t.calls) 次", t.otherTokens > 0 ? "另有其他模型 \(DSNum.cn(t.otherTokens)) token" : "DeepSeek 模型", "bolt", DSColor.spend)
                tile("余额", bal.map { dm.money($0) } ?? "—", "今天结束时", "creditcard", DSColor.balance)
            }
        }
    }

    private func picked(_ d: Date?) -> (date: Date, day: DSDay)? {
        guard let d else { return nil }
        let cal = Calendar.current
        return series.first { cal.isDate($0.date, inSameDayAs: d) }
    }

    private func tooltip(_ date: Date, _ main: String, _ sub: String) -> some View {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return VStack(alignment: .leading, spacing: 2) {
            Text(f.string(from: date)).font(.caption2).foregroundStyle(.secondary)
            Text(main).font(.caption.weight(.semibold).monospacedDigit())
            Text(sub).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DSColor.cardStroke))
    }

    private var axisDays: AxisMarkValues { .stride(by: .day, count: range > 14 ? 5 : range > 7 ? 2 : 1) }

    private var spendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每天花费").font(.subheadline.weight(.semibold))
            Chart {
                ForEach(series, id: \.date) { s in
                    BarMark(x: .value("日期", s.date, unit: .day), y: .value("花费", s.day.spend), width: .ratio(0.62))
                        .cornerRadius(4)
                        .foregroundStyle(DSColor.spend.opacity(pickedSpend == nil || picked(pickedSpend)?.date == s.date ? 1 : 0.35))
                }
                if let p = picked(pickedSpend) {
                    RuleMark(x: .value("日期", p.date, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.15))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            tooltip(p.date, "花了 \(dm.money(p.day.spend))",
                                    p.day.topUp > 0 ? "充值 \(dm.money(p.day.topUp))" : "\(p.day.calls) 次调用")
                        }
                }
            }
            .chartXSelection(value: $pickedSpend)
            .chartXAxis { AxisMarks(values: axisDays) { _ in AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true) } }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(dm.money(d)) } } } }
            .frame(height: 180)
        }
    }

    private var tokenChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("每天 Token").font(.subheadline.weight(.semibold))
                Spacer()
                HStack(spacing: 10) {
                    Label("DeepSeek", systemImage: "square.fill").foregroundStyle(DSColor.tokens)
                    Label("其他模型", systemImage: "square.fill").foregroundStyle(DSColor.other)
                }
                .font(.caption)
            }
            Chart {
                ForEach(series, id: \.date) { s in
                    BarMark(x: .value("日期", s.date, unit: .day), y: .value("Token", s.day.tokens), width: .ratio(0.62))
                        .foregroundStyle(DSColor.tokens)
                    BarMark(x: .value("日期", s.date, unit: .day), y: .value("Token", s.day.otherTokens), width: .ratio(0.62))
                        .foregroundStyle(DSColor.other)
                }
                if let p = picked(pickedTokens) {
                    RuleMark(x: .value("日期", p.date, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.15))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            tooltip(p.date, "DeepSeek \(DSNum.cn(p.day.tokens)) token", "其他模型 \(DSNum.cn(p.day.otherTokens)) token")
                        }
                }
            }
            .chartXSelection(value: $pickedTokens)
            .chartXAxis { AxisMarks(values: axisDays) { _ in AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true) } }
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Int.self) { Text(DSNum.cn(d)) } } } }
            .frame(height: 180)
        }
    }

    private var balanceChart: some View {
        let pts = dm.balanceSeries(range)
        return VStack(alignment: .leading, spacing: 8) {
            Text("余额变化").font(.subheadline.weight(.semibold))
            if pts.isEmpty {
                Text("还没有余额记录").font(.caption).foregroundStyle(.secondary)
            } else {
                let lo = (pts.map(\.balance).min() ?? 0), hi = (pts.map(\.balance).max() ?? 1)
                Chart(pts, id: \.date) { p in
                    LineMark(x: .value("日期", p.date, unit: .day), y: .value("余额", p.balance))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(DSColor.balance)
                    PointMark(x: .value("日期", p.date, unit: .day), y: .value("余额", p.balance))
                        .symbolSize(18).foregroundStyle(DSColor.balance)
                }
                .chartYScale(domain: max(0, lo - (hi - lo) * 0.2 - 0.5)...(hi + (hi - lo) * 0.1 + 0.5))
                .chartXAxis { AxisMarks(values: axisDays) { _ in AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true) } }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(dm.money(d)) } } } }
                .frame(height: 150)
            }
        }
    }

    private var modelBreakdown: some View {
        let models = dm.total(range).models.sorted { $0.value.tokens > $1.value.tokens }
        let maxTok = max(1, models.first?.value.tokens ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("按模型（最近 \(range) 天）").font(.subheadline.weight(.semibold))
            if models.isEmpty {
                Text("这段时间没有调用").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(models, id: \.key) { m in
                let ds = DSStats.isDeepSeek(m.key)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(m.key).font(.callout)
                        if !ds { Text("其他服务").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.secondary.opacity(0.15))) }
                        Spacer()
                        Text("\(m.value.calls) 次 · \(DSNum.cn(m.value.tokens)) token · \(ds ? "" : "估算 ")\(dm.money(m.value.cost))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        Capsule().fill(ds ? DSColor.tokens : DSColor.other)
                            .frame(width: max(3, g.size.width * CGFloat(m.value.tokens) / CGFloat(maxTok)))
                    }
                    .frame(height: 5)
                }
            }
        }
    }
}
