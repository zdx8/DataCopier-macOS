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
    /// USB 插入自动唤起时显示在表单顶部的说明条。
    @State private var usbHint: String?
    /// 各来源的设备名字段：每个来源路径对应一个文本框，扫描自动填入，
    /// 也可手填；留空则该来源不参与设备目录命名。
    @State private var deviceFields: [String: String] = [:]
    /// 正在扫描设备型号（扫描在后台进行，按钮暂不可重复点击）。
    @State private var scanningDevice = false
    /// 最近一次识别设备的结果摘要，显示在来源列表下方。
    @State private var usbScanSummary: String?

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
            // 用户补选目标文件夹即可开始拷贝。同时后台扫描卡内媒体文件，
            // 读取拍摄设备型号用于来源展示与归档路径预览。
            if let usb = model.pendingUSBSource {
                model.pendingUSBSource = nil
                sources = [usb]
                step = .copy
                usbHint = model.pendingUSBHint
                model.pendingUSBHint = nil
            }

            // 打开新建任务即自动识别：无来源时扫描电脑上已挂载的 USB 存储
            // 设备并列入来源；USB 唤起时则扫描卡内文件读取型号。
            startDeviceScan()
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
            // USB 插入自动唤起时的说明条：告诉用户为什么弹出本窗口。
            if let usbHint {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .foregroundStyle(.blue)
                    Text(usbHint)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.blue.opacity(0.08))
            }

            Form {
                CopyPresetPicker(options: $options)

                Section("任务") {
                    TextField("任务名称", text: $name, prompt: Text("留空则按时间自动命名"))
                }

                sourceSection($sources, showDeviceField: true)

                Section("目标") {
                    destinationRow($destination)
                }

                if options.copyPreset == .media {
                    MediaImportForm(settings: Binding(
                        get: { options.mediaSettings },
                        set: { options.mediaSettings = $0 }
                    ), previewDeviceName: previewDevice)

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

    // MARK: - 设备识别

    /// 点击「识别设备」：
    /// - 未选来源时，扫描电脑上所有已挂载的 USB 存储设备，把设备卷列为来源，
    ///   并把识别到的第一个型号填入设备名文本框；
    /// - 已有来源时，扫描第一个目录来源中的媒体文件读取设备型号。
    /// 读不到时保持留空，由用户手填或留空不添加设备目录。
    private func startDeviceScan() {
        guard !scanningDevice else { return }
        scanningDevice = true
        Task { @MainActor in
            if sources.isEmpty {
                let hits = await Task.detached(priority: .userInitiated) {
                    USBDeviceScanner.detectUSBDevices()
                }.value
                var identified = 0
                for hit in hits {
                    if !sources.contains(hit.volumePath) {
                        sources.append(hit.volumePath)
                    }
                    deviceFields[hit.volumePath] = hit.deviceModel ?? ""
                    if hit.deviceModel != nil { identified += 1 }
                }
                if hits.isEmpty {
                    usbScanSummary = "未发现已连接的 USB 存储设备"
                } else if identified > 0 {
                    usbScanSummary = "识别到 \(hits.count) 台 USB 设备，\(identified) 台已读取型号"
                } else {
                    usbScanSummary = "识别到 \(hits.count) 台 USB 设备，未能从文件读取型号"
                }
            } else {
                guard let root = sources.first(where: { Self.isDirectory($0) }) else {
                    scanningDevice = false
                    return
                }
                let detected = await Task.detached(priority: .userInitiated) {
                    USBDeviceScanner.detectDeviceModel(at: root)
                }.value
                deviceFields[root] = detected ?? ""
                usbScanSummary = detected.map { "识别到设备型号：\($0)" }
                    ?? "未能从来源文件读取设备型号，可手动填写"
            }
            scanningDevice = false
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// 归档路径预览使用的设备目录名：取第一个非空的来源设备名。
    /// 全部留空传空串（预览中不出现设备目录）。
    private var previewDevice: String? {
        let first = sources.lazy
            .compactMap { deviceFields[$0] }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first else { return "" }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : MediaArchiver.sanitize(trimmed)
    }

    /// 某个来源的设备名文本框绑定。
    private func deviceBinding(for path: String) -> Binding<String> {
        Binding(
            get: { deviceFields[path] ?? "" },
            set: { deviceFields[path] = $0 }
        )
    }

    // MARK: - 共用片段

    private func sourceSection(_ list: Binding<[String]>, showDeviceField: Bool = false) -> some View {
        Section {
            if list.wrappedValue.isEmpty {
                Text("尚未选择来源")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // 每个来源行都内嵌设备名文本框：无论是识别出的 USB 设备
                // 还是手动添加的文件夹，都可单独填写自定义设备目录名。
                ForEach(list.wrappedValue, id: \.self) { path in
                    sourceRow(path, list: list, showDeviceField: showDeviceField)
                }
            }

            HStack(spacing: 8) {
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
        } header: {
            // 「识别设备」按钮放在来源标题右侧，未选来源时也可点击，
            // 直接扫描电脑上已连接的 USB 存储设备并列入来源；
            // 识别结果摘要显示在按钮左侧。
            HStack(spacing: 10) {
                Text("来源")
                if showDeviceField {
                    Spacer(minLength: 8)
                    if let usbScanSummary {
                        Text(usbScanSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(usbScanSummary)
                    }
                    Button {
                        startDeviceScan()
                    } label: {
                        Label(scanningDevice ? "识别中…" : "识别设备",
                              systemImage: scanningDevice ? "circle.dotted" : "camera")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(scanningDevice)
                    .help("扫描电脑上已连接的 USB 存储设备并识别拍摄设备型号")
                }
            }
        }
    }

    /// 来源路径行。`showDeviceField` 为真时行内嵌该来源专属的设备名
    /// 文本框，路径过长时自动截断让位。
    private func sourceRow(_ path: String,
                           list: Binding<[String]>,
                           showDeviceField: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: sourceIcon(path))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            if showDeviceField {
                Spacer(minLength: 8)
                TextField("",
                          text: deviceBinding(for: path),
                          prompt: Text("未识别时可手动填写，留空则不添加设备名"))
                    // 占位提示较长，给足宽度避免末尾被截断；路径短些无妨
                    //（已有中间截断 + 悬浮看全文）。
                    .frame(minWidth: 200, idealWidth: 330, maxWidth: 360)
                    .layoutPriority(1)
            } else {
                Spacer(minLength: 4)
            }
            Button {
                list.wrappedValue.removeAll { $0 == path }
            } label: {
                Image(systemName: "minus.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
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
        // 媒体预设下的设备目录规则：各来源的设备名写入按来源映射，
        // 该来源读不到机型的素材归入各自名字的目录；全部留空 → 档位
        // 降级为不带设备变体，本次任务不添加设备目录。
        if sanitized.copyPreset == .media {
            var mapping: [String: String] = [:]
            for source in sources {
                let custom = (deviceFields[source] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !custom.isEmpty {
                    mapping[source] = MediaArchiver.sanitize(custom)
                }
            }
            sanitized.mediaSettings.sourceDeviceNames = mapping
            if mapping.isEmpty {
                sanitized.mediaSettings.folderGranularity =
                    sanitized.mediaSettings.folderGranularity.withoutDevice
            } else if let upgraded = sanitized.mediaSettings.folderGranularity.withDevice {
                sanitized.mediaSettings.folderGranularity = upgraded
            }
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
