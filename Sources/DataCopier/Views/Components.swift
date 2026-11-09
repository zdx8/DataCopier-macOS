import SwiftUI

// MARK: - 状态徽标

struct TaskStatusBadge: View {
    let state: TaskState

    var body: some View {
        BenchoStatus(text: state.displayName, color: tint)
    }

    private var tint: Color {
        switch state {
        case .idle: return Bencho.ink4
        case .running: return Bencho.signal
        case .cancelling: return Bencho.warn
        case .finished: return Bencho.ok
        case .failed: return Bencho.danger
        case .cancelled: return Bencho.warn
        }
    }
}

struct FileStatusBadge: View {
    let status: FileStatus

    var body: some View {
        BenchoStatus(text: status.displayName, color: tint, dot: false)
    }

    private var tint: Color {
        switch status {
        case .verified: return Bencho.ok
        case .copied: return Bencho.pick
        case .skipped: return Bencho.ink4
        case .failed: return Bencho.danger
        case .verifyFailed: return Bencho.danger
        case .planned: return Bencho.ink4
        }
    }
}

// MARK: - 转码状态徽标

struct TranscodeStatusBadge: View {
    let status: TranscodeStatus

    var body: some View {
        BenchoStatus(text: status.displayName, color: tint, dot: false)
    }

    private var tint: Color {
        switch status {
        case .succeeded: return Bencho.ok
        case .skipped: return Bencho.ink4
        case .failed: return Bencho.danger
        }
    }
}

// MARK: - 统计卡片

/// 一块纸面 + 11pt 大写标签 + 滚动数字。数字用 bencho 的 rolling-counter：
/// 值变化时逐位滚动，而不是整串跳变。
struct StatCard: View {
    let title: String
    let value: String
    var tint: Color = Bencho.ink
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.07 * 9.5)
                .foregroundStyle(Bencho.ink4)

            RollingNumber(text: value, size: 19, weight: .medium, color: tint)
                .lineLimit(1)
                .frame(height: 24, alignment: .leading)

            if let caption {
                Text(caption)
                    .font(Bencho.Typeface.meta(10.5))
                    .foregroundStyle(Bencho.ink5)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Bencho.fillSlab, in: RoundedRectangle(cornerRadius: Bencho.Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Bencho.Radius.row, style: .continuous)
                .strokeBorder(Bencho.hairline, lineWidth: 1)
        }
    }
}

// MARK: - 运行进度面板

struct ProgressPanel: View {
    let progress: TaskProgress
    let state: TaskState
    var averageSpeed: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                RollingNumber(text: Format.percent(progress.fraction), size: 30, weight: .medium)
                    .frame(height: 36, alignment: .leading)

                HStack(spacing: 5) {
                    Image(systemName: progress.phase.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(progress.phase.displayName)
                        .font(Bencho.Typeface.meta(11.5))
                }
                .foregroundStyle(Bencho.ink3)

                Spacer()
                TaskStatusBadge(state: state)
            }

            BenchoMeter(fraction: progress.fraction,
                        tint: state == .failed ? Bencho.danger : Bencho.ink,
                        height: 6)

            if progress.phase == .transcoding {
                transcodeMetrics
            } else {
                copyMetrics
            }

            if !progress.currentFile.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: progress.phase == .transcoding ? "film" : "doc")
                        .font(.system(size: 10))
                        .foregroundStyle(Bencho.ink5)
                    Text(progress.currentFile)
                        .font(Bencho.Typeface.meta(11))
                        .foregroundStyle(Bencho.ink4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.top, 2)
            }
        }
        .padding(18)
        .background(Bencho.fillSlab, in: RoundedRectangle(cornerRadius: Bencho.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Bencho.Radius.card, style: .continuous)
                .strokeBorder(Bencho.hairline, lineWidth: 1)
        }
    }

    /// 拷贝阶段的指标。转码阶段沿用同一块面板，但改显与转码相关的量，
    /// 避免把「已处理字节」这类拷贝专有指标带到转码语境下造成误读。
    private var copyMetrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 16, alignment: .leading)],
                  alignment: .leading,
                  spacing: 10) {
            metric("已处理", "\(Format.bytes(progress.processedBytes)) / \(Format.bytes(progress.totalBytes))")
            metric("文件", "\(progress.completedFiles) / \(progress.totalFiles)")
            metric("速度", Format.speed(progress.bytesPerSecond))
            metric("已用时", Format.duration(progress.elapsed))
            metric("预计", Format.eta(progress.eta))
            if progress.failedFiles > 0 {
                metric("异常", "\(progress.failedFiles)", tint: Bencho.danger)
            }
        }
    }

    private var transcodeMetrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 16, alignment: .leading)],
                  alignment: .leading,
                  spacing: 10) {
            metric("已转码", "\(progress.transcodeCompleted) / \(progress.transcodeTotal)")
            metric("倍速", progress.transcodeSpeed > 0
                   ? String(format: "%.1f×", progress.transcodeSpeed)
                   : "—")
            metric("已用时", Format.duration(progress.elapsed))
            metric("预计", Format.eta(progress.eta))
            if progress.transcodeFailed > 0 {
                metric("异常", "\(progress.transcodeFailed)", tint: Bencho.danger)
            }
        }
    }

    private func metric(_ title: String, _ value: String, tint: Color = Bencho.fillOn) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.06 * 9)
                .foregroundStyle(Bencho.ink5)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 路径行

