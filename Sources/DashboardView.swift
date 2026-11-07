import Charts
import SwiftUI

enum Num {
    /// 1234 -> "1234", 12345 -> "1.2万", 123456789 -> "1.23亿"
    static func cn(_ v: Int) -> String {
        let d = Double(v)
        if d >= 1e8 { return String(format: "%.2f亿", d / 1e8) }
        if d >= 1e4 { return String(format: "%.1f万", d / 1e4) }
        return "\(v)"
    }
    static func hours(_ s: Double) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(m)分钟" }
        return "\(m / 60)小时\(m % 60)分"
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(VizColor.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(VizColor.cardStroke))
    }
}

private struct StatTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let sub: String

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private enum TokenMetric: String, CaseIterable, Identifiable {
    case total = "全部", io = "输入+输出", cacheWrite = "缓存写入", cacheRead = "缓存读取"
    var id: String { rawValue }
    func value(_ t: TokenCounts) -> Int {
        switch self {
        case .total: return t.total
        case .io: return t.input + t.output
        case .cacheWrite: return t.cacheWrite
        case .cacheRead: return t.cacheRead
        }
    }
}

struct DashboardView: View {
    @ObservedObject var dm: DashboardModel
    @State private var range = 14
    @State private var metric: TokenMetric = .total
    @State private var pickedTokenDay: Date?
    @State private var pickedTimeDay: Date?
    @State private var source: StatSource

    init(dm: DashboardModel, source: StatSource = .claude) {
        self.dm = dm
        _source = State(initialValue: source)
    }

