import SwiftUI

// MARK: - 预设选择

/// 拷贝预设选择器。
///
/// 预设不是简单的界面分组，而是会改写任务语义的开关：选中「照片 / 视频拷贝」后，
/// 目标路径将完全由拍摄时间重建。因此这里用整块卡片而非下拉菜单，
/// 并把每个预设的行为要点直接写在卡片上，避免用户凭名称猜测。
struct CopyPresetPicker: View {
    @Binding var options: TaskOptions

    var body: some View {
        Section("拷贝预设") {
            HStack(alignment: .top, spacing: 8) {
                ForEach(CopyPreset.allCases) { preset in
                    Button {
                        select(preset)
                    } label: {
                        card(preset)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(.vertical, 2)

            if options.copyPreset == .media {
                Text("目标目录按拍摄时间重建，来源原有的目录结构不再保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 切换预设时套用推荐选项；重复点击当前预设不做任何改动，
    /// 否则用户的手动调整会被一次误触静默抹掉。
    private func select(_ preset: CopyPreset) {
        guard options.copyPreset != preset else { return }
        options = TaskOptions.recommended(for: preset, basedOn: options)
    }

    private func card(_ preset: CopyPreset) -> some View {
        let selected = options.copyPreset == preset

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(preset.displayName)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
            }

            Text(preset.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
                              lineWidth: selected ? 1.2 : 0.5)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - 归档配置

/// 媒体预设的归档配置。
struct MediaImportForm: View {
    @Binding var settings: MediaImportSettings

    var body: some View {
        Section("归档选项") {
            // 三项核心开关放在一起：文件重命名、照片/视频分类、归档目录层级。
            // 每项都按用户列出的枚举值给出明确文案，避免在标签里靠副标题补足。
            Picker("文件重命名", selection: $settings.renameByCaptureTime) {
                Text("文件名不改动").tag(false)
                Text("按拍摄时间重命名").tag(true)
            }
            if settings.renameByCaptureTime {
                Picker("命名方式", selection: $settings.renameMode) {
                    ForEach(MediaRenameMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if settings.renameMode == .customWithTimestamp {
                    TextField("自定义字段", text: $settings.customRenamePrefix, prompt: Text("例如：婚礼、旅行"))
                    Text("自定义字段会作为前缀拼在拍摄时间之前，留空则只保留时间戳。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("示例：\(exampleName)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Toggle("照片与视频分开存放", isOn: $settings.separateByType)

            Picker("归档目录", selection: $settings.folderGranularity) {
                ForEach(MediaFolderGranularity.allCases) { granularity in
                    Text(granularity.displayName).tag(granularity)
                }
            }

            // 归档规则有六七个开关，逐条列举示例路径比任何文字都直观。
            VStack(alignment: .leading, spacing: 3) {
                Text("归档路径预览")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(previewPath(for: .photo))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(previewPath(for: .video))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 3)
        }
    }

    /// 命名示例。自定义字段方式下用当前填写的字段拼出真实示例，
    /// 让用户在落盘前就能看到最终的文件名样子。
    private var exampleName: String {
        guard settings.renameMode == .customWithTimestamp, let date = Self.sampleDate else {
            return settings.renameMode.example
        }
        let prefix = settings.customRenamePrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = MediaArchiver.timestamp(date)
        return prefix.isEmpty ? "\(stamp).JPG" : "\(prefix)_\(stamp).JPG"
    }

    /// 归档路径预览。
    ///
    /// 直接调用引擎的路径计算函数而不是在界面里复刻一套拼接逻辑：
    /// 配置项有六七个且互相影响，任何一处手写示例都可能与真实落盘位置不一致，
    /// 而这种不一致只有在拷贝完成后才会被发现。
    private func previewPath(for kind: MediaKind) -> String {
        guard let date = Self.sampleDate else { return "—" }
        let original = kind == .photo ? "IMG_1234.JPG" : "MVI_5678.MOV"
        let fileName = MediaArchiver.fileName(originalName: original,
                                              captureDate: date,
                                              settings: settings)
        // 预览用的机型是固定样例：这里要说明的是目录层级，
        // 而不是任何一份具体素材的真实机型。
        let device = settings.classifyByDevice ? "iPhone 15 Pro" : nil
        return MediaArchiver.relativePath(kind: kind,
                                          captureDate: date,
                                          fileName: fileName,
                                          settings: settings,
                                          deviceModel: settings.classifyByDevice ? device : nil)
    }

    private static let sampleDate = MediaMetadata.makeLocalDate(year: 2024, month: 3, day: 15,
                                                                hour: 14, minute: 30, second: 22)
}

// MARK: - 可选细化与格式说明

/// 媒体预设的低频配置与格式说明。
///
/// 与 `MediaImportForm` 分开渲染：这两块属于「看完一次就不用再看」的内容，
/// 固定放在整个表单的最底部，不打扰高频的归档与转码配置。
struct MediaExtrasForm: View {
    @Binding var settings: MediaImportSettings

    var body: some View {
        Section {
            DisclosureGroup {
                if settings.separateByType {
                    TextField("照片目录名", text: $settings.photoFolderName, prompt: Text("Photos"))
                    TextField("视频目录名", text: $settings.videoFolderName, prompt: Text("Videos"))
                }

                Divider()

                Toggle("按拍摄设备型号分类", isOn: $settings.classifyByDevice)
                Text("从照片 EXIF 与视频容器中读取机型，在照片 / 视频目录下再建一层机型目录，"
                     + "便于按设备整体搬移或交付素材。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.classifyByDevice {
                    TextField("未识别设备的目录名",
                              text: $settings.unknownDeviceFolderName,
                              prompt: Text("未知设备"))
                    Text("元数据里没有机型信息的素材（截图、后期导出、扫描件等）统一归入此目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Picker("视频时间解释", selection: $settings.videoTimeZone) {
                    ForEach(VideoTimeZoneMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(settings.videoTimeZone.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("从文件名解析时间戳", isOn: $settings.parseFilenameTimestamp)
                Text("适用 `IMG_20240315_143022.JPG`、`VID_20240315_143022.mp4` 这类命名。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("无法确定时回退到文件修改时间", isOn: $settings.fallbackToFileDate)
                Text(settings.fallbackToFileDate
                     ? "元数据与文件名都无法给出时间时，用文件修改时间兜底——结果可能偏向拷贝当天的日期。"
                     : "关闭后，无法确定拍摄时间的文件将被跳过，并在报告中单独列出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text("高级选项")
            }
        } header: {
            Text("可选细化")
        } footer: {
            Text("默认即可应付多数相机卡导入；只有遇到目录名冲突、设备识别错误或视频日期错位时再展开。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("支持的格式") {
            LabeledContent("照片") {
                Text("\(MediaFileTypes.photoExtensions.count) 种扩展名")
                    .foregroundStyle(.secondary)
            }
            .help(MediaFileTypes.extensionList(for: .photo).map { ".\($0)" }.joined(separator: " "))

            LabeledContent("视频") {
                Text("\(MediaFileTypes.videoExtensions.count) 种扩展名")
                    .foregroundStyle(.secondary)
            }
            .help(MediaFileTypes.extensionList(for: .video).map { ".\($0)" }.joined(separator: " "))

            DisclosureGroup("查看格式清单") {
                formatList(title: "照片", kind: .photo)
                formatList(title: "视频", kind: .video)
            }
            .font(.callout)

            Text("其余类型的文件不会被拷贝。需要连其他文件一起搬运时，请改用「文件拷贝」。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatList(title: String, kind: MediaKind) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.medium))
            Text(MediaFileTypes.extensionList(for: kind).map { ".\($0)" }.joined(separator: "  "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }
}
