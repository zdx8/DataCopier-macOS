import Foundation

enum PlannerError: LocalizedError {
    case noSources
    case sourceMissing(String)
    case invalidDestination
    case destinationInsideSource(String, String)
    case cannotCreateDirectory(String, String)
    case cannotResolveRelativePath(String)
    case noMediaFiles

    var errorDescription: String? {
        switch self {
        case .noSources:
            return "请至少选择一个来源文件或文件夹"
        case .sourceMissing(let path):
            return "来源不存在或无权访问：\(path)"
        case .invalidDestination:
            return "请选择有效的目标文件夹"
        case .destinationInsideSource(let source, let destination):
            return "目标文件夹位于来源内部，会导致无限递归：\n来源 \(source)\n目标 \(destination)"
        case .cannotCreateDirectory(let path, let reason):
            return "无法创建目录 \(path)：\(reason)"
        case .cannotResolveRelativePath(let path):
            return "无法确定 \(path) 相对于来源目录的位置。为避免目录结构错乱，任务已中止。"
        case .noMediaFiles:
            return "所选来源中没有可识别的照片或视频文件。若需拷贝其他类型文件，请改用「文件拷贝」。"
        }
    }
}

/// 把任务定义展开为「逐文件」的拷贝计划。
enum FilePlanner {

    // MARK: - 规划产出

    /// 规划阶段的完整结果。除文件清单外还带回筛选与归档的统计信息，
    /// 供报告层如实呈现「哪些文件没有进入计划、原因是什么」。
    struct Plan: Sendable {
        var items: [FilePlanItem] = []
        /// 因格式不受支持而被排除的文件数（仅媒体预设）
        var filteredOutFiles: Int = 0
        /// 无法确定拍摄时间而未能排入计划的文件（仅媒体预设，
        /// 且关闭了「回退到文件修改时间」时才会产生）
        var undatedFiles: [UndatedFile] = []
    }

    /// 无法确定拍摄时间的文件。
    ///
    /// 保留下来是为了在报告中如实反映被跳过的内容，而不是让这些文件无声消失。
    struct UndatedFile: Sendable {
        var sourcePath: String
        /// 若时间可确定时本应落入的目标相对路径，用于提示用户
        var displayPath: String
        var size: Int64
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey
    ]

    /// 读取元数据的并发度。
    ///
    /// 视频的时间提取可能 fork ffprobe，并发过高会同时启动大量约 50 MB 的进程，
    /// 反而拖慢整体并挤占内存带宽。
    private static var metadataConcurrency: Int {
        max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
    }

    // MARK: - 校验

    static func validate(_ task: CopyTask) throws {
        guard !task.sources.isEmpty else { throw PlannerError.noSources }
        guard !task.destination.isEmpty else { throw PlannerError.invalidDestination }

        let fm = FileManager.default
        for source in task.sources {
            guard fm.fileExists(atPath: source) else {
                throw PlannerError.sourceMissing(source)
            }
        }

        var isDirectory: ObjCBool = false
        let destinationExists = fm.fileExists(atPath: task.destination, isDirectory: &isDirectory)
        if destinationExists && !isDirectory.boolValue {
            throw PlannerError.invalidDestination
        }

        let normalizedDestination = normalize(task.destination)
        for source in task.sources where fm.fileExists(atPath: source) {
            let normalizedSource = normalize(source)
            if normalizedDestination == normalizedSource
                || normalizedDestination.hasPrefix(normalizedSource + "/") {
                throw PlannerError.destinationInsideSource(source, task.destination)
            }
        }
    }

