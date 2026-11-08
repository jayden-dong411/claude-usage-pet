import AppKit
import Charts
import SwiftUI

private let accent = Color(red: 0.43, green: 0.36, blue: 0.86)
private let accentDeep = Color(red: 0.36, green: 0.28, blue: 0.70)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(compact ? .caption : .subheadline.weight(.semibold))
                Spacer()
                Text(window.map { "\(Int($0.utilization.rounded()))%" } ?? "—")
                    .font((compact ? Font.caption : .subheadline).monospacedDigit().weight(.semibold))
                    .foregroundStyle(window.map { barColor($0.utilization) } ?? .secondary)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                GeometryReader { g in
                    Capsule()
                        .fill(barColor(window?.utilization ?? 0))
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
                                Capsule().fill(p.isFinished ? Color.green.opacity(0.7) : Color.orange)
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
        .help("在 ChatGPT 里打开这个线程")
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dashboard: DashboardModel
    var openClaude: (SessionInfo) -> Void
    var openDashboard: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heatmapSection
            Divider()
            header
            if V3Assets.available { lookSwitch }
            usageSection
            PeerSection(peers: model.peers) { EmptyView() }
            Divider()
            tasksSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 350)
    }

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
                Text("正在统计 Codex 日志… \(Int(dashboard.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: model.frame ?? NSImage())
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 48)
                .contentShape(Rectangle())
                .onTapGesture { if V3Assets.available { Settings.shared.useV3.toggle() } }
                .help(V3Assets.available ? "点头像切换形象" : "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Pet.name).font(.headline)
                    Text(Pet.levelNames[model.level])
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.16)))
                        .foregroundStyle(accentDeep)
                }
                Text(["ChatGPT", model.usage?.plan].compactMap { $0 }.joined(separator: " · ") + " · Codex 额度")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { model.refresh(notify: false) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("刷新")
        }
    }

    @ViewBuilder private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                UsageBar(title: "5 小时额度", window: model.usage?.fiveHour, now: model.now,
                         forecast: model.history.forecast(account: model.usage?.account, fiveHour: true, window: model.usage?.fiveHour))
                let pts = model.history.fiveHourSeries(account: model.usage?.account, window: model.usage?.fiveHour)
                if pts.count >= 3 { Sparkline(points: pts) }
            }
            UsageBar(title: "每周额度", window: model.usage?.sevenDay, now: model.now,
                     forecast: model.history.forecast(account: model.usage?.account, fiveHour: false, window: model.usage?.sevenDay))
            if let u = model.usage {
                Group {
                if u.source == "ChatGPT 账号" {
                    Label("实时额度 · \(Fmt.when(u.observedAt)) 从 ChatGPT 账号读取", systemImage: "checkmark.circle")
                } else {
                    Label("数据来自 \(Fmt.when(u.observedAt)) 本机最后一次 Codex 请求；网页版、手机和云端任务的用量这里看不到"
                          + (model.liveError.map { "（实时查询失败：\($0)）" } ?? ""), systemImage: "clock")
                }
                }
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else if let err = model.usageError {
                Text(err).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.08)))
            }
        }
    }

    /// Claude limits shared by the Claude大小姐 pet; click to open Claude.
    /// GPT龙娘 sprite or the v3 figure.
    private var lookSwitch: some View {
        let useV3 = Settings.shared.useV3
        func option(_ title: String, _ icon: String, _ v: Bool) -> some View {
            Button { Settings.shared.useV3 = v } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                    Text(title).font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(useV3 == v ? Color.white : Color.primary.opacity(0.75))
                .background(RoundedRectangle(cornerRadius: 8).fill(useV3 == v ? accentDeep : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        return HStack(spacing: 4) {
            option("GPT龙娘", "sparkles", false)
            option("v3 小人", "figure.stand.dress", true)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
        .help("切换龙娘的形象")
    }

    @ViewBuilder private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("正在进行的任务").font(.subheadline.weight(.semibold))
                Spacer()
                let waiting = model.waitingSessions.count
                Text((waiting > 0 ? "\(waiting) 等你 · " : "") + "\(model.busyCount) 进行中 / \(model.sessions.count) 个线程")
                    .font(.caption).foregroundStyle(waiting > 0 ? alertRed : .secondary)
            }
            if model.sessions.isEmpty {
                Text("最近 6 小时没有 Codex 线程，龙娘在发呆～")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
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
                TaskRow(s: s, now: model.now).onTapGesture { openClaude(s) }
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
            Text("形象：GPT龙娘（tqlearning/ai-girl-chatgpt-pets）· 角色设定：ZipZipPipe · 仅本机使用")
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                .help(Pet.attribution)
        }
    }
}
