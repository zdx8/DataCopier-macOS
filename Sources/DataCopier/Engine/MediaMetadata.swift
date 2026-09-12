import Foundation
import ImageIO
import CoreGraphics

// MARK: - 媒体格式表

/// 受支持的照片与视频扩展名。
///
/// 以扩展名而非内容嗅探作为筛选依据：导入一张卡时文件数量可能上万，
/// 逐个嗅探文件头会让规划阶段本身成为瓶颈；而相机与手机的命名习惯稳定，
/// 扩展名判定的准确度在实际素材上足够。真正的编解码判定仍由转码阶段的
/// ffprobe 完成，两者职责不重叠。
enum MediaFileTypes {

    /// 照片格式：常见位图、现代高效格式、以及各厂商的 RAW。
    static let photoExtensions: Set<String> = [
        // 通用位图
        "jpg", "jpeg", "jpe", "jfif", "png", "tif", "tiff", "bmp", "tga",
        // 现代高效格式
        "heic", "heif", "hif", "avif", "webp", "jp2", "j2k", "jpf", "jpx", "exr",
        // 厂商 RAW
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf",
        "orf", "rwl", "rw2", "pef", "srw", "raw", "mrw", "x3f", "3fr", "fff",
        "iiq", "k25", "kdc", "mef", "mos", "erf", "dcr", "mdc", "pxn", "bay"
    ]

    /// 视频格式：涵盖消费相机、手机、专业摄像机与流媒体容器。
    static let videoExtensions: Set<String> = [
        // 通用容器
        "mp4", "m4v", "mov", "qt", "mkv", "avi", "divx", "wmv", "asf", "flv", "f4v",
        "webm", "mpg", "mpeg", "mpe", "m2v", "mpv", "vob", "ogv", "amv", "m4s",
        // 广播与专业
        "ts", "mts", "m2ts", "m2t", "mxf", "dv", "vro", "dvr-ms", "cav",
        // 移动设备
        "3gp", "3g2", "mod", "tod",
        // 专业与全景素材
        "r3d", "braw", "insv", "lrv",
        // 老式与流媒体
        "rm", "rmvb",
        // 裸流
        "hevc", "h264", "h265", "264", "265", "vc1", "y4m"
    ]

    /// 基于 ISO BMFF 容器（可零进程读取 `mvhd` 创建时间）的视频扩展名。
    static let isoBmffExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "3gp", "3g2"
    ]

    static func kind(forPath path: String) -> MediaKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if photoExtensions.contains(ext) { return .photo }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    static func kind(forExtension ext: String) -> MediaKind? {
        let value = ext.lowercased()
        if photoExtensions.contains(value) { return .photo }
        if videoExtensions.contains(value) { return .video }
        return nil
    }

    /// 供界面展示的扩展名清单（按字母序）。
    static func extensionList(for kind: MediaKind) -> [String] {
        let source = kind == .photo ? photoExtensions : videoExtensions
        return source.sorted()
    }
}

// MARK: - 拍摄时间

/// 单个文件的拍摄时间读取结果。
struct CaptureTimeResult: Sendable {
    var date: Date?
    var source: CaptureTimeSource?

    static let unresolved = CaptureTimeResult(date: nil, source: nil)
}

/// 单个文件的元数据读取结果：拍摄时间与拍摄设备型号。
///
/// 两者合并为一次读取而非各自独立成函数：照片要开一次 ImageIO，
/// 视频要扫一遍容器字节，分别调用会让整卡素材被解析两遍，
/// 而规划阶段的耗时几乎全部来自这一步。
struct MediaMetadataResult: Sendable {
    var capture: CaptureTimeResult = .unresolved
    /// 元数据中记录的原始设备型号；未记录时为 nil。
    /// 未经规范化，目录名的整理交给 `MediaImportSettings`。
    var deviceModel: String?

    static let unresolved = MediaMetadataResult()
}

