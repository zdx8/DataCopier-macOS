import Foundation

/// 单文件拷贝结果。
struct CopyOutcome {
    var status: FileStatus
    var sourceDigest: String?
    var destinationDigest: String?
    var bytes: Int64
    var message: String?
    var verified: Bool = false
    /// 文件最终写入的路径。
    ///
    /// 在「重命名保留两份」策略下该路径与计划路径不同（`a.bin` → `a 2.bin`），
    /// 因此下游（校验清单、转码阶段）必须使用这个值而不是规划阶段的预期路径。
    var finalPath: String?
}

enum ConflictResolution {
    case proceed(String)
    case skip(String)
}

enum ConflictResolver {

    static func resolve(destinationPath: String,
                        sourcePath: String,
                        policy: ConflictPolicy) throws -> ConflictResolution {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destinationPath) else {
            return .proceed(destinationPath)
        }

        switch policy {
        case .overwrite:
            return .proceed(destinationPath)
        case .skip:
            return .skip("目标已存在，按策略跳过")
        case .rename:
            return .proceed(uniquePath(for: destinationPath))
        case .onlyIfNewer:
            let sourceAttributes = try? fm.attributesOfItem(atPath: sourcePath)
            let destinationAttributes = try? fm.attributesOfItem(atPath: destinationPath)
            if let sourceDate = sourceAttributes?[.modificationDate] as? Date,
               let destinationDate = destinationAttributes?[.modificationDate] as? Date,
               destinationDate >= sourceDate {
                return .skip("目标文件不早于源文件，按策略跳过")
            }
            return .proceed(destinationPath)
        }
    }

    /// 生成不冲突的路径：`report.pdf` -> `report 2.pdf`
    static func uniquePath(for path: String) -> String {
        let fm = FileManager.default
        let ext = (path as NSString).pathExtension
        let base = (path as NSString).deletingPathExtension
        var index = 2
        while index < 10000 {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !fm.fileExists(atPath: candidate) { return candidate }
            index += 1
        }
        return "\(base) \(UUID().uuidString).\(ext)"
    }
}

/// 单文件拷贝执行器。
///
/// 设计要点：
/// 1. 数据通过 `read` / `write` 显式分块搬运，因此哈希可以在同一个循环里增量计算，
///    避免「先拷一遍、再读一遍算校验」的二次读盘开销。
/// 2. 先写入 `xxx.datacopier-tmp`，全部落盘后再原子重命名。中断只会留下临时文件，
///    目标目录里不会出现「看起来完整、实际残缺」的文件。
/// 3. 每次写盘后 `fsync`，保证进程崩溃或断电时数据已真正落到介质。
enum FileCopier {

