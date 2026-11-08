import AppKit
import Charts
import SwiftUI

private let accent = Color(red: 0.95, green: 0.52, blue: 0.16)
private let accentDeep = Color(red: 0.62, green: 0.32, blue: 0.10)
private let alertRed = Color(red: 0.92, green: 0.30, blue: 0.32)

private func barColor(_ u: Double) -> Color {
    switch u {
    case ..<40: return Color(red: 0.36, green: 0.78, blue: 0.62)
    case ..<70: return Color(red: 0.97, green: 0.70, blue: 0.22)
    case ..<90: return Color(red: 0.95, green: 0.42, blue: 0.15)
    default: return alertRed
    }
}

struct UsageBar: View {
    let title: String
    let window: LimitWindow?
    let now: Date
    var compact = false
    var forecast: Forecast? = nil
    /// An old reading (refresh failed or hasn't run): greyed out so it isn't mistaken for the current state.
    var stale = false

    private func tint(_ u: Double) -> Color { stale ? Color.secondary.opacity(0.55) : barColor(u) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(compact ? .caption : .subheadline.weight(.semibold))
                Spacer()
                Text(window.map { "\(Int($0.utilization.rounded()))%" } ?? "—")
                    .font((compact ? Font.caption : .subheadline).monospacedDigit().weight(.semibold))
                    .foregroundStyle(window.map { tint($0.utilization) } ?? .secondary)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                GeometryReader { g in
                    Capsule()
                        .fill(tint(window?.utilization ?? 0))
                        .frame(width: g.size.width * CGFloat(min(window?.utilization ?? 0, 100)) / 100)
                }
            }
            .frame(height: compact ? 5 : 8)
            if !compact {
                Text(window == nil ? "暂无数据" : Fmt.resetText(window?.resetsAt, now: now))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let forecast {
                Label(forecast.text, systemImage: forecast.isWarning ? "exclamationmark.triangle.fill" : "chart.line.uptrend.xyaxis")
                    .font(.caption2)
                    .foregroundStyle(forecast.isWarning ? alertRed : .secondary)
            }
        }
    }
}