struct PathRow: View {
    let icon: String
    let label: String
    let paths: [String]
    var onReveal: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Bencho.ink4)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)

            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.06 * 9)
                .foregroundStyle(Bencho.ink5)
                .frame(width: 34, alignment: .leading)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .font(Bencho.Typeface.mono(11.5))
                        .foregroundStyle(Bencho.ink2)
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
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11))
                        .foregroundStyle(Bencho.ink4)
                }
                .buttonStyle(.plain)
                .help("在访达中显示")
            }
        }
    }
}

// MARK: - 空态

struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        BenchoEmptyState(
            symbol: "externaldrive.badge.timemachine",
            title: "尚未选择任务",
            message: "从左侧选择已有任务，或创建一个新的拷贝 / 转码任务。",
            actionTitle: "新建任务"
        ) {
            model.showNewTaskSheet = true
        }
    }
}

// MARK: - 顶部提示

struct BannerView: View {
    let message: AppModel.BannerMessage
    let onDismiss: () -> Void

    var body: some View {
        BenchoToast(kind: message.kind,
                    text: message.text,
                    caption: message.caption,
                    onDismiss: onDismiss)
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
}

// MARK: - 可复用的选项目录

struct OptionsForm: View {
    @Binding var options: TaskOptions

    var body: some View {
        BenchoSection(title: "校验",
                      caption: "边拷边算哈希，不会二次读盘；开启复核会额外读取一遍目标文件做最终确认。") {
            BenchoFieldRow(label: "哈希算法") {
                Picker("", selection: $options.algorithm) {
                    ForEach(CheckAlgorithm.allCases) { algorithm in
                        Text(algorithm.displayName).tag(algorithm)
                    }
                }
                .labelsHidden()
                .frame(width: 132)
            }
            Toggle("拷贝完成后复核目标文件", isOn: $options.verifyAfterCopy)
                .toggleStyle(.bencho)
                .disabled(options.algorithm == .none)
        }

        BenchoSection(title: "拷贝行为", caption: options.conflictPolicy.detail) {
            BenchoFieldRow(label: "冲突策略") {
                Picker("", selection: $options.conflictPolicy) {
                    ForEach(ConflictPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .labelsHidden()
                .frame(width: 132)
            }
            Toggle("保留权限、时间戳与扩展属性", isOn: $options.preserveMetadata)
                .toggleStyle(.bencho)
            Toggle("按符号链接拷贝（不跟随）", isOn: $options.copySymlinksAsLinks)
                .toggleStyle(.bencho)
            Toggle("在目标目录生成校验清单", isOn: $options.exportManifest)
                .toggleStyle(.bencho)
        }

        BenchoSection(title: "性能",
                      caption: "并行度适合 4–8；机械硬盘或网络卷建议降到 2 以下，SSD 可提高。缓冲区越大，顺序读性能越好。") {
            BenchoFieldRow(label: "并行文件数") {
                Stepper(value: $options.concurrency, in: 1...16) {
                    Text("\(options.concurrency)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Bencho.fillOn)
                }
                .frame(width: 92)
            }
            BenchoFieldRow(label: "缓冲区大小") {
                Picker("", selection: $options.bufferSize) {
                    Text("512 KB").tag(512 * 1024)
                    Text("1 MB").tag(1024 * 1024)
                    Text("4 MB").tag(4 * 1024 * 1024)
                    Text("8 MB").tag(8 * 1024 * 1024)
                    Text("16 MB").tag(16 * 1024 * 1024)
                }
                .labelsHidden()
                .frame(width: 132)
            }
        }

        BenchoSection(title: "排除规则", caption: "按名称精确匹配排除，默认过滤 macOS 的系统隐藏文件。") {
            Text(options.excludedNames.joined(separator: "、"))
                .font(Bencho.Typeface.mono(11.5))
                .foregroundStyle(Bencho.ink3)
                .textSelection(.enabled)
        }
    }
}
