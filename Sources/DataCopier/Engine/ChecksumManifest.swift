import Foundation

/// 校验清单（checksums）文件的读写。
///
/// 采用 `<hex> <两个空格> <相对路径>` 的经典格式，与 `shasum` 的输出保持一致，
/// 因此在 SHA-256 / MD5 模式下生成的清单可以直接用系统命令复核：
/// `shasum -a 256 -c report.checksums.txt`
enum ChecksumManifest {

    static func fileName(for task: CopyTask) -> String {
        let safeName = task.name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        return safeName.isEmpty ? "checksums.txt" : "\(safeName).checksums.txt"
    }

    @discardableResult
    static func write(records: [FileRecord],
                      algorithm: CheckAlgorithm,
                      task: CopyTask) throws -> URL? {
        guard algorithm != .none else { return nil }

        let url = URL(fileURLWithPath: task.destination)
            .appendingPathComponent(fileName(for: task))

        let formatter = ISO8601DateFormatter()
        var lines: [String] = [
            "# DataCopier manifest v1",
            "# algorithm: \(algorithm.shortName)",
            "# generated: \(formatter.string(from: Date()))"
        ]

        for record in records {
            guard let digest = record.sourceDigest else { continue }
            guard record.status == .copied || record.status == .verified else { continue }
            // 原始拷贝已被转码流程删除的条目必须排除：清单要描述磁盘上实际存在的
            // 文件及其摘要，否则 `shasum -c` 会因为「文件不存在」而整份校验失败。
            guard record.transcode?.removedOriginal != true else { continue }
            lines.append("\(digest)  \(record.relativePath)")
        }

        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 解析清单文件，返回 `相对路径 -> 摘要` 的映射。
    static func parse(_ url: URL) throws -> [String: String] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }

            let digest = parts[0].lowercased()
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            result[path] = digest
        }

        return result
    }
}
