import Foundation

/// 持久化文件损坏时的「改名留档」策略。
///
/// 任务文件解析失败时若被静默当作空列表、随后又被覆盖写盘，用户数据会永久丢失。
/// 这里提供统一的留档动作并回报结果，让调用方据此决定是否继续写盘。
/// 独立成类型是为了让自检能直接验证留档行为，而不必启动整个应用模型。
enum CorruptFileBackup {

    /// 留档文件名的标记词，形如 `tasks.json.corrupt-2026-09-13T06-35-56Z`。
    static let marker = "corrupt"

    /// 把损坏文件改名留档，返回备份路径；文件不存在或改名失败时返回 nil。
    @discardableResult
    static func quarantine(_ url: URL, now: Date = Date()) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let backup = backupURL(for: url, now: now)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }

    /// 计算留档路径：`<原名>.corrupt-<时间戳>`。时间戳里的冒号会替换为短横线，
    /// 避免在 HFS+/APFS 之外的卷上产生非法文件名。
    static func backupURL(for url: URL, now: Date = Date()) -> URL {
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(marker)-\(stamp)")
    }
}
