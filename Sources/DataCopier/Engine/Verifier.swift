import Foundation

/// 独立的文件校验能力：既可对单个文件重新计算摘要，也可与既有清单批量比对。
enum Verifier {

    /// 流式读取文件并计算摘要。
    @discardableResult
    static func digest(ofFileAt path: String,
                       algorithm: CheckAlgorithm,
                       cancellation: Cancellation,
                       bufferSize: Int = 4 * 1024 * 1024) throws -> String? {
        guard algorithm != .none else { return nil }

        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        defer { close(descriptor) }

        var hasher = StreamingHasher(algorithm: algorithm)
        let size = max(64 * 1024, bufferSize)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }

        while true {
            try cancellation.check()
            let readCount = read(descriptor, buffer, size)
            if readCount < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if readCount == 0 { break }
            hasher.update(Data(bytes: buffer, count: readCount))
        }

        return hasher.digestHex()
    }

    /// 用既有清单（checksums 文件）校验目标目录。
    ///
    /// 返回不一致的条目列表，每项为 `(相对路径, 清单值, 实测值)`。
    static func verifyManifest(_ manifest: [String: String],
                               destinationRoot: String,
                               algorithm: CheckAlgorithm,
                               cancellation: Cancellation) -> [(path: String, expected: String, actual: String?)] {
        guard algorithm != .none else { return [] }
        var mismatches: [(String, String, String?)] = []

        for (relativePath, expected) in manifest {
            if cancellation.isCancelled { break }
            let full = destinationRoot.hasSuffix("/")
                ? destinationRoot + relativePath
                : destinationRoot + "/" + relativePath
            let actual = try? digest(ofFileAt: full, algorithm: algorithm, cancellation: cancellation)
            if actual != expected {
                mismatches.append((relativePath, expected, actual))
            }
        }

        return mismatches
    }
}
