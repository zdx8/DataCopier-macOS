import Foundation

/// 展示层统一使用的格式化工具，保证全应用单位与精度一致。
enum Format {

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.isAdaptive = true
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, value))
    }

    static func bytes(_ value: Double) -> String {
        bytes(Int64(value))
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 1 else { return "—" }
        return byteFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    /// 把秒数格式化为 `1h 02m 03s` / `02m 03s` / `12.3s`
    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "—" }
        if interval < 60 {
            return String(format: "%.1fs", interval)
        }
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        return String(format: "%02dm %02ds", minutes, seconds)
    }

    static func eta(_ interval: TimeInterval?) -> String {
        guard let interval, interval.isFinite, interval > 0 else { return "计算中" }
        return "剩余 " + duration(interval)
    }

    /// 进度占比。裁剪到 0–100%，用于「已完成百分比」这类不可能超过 1 的比例。
    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", min(1, max(0, fraction)) * 100)
    }

    /// 体积/压缩比。**不做** 0–100% 裁剪：输出体积膨胀到 150% 时必须如实显示
    /// `150.0%`，否则会掩盖负收益（「压缩比 100.0% / 节省 0 B」）。
    static func ratio(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        return String(format: "%.1f%%", max(0, fraction) * 100)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    /// 生成适合作为文件名的字符串。
    static func safeFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "未命名" : cleaned
    }
}
