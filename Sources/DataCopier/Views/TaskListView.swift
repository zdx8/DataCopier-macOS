import SwiftUI

struct TaskListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.tasks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("还没有任务")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.tasks) { task in
                    let running = model.isRunning(task.id)
                    TaskRow(task: task,
                            progress: model.progress[task.id],
                            isRunning: running,
                            startAction: { model.start(task.id) },
                            stopAction: { model.cancel(task.id) })
                        .tag(task.id)
                            .contextMenu {
                                Button("开始") { model.start(task.id) }
                                    .disabled(model.isRunning(task.id))
                                Button("停止") { model.cancel(task.id) }
                                    .disabled(!model.isRunning(task.id))
                                Divider()
                                Button("复制为副本") { model.duplicate(task.id) }
                                Button("在访达中显示目标") { model.revealDestination(task.id) }
                                Divider()
                                Button("删除", role: .destructive) { model.remove(task.id) }
                                    .disabled(model.isRunning(task.id))
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(model.tasks.isEmpty ? "0 个任务" : "共 \(model.tasks.count) 个任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.runningCount > 0 {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("\(model.runningCount) 个进行中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

struct TaskRow: View {
    let task: CopyTask
    let progress: TaskProgress?
    let isRunning: Bool
    var startAction: (() -> Void)?
    var stopAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                    .frame(width: 14)
                Text(task.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                // 任务类型一目了然：两种任务的执行内容与报告口径完全不同。
                if task.taskKind == .transcode {
                    Image(systemName: TaskKind.transcode.symbol)
                        .font(.caption2)
                        .foregroundStyle(.purple)
                        .help("转码任务")
                } else if task.options.copyPreset == .media {
                    Image(systemName: CopyPreset.media.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(CopyPreset.media.displayName)
                }
                Spacer(minLength: 4)
                TaskStatusBadge(state: task.state)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if isRunning, let progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                HStack(spacing: 6) {
                    Text(Format.percent(progress.fraction))
                    Text("·")
                    if task.taskKind == .transcode {
                        // 转码速度按「倍速」呈现，字节吞吐对视频编码没有参考意义。
                        Text("\(progress.completedFiles)/\(progress.totalFiles)")
                        if progress.transcodeSpeed > 0 {
                            Text("·")
                            Text(String(format: "%.1f×", progress.transcodeSpeed))
                        }
                    } else {
                        Text(Format.speed(progress.bytesPerSecond))
                        Text("·")
                        Text("\(progress.completedFiles)/\(progress.totalFiles)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            } else if let report = task.lastReport {
                HStack(spacing: 6) {
                    if task.taskKind == .transcode {
                        // 报告没有单独的「参与转码总数」字段，用三态之和还原。
                        Text("\(report.transcodedFiles)/\(report.transcodedFiles + report.transcodeSkippedFiles + report.transcodeFailedFiles) 已转码")
                        if report.transcodeSkippedFiles > 0 {
                            Text("·")
                            Text("跳过 \(report.transcodeSkippedFiles)")
                        }
                        if report.transcodeFailedFiles > 0 {
                            Text("·")
                            Text("失败 \(report.transcodeFailedFiles)")
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text(Format.bytes(report.copiedBytes))
                        Text("·")
                        if report.isMediaArchive {
                            Text("\(report.photoFiles) 照片 / \(report.videoFiles) 视频")
                        } else {
                            Text("\(report.copiedFiles) 个文件")
                        }
                        // failedFiles 已含校验不一致的记录（见 TaskRunner.append），
                        // 因此这里不能再加 verifyFailedFiles，否则异常数被重复累计。
                        if report.failedFiles > 0 {
                            Text("·")
                            Text("异常 \(report.failedFiles)")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        // 任务条上下留出少量内边距，相邻任务之间保持清晰的呼吸感。
        .padding(.vertical, 4)
        // 右侧预留按钮宽度，避免标题与状态徽标被悬浮按钮遮住。
        .padding(.trailing, 38)
        // 开始 / 停止按钮悬浮在任务条最右，且相对整条任务上下居中。
        .overlay(alignment: .trailing) {
            rowButton
        }
    }

    /// 任务条尾部的启停按钮。运行中显示停止，否则显示开始。
    ///
    /// 选中任务的高亮是系统强调色（蓝），按钮再用强调色会融进背景里，
    /// 因此改为实底圆形：开始用绿色、停止用橙色，白芯图标在任何选中态下都清晰。
    /// 尺寸约为任务条高度的三分之二（30pt），overlay 默认垂直居中。
    private var rowButton: some View {
        Button {
            if isRunning { stopAction?() } else { startAction?() }
        } label: {
            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isRunning ? Color.orange : Color.green))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isRunning ? "停止" : "开始")
    }

    private var subtitle: String {
        "\(task.sourcesDisplay) → \((task.destination as NSString).lastPathComponent)"
    }

    private var icon: String {
        switch task.state {
        case .running, .cancelling: return "arrow.triangle.2.circlepath"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle.fill"
        case .idle: return "circle.dashed"
        }
    }

    private var tint: Color {
        switch task.state {
        case .running, .cancelling: return .blue
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .orange
        case .idle: return .secondary
        }
    }
}
