import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// 关闭窗口时的行为，写入 UserDefaults 与 AppDelegate 共享。
    @AppStorage(CloseAction.storageKey) private var closeActionRaw: String = CloseAction.quit.rawValue

    @State private var encoders: [VideoCapability.EncoderInfo] = []
    @State private var ffmpegPath: String?
    @State private var ffmpegVersion: String?
    @State private var ffmpegEncoderCount: Int?
    @State private var usingOverride = false
    @State private var detected = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Form {
                Section("通用") {
                    Picker("点击关闭按钮时", selection: $closeActionRaw) {
                        Text("退出软件").tag(CloseAction.quit.rawValue)
                        Text("最小化到任务栏（常驻菜单栏）").tag(CloseAction.minimize.rawValue)
                    }
                    Text(closeActionHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("检测 USB 移动设备", isOn: $model.usbDetectEnabled)
                    Text("开启后，插入相机卡、U 盘等移动设备时会自动唤起软件并新建拷贝任务，来源预填为该设备。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AppearanceForm()

                CopyPresetPicker(options: $model.defaultOptions)

                if model.defaultOptions.copyPreset == .media {
                    MediaImportForm(settings: Binding(
                        get: { model.defaultOptions.mediaSettings },
                        set: { model.defaultOptions.mediaSettings = $0 }
                    ))
                }

                OptionsForm(options: $model.defaultOptions)

                TranscodeForm(settings: Binding(
                    get: { model.defaultOptions.transcodeSettings },
                    set: { model.defaultOptions.transcodeSettings = $0 }
                ))

                Section("运行环境") {
                    hardwareRow
                    ffmpegRow
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("完成") {
                    model.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 720, height: 780)
        .task { await refresh() }
    }

    private var closeActionHint: String {
        CloseAction.current == .minimize
            ? "关闭窗口后软件继续在菜单栏（屏幕右上角）常驻，点击菜单栏图标即可重新打开；从菜单栏菜单选择「退出」才会真正结束软件。"
            : "关闭窗口即退出软件。菜单栏图标会一直保留，随时可以从那里重新打开。"
    }

    // MARK: - 硬件能力

    @ViewBuilder
    private var hardwareRow: some View {
        if encoders.isEmpty {
            Text("正在探测本机视频编码器…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let hardware = encoders.filter { $0.isHardwareAccelerated }
            HStack(spacing: 6) {
                Image(systemName: hardware.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(hardware.isEmpty ? Color.orange : Color.green)
                Text(hardware.isEmpty
                     ? "VideoToolbox 未报告硬件编码器，转码将回退到软件编码"
                     : "VideoToolbox 硬件编码器：\(hardware.count) 个")
                    .font(.callout)
            }

            ForEach(hardware.prefix(5)) { encoder in
                Text("· \(encoder.name)　\(encoder.codec.isEmpty ? "—" : encoder.codec)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - FFmpeg

    private var ffmpegRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: detected ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(detected ? Color.green : Color.orange)
                Text(statusText)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
            }

            if let ffmpegPath, detected {
                Text(ffmpegPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(ffmpegPath)
            }

            HStack(spacing: 8) {
                Button("指定 ffmpeg…") {
                    if let picked = FilePanels.chooseFFmpeg() {
                        FFmpegLocator.overridePath = picked
                        Task { await refresh() }
                    }
                }
                if usingOverride {
                    Button("改回自动检测") {
                        FFmpegLocator.overridePath = nil
                        Task { await refresh() }
                    }
                }
                Button("重新检测") {
                    FFmpegCapability.invalidate()
                    Task { await refresh() }
                }
            }

            Text("FFmpeg 提供硬件与软件编码器、滤镜与格式支持。应用优先使用随包分发或系统路径中的版本；若装在别处可在此手动指定。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        guard detected else {
            return "未检测到 FFmpeg，转码功能不可用"
        }
        var text = "已就绪：FFmpeg \(ffmpegVersion ?? "")"
        if let ffmpegEncoderCount {
            text += "，可用编码器 \(ffmpegEncoderCount) 个"
        }
        if usingOverride {
            text += "（手动指定）"
        }
        return text
    }

    // MARK: - 探测

    private func refresh() async {
        let result = await Task.detached(priority: .utility) { () -> (encoders: [VideoCapability.EncoderInfo], path: String?, version: String?, count: Int?, override: Bool) in
            let encoders = VideoCapability.availableEncoders()
            let override = FFmpegLocator.overridePath != nil
            guard let url = FFmpegLocator.locate() else {
                return (encoders, nil, nil, nil, override)
            }
            let version = FFmpegLocator.version(of: url)
            // 编码器清单同时反映 FFmpeg 是否真的可执行——能列出编码器才说明可用。
            let count = FFmpegCapability.encoders(of: url).count
            return (encoders, url.path, version, count, override)
        }.value

        encoders = result.encoders
        ffmpegPath = result.path
        ffmpegVersion = result.version
        ffmpegEncoderCount = result.count
        usingOverride = result.override
        detected = result.path != nil && (result.count ?? 0) > 0
    }
}
