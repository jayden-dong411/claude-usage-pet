import AppKit
import Charts
import SwiftUI

private let accent = Color(red: 0.30, green: 0.42, blue: 0.99)
private let accentDeep = Color(red: 0.20, green: 0.30, blue: 0.80)
private let alertRed = Color(red: 0.92, green: 0.30, blue: 0.32)

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
        .help("打开 DeepSeek Harness")
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stats: DSDashboardModel
    var openClaude: (SessionInfo) -> Void
    var openDashboard: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heatmapSection
            Divider()
            header
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

    /// Daily spend calendar; click to open the full statistics.
    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("每日花费").font(.subheadline.weight(.semibold))
                Spacer()
                Button { openDashboard() } label: {
                    HStack(spacing: 2) { Text("用量统计"); Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderless).font(.caption)
            }
            SpendHeatmap(dm: stats, weeks: 22, cell: 10, gap: 3)
                .contentShape(Rectangle())
                .onTapGesture { openDashboard() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: model.frame ?? NSImage())
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Pet.name).font(.headline)
                    Text(Pet.levelNames[model.level])
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.16)))
                        .foregroundStyle(accentDeep)
                }
                Text("DeepSeek Harness · 账号余额")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { model.refresh(notify: false) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("刷新")
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.10)))
    }

    @ViewBuilder private var usageSection: some View {
        if let u = model.usage {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("账号余额").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(u.money(u.balance)).font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(model.level >= 4 ? alertRed : model.level == 3 ? Color.orange : accentDeep)
                }
                HStack(spacing: 8) {
                    tile("今天花了", u.money(u.today), "sun.max")
                    tile("近 7 天", u.money(u.week), "calendar")
                    tile("还能用", u.daysLeft.map { "约 \(Int($0)) 天" } ?? "—", "hourglass")
                }
                Label("DeepSeek Harness \(Fmt.when(u.observedAt)) 记下的余额（Harness 打开时会更新）", systemImage: "clock")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        } else {
            Text("还没读到 DeepSeek 余额。打开一次 DeepSeek Harness，它会把余额记在 ~/.dsh 里。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.08)))
        }
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
                Text("最近 6 小时 DeepSeek Harness 没有会话，鲸鱼在摸鱼～")
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
            Text("形象：DeepSeek娘 Q版冬装 2（lmy414/ai-chan-sheets #12）· CC BY-NC-SA")
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                .help(Pet.attribution)
        }
    }
}
