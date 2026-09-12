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
    /// 路径预览使用的设备目录名。三种取值：
    /// nil 使用固定样例机型（设置页等无真实设备的场景）；
    /// 空串不显示设备目录（来源区设备名留空 = 不按设备分层）；
    /// 非空使用传入的设备名（新建任务时扫描/手填的结果）。
    var previewDeviceName: String? = nil

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
                if settings.renameMode == .customWithTimestamp
                    || settings.renameMode == .customWithOriginalAndTimestamp {
                    TextField("自定义字段", text: $settings.customRenamePrefix, prompt: Text("默认为空，例如：婚礼、旅行"))
                    Text("自定义字段会作为前缀拼在文件名最前面，留空则只保留后面的部分。")
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

            // 归档目录的自定义子目录：拼进「月-日」叶子目录名，默认为空仅保留月-日。
            TextField("自定义子目录", text: $settings.folderSuffix, prompt: Text("默认为空，例如：婚礼、旅行"))
            Text("自定义子目录会以连字符拼接在「月-日」文件夹名之后，如 03-15-婚礼；留空则仅保留月-日。")
                .font(.caption)
                .foregroundStyle(.secondary)

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
    /// 让用户在落盘前就能看到最终的文件名样子。时间戳统一用今天，
    /// 与即将导入的素材时间更为接近。
    private var exampleName: String {
        let usesCustom = settings.renameMode == .customWithTimestamp
            || settings.renameMode == .customWithOriginalAndTimestamp
        guard usesCustom else {
            return settings.renameMode.example
        }
        let prefix = settings.customRenamePrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = MediaArchiver.timestamp(Date())
        switch settings.renameMode {
        case .customWithTimestamp:
            return prefix.isEmpty ? "\(stamp).JPG" : "\(prefix)_\(stamp).JPG"
        case .customWithOriginalAndTimestamp:
            let original = "IMG_1234"
            let core = "\(original)_\(stamp)"
            return prefix.isEmpty ? "\(core).JPG" : "\(prefix)_\(core).JPG"
        default:
            return settings.renameMode.example
        }
    }

    /// 归档路径预览。
    ///
    /// 直接调用引擎的路径计算函数而不是在界面里复刻一套拼接逻辑：
    /// 配置项有六七个且互相影响，任何一处手写示例都可能与真实落盘位置不一致，
    /// 而这种不一致只有在拷贝完成后才会被发现。
    private func previewPath(for kind: MediaKind) -> String {
        // 预览统一用今天的日期：马上要导入的素材大概率就是今天拍的，
        // 固定样例日期反而容易让人误以为归档目录被写死了。
        let date = Date()
        let original = kind == .photo ? "IMG_1234.JPG" : "MVI_5678.MOV"
        let fileName = MediaArchiver.fileName(originalName: original,
                                              captureDate: date,
                                              settings: settings)
        // 设备名三态：档位不带设备时无所谓；带设备时优先用来源区识别/
        // 手填的设备名，留空则预览中也不出现设备目录；未传参的场景
        // （设置页等）退回固定样例机型。
        let device: String?
        if !settings.folderGranularity.includesDevice {
            device = nil
        } else if let previewDeviceName {
            device = previewDeviceName.isEmpty ? nil : previewDeviceName
        } else {
            device = "iPhone 15 Pro"
        }
        return MediaArchiver.relativePath(kind: kind,
                                          captureDate: date,
                                          fileName: fileName,
                                          settings: settings,
                                          deviceModel: device)
    }
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

                if settings.folderGranularity.includesDevice {
                    Text("设备档位会从照片 EXIF 与视频容器中读取机型，在类型目录之后"
                         + "（如 2024/03/03-15/Photos/机型）再按设备分一层目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("未识别设备的目录名",
                              text: $settings.unknownDeviceFolderName,
                              prompt: Text("未知设备"))
                    Text("元数据里没有机型信息的素材（截图、后期导出、扫描件等）统一归入此目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
