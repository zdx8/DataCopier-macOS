import SwiftUI

/// 新建任务表单。
///
/// 第一步先选任务类型（拷贝 / 转码），随后进入各自的配置表单；
/// 两种任务落在同一份任务列表中，仅执行内容与展示口径不同。
struct NewTaskSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Step { case choose, copy, transcode }

    @State private var step: Step = .choose

    // 拷贝任务表单状态
    @State private var name = ""
    @State private var sources: [String] = []
    @State private var destination = ""
    @State private var options: TaskOptions = .default
    @State private var validationMessage: String?

    // 转码任务表单状态
    @State private var transcodeName = ""
    @State private var transcodeSources: [String] = []
    @State private var transcodeDestination = ""
    @State private var transcodeSettings: TranscodeSettings = .default
    @State private var transcodeValidation: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            switch step {
            case .choose:
                chooseContent
            case .copy:
                copyForm
            case .transcode:
                transcodeForm
            }
        }
        .frame(width: 620, height: 640)
        .onAppear {
            options = model.defaultOptions
            transcodeSettings = model.defaultOptions.transcodeSettings

            // USB 插入唤起：直接跳到拷贝表单，来源预填为刚挂载的卷，
            // 用户补选目标文件夹即可开始拷贝。
            if let usb = model.pendingUSBSource {
                model.pendingUSBSource = nil
                sources = [usb]
                step = .copy
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            if step != .choose {
                Button {
                    step = .choose
                    validationMessage = nil
                    transcodeValidation = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
            }
            Text(title)
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var title: String {
        switch step {
        case .choose: return "新建任务"
        case .copy: return "新建拷贝任务"
        case .transcode: return "新建转码任务"
        }
    }

    // MARK: - 第一步：选择类型

    private var chooseContent: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("请选择要创建的任务类型")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ForEach(TaskKind.allCases) { kind in
                    Button {
                        step = kind == .copy ? .copy : .transcode
                    } label: {
                        kindCard(kind)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)
            Spacer()
            Spacer()
        }
    }

    private func kindCard(_ kind: TaskKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(kind == .transcode ? Color.purple : Color.accentColor)
                .frame(width: 34, alignment: .center)

            Text(kind.displayName)
                .font(.title3.weight(.semibold))

            Text(kind.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .padding(18)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    // MARK: - 拷贝任务表单

    private var copyForm: some View {
        VStack(spacing: 0) {
            Form {
                CopyPresetPicker(options: $options)

                Section("任务") {
                    TextField("任务名称", text: $name, prompt: Text("留空则按时间自动命名"))
                }

                sourceSection($sources)

                Section("目标") {
                    destinationRow($destination)
                }

                if options.copyPreset == .media {
                    MediaImportForm(settings: Binding(
                        get: { options.mediaSettings },
                        set: { options.mediaSettings = $0 }
                    ))

                    // 视频转码属于媒体素材整理链路，只在媒体拷贝预设下提供；
                    // 文件拷贝强调原样搬运，不出现转码模块。
                    TranscodeForm(settings: Binding(
                        get: { options.transcodeSettings },
                        set: { options.transcodeSettings = $0 }
                    ))
                }

                OptionsForm(options: $options)

                // 低频内容统一沉底：可选细化与格式说明放表单最下面。
                if options.copyPreset == .media {
                    MediaExtrasForm(settings: Binding(
                        get: { options.mediaSettings },
                        set: { options.mediaSettings = $0 }
                    ))
                }
            }
            .formStyle(.grouped)

            validationBar(validationMessage)

            Divider()

            footer {
                Button("恢复默认选项") {
                    options = TaskOptions.recommended(for: options.copyPreset, basedOn: .default)
                }
                createButtons(disabled: sources.isEmpty || destination.isEmpty) { createCopy() }
            }
        }
    }

    // MARK: - 转码任务表单

    private var transcodeForm: some View {
        VStack(spacing: 0) {
            Form {
                TranscodeForm(settings: Binding(
                    get: { transcodeSettings },
                    set: { transcodeSettings = $0 }
                ), standalone: true)

                Section("任务") {
                    TextField("任务名称", text: $transcodeName, prompt: Text("留空则按时间自动命名"))
                }

                sourceSection($transcodeSources)

                Section("输出") {
                    destinationRow($transcodeDestination)
                    Text("转码输出统一写入该文件夹，文件名带预设后缀，不会覆盖原始视频。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            validationBar(transcodeValidation)

            Divider()

            footer {
                createButtons(disabled: transcodeSources.isEmpty || transcodeDestination.isEmpty) {
                    createTranscode()
                }
            }
        }
    }

    // MARK: - 共用片段

    private func sourceSection(_ list: Binding<[String]>) -> some View {
        Section("来源") {
            if list.wrappedValue.isEmpty {
                Text("尚未选择来源")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(list.wrappedValue, id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(systemName: sourceIcon(path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer(minLength: 4)
                        Button {
                            list.wrappedValue.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                Button("添加文件或文件夹…") {
                    let picked = FilePanels.chooseSources()
                    for path in picked where !list.wrappedValue.contains(path) {
                        list.wrappedValue.append(path)
                    }
                }
                if !list.wrappedValue.isEmpty {
                    Button("清空") { list.wrappedValue.removeAll() }
                }
            }
        }
    }

    private func destinationRow(_ path: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(path.wrappedValue.isEmpty ? "尚未选择文件夹" : path.wrappedValue)
                .font(path.wrappedValue.isEmpty ? .callout : .system(.caption, design: .monospaced))
                .foregroundStyle(path.wrappedValue.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path.wrappedValue)
            Spacer(minLength: 4)
            Button("选择…") {
                if let picked = FilePanels.chooseDestination() {
                    path.wrappedValue = picked
                }
            }
        }
    }

    private func validationBar(_ message: String?) -> some View {
        Group {
            if let message {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func footer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func createButtons(disabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("创建任务") { action() }
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
        }
    }

    private func sourceIcon(_ path: String) -> String {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? "folder" : "doc"
    }

    // MARK: - 创建

    private func createCopy() {
        var sanitized = options
        sanitized.concurrency = max(1, min(16, sanitized.concurrency))
        sanitized.bufferSize = max(64 * 1024, sanitized.bufferSize)
        sanitized.transcodeSettings.concurrency = max(1, min(6, sanitized.transcodeSettings.concurrency))
        // 文件拷贝预设没有转码模块，强制关闭以保证状态与界面一致。
        if sanitized.copyPreset == .everything {
            sanitized.transcodeSettings.enabled = false
        }

        do {
            let task = CopyTask(name: name, sources: sources, destination: destination, options: sanitized)
            try FilePlanner.validate(task)
            model.addTask(kind: .copy, name: name, sources: sources, destination: destination, options: sanitized)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func createTranscode() {
        var settings = transcodeSettings
        settings.enabled = true
        settings.concurrency = max(1, min(6, settings.concurrency))

        // 转码任务不涉及拷贝与校验，关掉无关选项；排除规则沿用默认配置，
        // 以便扫描来源时同样跳过 .DS_Store 等系统文件。
        var options = TaskOptions.default
        options.excludedNames = model.defaultOptions.excludedNames
        options.transcodeSettings = settings
        options.algorithm = .none
        options.exportManifest = false

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: transcodeDestination, isDirectory: &isDirectory)
        if !exists {
            transcodeValidation = "输出文件夹不存在，请重新选择。"
            return
        }

        model.addTask(kind: .transcode,
                      name: transcodeName,
                      sources: transcodeSources,
                      destination: transcodeDestination,
                      options: options)
        dismiss()
    }
}
