import Foundation
import AppKit

/// 应用级状态容器：任务列表、运行中进度、持久化与导出。
@MainActor
final class AppModel: ObservableObject {

    @Published var tasks: [CopyTask] = []
    @Published var selection: CopyTask.ID?
    @Published var progress: [UUID: TaskProgress] = [:]
    @Published var showNewTaskSheet = false
    @Published var showSettings = false
    @Published var banner: BannerMessage?
    /// USB 设备挂载时待预填到新建任务表单的来源路径。
    @Published var pendingUSBSource: String?
    /// USB 唤起时给新建任务表单顶部展示的说明（设备类型 + 卷名）。
    @Published var pendingUSBHint: String?
    /// 是否在插入 USB 移动设备时自动弹出拷贝任务（设置页可开关）。
    @Published var usbDetectEnabled: Bool =
        UserDefaults.standard.object(forKey: AppModel.usbDetectKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(usbDetectEnabled, forKey: AppModel.usbDetectKey)
        }
    }
    /// USB 自动检测的偏好存储键。
    static let usbDetectKey = "DataCopier.usbDetectEnabled"

    /// 新建任务时继承的默认选项
    @Published var defaultOptions: TaskOptions = .default

    private var runners: [UUID: TaskRunner] = [:]

    private let directoryURL: URL
    private let tasksURL: URL
    private let optionsURL: URL
    /// 任务完成后自动生成的 PDF 报告统一存放的目录。
    private let reportsDirectory: URL

    struct BannerMessage: Identifiable, Equatable {
        enum Kind { case info, success, warning, error }
        let id = UUID()
        var kind: Kind
        var text: String
        /// 副标题，可选。用来在主文案下方补一行提示（如「点击查看报告」）。
        var caption: String?
    }

    // MARK: - 生命周期

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directoryURL = support.appendingPathComponent("DataCopier", isDirectory: true)
        tasksURL = directoryURL.appendingPathComponent("tasks.json")
        optionsURL = directoryURL.appendingPathComponent("default-options.json")
        reportsDirectory = directoryURL.appendingPathComponent("reports", isDirectory: true)

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        load()
        observeUSBMounts()
    }

    // MARK: - USB 移动设备检测

    /// 监听系统卷挂载：可移除存储（相机卡 / U 盘）插入时唤起主窗口并
    /// 预填来源打开新建拷贝任务。开关关闭时仅记录不动作。
    private func observeUSBMounts() {
        NSWorkspace.shared.notificationCenter
            .addObserver(forName: NSWorkspace.didMountNotification,
                         object: nil, queue: .main) { [weak self] note in
                let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                Task { @MainActor in
                    self?.handleVolumeMounted(url: url)
                }
            }
    }

    private func handleVolumeMounted(url: URL?) {
        guard usbDetectEnabled, let url else { return }
        // 只响应可移除/可弹出的卷：内置硬盘、网络盘、Time Machine 等不打扰。
        let values = try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey])
        let removable = values?.volumeIsRemovable ?? false
        let ejectable = values?.volumeIsEjectable ?? false
        guard removable || ejectable else { return }

        pendingUSBSource = url.path
        let volumeName = (url.path as NSString).lastPathComponent
        let capacity = Int64((try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))?
            .volumeTotalCapacity ?? 0)
        let kind = USBDevice.kind(volumeName: volumeName, totalCapacity: capacity)
        pendingUSBHint = "检测到\(kind)「\(volumeName)」已连接，已自动预填来源，选择目标文件夹即可开始拷贝"
        showNewTaskSheet = true
        MenuBarController.showMainWindow()
        banner = BannerMessage(kind: .info,
                               text: "检测到\(kind)「\(volumeName)」",
                               caption: "已自动打开新建拷贝任务并预填来源")
    }

    // MARK: - 查询

    func task(id: UUID) -> CopyTask? {
        tasks.first { $0.id == id }
    }

    var selectedTask: CopyTask? {
        guard let selection else { return nil }
        return task(id: selection)
    }

    func isRunning(_ id: UUID) -> Bool {
        runners[id] != nil
    }

    var runningCount: Int { runners.count }

    // MARK: - 任务管理

    func addTask(kind: TaskKind = .copy,
                 name: String,
                 sources: [String],
                 destination: String,
                 options: TaskOptions) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = CopyTask(
            name: trimmed.isEmpty ? defaultName(for: kind) : trimmed,
            sources: sources,
            destination: destination,
            options: options,
            kind: kind
        )
        tasks.append(task)
        selection = task.id
        save()
    }

    private func defaultName(for kind: TaskKind) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "\(kind.displayName) \(formatter.string(from: Date()))"
    }

    func update(_ task: CopyTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        save()
    }

    func remove(_ id: UUID) {
        guard runners[id] == nil else {
            banner = BannerMessage(kind: .warning, text: "任务正在运行，请先停止后再删除")
            return
        }
        tasks.removeAll { $0.id == id }
        progress[id] = nil
        if selection == id { selection = tasks.first?.id }
        save()
    }

    func duplicate(_ id: UUID) {
        guard let task = task(id: id) else { return }
        var copy = task
        copy.id = UUID()
        copy.name = task.name + " 副本"
        copy.state = .idle
        copy.lastReport = nil
        copy.createdAt = Date()
        tasks.append(copy)
        selection = copy.id
        save()
    }

    // MARK: - 执行

    func start(_ id: UUID) {
        guard runners[id] == nil, let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        var task = tasks[index]
        task.state = .running
        tasks[index] = task
        progress[id] = TaskProgress()

        let runner = TaskRunner()
        runners[id] = runner

        runner.run(task: task) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.progress[id] = snapshot
            }
        } completion: { [weak self] report in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.runners[id] = nil
                if let idx = self.tasks.firstIndex(where: { $0.id == id }) {
                    var finished = self.tasks[idx]
                    finished.lastReport = report
                    if report.cancelled {
                        finished.state = .cancelled
                    } else if report.success {
                        finished.state = .finished
                    } else {
                        finished.state = .failed
                    }
                    self.tasks[idx] = finished
                }
                // 任务结束后在 Finder 中打开目标文件夹：拷贝完成通常紧接着
                // 就是查看/整理素材，直接把结果呈到眼前省一次手动寻找。
                // 取消的任务不打扰；目标文件夹缺失时静默跳过。
                if !report.cancelled {
                    let destination = self.task(id: id)?.destination ?? ""
                    if !destination.isEmpty {
                        NSWorkspace.shared.open(URL(fileURLWithPath: destination))
                    }
                }
                let count = report.failures.count + report.mismatches.count + report.transcodeFailures.count
                if report.cancelled {
                    self.banner = BannerMessage(kind: .warning, text: "任务「\(report.taskName)」已取消")
                } else if count > 0 {
                    self.banner = BannerMessage(kind: .error, text: "任务「\(report.taskName)」完成，但有 \(count) 个文件存在问题")
                } else {
                    // 提示文案按任务类型区分：转码任务没有「拷贝 N 个文件」的口径。
                    if self.task(id: id)?.taskKind == .transcode {
                        var text = "转码任务「\(report.taskName)」完成：成功 \(report.transcodedFiles) 个"
                        if report.transcodeSkippedFiles > 0 {
                            text += "，跳过 \(report.transcodeSkippedFiles) 个"
                        }
                        if report.transcodeOutputBytes > 0 {
                            text += "，输出 \(Format.bytes(report.transcodeOutputBytes))"
                            if report.transcodeSavedBytes > 0 {
                                text += "，节省 \(Format.bytes(report.transcodeSavedBytes))"
                            }
                        }
                        self.banner = BannerMessage(kind: .success, text: text)
                    } else {
                        var text = "任务「\(report.taskName)」完成：拷贝 \(report.copiedFiles) 个文件，\(Format.bytes(report.copiedBytes))，平均 \(Format.speed(report.averageBytesPerSecond))"
                        if report.isMediaArchive {
                            text = "任务「\(report.taskName)」完成：归档 \(report.photoFiles) 张照片、\(report.videoFiles) 个视频，共 \(Format.bytes(report.copiedBytes))"
                            if report.filteredOutFiles > 0 {
                                text += "，已排除 \(report.filteredOutFiles) 个非照片/视频文件"
                            }
                        }
                        if report.transcodeEnabled && report.transcodedFiles > 0 {
                            text += "；转码 \(report.transcodedFiles) 个，输出 \(Format.bytes(report.transcodeOutputBytes))"
                            if report.transcodeSavedBytes > 0 {
                                text += "，节省 \(Format.bytes(report.transcodeSavedBytes))"
                            }
                        }
                        self.banner = BannerMessage(kind: .success, text: text)
                    }
                }
                // 任务完成后自动生成 PDF 报告：后台渲染并写入 reports 目录，
                // 完成提示的副标题里告知保存位置。取消的任务不出报告。
                if !report.cancelled {
                    let fileName = ReportExporter.suggestedFileName(for: report, format: .pdf)
                    let pdfURL = self.reportsDirectory.appendingPathComponent(fileName)
                    let bannerText = self.banner?.text
                    let bannerKind = self.banner?.kind
                    Task.detached(priority: .utility) {
                        let data = try? ReportExporter.payload(report, format: .pdf)
                        if let data {
                            try? data.write(to: pdfURL, options: .atomic)
                        }
                        await MainActor.run { [weak self] in
                            // 横幅可能已被更新的提示替换，只在仍是本任务的提示时补充说明。
                            guard let self, self.banner?.text == bannerText, let bannerKind else { return }
                            self.banner = BannerMessage(
                                kind: bannerKind,
                                text: bannerText ?? "",
                                caption: data != nil
                                    ? "PDF 报告已保存：\(pdfURL.path)"
                                    : "PDF 报告生成失败"
                            )
                        }
                    }
                }
                self.save()
            }
        }
    }

    func cancel(_ id: UUID) {
        guard let runner = runners[id] else { return }
        runner.cancel()
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].state = .cancelling
        }
    }

    func startAll() {
        for task in tasks where task.state == .idle || task.state.isTerminal {
            start(task.id)
        }
    }

    func cancelAll() {
        for id in runners.keys { cancel(id) }
    }

    // MARK: - 导出

    func exportReport(for id: UUID, format: ReportExportFormat) {
        guard let task = task(id: id), let report = task.lastReport else {
            banner = BannerMessage(kind: .warning, text: "该任务还没有可导出的报告")
            return
        }
        let suggested = ReportExporter.suggestedFileName(for: report, format: format)
        guard let url = FilePanels.saveReport(suggestedName: suggested, fileExtension: format.fileExtension) else {
            return
        }
        do {
            try ReportExporter.write(report, format: format, to: url)
            banner = BannerMessage(kind: .success, text: "报告已导出到 \(url.lastPathComponent)")
        } catch {
            banner = BannerMessage(kind: .error, text: "导出失败：\(error.localizedDescription)")
        }
    }

    func exportManifest(for id: UUID) {
        guard let task = task(id: id), let report = task.lastReport else {
            banner = BannerMessage(kind: .warning, text: "该任务还没有可导出的校验清单")
            return
        }
        guard task.options.algorithm != .none else {
            banner = BannerMessage(kind: .warning, text: "该任务未启用校验算法，无法生成清单")
            return
        }
        do {
            if let url = try ChecksumManifest.write(records: report.records,
                                                    algorithm: task.options.algorithm,
                                                    task: task) {
                banner = BannerMessage(kind: .success, text: "校验清单已写入 \(url.path)")
            }
        } catch {
            banner = BannerMessage(kind: .error, text: "写入清单失败：\(error.localizedDescription)")
        }
    }

    /// 用既有清单复核目标目录。
    func verifyAgainstManifest(for id: UUID) {
        guard let task = task(id: id) else { return }
        let algorithm = task.options.algorithm == .none ? CheckAlgorithm.sha256 : task.options.algorithm
        guard let manifestPath = FilePanels.chooseManifest() else { return }

        do {
            let manifest = try ChecksumManifest.parse(URL(fileURLWithPath: manifestPath))
            guard !manifest.isEmpty else {
                banner = BannerMessage(kind: .warning, text: "清单文件为空或格式无法识别")
                return
            }
            let cancellation = Cancellation()
            let mismatches = Verifier.verifyManifest(manifest,
                                                     destinationRoot: task.destination,
                                                     algorithm: algorithm,
                                                     cancellation: cancellation)
            if mismatches.isEmpty {
                banner = BannerMessage(kind: .success, text: "清单比对通过：\(manifest.count) 个文件全部一致")
            } else {
                let preview = mismatches.prefix(3).map(\.path).joined(separator: "、")
                banner = BannerMessage(kind: .error,
                                       text: "清单比对发现 \(mismatches.count) 处不一致：\(preview)")
            }
        } catch {
            banner = BannerMessage(kind: .error, text: "读取清单失败：\(error.localizedDescription)")
        }
    }

    func revealDestination(_ id: UUID) {
        guard let task = task(id: id) else { return }
        FilePanels.revealInFinder(task.destination)
    }

    // MARK: - 持久化

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(tasks)
            try data.write(to: tasksURL, options: .atomic)

            let optionsData = try encoder.encode(defaultOptions)
            try optionsData.write(to: optionsURL, options: .atomic)
        } catch {
            banner = BannerMessage(kind: .error, text: "保存任务列表失败：\(error.localizedDescription)")
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: tasksURL),
           let stored = try? decoder.decode([CopyTask].self, from: data) {
            tasks = stored.map { task in
                var normalized = task
                if normalized.state == .running || normalized.state == .cancelling {
                    normalized.state = .idle
                }
                return normalized
            }
        }

        if let data = try? Data(contentsOf: optionsURL),
           let stored = try? decoder.decode(TaskOptions.self, from: data) {
            defaultOptions = stored
        }

        selection = tasks.first?.id
    }
}
