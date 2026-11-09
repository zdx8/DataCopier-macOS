import Foundation

/// 依据拍摄时间与设备型号计算媒体文件在目标目录中的位置与名称。
///
/// 归档结构为「类型目录 / 日期目录 / 设备目录 / 文件名」，每段都可独立关闭：
/// 设备目录由归档档位控制——带「/设备」的档位在日期层级之后再按机型分一层，
/// 不带的则完全不出现机型目录：
///
/// ```
/// Photos/2024/03/03-15/iPhone 15 Pro/20240315_143022_IMG_1234.JPG
/// Videos/2024/03/03-15/ILCE-7M4/20240315_143022_MVI_5678.MOV
/// ```
///
/// 设备目录放在日期之后而非类型之下：浏览某一天的素材时，同日各机型一目了然，
/// 且不会把同一台设备的素材按日期切碎——两层信息都保留完整。
///
/// 所有日期字段都通过 `Calendar` 取值后手工格式化，而非 `DateFormatter`：
/// 后者不是线程安全的，而规划阶段会对成千上万个文件并发执行这段逻辑。
enum MediaArchiver {

    /// 时间戳文本，形如 `20240315_143022`。
    static func timestamp(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d_%02d%02d%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// 归档后的文件名（含扩展名，扩展名保持原有大小写）。
    static func fileName(originalName: String,
                         captureDate: Date,
                         settings: MediaImportSettings,
                         calendar: Calendar = .current) -> String {
        let ext = (originalName as NSString).pathExtension
        let stem = (originalName as NSString).deletingPathExtension
        let stamp = timestamp(captureDate, calendar: calendar)

        let base: String
        if settings.renameByCaptureTime {
            switch settings.renameMode {
            case .timestampOnly:
                base = stamp
            case .timestampWithOriginal:
                // 原名已含同一时间戳时不再重复前缀。手机导出的文件名常形如
                // `IMG_20240315_143022.jpg`，若直接前缀会得到 `20240315_143022_IMG_20240315_143022`。
                base = stem.contains(stamp) ? stem : "\(stamp)_\(stem)"
            case .customWithTimestamp:
                // 自定义字段作为前缀：`婚礼_20240315_143022.JPG`。
                // 字段为空时回退到纯时间戳，保证输出文件名永远可用。
                let prefix = settings.customRenamePrefix
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                base = prefix.isEmpty ? stamp : "\(prefix)_\(stamp)"
            case .customWithOriginalAndTimestamp:
                // 自定义字段 + 原文件名 + 时间戳：`婚礼_IMG_1234_20240315_143022.JPG`。
                // 原名已含同一时间戳时不重复追加；字段为空回退到 原名_时间戳。
                let prefix = settings.customRenamePrefix
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                let core = stem.contains(stamp) ? stem : "\(stem)_\(stamp)"
                base = prefix.isEmpty ? core : "\(prefix)_\(core)"
            }
        } else {
            base = stem
        }

        let safe = sanitize(base)
        return ext.isEmpty ? safe : "\(safe).\(ext)"
    }

    /// 目标目录内的相对路径。
    ///
    /// `deviceModel` 为已整理好的设备目录名；传 nil 表示本次不按设备分层
    /// （未启用该分类，或调用方不关心）。
    static func relativePath(kind: MediaKind,
                             captureDate: Date,
                             fileName: String,
                             settings: MediaImportSettings,
                             deviceModel: String? = nil,
                             calendar: Calendar = .current) -> String {
        var components: [String] = []
        // 层级顺序：日期档位 → 类型目录（照片/视频）→ 设备目录。
        // 日期在最外层，浏览某天素材时先进入日期，再按照片/视频分流，
        // 同一天内同设备的照片与视频彼此相邻。
        let custom = settings.folderSuffix
            .trimmingCharacters(in: .whitespacesAndNewlines)
        components.append(contentsOf: settings.folderGranularity.components(
            for: captureDate,
            calendar: calendar,
            custom: custom.isEmpty ? "" : sanitize(custom)))
        if settings.separateByType {
            components.append(settings.folderName(for: kind))
        }
        // 设备目录位于类型目录之后（如 年/月/月-日/照片/机型）。双重保险：
        // 档位不带「/设备」时即使调用方传了机型也不追加（正常调用链中
        // `deviceFolderName` 此时已返回 nil）；平铺档位没有设备变体。
        if settings.folderGranularity.includesDevice, let deviceModel, !deviceModel.isEmpty {
            components.append(deviceModel)
        }
        components.append(fileName)
        return components.joined(separator: "/")
    }

    /// 目标相对路径所处的目录（用于归档统计与目录预创建）。
    static func folder(of relativePath: String) -> String {
        let directory = (relativePath as NSString).deletingLastPathComponent
        return directory == "." ? "" : directory
    }

    /// 清理文件名中不适合落盘的字符，并限制单段长度。
    ///
    /// 冒号在 POSIX 层合法但在 Finder 中显示为路径分隔符，统一替换为短横线；
    /// 长度限制为 180 字节，给扩展名与去重序号留出余量（APFS 单段上限 255 字节）。
    static func sanitize(_ name: String) -> String {
        var value = name
        for bad in [":", "/", "\\", "\u{0}"] {
            value = value.replacingOccurrences(of: bad, with: "-")
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = "未命名" }

        if value.utf8.count > 180 {
            var trimmed = ""
            for character in value {
                if (trimmed + String(character)).utf8.count > 180 { break }
                trimmed.append(character)
            }
            value = trimmed.isEmpty ? "未命名" : trimmed
        }
        return value
    }
}