    private var series: [(date: Date, stats: DayStats)] { dm.series(range, source) }
    private var claudeSeries: [(date: Date, stats: DayStats)] { dm.series(range, .claude) }
    private var codexSeries: [(date: Date, stats: DayStats)] { dm.series(range, .codex) }
    private var stacked: Bool { source == .all }
    private var sourceTitle: String { source == .claude ? "Claude Code" : source == .codex ? "Codex" : "Claude + Codex" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("每日 Token", "颜色越深用得越多，悬停看当天详情")
                        TokenHeatmap(days: dm.days(for: source), weeks: 38, cell: 13, gap: 4)
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
                .padding(.top, 4)
                tokenChart
                timeChart
                HStack(alignment: .top, spacing: 12) {
                    breakdown("按模型", tint: VizColor.tokens,
                              rows: dm.total(range, source).models.map { ($0.key, $0.value.total, nil) })
                    breakdown("按项目", tint: VizColor.tokens,
                              rows: dm.total(range, source).projects.map { ($0.key, $0.value.tokens.total, $0.value.activeSeconds) })
                }
                Text("数据来自这台 Mac 上的本地记录：Claude Code 读 ~/.claude/projects（桌面版和终端都算），Codex 读 ~/.codex/sessions（ChatGPT 桌面版和 Codex CLI 都算），不含其他设备和网页版聊天。Codex 的「输入」指未命中缓存的输入。使用时长按同一会话里相邻两条记录间隔不超过 5 分钟累计。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .frame(minWidth: 760, minHeight: 640)
    }

    private func sectionTitle(_ title: String, _ hint: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if let hint { Text(hint).font(.caption).foregroundStyle(.tertiary) }
            Spacer()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sourceTitle) 用量统计").font(.title2.weight(.bold))
                let tot = dm.total(range, source)
                Text("最近 \(range) 天 · \(Num.hours(tot.activeSeconds)) · \(Num.cn(tot.tokens.total)) token · \(tot.sessions.count) 个会话")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $source) {
                ForEach(StatSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .controlSize(.large)
            .help("切换统计来源：Claude Code、Codex（ChatGPT）或两者合计")
            if dm.indexing {
                ProgressView(value: dm.progress).frame(width: 110)
                Text(dm.lastIndexed == nil ? "首次统计 \(Int(dm.progress * 100))%" : "更新中…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let t = dm.lastIndexed {
                Text("更新于 \(Fmt.clock(t))").font(.caption).foregroundStyle(.secondary)
            }
            Button { dm.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(dm.indexing).help("重新统计")
        }
    }

    private var todayTiles: some View {
        let t = dm.today(source)
        return VStack(alignment: .leading, spacing: 8) {
            Text("今天").font(.headline)
            HStack(spacing: 10) {
                StatTile(icon: "clock.fill", tint: VizColor.time, title: "使用时长",
                         value: Num.hours(t.activeSeconds), sub: "\(t.sessions.count) 个会话")
                StatTile(icon: "flame.fill", tint: VizColor.tokens, title: "总 Token",
                         value: Num.cn(t.tokens.total), sub: "\(t.messages) 次回复")
                StatTile(icon: "text.bubble.fill", tint: VizColor.tokens, title: "输入 + 输出",
                         value: Num.cn(t.tokens.input + t.tokens.output), sub: "输出 \(Num.cn(t.tokens.output))")
                StatTile(icon: "archivebox.fill", tint: VizColor.tokens, title: "缓存",
                         value: Num.cn(t.tokens.cacheRead + t.tokens.cacheWrite),
                         sub: "读 \(Num.cn(t.tokens.cacheRead)) · 写 \(Num.cn(t.tokens.cacheWrite))")
            }
        }
    }

    /// "Claude x · Codex y" for one day in the combined charts.
    private func splitText(_ day: Date, _ f: (DayStats) -> String) -> String {
        let k = DashboardModel.key(day)
        return "Claude \(f(dm.days[k] ?? DayStats())) · Codex \(f(dm.codexDays[k] ?? DayStats()))"
    }

    private func axisDays() -> AxisMarkValues { .stride(by: .day, count: range > 14 ? 5 : (range > 7 ? 2 : 1)) }

    private func picked(_ d: Date?) -> (date: Date, stats: DayStats)? {
        guard let d else { return nil }
        return series.first { Calendar.current.isDate($0.date, inSameDayAs: d) }
    }

    private var tokenChart: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("每天 Token").font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("", selection: $metric) {
                        ForEach(TokenMetric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Chart {
                    if stacked {
                        ForEach(Array(zip(claudeSeries, codexSeries).enumerated()), id: \.offset) { _, pair in
                            BarMark(x: .value("日期", pair.0.date, unit: .day),
                                    y: .value("Token", metric.value(pair.0.stats.tokens)), width: .ratio(0.62))
                                .foregroundStyle(by: .value("来源", "Claude"))
                            BarMark(x: .value("日期", pair.1.date, unit: .day),
                                    y: .value("Token", metric.value(pair.1.stats.tokens)), width: .ratio(0.62))
                                .foregroundStyle(by: .value("来源", "Codex"))
                        }
                    } else {
                        ForEach(series, id: \.date) { d in
                            BarMark(x: .value("日期", d.date, unit: .day),
                                    y: .value("Token", metric.value(d.stats.tokens)), width: .ratio(0.62))
                                .cornerRadius(4)
                                .foregroundStyle((source == .codex ? VizColor.codex : VizColor.tokens)
                                    .opacity(pickedTokenDay == nil || picked(pickedTokenDay)?.date == d.date ? 1 : 0.35))
                        }
                    }
                    if let p = picked(pickedTokenDay) {
                        RuleMark(x: .value("日期", p.date, unit: .day))
                            .foregroundStyle(Color.primary.opacity(0.15))
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                tooltip(p.date, "\(metric.rawValue) \(Num.cn(metric.value(p.stats.tokens)))",
                                        stacked ? splitText(p.date) { Num.cn(metric.value($0.tokens)) } : "\(p.stats.messages) 次回复")
                            }
                    }
                }
                .chartForegroundStyleScale(["Claude": VizColor.tokens, "Codex": VizColor.codex])
                .chartLegend(stacked ? .visible : .hidden)
                .chartXSelection(value: $pickedTokenDay)
                .chartYAxis { AxisMarks { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel { if let i = v.as(Int.self) { Text(Num.cn(i)).foregroundStyle(Color.secondary) } }
                } }
                .chartXAxis { AxisMarks(values: axisDays()) {
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day()).foregroundStyle(Color.secondary)
                } }
                .frame(height: 200)
            }
        }
    }

    private var timeChart: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("每天使用时长").font(.subheadline.weight(.semibold))
                Chart {
                    if stacked {
                        ForEach(Array(zip(claudeSeries, codexSeries).enumerated()), id: \.offset) { _, pair in
                            BarMark(x: .value("日期", pair.0.date, unit: .day),
                                    y: .value("小时", pair.0.stats.activeSeconds / 3600), width: .ratio(0.62))
                                .foregroundStyle(by: .value("来源", "Claude"))
                            BarMark(x: .value("日期", pair.1.date, unit: .day),
                                    y: .value("小时", pair.1.stats.activeSeconds / 3600), width: .ratio(0.62))
                                .foregroundStyle(by: .value("来源", "Codex"))
                        }
                    } else {
                        ForEach(series, id: \.date) { d in
                            BarMark(x: .value("日期", d.date, unit: .day),
                                    y: .value("小时", d.stats.activeSeconds / 3600), width: .ratio(0.62))
                                .cornerRadius(4)
                                .foregroundStyle(VizColor.time.opacity(pickedTimeDay == nil || picked(pickedTimeDay)?.date == d.date ? 1 : 0.35))
                        }
                    }
                    if let p = picked(pickedTimeDay) {
                        RuleMark(x: .value("日期", p.date, unit: .day))
                            .foregroundStyle(Color.primary.opacity(0.15))
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                tooltip(p.date, Num.hours(p.stats.activeSeconds),
                                        stacked ? splitText(p.date) { Num.hours($0.activeSeconds) } : "\(p.stats.sessions.count) 个会话")
                            }
                    }
                }
                .chartForegroundStyleScale(["Claude": VizColor.tokens, "Codex": VizColor.codex])
                .chartLegend(stacked ? .visible : .hidden)
                .chartXSelection(value: $pickedTimeDay)
                .chartYAxis { AxisMarks { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel { if let h = v.as(Double.self) { Text(String(format: "%.0f 时", h)).foregroundStyle(Color.secondary) } }
                } }
                .chartXAxis { AxisMarks(values: axisDays()) {
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day()).foregroundStyle(Color.secondary)
                } }
                .frame(height: 150)
            }
        }
    }

    private func tooltip(_ date: Date, _ main: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.month(.defaultDigits).day().weekday(.abbreviated))
                .font(.caption2).foregroundStyle(.secondary)
            Text(main).font(.caption.weight(.semibold)).monospacedDigit()
            Text(sub).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VizColor.cardStroke))
    }

    private func breakdown(_ title: String, tint: Color, rows: [(String, Int, Double?)]) -> some View {
        let sorted = rows.filter { $0.1 > 0 || ($0.2 ?? 0) > 0 }.sorted { $0.1 > $1.1 }.prefix(8)
        let maxV = max(1, sorted.first?.1 ?? 1)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline.weight(.semibold))
                if sorted.isEmpty {
                    Text("暂无数据").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(sorted.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(r.0).font(.callout).lineLimit(1)
                            Spacer()
                            if let s = r.2 { Text(Num.hours(s)).font(.caption).foregroundStyle(.secondary) }
                            Text(Num.cn(r.1)).font(.callout.weight(.medium).monospacedDigit())
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.06))
                                Capsule().fill(tint)
                                    .frame(width: max(3, g.size.width * CGFloat(r.1) / CGFloat(maxV)))
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
    }
}
