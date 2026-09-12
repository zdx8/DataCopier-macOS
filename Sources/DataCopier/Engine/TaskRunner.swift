import Foundation

/// 任务执行器：负责把一个 `CopyTask` 展开、并行拷贝、汇总进度并产出报告。
///
/// 并发模型：固定数量的工作线程从一个共享索引计数器上取任务，天然实现负载均衡
/// （大文件不会阻塞小文件所在的分支）。所有共享状态由 `NSLock` 保护，
/// 进度以固定频率回主线程推送，避免高频锁竞争与 UI 抖动。
///
/// 执行分为两个串行阶段：
///  1. **拷贝** —— 磁盘瓶颈，并发度可较高（默认 4）。
///  2. **转码** —— 计算与 GPU 瓶颈，并发度应显著更低（默认 2），
///     否则多个 FFmpeg 进程会互相抢占编码器与内存带宽，总吞吐反而下降。
/// 两阶段之所以串行而非重叠，是为了让每一阶段都能独占各自的关键资源。
final class TaskRunner: @unchecked Sendable {

    private let lock = NSLock()
    private let cancellation = Cancellation()
    private let meter = SpeedMeter()

    private var running = false
    private var startedAt = Date()
    private var phase: TaskPhase = .idle

    private var totalFiles = 0
    private var totalBytes: Int64 = 0
    private var processedBytes: Int64 = 0
    private var completedFiles = 0
    private var currentFile = ""

    private var copiedFiles = 0
    private var copiedBytes: Int64 = 0
    private var skippedFiles = 0
    private var failedFiles = 0
    private var verifiedFiles = 0
    private var verifyFailedFiles = 0

    private var records: [FileRecord] = []
    private var droppedRecords = 0
    private var recordLimit = 20000

    // 转码阶段状态
    /// 本次执行使用的转码配置快照
    private var settings: TranscodeSettings = .default
    /// 任务类型快照。独立转码任务跳过拷贝阶段，直接进入转码。
    private var kind: TaskKind = .copy
    private var transcodeTotal = 0
    private var transcodeCompleted = 0
    private var transcodeFailed = 0
    private var transcodeCurrent = ""
    private var transcodeCurrentFraction: Double = 0
    private var transcodeSpeed: Double = 0
    private var transcodeStartedAt: Date?
    private var transcodeElapsed: TimeInterval = 0
    private var transcodeResults: [String: TranscodeOutcome] = [:]
    private var transcodeNote: String?

    // 归档阶段统计（仅媒体预设）
    /// 本次执行使用的预设快照
    private var preset: CopyPreset = .everything
    private var filteredOutFiles = 0
    private var renamedFiles = 0
    private var photoFiles = 0
    private var videoFiles = 0
    private var captureMetadataFiles = 0
    private var captureFallbackFiles = 0
    private var captureEarliest: Date?
    private var captureLatest: Date?
    private var undatedFiles: [FilePlanner.UndatedFile] = []
    /// 归档目录 → 计划文件数。在规划阶段一次算清，不受明细条数上限影响。
    private var folderCounts: [String: Int] = [:]
    /// 设备目录名 → 计划文件数。仅在启用按设备分类时非空。
    private var deviceCounts: [String: Int] = [:]

    private var timer: DispatchSourceTimer?
    private let progressQueue = DispatchQueue(label: "com.datacopier.progress")
    private var progressHandler: ((TaskProgress) -> Void)?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func cancel() {
        cancellation.cancel()
    }

    // MARK: - 入口

