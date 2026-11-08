import AppKit
import Charts
import SwiftUI

private let accent = Color(red: 0.80, green: 0.62, blue: 0.20)
private let accentDeep = Color(red: 0.62, green: 0.45, blue: 0.08)
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
        .help("打开 Grok Bot")
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    var openClaude: (SessionInfo) -> Void
    var openSettings: () -> Void = {}
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                Text(["Grok Bot", model.usage?.plan].compactMap { $0 }.joined(separator: " · ") + " · 每周额度")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { model.refresh(notify: false) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("刷新")
        }
    }

    private func barColor(_ u: Double) -> Color {
        u < 40 ? Color(red: 0.36, green: 0.78, blue: 0.62) : u < 70 ? Color(red: 0.97, green: 0.70, blue: 0.22)
            : u < 90 ? Color(red: 0.95, green: 0.42, blue: 0.15) : alertRed
    }

    @ViewBuilder private var usageSection: some View {
        if let u = model.usage, let w = u.windows.first {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("每周额度").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(w.utilization.rounded()))%").font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(barColor(w.utilization))
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    GeometryReader { g in
                        Capsule().fill(barColor(w.utilization))
                            .frame(width: g.size.width * CGFloat(min(w.utilization, 100)) / 100)
                    }
                }
                .frame(height: 8)
                Text(w.resetsAt.map { "\(Fmt.duration($0.timeIntervalSince(model.now)))后重置 · \(Fmt.when($0))" } ?? "已重置")
                    .font(.caption).foregroundStyle(.secondary)
                Label("Grok Bot \(Fmt.when(u.observedAt)) 读到的数据（Grok Bot 打开时会更新）", systemImage: "clock")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        } else {
            Text("还没读到 Grok Bot 的额度。打开一次 Grok Bot 桌面版，它会把每周用量缓存到本机。")
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
                Text((waiting > 0 ? "\(waiting) 等你 · " : "") + "\(model.busyCount) 进行中 / \(model.sessions.count) 个机器人")
                    .font(.caption).foregroundStyle(waiting > 0 ? alertRed : .secondary)
            }
            if model.sessions.isEmpty {
                Text("最近 6 小时 Grok Bot 没有动静，本小姐在发呆～")
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
                Button { openSettings() } label: { Label("设置", systemImage: "gearshape") }
                Spacer()
                Button("退出", action: quit)
            }
            .buttonStyle(.borderless).font(.caption)
            Text("形象：Grok娘设定图（lmy414/ai-chan-sheets）· 角色设定：ZipZipPipe · CC BY-NC-SA")
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                .help(Pet.attribution)
        }
    }
}