    static func perform(item: FilePlanItem,
                        task: CopyTask,
                        cancellation: Cancellation,
                        onBytes: @escaping (Int64) -> Void) throws -> CopyOutcome {
        try cancellation.check()

        let fm = FileManager.default
        guard fm.fileExists(atPath: item.sourcePath) else {
            return CopyOutcome(status: .failed, bytes: 0, message: "来源文件已不存在")
        }

        if item.isSymlink && task.options.copySymlinksAsLinks {
            return try copySymlink(item: item, policy: task.options.conflictPolicy)
        }

        let resolution = try ConflictResolver.resolve(
            destinationPath: item.destinationPath,
            sourcePath: item.sourcePath,
            policy: task.options.conflictPolicy
        )

        var finalPath = item.destinationPath
        switch resolution {
        case .skip(let reason):
            return CopyOutcome(status: .skipped, bytes: 0, message: reason)
        case .proceed(let path):
            finalPath = path
        }

        let parent = (finalPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }

        let temporaryPath = finalPath + ".datacopier-tmp"
        if fm.fileExists(atPath: temporaryPath) {
            try? fm.removeItem(atPath: temporaryPath)
        }

        let sourceDescriptor = open(item.sourcePath, O_RDONLY)
        guard sourceDescriptor >= 0 else {
            return CopyOutcome(status: .failed, bytes: 0, message: "无法读取来源文件：\(errnoDescription())")
        }
        defer { close(sourceDescriptor) }

        let destinationDescriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard destinationDescriptor >= 0 else {
            return CopyOutcome(status: .failed, bytes: 0, message: "无法写入目标文件：\(errnoDescription())")
        }

        var hasher = StreamingHasher(algorithm: task.options.algorithm)
        let bufferSize = max(64 * 1024, task.options.bufferSize)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var transferredBytes: Int64 = 0
        var failureMessage: String?
        var wasCancelled = false

        while true {
            if cancellation.isCancelled {
                wasCancelled = true
                break
            }

            let readCount = read(sourceDescriptor, buffer, bufferSize)
            if readCount < 0 {
                if errno == EINTR { continue }
                failureMessage = "读取失败：\(errnoDescription())"
                break
            }
            if readCount == 0 { break }

            hasher.update(Data(bytes: buffer, count: readCount))

            do {
                try writeAll(descriptor: destinationDescriptor, pointer: buffer, count: readCount)
            } catch {
                failureMessage = error.localizedDescription
                break
            }

            transferredBytes += Int64(readCount)
            onBytes(Int64(readCount))
        }

        if failureMessage == nil && !wasCancelled {
            _ = fsync(destinationDescriptor)
        }
        close(destinationDescriptor)

        if wasCancelled {
            try? fm.removeItem(atPath: temporaryPath)
            throw OperationCancelled()
        }

        if let failureMessage {
            try? fm.removeItem(atPath: temporaryPath)
            return CopyOutcome(status: .failed, bytes: transferredBytes, message: failureMessage)
        }

        if task.options.preserveMetadata {
            MetadataCopier.copy(from: item.sourcePath, to: temporaryPath)
        }

        do {
            if fm.fileExists(atPath: finalPath) {
                try? fm.removeItem(atPath: finalPath)
            }
            try fm.moveItem(atPath: temporaryPath, toPath: finalPath)
        } catch {
            try? fm.removeItem(atPath: temporaryPath)
            return CopyOutcome(status: .failed,
                               bytes: transferredBytes,
                               message: "写入目标位置失败：\(error.localizedDescription)")
        }

        let sourceDigest = hasher.digestHex()

        guard task.options.verifyAfterCopy && task.options.algorithm != .none else {
            return CopyOutcome(status: .copied,
                               sourceDigest: sourceDigest,
                               destinationDigest: sourceDigest,
                               bytes: transferredBytes,
                               finalPath: finalPath)
        }

        do {
            let destinationDigest = try Verifier.digest(
                ofFileAt: finalPath,
                algorithm: task.options.algorithm,
                cancellation: cancellation,
                bufferSize: bufferSize
            )
            let matches = destinationDigest == sourceDigest
            return CopyOutcome(
                status: matches ? .verified : .verifyFailed,
                sourceDigest: sourceDigest,
                destinationDigest: destinationDigest,
                bytes: transferredBytes,
                message: matches ? nil : "目标文件校验值与源文件不一致，数据可能已损坏",
                verified: matches,
                finalPath: finalPath
            )
        } catch is OperationCancelled {
            throw OperationCancelled()
        } catch {
            return CopyOutcome(status: .copied,
                               sourceDigest: sourceDigest,
                               destinationDigest: nil,
                               bytes: transferredBytes,
                               message: "拷贝成功，但复核读取失败：\(error.localizedDescription)",
                               finalPath: finalPath)
        }
    }

    // MARK: - 符号链接

    private static func copySymlink(item: FilePlanItem, policy: ConflictPolicy) throws -> CopyOutcome {
        guard let target = item.linkTarget else {
            return CopyOutcome(status: .failed, bytes: 0, message: "无法解析符号链接指向")
        }

        let fm = FileManager.default
        let resolution = try ConflictResolver.resolve(
            destinationPath: item.destinationPath,
            sourcePath: item.sourcePath,
            policy: policy
        )

        var finalPath = item.destinationPath
        switch resolution {
        case .skip(let reason):
            return CopyOutcome(status: .skipped, bytes: 0, message: reason)
        case .proceed(let path):
            finalPath = path
        }

        let parent = (finalPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: finalPath) {
            try? fm.removeItem(atPath: finalPath)
        }

        try fm.createSymbolicLink(atPath: finalPath, withDestinationPath: target)
        return CopyOutcome(status: .copied, bytes: 0, message: "已重建符号链接", finalPath: finalPath)
    }

    // MARK: - 工具

    private static func writeAll(descriptor: Int32, pointer: UnsafeRawPointer, count: Int) throws {
        var written = 0
        while written < count {
            let result = write(descriptor, pointer.advanced(by: written), count - written)
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            written += result
        }
    }
}

func errnoDescription() -> String {
    String(cString: strerror(errno))
}