    private static func normalize(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        var value = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    // MARK: - 计划生成

    /// 按任务预设选择规划策略。
    ///
    /// 两个预设共用同一套枚举与去重逻辑，差异只在「目标路径怎么算」：
    /// 文件拷贝沿用来源结构，媒体拷贝则依据拍摄时间重组。
    static func plan(_ task: CopyTask, cancellation: Cancellation) throws -> Plan {
        switch task.options.copyPreset {
        case .everything:
            return try planVerbatim(task, cancellation: cancellation)
        case .media:
            return try planMedia(task, cancellation: cancellation)
        }
    }

    /// 文件拷贝：完整保留来源目录结构。
    ///
    /// 注意：macOS 上 `/tmp` 是 `/private/tmp` 的符号链接，Enumerator 返回的路径
    /// 与用户传入的路径文本可能不一致。所有相对路径计算都基于「已解析符号链接」的
    /// 路径分量，确保 `/tmp/x` 与 `/private/tmp/x` 能正确对应；一旦无法对应，
    /// 会显式报错而不是退化成只取文件名——后者会把多层目录静默拍平成一层，
    /// 对数据拷贝工具而言是不可接受的失败模式。
    private static func planVerbatim(_ task: CopyTask, cancellation: Cancellation) throws -> Plan {
        let entries = try enumerate(task: task, cancellation: cancellation)

        var plan = Plan()
        var seenDestinations = Set<String>()
        var unresolved: [String] = []

        for entry in entries {
            try cancellation.check()

            guard let relative = entry.relativePath else {
                unresolved.append(entry.sourcePath)
                continue
            }

            let destinationPath = join(task.destination, relative)
            if !seenDestinations.insert(normalize(destinationPath).lowercased()).inserted { continue }

            plan.items.append(FilePlanItem(
                sourcePath: entry.sourcePath,
                relativePath: relative,
                destinationPath: destinationPath,
                size: entry.size,
                isSymlink: entry.isSymlink,
                linkTarget: entry.linkTarget
            ))
        }

        if let firstUnresolved = unresolved.first {
            throw PlannerError.cannotResolveRelativePath(firstUnresolved)
        }
        return plan
    }

    /// 媒体拷贝：先按格式筛选，再按拍摄时间重组目录与文件名。
    private static func planMedia(_ task: CopyTask, cancellation: Cancellation) throws -> Plan {
        let settings = task.options.mediaSettings
        let entries = try enumerate(task: task, cancellation: cancellation)

        // ---- 步骤一：格式筛选 ----
        var mediaEntries: [(entry: SourceEntry, kind: MediaKind)] = []
        var filteredOut = 0
        for entry in entries {
            if let kind = MediaFileTypes.kind(forPath: entry.sourcePath) {
                mediaEntries.append((entry, kind))
            } else {
                filteredOut += 1
            }
        }

        var plan = Plan()
        plan.filteredOutFiles = filteredOut

        guard !mediaEntries.isEmpty else {
            // 来源里确实一个媒体文件都没有：这几乎总是用户选错了预设，
            // 明确报错比静默产出空任务更有帮助。
            if filteredOut > 0 { throw PlannerError.noMediaFiles }
            return plan
        }

        // ---- 步骤二：并发读取拍摄时间与设备型号 ----
        let metadata = readMetadata(entries: mediaEntries,
                                    settings: settings,
                                    cancellation: cancellation)

        // ---- 步骤三：计算归档路径 ----
        var seenDestinations = Set<String>()

        for (index, pair) in mediaEntries.enumerated() {
            try cancellation.check()

            let entry = pair.entry
            let kind = pair.kind
            let result = metadata[index]
            // 设备目录解析优先级：真实 EXIF/容器机型 > 来源对应的自定义
            // 设备名 > 全局「未知设备」目录。读不到机型时优先用该来源
            // 独自填写的设备名，让多来源导入时各卡素材各归其位。
            let deviceFolder: String?
            if MediaImportSettings.normalizedDeviceName(result.deviceModel) != nil {
                deviceFolder = settings.deviceFolderName(for: result.deviceModel)
            } else if settings.folderGranularity.includesDevice,
                      let custom = settings.sourceDeviceFolderName(for: entry.sourceRoot) {
                deviceFolder = custom
            } else {
                deviceFolder = settings.deviceFolderName(for: nil)
            }

            guard let captureDate = result.capture.date else {
                plan.undatedFiles.append(UndatedFile(
                    sourcePath: entry.sourcePath,
                    displayPath: fallbackDisplayPath(name: entry.name, kind: kind,
                                                     settings: settings, device: deviceFolder),
                    size: entry.size
                ))
                continue
            }

            let fileName = MediaArchiver.fileName(originalName: entry.name,
                                                  captureDate: captureDate,
                                                  settings: settings)
            let baseRelative = MediaArchiver.relativePath(kind: kind,
                                                          captureDate: captureDate,
                                                          fileName: fileName,
                                                          settings: settings,
                                                          deviceModel: deviceFolder)
            let relative = uniqueRelativePath(baseRelative, seen: &seenDestinations)

            plan.items.append(FilePlanItem(
                sourcePath: entry.sourcePath,
                relativePath: relative,
                destinationPath: join(task.destination, relative),
                size: entry.size,
                isSymlink: entry.isSymlink,
                linkTarget: entry.linkTarget,
                captureDate: captureDate,
                captureSource: result.capture.source,
                mediaKind: kind,
                deviceModel: deviceFolder,
                originalName: fileName == entry.name ? nil : entry.name
            ))
        }

        return plan
    }

    /// 无法确定时间时，用于提示用户该文件本会落入的位置。
    private static func fallbackDisplayPath(name: String,
                                            kind: MediaKind,
                                            settings: MediaImportSettings,
                                            device: String?) -> String {
        var components: [String] = []
        if settings.separateByType { components.append(settings.folderName(for: kind)) }
        if let device, !device.isEmpty { components.append(device) }
        components.append(name)
        return components.joined(separator: "/")
    }

    // MARK: - 来源枚举

    /// 枚举期间收集的单个文件条目。
    private struct SourceEntry {
        var sourcePath: String
        var name: String
        var size: Int64
        var isSymlink: Bool
        var linkTarget: String?
        var modifiedDate: Date?
        /// 来源结构下的相对路径（`来源根名/子路径`）。无法解析时为 nil，
        /// 仅在「文件拷贝」下构成错误。
        var relativePath: String?
        /// 该文件来自任务配置里的哪个来源路径，用于按来源解析设备目录名。
        var sourceRoot: String
    }

    private static func enumerate(task: CopyTask, cancellation: Cancellation) throws -> [SourceEntry] {
        let fm = FileManager.default
        let excluded = Set(task.options.excludedNames)
        var entries: [SourceEntry] = []

        for sourcePath in task.sources {
            try cancellation.check()
            let originalURL = URL(fileURLWithPath: sourcePath)
            let rootURL = originalURL.resolvingSymlinksInPath()
            let rootName = originalURL.lastPathComponent

            guard let rootValues = try? rootURL.resourceValues(forKeys: Set(resourceKeys)) else {
                continue
            }

            if rootValues.isDirectory == true {
                guard let enumerator = fm.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: resourceKeys,
                    options: [],
                    errorHandler: { _, _ in true }
                ) else { continue }

                for case let url as URL in enumerator {
                    try cancellation.check()
                    guard let childValues = try? url.resourceValues(forKeys: Set(resourceKeys)) else { continue }
                    if childValues.isDirectory == true { continue }

                    let name = url.lastPathComponent
                    if excluded.contains(name) { continue }

                    let isLink = childValues.isSymbolicLink == true
                    if isLink && !task.options.copySymlinksAsLinks { continue }

                    entries.append(SourceEntry(
                        sourcePath: url.path,
                        name: name,
                        size: isLink ? 0 : Int64(childValues.fileSize ?? 0),
                        isSymlink: isLink,
                        linkTarget: isLink ? (try? fm.destinationOfSymbolicLink(atPath: url.path)) : nil,
                        modifiedDate: childValues.contentModificationDate,
                        relativePath: relativePath(of: url, root: rootURL, rootName: rootName),
                        sourceRoot: sourcePath
                    ))
                }
            } else {
                let name = originalURL.lastPathComponent
                if excluded.contains(name) { continue }

                let isLink = rootValues.isSymbolicLink == true
                if isLink && !task.options.copySymlinksAsLinks { continue }

                entries.append(SourceEntry(
                    sourcePath: sourcePath,
                    name: name,
                    size: isLink ? 0 : Int64(rootValues.fileSize ?? 0),
                    isSymlink: isLink,
                    linkTarget: isLink ? (try? fm.destinationOfSymbolicLink(atPath: sourcePath)) : nil,
                    modifiedDate: rootValues.contentModificationDate,
                    // 单文件来源没有上层目录，直接以文件名作为相对路径。
                    relativePath: name,
                    sourceRoot: sourcePath
                ))
            }
        }

        return entries
    }

