import Foundation

/// USB 移动设备分类。
///
/// 纯函数实现，便于自检直接验证；AppModel 在卷挂载时调用，
/// 用推断出的设备类型生成更友好的提示文案。
enum USBDevice {

    /// 根据卷名与容量推断设备类型：
    /// 卷名命中存储卡关键词判「相机存储卡」；容量 ≥ 200GB 判「移动硬盘」；否则判「U盘」。
    static func kind(volumeName: String, totalCapacity: Int64) -> String {
        let name = volumeName.lowercased()
        let cardKeywords = ["sd", "cf", "tf", "micro", "xd", "memory card", "eos",
                            "sony", "nikon", "canon", "fujifilm", "gopro", "dji",
                            "xtrem", "prograde", "sandisk", "kingston", "transcend"]
        if cardKeywords.contains(where: { name.contains($0) }) { return "相机存储卡" }
        if totalCapacity >= 200 * 1024 * 1024 * 1024 { return "移动硬盘" }
        return "U盘"
    }
}
