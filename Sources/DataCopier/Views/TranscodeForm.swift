import SwiftUI

/// 转码配置表单。
///
/// 复用于三处：新建转码任务（`standalone`）、拷贝任务的配置页、默认选项设置页。
/// 探测 FFmpeg 的可用性并据此决定开关是否可用——与其让用户配好参数后在运行时
/// 才发现缺 FFmpeg，不如提前说清。
struct TranscodeForm: View {

    @Binding var settings: TranscodeSettings
    /// `true` 表示这是独立转码任务的表单：没有「启用拷贝后转码」开关
    /// （任务本身就是转码），文案也改为针对原始视频文件。
    var standalone: Bool = false

    @State private var ffmpegPath: String?
    @State private var ffmpegVersion: String?
    @State private var probeFinished = false

    private var ffmpegReady: Bool { ffmpegPath != nil }
    private var preset: TranscodePreset { settings.preset }

    var body: some View {
        Section(standalone ? "转码设置" : "视频转码（拷贝完成后）") {
            if !standalone {
                Toggle("启用拷贝后转码", isOn: $settings.enabled)
                    .disabled(!ffmpegReady)
            }

            availabilityRow

            if (standalone || settings.enabled) && ffmpegReady {
                presetPicker
                presetSummary

                if settings.presetID == TranscodePresets.customID {
                    customFields
                }

                advancedOptions
            }
        }
        .task {
            // 探测结果带缓存：切换详情页分区、重复打开表单都不会反复起子进程。
            let probe = await Task.detached(priority: .utility) {
                FFmpegLocator.probe()
            }.value
            ffmpegPath = probe.path
            ffmpegVersion = probe.version
            probeFinished = true
        }
    }

    // MARK: - FFmpeg 状态

    @ViewBuilder
    private var availabilityRow: some View {
        if !probeFinished {
            Text("正在检测 FFmpeg…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let ffmpegPath {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.green)
                Text("FFmpeg \(ffmpegVersion ?? "")　\(ffmpegPath)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(ffmpegPath)
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                Text("未检测到 FFmpeg，转码不可用。可在「设置」中手动指定其路径。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 预设选择

    private var presetPicker: some View {
        Picker("转码预设", selection: $settings.presetID) {
            ForEach(TranscodePresets.all) { item in
                Text("\(item.name)　—　\(item.estimatedSizeText)").tag(item.id)
            }
            Divider()
            Text("自定义参数").tag(TranscodePresets.customID)
        }
    }

    private var presetSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: preset.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(preset.name)
                    .font(.caption.weight(.medium))
                if hardwareBadge {
                    Text("硬件加速")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.16), in: Capsule())
                        .foregroundStyle(Color.green)
                }
            }

            Text(preset.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(preset.detailLine)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    /// 仅当预设需要重新编码、且本机 VideoToolbox 报告存在对应硬件通路时置位。
    private var hardwareBadge: Bool {
        guard settings.preferHardwareAcceleration, preset.videoCodec.isReencode else { return false }
        return VideoCapability.hasHardwareEncoder(for: preset.videoCodec)
    }

    // MARK: - 自定义参数

    @ViewBuilder
    private var customFields: some View {
        Picker("视频编码", selection: $settings.custom.videoCodec) {
            ForEach(TranscodeVideoCodec.allCases) { codec in
                Text(codec.displayName).tag(codec)
            }
        }

        if settings.custom.videoCodec.isReencode {
            Picker("分辨率上限", selection: $settings.custom.maxLongEdge) {
                ForEach(CustomTranscodeOptions.longEdgeChoices, id: \.self) { edge in
                    Text(CustomTranscodeOptions.longEdgeLabel(edge)).tag(edge)
                }
            }

            HStack {
                Text("目标码率")
                Slider(value: $settings.custom.videoBitRateMbps, in: 1...40, step: 0.5)
                Text(String(format: "%.1f Mbps", settings.custom.videoBitRateMbps))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 92, alignment: .trailing)
            }
        }

        Picker("音频", selection: $settings.custom.audioMode) {
            ForEach(TranscodeAudioMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }

        Picker("容器格式", selection: $settings.custom.container) {
            ForEach(TranscodeContainer.allCases) { container in
                Text(container.displayName).tag(container)
            }
        }

        if settings.custom.videoCodec == .prores && !settings.custom.container.supportsProRes {
            Text("ProRes 无法写入 \(settings.custom.container.displayName)，执行时会自动改用 MOV。")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 高级选项

    private var advancedOptions: some View {
        DisclosureGroup("高级选项") {
            Picker("跳过小文件", selection: $settings.skipFilesSmallerThanMB) {
                Text("不跳过").tag(0)
                Text("10 MB").tag(10)
                Text("50 MB").tag(50)
                Text("100 MB").tag(100)
                Text("500 MB").tag(500)
            }

            Stepper(value: $settings.concurrency, in: 1...6) {
                Text("转码并发数：\(settings.concurrency)")
            }

            Toggle("优先使用硬件编码（不可用时自动回退软件编码）",
                   isOn: $settings.preferHardwareAcceleration)

            Toggle("转码结果未变小时保留原文件", isOn: $settings.discardOutputIfLarger)

            Toggle("转码成功后删除原始拷贝", isOn: $settings.removeSourceAfterSuccess)
                .foregroundStyle(settings.removeSourceAfterSuccess ? Color.red : Color.primary)

            if standalone {
                Text("转码输出统一写入任务的目标文件夹，文件名带预设后缀，因此默认不会覆盖已有文件。转码并发数建议保持 1–2：多个编码进程会互相抢占硬件编码器与内存带宽。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.removeSourceAfterSuccess {
                    Text("注意：删除的是来源中的原始视频文件，删除后无法恢复。仅在转码成功且输出可读时才执行。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("转码输出与拷贝结果同目录，文件名带预设后缀，因此默认不会覆盖原始素材。转码并发数建议保持 1–2：多个编码进程会互相抢占硬件编码器与内存带宽。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.removeSourceAfterSuccess {
                    Text("注意：删除的是拷贝到目标位置的那一份（源文件不受影响）。仅在转码成功且输出可读时才执行。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