    // MARK: - 元数据读取

    private static func readMetadata(entries: [(entry: SourceEntry, kind: MediaKind)],
                                     settings: MediaImportSettings,
                                     cancellation: Cancellation) -> [MediaMetadataResult] {
        let count = entries.count
        guard count > 0 else { return [] }

        let probe = FFmpegLocator.locateProbe()
        let results = ConcurrentResults<MediaMetadataResult>()
        let counter = WorkCounter()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.datacopier.media.metadata", attributes: .concurrent)
        let workers = min(metadataConcurrency, count)

        for _ in 0..<workers {
            group.enter()
            queue.async {
                while true {
                    if cancellation.isCancelled { break }
                    let index = counter.next()
                    guard index < count else { break }
                    let pair = entries[index]
                    let value = MediaMetadata.read(
                        forPath: pair.entry.sourcePath,
                        kind: pair.kind,
                        settings: settings,
                        probe: probe,
                        modifiedDate: pair.entry.modifiedDate
                    )
                    results.set(value, at: index)
                }
                group.leave()
            }
        }
        group.wait()

        return (0..<count).map { results.value(at: $0) ?? .unresolved }
    }

    // MARK: - 路径唯一化

    /// 保证同一任务内不产生两个相同的目标路径。
    ///
    /// 按拍摄时间命名后仍可能撞名：连拍、双机位同步、或带有毫秒被截断的文件名
    /// 都可能落在同一秒。此处追加序号而非覆盖，因为一次导入内的两个文件
    /// 大概率是两张不同的照片。
    ///
    /// 去重键统一小写：macOS 默认的 APFS 不区分大小写，`A.JPG` 与 `a.jpg`
    /// 会落到同一个位置。
    private static func uniqueRelativePath(_ relative: String, seen: inout Set<String>) -> String {
        var candidate = relative
        var index = 2
        while !seen.insert(candidate.lowercased()).inserted {
            let directory = (candidate as NSString).deletingLastPathComponent
            let file = (candidate as NSString).lastPathComponent
            let ext = (file as NSString).pathExtension
            let stem = (file as NSString).deletingPathExtension
            let name = ext.isEmpty ? "\(stem)_\(index)" : "\(stem)_\(index).\(ext)"
            candidate = directory.isEmpty || directory == "." ? name : "\(directory)/\(name)"
            index += 1
            if index > 9999 { break }
        }
        return candidate
    }