/// 从媒体文件中提取拍摄时间与设备型号。
///
/// 回退顺序按证据强度递减，每一步都带回来源标记，使报告可以区分
/// 「相机记录的权威时间」与「根据文件名或文件时间推断的近似值」：
///
/// 1. 照片 → EXIF `DateTimeOriginal` / `DateTimeDigitized` / TIFF `DateTime`
/// 2. 视频 → ISO BMFF 容器的 `mvhd` 创建时间（零进程开销的快速路径）
/// 3. 视频 → ffprobe 读取容器元数据（非 ISO BMFF 容器走此路）
/// 4. 文件名中的时间戳（形如 `IMG_20240315_143022.JPG`）
/// 5. 文件修改时间
///
/// 设备型号的来源与时间不同：照片取 EXIF 的 `Model` 标签；视频取容器的
/// `©mod` 标签，同样优先走零进程的字节解析，只在取不到时才动用 ffprobe。
enum MediaMetadata {

    // MARK: - 主入口

    static func read(forPath path: String,
                     kind: MediaKind,
                     settings: MediaImportSettings,
                     probe: URL?,
                     modifiedDate: Date?) -> MediaMetadataResult {
        var result = MediaMetadataResult()

        switch kind {
        case .photo:
            let info = exifInfo(atPath: path)
            if let date = info.date {
                result.capture = CaptureTimeResult(date: date, source: .exif)
            }
            result.deviceModel = info.model

        case .video:
            let ext = (path as NSString).pathExtension.lowercased()
            let isISO = MediaFileTypes.isoBmffExtensions.contains(ext)

            // 需要 ffprobe 的两种情形：非 ISO BMFF 容器必须靠它取时间；
            // ISO BMFF 容器则在「启用了设备分类但字节里没有型号」时补一次查询。
            if isISO {
                let info = isoBmffInfo(atPath: path, mode: settings.videoTimeZone)
                if let date = info.date {
                    result.capture = CaptureTimeResult(date: date, source: .container)
                }
                result.deviceModel = info.model
            }

            let needsProbe = !isISO || (result.deviceModel == nil && settings.classifyByDevice)
            if needsProbe, let probe {
                let info = probeInfo(atPath: path, probe: probe, mode: settings.videoTimeZone)
                if result.capture.date == nil, let date = info.date {
                    result.capture = CaptureTimeResult(date: date, source: .container)
                }
                if result.deviceModel == nil {
                    result.deviceModel = info.model
                }
            }
        }

        if result.capture.date == nil {
            if settings.parseFilenameTimestamp,
               let date = filenameDate((path as NSString).lastPathComponent) {
                result.capture = CaptureTimeResult(date: date, source: .filename)
            } else if settings.fallbackToFileDate, let modifiedDate {
                result.capture = CaptureTimeResult(date: modifiedDate, source: .fileDate)
            }
        }

        return result
    }

    /// 只关心拍摄时间的调用方使用的便捷入口。
    static func captureTime(forPath path: String,
                            kind: MediaKind,
                            settings: MediaImportSettings,
                            probe: URL?,
                            modifiedDate: Date?) -> CaptureTimeResult {
        read(forPath: path, kind: kind, settings: settings,
             probe: probe, modifiedDate: modifiedDate).capture
    }

    // MARK: - 照片：EXIF

    /// 一次读取照片的 EXIF：拍摄时间与设备型号。
    ///
    /// 只用 ImageIO 读取元数据而不解码像素，因此对整卡照片遍历的开销很低。
    /// 时间优先级遵循 EXIF 规范：原始拍摄时间优于数字化时间，两者都缺失时退回
    /// TIFF 段的通用时间字段——扫描件与后期处理过的图片常只有后者。
    ///
    /// 型号取 TIFF 段的 `Model` 标签。刻意不退回 `Make`（厂商名）：
    /// 「Canon」与「Canon EOS R5」混在同一层目录里，反而比统一归入「未识别」
    /// 更难解释，也让目录结构随素材来源随机变化。
    static func exifInfo(atPath path: String) -> (date: Date?, model: String?) {
        let url = URL(fileURLWithPath: path)
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let candidates: [String?] = [
            exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String,
            tiff?[kCGImagePropertyTIFFDateTime] as? String
        ]

        var date: Date?
        for case let text? in candidates {
            if let parsed = parseExifDate(text) { date = parsed; break }
        }
        return (date, tiff?[kCGImagePropertyTIFFModel] as? String)
    }

