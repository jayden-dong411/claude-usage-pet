import AppKit
import SwiftUI

/// Chart colours. Ramps validated with the dataviz skill's validator (ordinal, light & dark).
enum VizColor {
    private static func c(_ light: UInt32, _ dark: UInt32) -> Color {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                    blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        return Color(nsColor: Theme.dynamic(ns(light), ns(dark)))
    }
    static let tokens = c(0x6250d6, 0x9085e9)        // categorical slot 7 (violet)
    static let time = c(0x1baf7a, 0x199e70)          // categorical slot 3 (aqua)
    static let empty = c(0xe5e3ec, 0x3b3a40)
    /// Heat steps 1...4, low to high.
    static let heat = [c(0xa596ef, 0x4d4290), c(0x8574e6, 0x6150b0), c(0x6250d6, 0x7f6ee0), c(0x45369e, 0xaca1f2)]
    static let card = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.07)
}

/// GitHub-style calendar of daily token use: one column per week (Mon–Sun), darker = more.
struct TokenHeatmap: View {
    let days: [String: DayStats]
    var weeks = 22
    var cell: CGFloat = 10
    var gap: CGFloat = 3
    var showSummary = true

    @State private var hovered: Date?

    private struct Day: Identifiable {
        let id: Date
        let key: String
        let value: Int
        let future: Bool
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2          // weeks start on Monday
        c.locale = Locale(identifier: "zh_CN")
        return c
    }

    /// Columns of 7 days, oldest week first; the last column is the current week.
    private var columns: [[Day]] {
        let today = cal.startOfDay(for: Date())
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)?.start,
              let first = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) else { return [] }
        return (0..<weeks).map { w in
            (0..<7).compactMap { d -> Day? in
                guard let date = cal.date(byAdding: .day, value: w * 7 + d, to: first) else { return nil }
                let key = DashboardModel.key(date)
                return Day(id: date, key: key, value: days[key]?.tokens.total ?? 0, future: date > today)
            }
        }
    }

    /// Quartile cut points of the non-zero days in view, like GitHub's levels.
    private func thresholds(_ cols: [[Day]]) -> [Int] {
        let vals = cols.flatMap { $0 }.map(\.value).filter { $0 > 0 }.sorted()
        guard !vals.isEmpty else { return [1, 2, 3] }
        return [0.25, 0.5, 0.75].map { vals[min(vals.count - 1, Int(Double(vals.count) * $0))] }
    }

    private func level(_ v: Int, _ t: [Int]) -> Int {
        if v <= 0 { return 0 }
        if v < t[0] { return 1 }
        if v < t[1] { return 2 }
        if v < t[2] { return 3 }
        return 4
    }

    private func color(_ lvl: Int) -> Color { lvl == 0 ? VizColor.empty : VizColor.heat[lvl - 1] }

    /// "11月" above the week that contains the 1st; the first column is labelled too
    /// unless a new month starts within the next two weeks (labels would collide).
    private func monthLabel(_ cols: [[Day]], index: Int) -> String? {
        let starts = { (c: [Day]) in c.first(where: { self.cal.component(.day, from: $0.id) == 1 }) }
        if let d = starts(cols[index]) { return "\(cal.component(.month, from: d.id))月" }
        if index == 0, let d = cols[0].first, !cols.dropFirst().prefix(2).contains(where: { starts($0) != nil }) {
            return "\(cal.component(.month, from: d.id))月"
        }
        return nil
    }

    private func describe(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        let s = days[DashboardModel.key(d)] ?? DayStats()
        if s.tokens.total == 0 { return "\(f.string(from: d)) · 没有使用" }
        return "\(f.string(from: d)) · \(Num.cn(s.tokens.total)) token · \(Num.hours(s.activeSeconds)) · \(s.messages) 次回复"
    }

    var body: some View {
        let cols = columns
        let t = thresholds(cols)
        let all = cols.flatMap { $0 }.filter { !$0.future }
        let total = all.reduce(0) { $0 + $1.value }
        let active = all.filter { $0.value > 0 }.count
        let labelW: CGFloat = cell * 1.6

        VStack(alignment: .leading, spacing: 6) {
            // Month labels
            HStack(spacing: gap) {
                Color.clear.frame(width: labelW, height: 1)
                ForEach(Array(cols.enumerated()), id: \.offset) { i, _ in
                    Text(monthLabel(cols, index: i) ?? "")
                        .font(.system(size: max(8, cell - 1)))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(width: cell, alignment: .leading)
                }
            }
            HStack(alignment: .top, spacing: gap) {
                VStack(alignment: .trailing, spacing: gap) {
                    ForEach(0..<7, id: \.self) { r in
                        Text(r == 0 ? "一" : r == 2 ? "三" : r == 4 ? "五" : "")
                            .font(.system(size: max(8, cell - 1)))
                            .foregroundStyle(.secondary)
                            .frame(width: labelW, height: cell, alignment: .trailing)
                    }
                }
                ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                    VStack(spacing: gap) {
                        ForEach(col) { d in
                            RoundedRectangle(cornerRadius: cell * 0.22)
                                .fill(d.future ? Color.clear : color(level(d.value, t)))
                                .overlay(RoundedRectangle(cornerRadius: cell * 0.22)
                                    .strokeBorder(hovered == d.id ? Color.primary.opacity(0.6) : .clear, lineWidth: 1))
                                .frame(width: cell, height: cell)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside && !d.future { hovered = d.id } else if hovered == d.id { hovered = nil }
                                }
                                .help(d.future ? "" : describe(d.id))
                        }
                    }
                }
            }
            if showSummary {
                HStack(spacing: 4) {
                    Text(hovered.map(describe) ?? "近 \(weeks) 周 \(Num.cn(total)) token · 用了 \(active) 天")
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
}
