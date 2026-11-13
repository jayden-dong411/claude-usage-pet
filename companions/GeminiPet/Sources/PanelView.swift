import AppKit
import SwiftUI

private let accent = Color(red: 0.42, green: 0.36, blue: 0.95)
private let accentDeep = Color(red: 0.30, green: 0.24, blue: 0.78)
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
        .help("打开 Antigravity")
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stats: DashboardModel
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
        .fitsScreen()
    }

    /// Daily Gemini tokens; click to open the statistics (with Claude Code and Codex alongside).
    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("每日 Gemini Token").font(.subheadline.weight(.semibold))
                Spacer()
                Button { openDashboard() } label: {
                    HStack(spacing: 2) { Text("用量统计"); Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderless).font(.caption)
            }
            TokenHeatmap(days: stats.days(for: .gemini), weeks: 22, cell: 10, gap: 3)
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
                Text("Antigravity · " + (model.usage?.plan ?? "Gemini 额度"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { model.refresh(notify: false); model.refreshPeers() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("刷新")
        }
    }

    private func barColor(_ v: Double) -> Color {
        v < 70 ? Color(red: 0.24, green: 0.70, blue: 0.48) : v < 90 ? .orange : alertRed
    }

    private func bar(_ title: String, _ w: PeerWindow, big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(big ? .subheadline.weight(.semibold) : .caption)
                Spacer()
                Text("已用 \(Int(w.utilization.rounded()))%")
                    .font((big ? Font.title3 : Font.caption).weight(.bold).monospacedDigit())
                    .foregroundStyle(barColor(w.utilization))
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                GeometryReader { g in
                    Capsule().fill(barColor(w.utilization))
                        .frame(width: g.size.width * CGFloat(min(w.utilization, 100)) / 100)
                }
            }
            .frame(height: big ? 8 : 5)
            Text(w.resetsAt.map { big ? "\(Fmt.when($0)) 恢复（还有 \(Fmt.duration($0.timeIntervalSinceNow))）" : "\(Fmt.when($0)) 恢复" } ?? "已恢复")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }
    }

    @ViewBuilder private var usageSection: some View {
        if let u = model.usage {
            VStack(alignment: .leading, spacing: 10) {
                if let five = model.gemini { bar("Gemini · 5 小时", five, big: true) }
                if let week = model.week { bar("Gemini · 每周", week, big: true) }
                if !model.otherWindows.isEmpty {
                    Divider()
                    Text("Claude / GPT 模型（另一组额度）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(model.otherWindows.enumerated()), id: \.offset) { _, w in
                            bar(w.label.components(separatedBy: " · ").last ?? w.label, w, big: false)
                        }
                    }
                }
                Label(model.connected ? "Antigravity 实时额度 · \(Fmt.when(u.observedAt)) 读取"
                                      : "Antigravity 没开，显示 \(Fmt.when(u.observedAt)) 的额度",
                      systemImage: "clock")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.08)))
        } else {
            Text("还没读到 Gemini 额度。打开 Antigravity，我就能从它的本机服务里读到额度。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.08)))
        }
    }

    @ViewBuilder private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近的对话").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.busyCount) 进行中 / \(model.sessions.count) 个对话")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.connected {
                Text("Antigravity 没有打开，看不到对话。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else if model.sessions.isEmpty {
                Text("最近 6 小时 Antigravity 没有对话，星星在发呆～")
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
            Text("形象：Gemini娘（lmy414/ai-chan-sheets #10）· CC BY-NC-SA")
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                .help(Pet.attribution)
        }
    }
}