    func run(task: CopyTask,
             onProgress: @escaping (TaskProgress) -> Void,
             completion: @escaping (TaskReport) -> Void) {
        let startTimestamp = Date()

        lock.lock()
        running = true
        progressHandler = onProgress
        startedAt = startTimestamp
        phase = .idle
        recordLimit = max(1000, task.options.maxRecordedEntries)
        meter.reset()
        totalFiles = 0
        totalBytes = 0
        processedBytes = 0
        completedFiles = 0
        currentFile = ""
        copiedFiles = 0
        copiedBytes = 0
        skippedFiles = 0
        failedFiles = 0
        verifiedFiles = 0
        verifyFailedFiles = 0
        records.removeAll(keepingCapacity: true)
        droppedRecords = 0
        transcodeTotal = 0
        transcodeCompleted = 0
        transcodeFailed = 0
        transcodeCurrent = ""
        transcodeCurrentFraction = 0
        transcodeSpeed = 0
        transcodeStartedAt = nil
        transcodeElapsed = 0
        transcodeResults.removeAll(keepingCapacity: true)
        transcodeNote = nil
        settings = task.options.transcodeSettings
        kind = task.taskKind
        preset = task.options.copyPreset
        filteredOutFiles = 0
        renamedFiles = 0
        photoFiles = 0
        videoFiles = 0
        captureMetadataFiles = 0
        captureFallbackFiles = 0
        captureEarliest = nil
        captureLatest = nil
        undatedFiles = []
        folderCounts = [:]
        deviceCounts = [:]
        lock.unlock()

        var baseReport = TaskReport(
            taskName: task.name,
            startedAt: startTimestamp,
            finishedAt: startTimestamp,
            sourceRoots: task.sources,
            destination: task.destination,
            algorithm: task.options.algorithm,
            conflictPolicy: task.options.conflictPolicy,
            verifyAfterCopy: task.options.verifyAfterCopy
        )
        baseReport.taskKind = task.taskKind

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if kind == .transcode {
                self.executeTranscode(task: task, baseReport: baseReport, completion: completion)
            } else {
                self.execute(task: task, baseReport: baseReport, completion: completion)
            }
        }
    }

    // MARK: - 执行流程

    private func execute(task: CopyTask,
                         baseReport: TaskReport,
                         completion: @escaping (TaskReport) -> Void) {
        let items: [FilePlanItem]
        do {
            try FilePlanner.validate(task)
            let plan = try FilePlanner.plan(task, cancellation: cancellation)
            items = plan.items

            lock.lock()
            filteredOutFiles = plan.filteredOutFiles
            undatedFiles = plan.undatedFiles
            folderCounts = TaskRunner.folderCounts(for: items)
            deviceCounts = TaskRunner.deviceCounts(for: items)
            for item in items {
                if item.originalName != nil { renamedFiles += 1 }
                switch item.mediaKind {
                case .photo: photoFiles += 1
                case .video: videoFiles += 1
                case nil: break
                }
                if let source = item.captureSource {
                    if source.isAuthoritative {
                        captureMetadataFiles += 1
                    } else {
                        captureFallbackFiles += 1
                    }
                }
                if let date = item.captureDate {
                    if captureEarliest == nil || date < (captureEarliest ?? date) { captureEarliest = date }
                    if captureLatest == nil || date > (captureLatest ?? date) { captureLatest = date }
                }
            }
            // 无法确定拍摄时间的文件不进入拷贝队列，但它们同样是本次任务的
            // 一部分，计入总数才能让进度条与统计口径保持一致。
            totalFiles = items.count + plan.undatedFiles.count
            totalBytes = items.reduce(0) { $0 + $1.size }
                + plan.undatedFiles.reduce(0) { $0 + $1.size }
            phase = items.isEmpty ? .finalizing : .copying
            lock.unlock()

            for undated in plan.undatedFiles {
                append(record: FileRecord(
                    relativePath: undated.displayPath,
                    sourcePath: undated.sourcePath,
                    destinationPath: FilePlanner.join(task.destination, undated.displayPath),
                    size: undated.size,
                    status: .skipped,
                    message: "未能确定拍摄时间，已跳过。可在「照片 / 视频归档」中开启「回退到文件修改时间」。"
                ))
            }

            try FilePlanner.prepareDirectories(for: items, destination: task.destination)
        } catch {
            var report = baseReport
            report.presetID = task.options.copyPreset.rawValue
            report.finishedAt = Date()
            let cancelled = cancellation.isCancelled
            report.cancelled = cancelled
            if !cancelled {
                report.failedFiles = 1
                report.records = [
                    FileRecord(relativePath: "—",
                               sourcePath: task.sources.joined(separator: " , "),
                               destinationPath: task.destination,
                               size: 0,
                               status: .failed,
                               message: error.localizedDescription)
                ]
            }
            finish(report: report, completion: completion)
            return
        }

        startProgressTimer()

        if !items.isEmpty {
            // ---- 阶段一：拷贝 ----
            let workerCount = max(1, min(task.options.concurrency, max(1, items.count)))
            let counter = WorkCounter()
            let group = DispatchGroup()

            for _ in 0..<workerCount {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { group.leave(); return }
                    while true {
                        if self.cancellation.isCancelled { break }
                        let index = counter.next()
                        guard index < items.count else { break }
                        let record = self.process(item: items[index], task: task)
                        self.append(record: record)
                    }
                    group.leave()
                }
            }
            group.wait()
        }

        // ---- 阶段二：转码 ----
        runTranscodeStage(task: task)

        stopProgressTimer()

        let report = buildReport(base: baseReport)

        if task.options.exportManifest && task.options.algorithm != .none {
            _ = try? ChecksumManifest.write(
                records: report.records,
                algorithm: task.options.algorithm,
                task: task
            )
        }

        finish(report: report, completion: completion)
    }

    // MARK: - 独立转码任务

    /// 独立转码任务：不做拷贝与校验，直接把来源中的视频转码到目标目录。
    ///
    /// 输入记录就是来源里的原始视频（`status == .planned`），转码引擎据此
    /// 读取文件并输出到任务目标目录；明细中的转码结果与报告口径与
    /// 「拷贝后转码」完全一致，下游展示无需区分来源。
    private func executeTranscode(task: CopyTask,
                                  baseReport: TaskReport,
                                  completion: @escaping (TaskReport) -> Void) {
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: task.destination, withIntermediateDirectories: true)
        } catch {
            var report = baseReport
            report.finishedAt = Date()
            report.cancelled = cancellation.isCancelled
            if !cancellation.isCancelled {
                report.failedFiles = 1
                report.records = [FileRecord(
                    relativePath: "—",
                    sourcePath: task.sources.joined(separator: " , "),
                    destinationPath: task.destination,
                    size: 0,
                    status: .failed,
                    message: "无法创建输出目录：\(error.localizedDescription)"
                )]
            }
            finish(report: report, completion: completion)
            return
        }

        // 扫描来源中的视频：目录递归展开，单文件直接判断；排除规则沿用任务选项。
        let excluded = Set(task.options.excludedNames)
        var candidates: [FileRecord] = []
        for source in task.sources {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if let record = transcodeCandidate(path: source, root: (source as NSString).deletingLastPathComponent,
                                                   excluded: excluded) {
                    candidates.append(record)
                }
                continue
            }
            let enumerator = fm.enumerator(atPath: source)
            while let sub = enumerator?.nextObject() as? String {
                let full = (source as NSString).appendingPathComponent(sub)
                if let record = transcodeCandidate(path: full, root: source, excluded: excluded) {
                    candidates.append(record)
                }
            }
        }

        lock.lock()
        // 独立转码任务的唯一阶段就是转码：无论配置如何都强制启用，
        // 避免「新建时默认关闭」导致任务跑了却什么都不做。
        settings.enabled = true
        records = candidates
        totalFiles = candidates.count
        totalBytes = candidates.reduce(0) { $0 + $1.size }
        phase = candidates.isEmpty ? .finalizing : .transcoding
        lock.unlock()

        startProgressTimer()
        runTranscodeStage(task: task)
        stopProgressTimer()

        finish(report: buildReport(base: baseReport), completion: completion)
    }

    /// 为来源中的一个条目构造转码候选记录；目录或非视频文件返回 nil。
    private func transcodeCandidate(path: String, root: String, excluded: Set<String>) -> FileRecord? {
        let name = (path as NSString).lastPathComponent
        guard !excluded.contains(name) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              VideoFileTypes.isVideo(path) else { return nil }

        // relativePath 相对来源根；单文件来源时就是文件名。
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : name
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        // destinationPath 对转码引擎而言是「输入路径」，这里即原始视频。
        return FileRecord(relativePath: relative, sourcePath: path, destinationPath: path,
                          size: size, status: .planned)
    }

    // MARK: - 单文件拷贝

    private func process(item: FilePlanItem, task: CopyTask) -> FileRecord {
        lock.lock()
        currentFile = item.relativePath
        lock.unlock()

        let start = Date()

        do {
            let outcome = try FileCopier.perform(item: item,
                                                 task: task,
                                                 cancellation: cancellation) { delta in
                self.lock.lock()
                self.processedBytes += delta
                self.meter.record(cumulativeBytes: self.processedBytes)
                self.lock.unlock()
            }

            let duration = Date().timeIntervalSince(start)
            return FileRecord(
                relativePath: item.relativePath,
                sourcePath: item.sourcePath,
                // 记录实际落盘路径：重命名策略下它与计划路径不同。
                destinationPath: outcome.finalPath ?? item.destinationPath,
                size: item.size,
                status: outcome.status,
                sourceDigest: outcome.sourceDigest,
                destinationDigest: outcome.destinationDigest,
                duration: duration,
                bytesPerSecond: duration > 0 ? Double(outcome.bytes) / duration : 0,
                message: outcome.message,
                verified: outcome.verified,
                captureDate: item.captureDate,
                captureSource: item.captureSource,
                mediaKind: item.mediaKind,
                deviceModel: item.deviceModel,
                originalName: item.originalName
            )
        } catch is OperationCancelled {
            return archiveRecord(item: item,
                                 destinationPath: item.destinationPath,
                                 status: .skipped,
                                 duration: Date().timeIntervalSince(start),
                                 message: "任务取消，未完成")
        } catch {
            return archiveRecord(item: item,
                                 destinationPath: item.destinationPath,
                                 status: .failed,
                                 duration: Date().timeIntervalSince(start),
                                 message: error.localizedDescription)
        }
    }

    /// 构造携带归档信息的文件记录。
    ///
    /// 失败与取消分支同样需要带上拍摄时间与媒体类型：否则报告里这些条目
    /// 会失去「是哪张照片出问题」的上下文，只剩一个路径。
    private func archiveRecord(item: FilePlanItem,
                               destinationPath: String,
                               status: FileStatus,
                               duration: TimeInterval,
                               message: String?) -> FileRecord {
        FileRecord(
            relativePath: item.relativePath,
            sourcePath: item.sourcePath,
            destinationPath: destinationPath,
            size: item.size,
            status: status,
            duration: duration,
            message: message,
            captureDate: item.captureDate,
            captureSource: item.captureSource,
            mediaKind: item.mediaKind,
            deviceModel: item.deviceModel,
            originalName: item.originalName
        )
    }

    /// 统计各归档目录的预计文件数。
    private static func folderCounts(for items: [FilePlanItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            let folder = MediaArchiver.folder(of: item.relativePath)
            counts[folder, default: 0] += 1
        }
        return counts
    }

    /// 统计各拍摄设备的计划文件数，键为归档所用的设备目录名。
    private static func deviceCounts(for items: [FilePlanItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            guard let device = item.deviceModel, !device.isEmpty else { continue }
            counts[device, default: 0] += 1
        }
        return counts
    }

    private func append(record: FileRecord) {
        lock.lock()
        completedFiles += 1
        if record.status.isProblem { failedFiles += 1 }

        switch record.status {
        case .copied:
            copiedFiles += 1
            copiedBytes += record.size
        case .verified:
            copiedFiles += 1
            copiedBytes += record.size
            verifiedFiles += 1
        case .verifyFailed:
            copiedFiles += 1
            copiedBytes += record.size
            verifyFailedFiles += 1
        case .skipped:
            skippedFiles += 1
        case .failed, .planned:
            break
        }

        if records.count < recordLimit {
            records.append(record)
        } else {
            droppedRecords += 1
        }
        lock.unlock()
    }

    // MARK: - 阶段二：转码

    private func runTranscodeStage(task: CopyTask) {
        let settings = task.options.transcodeSettings
        guard settings.enabled, !cancellation.isCancelled else { return }

        // FFmpeg 整体缺失属于环境问题而非单个文件的问题：一次性跳过整个阶段并给出
        // 明确说明，好过让每个视频文件各自失败一次、在报告里堆出一串同因错误。
        guard FFmpegLocator.isAvailable else {
            lock.lock()
            transcodeNote = "未找到 FFmpeg，已跳过整个转码阶段。可在「设置」中指定其路径。"
            phase = .finalizing
            lock.unlock()
            return
        }

        lock.lock()
        let snapshot = records
        lock.unlock()

        let candidates = snapshot.filter { TranscodeEngine.isCandidate(record: $0, settings: settings) }
        guard !candidates.isEmpty else {
            lock.lock()
            transcodeNote = "没有符合条件的视频文件，已跳过转码阶段"
            phase = .finalizing
            lock.unlock()
            return
        }

        lock.lock()
        phase = .transcoding
        transcodeTotal = candidates.count
        transcodeStartedAt = Date()
        lock.unlock()

        let workerCount = max(1, min(settings.concurrency, candidates.count))
        let counter = WorkCounter()
        let group = DispatchGroup()

        for _ in 0..<workerCount {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { group.leave(); return }
                while true {
                    if self.cancellation.isCancelled { break }
                    let index = counter.next()
                    guard index < candidates.count else { break }
                    let record = candidates[index]

                    self.lock.lock()
                    self.transcodeCurrent = record.relativePath
                    self.transcodeCurrentFraction = 0
                    self.transcodeSpeed = 0
                    self.lock.unlock()

                    let outcome = TranscodeEngine.process(
                        record: record,
                        settings: settings,
                        cancellation: self.cancellation,
                        outputDirectory: kind == .transcode ? task.destination : nil
                    ) { snapshot in
                        self.lock.lock()
                        if snapshot.fraction >= 0 { self.transcodeCurrentFraction = snapshot.fraction }
                        if snapshot.speed > 0 { self.transcodeSpeed = snapshot.speed }
                        self.lock.unlock()
                    }

                    self.finishFile(transcode: outcome, relativePath: record.relativePath)
                }
                group.leave()
            }
        }

        group.wait()

        lock.lock()
        phase = .finalizing
        transcodeCurrent = ""
        transcodeCurrentFraction = 0
        if let started = transcodeStartedAt {
            transcodeElapsed = Date().timeIntervalSince(started)
        }
        lock.unlock()
    }

    private func finishFile(transcode outcome: TranscodeOutcome, relativePath: String) {
        lock.lock()
        transcodeResults[relativePath] = outcome
        transcodeCompleted += 1
        // 独立转码任务没有拷贝阶段，用它自己的计数驱动列表上的 x/y 进度。
        if kind == .transcode { completedFiles += 1 }
        if outcome.status == .failed { transcodeFailed += 1 }
        transcodeCurrentFraction = 0
        transcodeSpeed = 0
        lock.unlock()
    }

    // MARK: - 进度

    private func startProgressTimer() {
        let source = DispatchSource.makeTimerSource(queue: progressQueue)
        source.schedule(deadline: .now() + 0.2, repeating: 0.2, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let handler = self.progressHandler
            let snapshot = self.progressSnapshotLocked()
            self.lock.unlock()
            guard let handler else { return }
            DispatchQueue.main.async { handler(snapshot) }
        }
        source.resume()
        timer = source
    }

    private func stopProgressTimer() {
        timer?.cancel()
        timer = nil
    }

    private func progressSnapshotLocked() -> TaskProgress {
        let elapsed = Date().timeIntervalSince(startedAt)
        let speed = meter.currentSpeed()

        var eta: TimeInterval?
        switch phase {
        case .transcoding:
            // 转码阶段按「已完成文件数」外推：素材时长的分布通常很分散，
            // 用已完成素材的实时倍速外推反而比按文件数平均更不稳定。
            if transcodeCompleted > 0, transcodeTotal > transcodeCompleted {
                let perFile = (Date().timeIntervalSince(transcodeStartedAt ?? startedAt)) / Double(transcodeCompleted)
                eta = perFile * Double(transcodeTotal - transcodeCompleted)
            }
        case .idle, .copying, .finalizing:
            if speed > 1 && totalBytes > processedBytes {
                eta = Double(totalBytes - processedBytes) / speed
            }
        }

        return TaskProgress(
            phase: phase,
            totalFiles: totalFiles,
            completedFiles: completedFiles,
            failedFiles: failedFiles,
            totalBytes: totalBytes,
            processedBytes: processedBytes,
            currentFile: phase == .transcoding ? transcodeCurrent : currentFile,
            bytesPerSecond: speed,
            elapsed: elapsed,
            eta: eta,
            transcodeTotal: transcodeTotal,
            transcodeCompleted: transcodeCompleted,
            transcodeFailed: transcodeFailed,
            transcodeCurrent: transcodeCurrent,
            transcodeCurrentFraction: transcodeCurrentFraction,
            transcodeSpeed: transcodeSpeed
        )
    }

    // MARK: - 汇总

    private func buildReport(base: TaskReport) -> TaskReport {
        lock.lock()
        var snapshotRecords = records
        let dropped = droppedRecords
        let outcomes = transcodeResults
        let totals = (
            files: totalFiles,
            bytes: totalBytes,
            copied: copiedFiles,
            copiedBytes: copiedBytes,
            skipped: skippedFiles,
            failed: failedFiles,
            verified: verifiedFiles,
            verifyFailed: verifyFailedFiles
        )
        let peak = meter.peakSpeed
        let wasCancelled = cancellation.isCancelled
        let settingsSnapshot = settings
        let elapsedTranscode = transcodeElapsed
        let note = transcodeNote
        let archive = (
            preset: preset,
            filtered: filteredOutFiles,
            renamed: renamedFiles,
            photos: photoFiles,
            videos: videoFiles,
            metadata: captureMetadataFiles,
            fallback: captureFallbackFiles,
            earliest: captureEarliest,
            latest: captureLatest,
            folders: folderCounts,
            devices: deviceCounts
        )
        lock.unlock()

        // 把转码结果挂回对应的文件记录。
        for index in snapshotRecords.indices {
            if let outcome = outcomes[snapshotRecords[index].relativePath] {
                snapshotRecords[index].transcode = outcome
            }
        }

        var report = base
        report.finishedAt = Date()
        report.totalFiles = totals.files
        report.totalBytes = totals.bytes
        report.copiedFiles = totals.copied
        report.copiedBytes = totals.copiedBytes
        report.skippedFiles = totals.skipped
        report.failedFiles = totals.failed
        report.verifiedFiles = totals.verified
        report.verifyFailedFiles = totals.verifyFailed
        report.cancelled = wasCancelled
        report.records = snapshotRecords.sorted { $0.relativePath < $1.relativePath }
        report.truncatedRecordCount = dropped

        // 峰值吞吐不得低于整体平均吞吐，否则短任务会显示为 0
        let elapsed = report.elapsed
        let average = elapsed > 0 ? Double(totals.copiedBytes) / elapsed : 0
        report.peakBytesPerSecond = max(peak, average)

        let succeeded = outcomes.values.filter { $0.status == .succeeded }
        report.transcodeEnabled = settingsSnapshot.enabled
        report.transcodePresetName = settingsSnapshot.enabled ? settingsSnapshot.presetName : nil
        report.transcodedFiles = succeeded.count
        report.transcodeSkippedFiles = outcomes.values.filter { $0.status == .skipped }.count
        report.transcodeFailedFiles = outcomes.values.filter { $0.status == .failed }.count
        report.transcodeInputBytes = succeeded.reduce(0) { $0 + $1.inputBytes }
        report.transcodeOutputBytes = succeeded.reduce(0) { $0 + $1.outputBytes }
        report.transcodeDuration = elapsedTranscode
        report.transcodeHardwareFiles = succeeded.filter { $0.usedHardware }.count
        report.transcodeRemovedOriginals = outcomes.values.filter { $0.removedOriginal }.count
        report.transcodeNote = note

        report.presetID = archive.preset.rawValue
        report.filteredOutFiles = archive.filtered
        report.renamedFiles = archive.renamed
        report.photoFiles = archive.photos
        report.videoFiles = archive.videos
        report.captureMetadataFiles = archive.metadata
        report.captureFallbackFiles = archive.fallback
        report.captureEarliest = archive.earliest
        report.captureLatest = archive.latest
        report.mediaFolderCounts = archive.folders
        report.deviceCounts = archive.devices

        return report
    }

    private func finish(report: TaskReport, completion: @escaping (TaskReport) -> Void) {
        stopProgressTimer()

        lock.lock()
        running = false
        phase = .finalizing
        let handler = progressHandler
        let final = progressSnapshotLocked()
        progressHandler = nil
        lock.unlock()

        DispatchQueue.main.async {
            handler?(final)
            completion(report)
        }
    }
}
