import SwiftUI

// MARK: - 状态徽标

struct TaskStatusBadge: View {
    let state: TaskState

    var body: some View {
        Text(state.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch state {
        case .idle: return .secondary
        case .running: return .blue
        case .cancelling: return .orange
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

struct FileStatusBadge: View {
    let status: FileStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch status {
        case .verified: return .green
        case .copied: return .blue
        case .skipped: return .secondary
        case .failed: return .red
        case .verifyFailed: return .red
        case .planned: return .secondary
        }
    }
}

// MARK: - 转码状态徽标

struct TranscodeStatusBadge: View {
    let status: TranscodeStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch status {
        case .succeeded: return .green
        case .skipped: return .secondary
        case .failed: return .red
        }
    }
}

// MARK: - 统计卡片

struct StatCard: View {
    let title: String
    let value: String
    var tint: Color = .primary
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - 运行进度面板

struct ProgressPanel: View {
    let progress: TaskProgress
    let state: TaskState
    var averageSpeed: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.percent(progress.fraction))
                    .font(.system(size: 26, weight: .medium))
                    .monospacedDigit()

                Label(progress.phase.displayName, systemImage: progress.phase.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()
                TaskStatusBadge(state: state)
            }

            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)

            if progress.phase == .transcoding {
                transcodeMetrics
            } else {
                copyMetrics
            }

            if !progress.currentFile.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: progress.phase == .transcoding ? "film" : "doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(progress.currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    /// 拷贝阶段的指标。转码阶段沿用同一块面板，但改显与转码相关的量，
    /// 避免把「已处理字节」这类拷贝专有指标带到转码语境下造成误读。
    private var copyMetrics: some View {
        HStack(spacing: 16) {
            metric("已处理", "\(Format.bytes(progress.processedBytes)) / \(Format.bytes(progress.totalBytes))")
            metric("文件", "\(progress.completedFiles) / \(progress.totalFiles)")
            metric("速度", Format.speed(progress.bytesPerSecond))
            metric("已用时", Format.duration(progress.elapsed))
            metric("预计", Format.eta(progress.eta))
            if progress.failedFiles > 0 {
                metric("异常", "\(progress.failedFiles)", tint: .red)
            }
        }
    }

    private var transcodeMetrics: some View {
        HStack(spacing: 16) {
            metric("已转码", "\(progress.transcodeCompleted) / \(progress.transcodeTotal)")
            metric("倍速", progress.transcodeSpeed > 0
                   ? String(format: "%.1f×", progress.transcodeSpeed)
                   : "—")
            metric("已用时", Format.duration(progress.elapsed))
            metric("预计", Format.eta(progress.eta))
            if progress.transcodeFailed > 0 {
                metric("异常", "\(progress.transcodeFailed)", tint: .red)
            }
        }
    }

    private func metric(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

// MARK: - 路径行

struct PathRow: View {
    let icon: String
    let label: String
    let paths: [String]
    var onReveal: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
                .padding(.top, 1)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(path)
                }
            }

            Spacer(minLength: 0)

            if let onReveal {
                Button {
                    onReveal()
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("在访达中显示")
            }
        }
    }
}

// MARK: - 空态

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.timemachine")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("尚未选择任务")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("在左侧新建一个拷贝任务，或从列表中选择已有任务查看详情。")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 顶部提示

struct BannerView: View {
    let message: AppModel.BannerMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.callout.weight(.semibold))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.text)
                    .font(.callout)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption = message.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("关闭")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.32), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
        // 不同的提示类别对应不同的停留时长：成功/信息提示短促，警告多停留便于阅读，
        // 错误不自动消失——拷贝失败、导出失败这类需要用户确认或重试。
        .task(id: message.id) {
            guard let seconds = autoDismissSeconds else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled {
                onDismiss()
            }
        }
    }

    private var autoDismissSeconds: TimeInterval? {
        switch message.kind {
        case .info, .success: return 5
        case .warning: return 8
        case .error: return nil
        }
    }

    private var symbol: String {
        switch message.kind {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private var tint: Color {
        switch message.kind {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - 可复用的选项目录

struct OptionsForm: View {
    @Binding var options: TaskOptions

    var body: some View {
        Section("校验") {
            Picker("哈希算法", selection: $options.algorithm) {
                ForEach(CheckAlgorithm.allCases) { algorithm in
                    Text(algorithm.displayName).tag(algorithm)
                }
            }
            Toggle("拷贝完成后复核目标文件", isOn: $options.verifyAfterCopy)
                .disabled(options.algorithm == .none)
            Text("边拷边算哈希，不会二次读盘；开启复核会额外读取一遍目标文件做最终确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("拷贝行为") {
            Picker("冲突策略", selection: $options.conflictPolicy) {
                ForEach(ConflictPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            Text(options.conflictPolicy.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("保留权限、时间戳与扩展属性", isOn: $options.preserveMetadata)
            Toggle("按符号链接拷贝（不跟随）", isOn: $options.copySymlinksAsLinks)
            Toggle("在目标目录生成校验清单", isOn: $options.exportManifest)
        }

        Section("性能") {
            Stepper(value: $options.concurrency, in: 1...16) {
                Text("并行文件数：\(options.concurrency)")
            }
            Picker("缓冲区大小", selection: $options.bufferSize) {
                Text("512 KB").tag(512 * 1024)
                Text("1 MB").tag(1024 * 1024)
                Text("4 MB").tag(4 * 1024 * 1024)
                Text("8 MB").tag(8 * 1024 * 1024)
                Text("16 MB").tag(16 * 1024 * 1024)
            }
            Text("并行度适合 4–8；机械硬盘或网络卷建议降到 2 以下，SSD 可提高。缓冲区越大，顺序读性能越好。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("排除规则") {
            Text(options.excludedNames.joined(separator: "、"))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("按名称精确匹配排除，默认过滤 macOS 的系统隐藏文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