/// Small line of the current 5-hour window's readings, scaled to their own range.
struct Sparkline: View {
    let points: [(Date, Double)]
    var body: some View {
        let vals = points.map(\.1)
        let lo = max(0, (vals.min() ?? 0) - 5), hi = min(100, (vals.max() ?? 100) + 5)
        HStack(spacing: 8) {
            Chart(Array(points.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("时间", p.0), yStart: .value("基线", lo), yEnd: .value("用量", p.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [VizColor.tokens.opacity(0.28), VizColor.tokens.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", p.0), y: .value("用量", p.1))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(VizColor.tokens)
            }
            .chartYScale(domain: lo...max(hi, lo + 1))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 30)
            if let f = points.first, let l = points.last {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("本时段").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text("\(Int(f.1))% → \(Int(l.1))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
    }
}

struct TaskRow: View {
    let s: SessionInfo
    let now: Date

    private var dotColor: Color {
        if s.isWaiting { return alertRed }
        return s.isBusy ? .orange : Color.green.opacity(0.7)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(s.folderName) · \(s.entryLabel)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let p = s.progress {
                    HStack(spacing: 6) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            GeometryReader { g in
                                Capsule()
                                    .fill(p.isFinished ? Color.green.opacity(0.7) : Color.orange)
                                    .frame(width: g.size.width * CGFloat(p.fraction))
                            }
                        }
                        .frame(width: 70, height: 4)
                        Text("\(p.done)/\(p.total)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(p.isFinished ? Color.green : Color.orange)
                        if let step = p.current, s.isBusy || s.isWaiting {
                            Text(step).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(s.statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(s.isWaiting ? alertRed : (s.isBusy ? Color.orange : Color.secondary))
                Text(Fmt.duration(now.timeIntervalSince(s.statusSince)))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
        }
        .contentShape(Rectangle())
        .help(s.entrypoint.contains("desktop") ? "在 Claude 里打开这个会话" : s.cwd)
    }
}

/// Big two-option switch between the sticker heads and the animated figure.
struct LookSwitch: View {
    @ObservedObject var settings = Settings.shared

    private func option(_ o: FigureOption) -> some View {
        let on = settings.figure == o.id
        return Button {
            if !on { settings.figure = o.id }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: o.icon).font(.system(size: 13, weight: .semibold))
                Text(o.title).font(.callout.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? accent : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(FigureOption.available) { option($0) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
        .animation(.easeOut(duration: 0.15), value: settings.figure)
        .help("一键切换大小姐的形象")
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dashboard: DashboardModel
    var openLogin: () -> Void
    var openSecondaryLogin: () -> Void = {}
    var openClaude: (SessionInfo) -> Void
    var openDashboard: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void

    private var subtitle: String {
        guard let u = model.usage else { return "大小姐现在：\(Doro.levelNames[model.level])" }
        let who = [u.account, u.plan].compactMap { $0 }.joined(separator: " · ")
        return who.isEmpty ? "大小姐现在：\(Doro.levelNames[model.level])" : who
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heatmapSection
            Divider()
            header
            if FigureOption.available.count > 1 { LookSwitch() }
            usageSection
            PeerSection(peers: model.peers, extraSummary: secondarySummary) {
                if model.hasSecondary { secondarySection }
            }
            Divider()
            tasksSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 350)
        .fitsScreen()
    }

    /// GitHub-style calendar of daily tokens; click to open the full statistics.
    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("每日 Token").font(.subheadline.weight(.semibold))
                Spacer()
                Button { openDashboard() } label: {
                    HStack(spacing: 2) { Text("用量统计"); Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderless).font(.caption)
            }
            TokenHeatmap(days: dashboard.days, weeks: 22, cell: 10, gap: 3)
                .contentShape(Rectangle())
                .onTapGesture { openDashboard() }
            if dashboard.days.isEmpty && dashboard.indexing {
                Text("正在统计会话记录… \(Int(dashboard.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: model.frame ?? Faces.image(model.face) ?? NSImage())
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
                .onTapGesture {
                    let opts = FigureOption.available.map(\.id)
                    if opts.count > 1, let i = opts.firstIndex(of: Settings.shared.figure) {
                        Settings.shared.figure = opts[(i + 1) % opts.count]
                    }
                }
                .help(FigureOption.available.count > 1 ? "点头像切换形象" : "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Claude大小姐").font(.headline)
                    Text(Doro.levelNames[model.level])
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.18)))
                        .foregroundStyle(accentDeep)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.loadingUsage {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await model.refreshUsage() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("刷新用量")
            }
        }
    }

    @ViewBuilder private var usageSection: some View {
        let acct = model.usage?.account
        let stale = model.usageStale
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                UsageBar(title: "5 小时限额", window: model.usage?.fiveHour, now: model.now,
                         forecast: stale ? nil : model.history.forecast(account: acct, fiveHour: true, window: model.usage?.fiveHour),
                         stale: stale)
                let pts = model.history.fiveHourSeries(account: acct, window: model.usage?.fiveHour)
                if pts.count >= 3 { Sparkline(points: pts) }
            }
            UsageBar(title: "每周限额（7 天）", window: model.usage?.sevenDay, now: model.now,
                     forecast: stale ? nil : model.history.forecast(account: acct, fiveHour: false, window: model.usage?.sevenDay),
                     stale: stale)
            if let extras = model.usage?.extras, !extras.isEmpty {
                ForEach(Array(extras.enumerated()), id: \.offset) { _, e in
                    UsageBar(title: e.label, window: e.window, now: model.now, compact: true, stale: stale)
                }
            }
            if model.usageError != nil || stale {
                VStack(alignment: .leading, spacing: 6) {
                    if model.usage != nil {
                        Label("上面是 \(model.lastUsageUpdate.map { petAgo($0, now: model.now) } ?? "之前") 的数据"
                              + (model.usageError == nil ? "，正在重新获取…" : "，刷新失败了："),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(accentDeep)
                    }
                    if let err = model.usageError {
                        Text(err).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.needsLogin {
                        Button("登录 claude.ai 查看用量", action: openLogin)
                            .buttonStyle(.borderedProminent).tint(accent).controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.08)))
            }
            if !model.hasSecondary {
                Button { openSecondaryLogin() } label: { Label("添加另一个账号", systemImage: "person.badge.plus") }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }

    /// Codex (ChatGPT) limits read from ~/.codex logs; click to open ChatGPT.
    /// "另一个账号 18%" for the collapsed header.
    private var secondarySummary: String? {
        guard model.hasSecondary else { return nil }
        return "另一个账号 " + (model.secondary?.fiveHour.map { "\(Int($0.utilization.rounded()))%" } ?? "—")
    }

    private var secondarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("另一个账号").font(.subheadline.weight(.semibold))
                if let s = model.secondary {
                    Text([s.account, s.plan].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            if let s = model.secondary {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        UsageBar(title: "5 小时", window: s.fiveHour, now: model.now, compact: true)
                        Text(s.fiveHour?.resetsAt.map { "\(Fmt.when($0)) 重置" } ?? "未开始计时")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        UsageBar(title: "每周", window: s.sevenDay, now: model.now, compact: true)
                        Text(s.sevenDay?.resetsAt.map { "\(Fmt.when($0)) 重置" } ?? "未开始计时")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Text(model.secondaryError ?? "读取中…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("登录", action: openSecondaryLogin).controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    @ViewBuilder private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("正在进行的任务").font(.subheadline.weight(.semibold))
                Spacer()
                let waiting = model.waitingSessions.count
                Text((waiting > 0 ? "\(waiting) 等你 · " : "") + "\(model.busyCount) 进行中 / \(model.sessions.count) 个会话")
                    .font(.caption).foregroundStyle(waiting > 0 ? alertRed : .secondary)
            }
            if model.sessions.isEmpty {
                Text("现在没有 Claude 会话，大小姐在悠闲喝茶～")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else if model.sessions.count > 6 {
                ScrollView { rows }.frame(height: 260)
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 10) {
            ForEach(model.sessions) { s in
                TaskRow(s: s, now: model.now)
                    .onTapGesture { openClaude(s) }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { openDashboard() } label: { Label("用量统计", systemImage: "chart.bar.xaxis") }
                Button { openSettings() } label: { Label("设置", systemImage: "gearshape") }
                Spacer()
                Button("退出", action: quit)
            }
            .buttonStyle(.borderless).font(.caption)
            Text(model.lastUsageUpdate.map { "\(model.usage?.source ?? "") · 更新于 \(Fmt.clock($0))" } ?? "用量尚未获取")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text("素材：Claude大小姐的日记本 · 角色设定：ZipZipPipe（胖次狐）· CC BY-NC-SA 4.0")
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                .help(Doro.attribution)
        }
    }
}