    /// 只取拍摄时间，供需要单独调用型号的场景之外的旧调用方使用。
    static func exifDate(atPath path: String) -> Date? {
        exifInfo(atPath: path).date
    }

    /// 解析 EXIF 时间字符串，格式为 `yyyy:MM:dd HH:mm:ss`。
    ///
    /// EXIF 不携带时区信息，按本机时区解释——这与相机屏幕上显示的时间一致，
    /// 也符合用户「那天拍的」的直觉。
    static func parseExifDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 19 else { return nil }

        let head = trimmed.prefix(19)
        let halves = head.split(separator: " ")
        guard halves.count == 2 else { return nil }

        let dateParts = halves[0].split(whereSeparator: { $0 == ":" || $0 == "-" || $0 == "/" })
        let timeParts = halves[1].split(separator: ":")
        guard dateParts.count == 3, timeParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]),
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]), let second = Int(timeParts[2]) else {
            return nil
        }

        return makeLocalDate(year: year, month: month, day: day,
                             hour: hour, minute: minute, second: second)
    }

    // MARK: - 视频：ISO BMFF 快速路径

    /// ISO BMFF 的时间基准为 1904-01-01 00:00:00 UTC。
    private static let reference1904: Date? = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = 1904
        components.month = 1
        components.day = 1
        return calendar.date(from: components)
    }()

    private static let movieHeaderMarker = Data([0x6D, 0x76, 0x68, 0x64]) // "mvhd"

    /// 直接解析容器内的 `mvhd` 创建时间与 `©mod` 设备型号。
    ///
    /// 一次导入常包含数百个视频，若每个都调用一次 ffprobe，进程启动开销会成为
    /// 整个规划阶段最慢的一环。`mvhd` 与 `udta` 都位于 `moov` 内，绝大多数相机与
    /// 手机把 `moov` 写在文件头部，读取前若干字节即可命中；对 `moov` 后置的文件
    /// （边录边写或被后期重封装过）再补读文件尾——`udta` 在 `moov` 尾部，
    /// 因此后置情形下型号几乎只在文件尾才能读到。
    static func isoBmffInfo(atPath path: String,
                            mode: VideoTimeZoneMode) -> (date: Date?, model: String?) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)

        var date: Date?
        var model: String?

        let headLength = 256 * 1024
        if let head = try? handle.read(upToCount: headLength), !head.isEmpty {
            if let seconds = findMovieHeaderSeconds(in: head) {
                date = makeContainerDate(secondsSince1904: seconds, mode: mode)
            }
            model = findDeviceModel(in: head)
        }

        // 任一项缺失才补读文件尾，避免为已命中的文件多读一次。
        if (date == nil || model == nil), fileSize > UInt64(headLength) {
            let tailLength = 512 * 1024
            let offset = fileSize > UInt64(tailLength) ? fileSize - UInt64(tailLength) : 0
            try? handle.seek(toOffset: offset)
            if let tail = try? handle.read(upToCount: tailLength), !tail.isEmpty {
                if date == nil, let seconds = findMovieHeaderSeconds(in: tail) {
                    date = makeContainerDate(secondsSince1904: seconds, mode: mode)
                }
                if model == nil { model = findDeviceModel(in: tail) }
            }
        }
        return (date, model)
    }

    /// 只取创建时间，供只需要时间的调用方使用。
    static func isoBmffDate(atPath path: String, mode: VideoTimeZoneMode) -> Date? {
        isoBmffInfo(atPath: path, mode: mode).date
    }

    /// 在字节流中定位 `mvhd` 并读出 creation_time。
    ///
    /// 使用标记搜索而非完整的 box 遍历：`mvhd` 在合法文件中唯一，
    /// 且随后的时间值会经过范围校验，误命中的字节序列会被拒绝。
    static func findMovieHeaderSeconds(in data: Data) -> Int64? {
        var searchStart = data.startIndex
        while searchStart < data.endIndex,
              let range = data.range(of: movieHeaderMarker, in: searchStart..<data.endIndex) {
            let versionIndex = range.upperBound
            guard versionIndex < data.endIndex else { return nil }
            let version = data[versionIndex]

            if version == 1 {
                let valueIndex = versionIndex + 1 + 3 // version(1) + flags(3)
                guard valueIndex + 8 <= data.endIndex else { return nil }
                var value: UInt64 = 0
                for offset in 0..<8 {
                    value = (value << 8) | UInt64(data[valueIndex + offset])
                }
                return Int64(clamping: value)
            }
            if version == 0 {
                let valueIndex = versionIndex + 1 + 3
                guard valueIndex + 4 <= data.endIndex else { return nil }
                var value: UInt32 = 0
                for offset in 0..<4 {
                    value = (value << 8) | UInt32(data[valueIndex + offset])
                }
                return Int64(value)
            }
            // 未知版本号，继续向后搜索。
            searchStart = range.upperBound
        }
        return nil
    }

    /// 把容器时间戳换算为可用于归档的日期。
    ///
    /// 数值为 0 或落在合理年份之外时视为占位值并拒绝——不少设备的容器的确写入 0。
    static func makeContainerDate(secondsSince1904 seconds: Int64, mode: VideoTimeZoneMode) -> Date? {
        guard seconds > 0, seconds < 6_500_000_000, let reference = reference1904 else { return nil }
        let absolute = reference.addingTimeInterval(TimeInterval(seconds))

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = utcCalendar.component(.year, from: absolute)
        guard (1970...2100).contains(year) else { return nil }

        switch mode {
        case .convertFromUTC:
            return absolute
        case .asLocal:
            // 把 UTC 时刻的日历字段原样当作本地时间来解释。
            let parts = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                   from: absolute)
            return makeLocalDate(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0,
                                 hour: parts.hour ?? 0, minute: parts.minute ?? 0,
                                 second: parts.second ?? 0)
        }
    }

    // MARK: - 视频：设备型号（容器字节）

    /// `©mod` 的字节形式：0xA9 后接 ASCII "mod"。
    private static let deviceModelMarker = Data([0xA9, 0x6D, 0x6F, 0x64])

    /// 在字节流中定位 `©mod` 并取出型号文本。
    ///
    /// 与 `mvhd` 一样采用标记搜索而非完整 box 遍历：`udta` 层级不深但 box 种类繁多，
    /// 写一个通用遍历器收益有限。误命中（标记字节恰好出现在压缩数据里）由一个
    /// 结构校验和文本可打印性校验共同挡住——取错型号只会建错一层目录，
    /// 不会损坏数据，因此这里的校验强度与风险是匹配的。
    static func findDeviceModel(in data: Data) -> String? {
        var searchStart = data.startIndex
        while searchStart < data.endIndex,
              let range = data.range(of: deviceModelMarker, in: searchStart..<data.endIndex) {
            if let value = deviceModelValue(in: data, afterKey: range.upperBound) {
                return value
            }
            searchStart = range.upperBound
        }
        return nil
    }

    /// 解析 `©mod` 之后的载荷，兼容两种实际存在的写入惯例。
    private static func deviceModelValue(in data: Data, afterKey index: Int) -> String? {
        // 形态一：iTunes / ISO 风格——键后紧跟一个 `data` 盒子。
        // 布局为 [盒长 u32]["data"][版本与类型 u32][语言 u32][文本]，文本自盒内偏移 16 起。
        if index + 16 <= data.count,
           data[(index + 4)..<(index + 8)].elementsEqual("data".utf8) {
            let boxSize = Int(readUInt32(data, at: index))
            if boxSize >= 16, index + boxSize <= data.count {
                let payload = data[(index + 16)..<(index + boxSize)]
                if let text = decodeDeviceText(payload) { return text }
            }
        }

        // 形态二：QuickTime 的 udta 文本原子——[文本长度 u16][语言码 u16][文本]。
        // FFmpeg 写元数据时采用这一形态，长度上限用于排除把盒长误读成长度的情形。
        if index + 4 <= data.count {
            let length = Int(readUInt16(data, at: index))
            if length > 0, length <= 64, index + 4 + length <= data.count {
                let payload = data[(index + 4)..<(index + 4 + length)]
                if let text = decodeDeviceText(payload) { return text }
            }
        }
        return nil
    }

    /// 把候选载荷解码为型号文本，并拒绝不像型号的内容。
    private static func decodeDeviceText(_ payload: Data) -> String? {
        var bytes = payload
        while let last = bytes.last, last == 0 { bytes.removeLast() }
        guard !bytes.isEmpty, let text = String(data: bytes, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }

        // 视频数据里偶然出现的标记字节解出来多为不可打印字符，据此拒绝。
        let scalars = trimmed.unicodeScalars
        var printable = 0
        for scalar in scalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { printable += 1; continue }
            if scalar == " " || scalar == "-" || scalar == "_" || scalar == "." ||
                scalar == "(" || scalar == ")" || scalar == "+" || scalar == "/" { printable += 1 }
        }
        guard printable * 10 >= scalars.count * 9 else { return nil }
        return trimmed
    }

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        (UInt32(data[index]) << 24) | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8) | UInt32(data[index + 3])
    }

    private static func readUInt16(_ data: Data, at index: Int) -> UInt16 {
        (UInt16(data[index]) << 8) | UInt16(data[index + 1])
    }

    // MARK: - 视频：ffprobe 回退

    /// 用 ffprobe 读取容器记录的创建时间与设备型号。
    ///
    /// 适用于 MKV / AVI / MTS 等非 ISO BMFF 容器，也用于 ISO BMFF 容器里
    /// 没有 `©mod` 标签的视频（安卓录制的 MP4 常属此类）。
    /// 时间与型号合并为一次调用：两次进程启动的开销在这个环节是主要成本。
    static func probeInfo(atPath path: String,
                          probe: URL,
                          mode: VideoTimeZoneMode) -> (date: Date?, model: String?) {
        guard FileManager.default.isExecutableFile(atPath: probe.path) else { return (nil, nil) }

        let output = FFmpegRunner.capture(executable: probe, arguments: [
            "-hide_banner", "-v", "error",
            "-show_entries",
            "format_tags=creation_time,com.apple.quicktime.model,model:stream_tags=com.apple.quicktime.model,model",
            "-of", "default=noprint_wrappers=1",
            path
        ], timeout: 20)

        let fields = parseProbeFields(output)
        let date = fields["creation_time"].flatMap { parseISO8601($0, mode: mode) }
        let model = fields["com.apple.quicktime.model"] ?? fields["model"]
        return (date, model)
    }

    /// 把 ffprobe 的 `key=value` 输出整理成字典。
    ///
    /// `default=noprint_wrappers=1` 下标签行仍带 `TAG:` 前缀，这里对它保持容忍；
    /// 同一键在 format 段与 stream 段各出现一次时保留首个非空值。
    static func parseProbeFields(_ output: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in output.split(separator: "\n") {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("TAG:") { line.removeFirst(4) }

            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, value != "N/A" else { continue }
            if fields[key] == nil { fields[key] = value }
        }
        return fields
    }

    /// 只取创建时间，供只需要时间的调用方使用。
    static func probeDate(atPath path: String, probe: URL, mode: VideoTimeZoneMode) -> Date? {
        probeInfo(atPath: path, probe: probe, mode: mode).date
    }

    /// 解析 ffprobe 输出的 ISO 8601 时间。
    static func parseISO8601(_ text: String, mode: VideoTimeZoneMode) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .asLocal:
            // 取字面字段构造本地时间，忽略时区标记。
            guard let components = literalComponents(trimmed) else { return nil }
            return makeLocalDate(year: components.year ?? 0, month: components.month ?? 0,
                                 day: components.day ?? 0, hour: components.hour ?? 0,
                                 minute: components.minute ?? 0, second: components.second ?? 0)

        case .convertFromUTC:
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: trimmed) { return date }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: trimmed) { return date }

            // 未带时区标记的时间按本地时间处理。
            guard let components = literalComponents(trimmed) else { return nil }
            return makeLocalDate(year: components.year ?? 0, month: components.month ?? 0,
                                 day: components.day ?? 0, hour: components.hour ?? 0,
                                 minute: components.minute ?? 0, second: components.second ?? 0)
        }
    }

    /// 从 `2024-03-15T06:30:22.123456Z` 中取出前 19 个字符的日历字段。
    static func literalComponents(_ text: String) -> DateComponents? {
        guard text.count >= 19 else { return nil }
        let head = text.prefix(19)
        let dateParts = head.prefix(10).split(separator: "-")
        let timeParts = head.dropFirst(11).split(separator: ":")
        guard dateParts.count == 3, timeParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]),
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]), let second = Int(timeParts[2]) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components
    }

    // MARK: - 文件名时间戳

    /// 连写式：`20240315_143022`、`IMG_20240315_143022`、`PXL_20240315_143022123`
    private static let compactStamp = try? NSRegularExpression(
        pattern: "(19\\d{2}|20\\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\\d|3[01])[_\\-]?([01]\\d|2[0-3])([0-5]\\d)([0-5]\\d)"
    )

    /// 分隔式：`2024-03-15 14.30.22`、`2024_03_15-14-30-22`
    private static let separatedStamp = try? NSRegularExpression(
        pattern: "(19\\d{2}|20\\d{2})[-_.](0[1-9]|1[0-2])[-_.](0[1-9]|[12]\\d|3[01])[ _T]([01]\\d|2[0-3])[-_.:]([0-5]\\d)[-_.:]([0-5]\\d)"
    )

    /// 从文件名推断时间戳。
    ///
    /// 覆盖相机与手机常见的命名习惯。仅接受「日期 + 时分秒」完整的模式，
    /// 不接受只有日期的形式——后者极易与设备编号、固件版本等数字混淆。
    static func filenameDate(_ fileName: String) -> Date? {
        let stem = (fileName as NSString).deletingPathExtension
        guard stem.count >= 14 else { return nil }

        let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        for expression in [compactStamp, separatedStamp] {
            guard let regex = expression,
                  let match = regex.firstMatch(in: stem, options: [], range: range) else { continue }

            var values: [Int] = []
            for group in 1...6 {
                guard let groupRange = Range(match.range(at: group), in: stem),
                      let value = Int(stem[groupRange]) else {
                    values.removeAll()
                    break
                }
                values.append(value)
            }
            guard values.count == 6 else { continue }

            if let date = makeLocalDate(year: values[0], month: values[1], day: values[2],
                                        hour: values[3], minute: values[4], second: values[5]) {
                return date
            }
        }
        return nil
    }

    // MARK: - 工具

    /// 用本机时区构造日期，并拒绝会被自动进位的非法日期（例如 2 月 30 日）。
    static func makeLocalDate(year: Int, month: Int, day: Int,
                              hour: Int, minute: Int, second: Int) -> Date? {
        guard (1970...2100).contains(year),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        guard let date = calendar.date(from: components) else { return nil }

        // Calendar 会把 2 月 30 日规范化为 3 月 2 日，这里回读字段确认未发生进位。
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return date
    }
}
