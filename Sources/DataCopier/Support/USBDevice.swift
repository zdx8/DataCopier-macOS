import Foundation

/// USB 移动设备分类。
///
/// 纯函数实现，便于自检直接验证；AppModel 在卷挂载时调用，
/// 用推断出的设备类型生成更友好的提示文案。
enum USBDevice {

    /// 短缩写。必须按「词元」精确匹配：直接做子串匹配会让 `BackupsDisk`、
    /// `GamesDisk`、`PhotosDisk` 这类卷名里的偶然 `sd` 全部误判为相机存储卡。
    private static let shortCardTokens: Set<String> = ["sd", "cf", "tf", "xd"]

    /// 较长的关键词。卷名常把它们拼进单词（如 `EOS_DIGITAL`、`SanDisk`），
    /// 因此保留子串匹配。
    private static let longCardKeywords = [
        "micro", "memory card", "eos", "sony", "nikon", "canon", "fujifilm",
        "gopro", "dji", "xtrem", "prograde", "sandisk", "kingston", "transcend"
    ]

    /// 根据卷名与容量推断设备类型：
    /// 卷名命中存储卡关键词判「相机存储卡」；容量 ≥ 200GB 判「移动硬盘」；否则判「U盘」。
    ///
    /// 说明：容量档位只是兜底启发式，容量很大的 U 盘会被判为「移动硬盘」。
    /// 该结果仅用于提示文案，不影响任何拷贝行为。
    static func kind(volumeName: String, totalCapacity: Int64) -> String {
        let name = volumeName.lowercased()

        // 词元切分：按非字母数字字符断开，短缩写据此精确比对。
        let tokens = Set(
            name.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        if !tokens.isDisjoint(with: shortCardTokens) { return "相机存储卡" }

        // 长关键词按子串判定。
        if longCardKeywords.contains(where: { name.contains($0) }) { return "相机存储卡" }

        // `SDcard`、`CFExpress` 这类「缩写直接接词」的写法按前缀兜底，
        // 但不会命中 `BackupsDisk` 这种缩写出现在中段的偶然子串。
        if ["sd", "cf", "tf", "xd"].contains(where: { name.hasPrefix($0) }) {
            return "相机存储卡"
        }

        if totalCapacity >= 200 * 1024 * 1024 * 1024 { return "移动硬盘" }
        return "U盘"
    }
}