    // MARK: - 目录准备

    /// 预先创建所有目标目录，避免工作线程争抢创建。
    static func prepareDirectories(for items: [FilePlanItem], destination: String) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
        } catch {
            throw PlannerError.cannotCreateDirectory(destination, error.localizedDescription)
        }

        var directories = Set<String>()
        for item in items {
            directories.insert((item.destinationPath as NSString).deletingLastPathComponent)
        }
        for directory in directories.sorted() {
            if fm.fileExists(atPath: directory) { continue }
            do {
                try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            } catch {
                throw PlannerError.cannotCreateDirectory(directory, error.localizedDescription)
            }
        }
    }

    /// 按「已解析符号链接」的路径分量计算相对路径，避免 /tmp 与 /private/tmp 之类的
    /// 文本差异导致匹配失败。
    private static func relativePath(of url: URL, root: URL, rootName: String) -> String? {
        let rootComponents = root.resolvingSymlinksInPath().pathComponents
        let urlComponents = url.resolvingSymlinksInPath().pathComponents

        guard urlComponents.count > rootComponents.count,
              Array(urlComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }

        let suffix = urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
        return rootName + "/" + suffix
    }

    /// 拼接目标目录与相对路径。对来源目录与归档路径同样适用，
    /// 因此对外暴露供执行器登记「未能确定拍摄时间」的条目使用。
    static func join(_ base: String, _ relative: String) -> String {
        base.hasSuffix("/") ? base + relative : base + "/" + relative
    }
}
