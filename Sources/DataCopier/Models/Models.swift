import Foundation

// MARK: - 校验算法

/// 可选的哈希算法。xxHash64 用于快速初筛，SHA-256 / MD5 用于强一致性确认。
enum CheckAlgorithm: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case xxhash64
    case sha256
    case md5

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "不校验"
        case .xxhash64: return "xxHash64（快速）"
        case .sha256: return "SHA-256（强校验）"
        case .md5: return "MD5（兼容）"
        }
    }

    var shortName: String {
        switch self {
        case .none: return "无"
        case .xxhash64: return "xxh64"
        case .sha256: return "sha256"
        case .md5: return "md5"
        }
    }

    /// 是否为密码学哈希（用于生成 shasum 兼容清单）
    var isCryptographic: Bool {
        self == .sha256 || self == .md5
    }

    var digestHexLength: Int {
        switch self {
        case .none: return 0
        case .xxhash64: return 16
        case .sha256: return 64
        case .md5: return 32
        }
    }
}

// MARK: - 冲突策略

enum ConflictPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case overwrite
    case skip
    case rename
    case onlyIfNewer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overwrite: return "覆盖已存在文件"
        case .skip: return "跳过已存在文件"
        case .rename: return "重命名保留两份"
        case .onlyIfNewer: return "仅当源文件更新时覆盖"
        }
    }

    var detail: String {
        switch self {
        case .overwrite: return "目标存在同名文件时直接覆盖"
        case .skip: return "目标存在同名文件时跳过，适合断点续传场景"
        case .rename: return "目标存在同名文件时自动加序号，两份都保留"
        case .onlyIfNewer: return "比较修改时间，源较旧则跳过"
        }
    }
}

// MARK: - 任务预设

/// 任务级预设，决定「拷什么」与「如何组织目标目录」。
///
/// 两个预设的差异集中在规划阶段：所有文件拷贝保持来源结构原样搬运；
/// 媒体拷贝则先按格式筛选，再依据拍摄时间重组目录与文件名。
/// 拷贝引擎、校验引擎与报告层完全共用，因此预设不会带来两套执行路径。
enum CopyPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 保持来源目录结构，不做格式筛选与重命名。
    case everything
    /// 仅拷贝照片与视频，按拍摄时间重命名并分类归档。
    case media

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .everything: return "文件拷贝"
        case .media: return "媒体拷贝"
        }
    }

    var summary: String {
        switch self {
        case .everything:
            return "完整拷贝来源目录，保留原始目录层级，全部文件类型，文件名不改动，适合整盘项目迁移。"
        case .media:
            return "照片视频，适合相机卡导入素材整理，目标目录按拍摄时间重建，来源原有的目录结构不再保留。"
        }
    }

    var symbol: String {
        switch self {
        case .everything: return "folder"
        case .media: return "photo.on.rectangle.angled"
        }
    }
}

// MARK: - 任务类型

/// 任务的大类。新建任务时先选类型，再进入各自的配置表单；
/// 两者共用同一份任务列表、状态机与报告框架。
enum TaskKind: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 把来源文件搬运到目标位置
    case copy
    /// 扫描来源中的视频并按预设重编码输出
    case transcode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copy: return "拷贝任务"
        case .transcode: return "转码任务"
        }
    }

    var symbol: String {
        switch self {
        case .copy: return "arrow.down.doc"
        case .transcode: return "wand.and.stars"
        }
    }

    /// 新建任务类型选择页的一句话说明。
    var summary: String {
        switch self {
        case .copy:
            return "把来源文件完整搬运到目标位置，支持整盘迁移与照片视频素材整理。"
        case .transcode:
            return "扫描来源中的视频，按预设重编码后输出到目标文件夹，可选保留或删除原片。"
        }
    }
}

/// 媒体文件的类型归属。仅用于决定归档位置，不参与格式支持性判断。
enum MediaKind: String, CaseIterable, Codable, Sendable {
    case photo
    case video

    var displayName: String {
        switch self {
        case .photo: return "照片"
        case .video: return "视频"
        }
    }

    var symbol: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        }
    }
}

/// 拍摄时间的来源。报告中记录该值，便于判断一次导入的时间准确性。
enum CaptureTimeSource: String, Codable, Sendable {
    /// 照片 EXIF 的原始拍摄时间
    case exif
    /// 视频容器内记录的创建时间
    case container
    /// 从文件名中的时间戳推断
    case filename
    /// 回退到文件的修改时间
    case fileDate

    var displayName: String {
        switch self {
        case .exif: return "EXIF 拍摄时间"
        case .container: return "视频容器时间"
        case .filename: return "文件名时间戳"
        case .fileDate: return "文件修改时间"
        }
    }

    /// 是否为可靠的拍摄时间。文件名与文件时间属于推断值，界面上需要区分。
    var isAuthoritative: Bool {
        self == .exif || self == .container
    }
}

/// 按拍摄时间重命名时的命名方式。
enum MediaRenameMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 时间戳后接原文件名，保留相机给的编号信息
    case timestampWithOriginal
    /// 只保留时间戳
    case timestampOnly
    /// 自定义字段 + 拍摄时间，例如「婚礼_20240315_143022.JPG」
    case customWithTimestamp
    /// 自定义字段 + 原文件名 + 拍摄时间，例如「婚礼_IMG_1234_20240315_143022.JPG」
    case customWithOriginalAndTimestamp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .timestampWithOriginal: return "时间戳 + 原文件名"
        case .timestampOnly: return "仅时间戳"
        case .customWithTimestamp: return "自定义字段 + 拍摄时间"
        case .customWithOriginalAndTimestamp: return "自定义字段 + 原文件名 + 拍摄时间"
        }
    }

    var example: String {
        switch self {
        case .timestampWithOriginal: return "20240315_143022_IMG_1234.JPG"
        case .timestampOnly: return "20240315_143022.JPG"
        case .customWithTimestamp: return "婚礼_20240315_143022.JPG"
        case .customWithOriginalAndTimestamp: return "婚礼_IMG_1234_20240315_143022.JPG"
        }
    }
}

/// 归档目录的层级规则。
///
/// 三种日期档位各有一对变体：带「/设备」的在日期层级之后再按机型分一层目录，
/// 不带的则完全不按设备分类。「不归类」没有设备变体——平铺时再分机型意义不大。
///
/// 带设备的叶子目录统一以「月-日」命名（如 `03-15`），
/// 用户自定义字段以连字符拼接在叶子目录名上（如 `03-15-婚礼`）：
///
/// ```
/// Photos/2024/03/03-15-婚礼/iPhone 15 Pro/20240315_143022_IMG_1234.JPG
/// ```
enum MediaFolderGranularity: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 年/月/月-日-自定义/设备：`2024/03/03-15/iPhone 15 Pro`
    case yearMonthDayDevice
    /// 年/月/月-日-自定义：`2024/03/03-15`
    case yearMonthDay
    /// 年/月-日-自定义/设备：`2024/03-15/iPhone 15 Pro`
    case yearMonthDayFlatDevice
    /// 年/月-日-自定义：`2024/03-15`
    case yearMonthDayFlat
    /// 月-日-自定义/设备：`03-15/iPhone 15 Pro`
    case monthDayFlatDevice
    /// 月-日-自定义：`03-15`
    case monthDayFlat
    /// 不归类（平铺）
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .yearMonthDayDevice: return "年/月/月-日-自定义/设备"
        case .yearMonthDay: return "年/月/月-日-自定义"
        case .yearMonthDayFlatDevice: return "年/月-日-自定义/设备"
        case .yearMonthDayFlat: return "年/月-日-自定义"
        case .monthDayFlatDevice: return "月-日-自定义/设备"
        case .monthDayFlat: return "月-日-自定义"
        case .none: return "不归类（平铺）"
        }
    }

    var example: String {
        switch self {
        case .yearMonthDayDevice: return "2024/03/03-15-婚礼/iPhone 15 Pro"
        case .yearMonthDay: return "2024/03/03-15-婚礼"
        case .yearMonthDayFlatDevice: return "2024/03-15-婚礼/iPhone 15 Pro"
        case .yearMonthDayFlat: return "2024/03-15-婚礼"
        case .monthDayFlatDevice: return "03-15-婚礼/iPhone 15 Pro"
        case .monthDayFlat: return "03-15-婚礼"
        case .none: return "（平铺，无子目录）"
        }
    }

    /// 该档位是否在日期层级之后按机型再分一层目录。
    var includesDevice: Bool {
        switch self {
        case .yearMonthDayDevice, .yearMonthDayFlatDevice, .monthDayFlatDevice:
            return true
        case .yearMonthDay, .yearMonthDayFlat, .monthDayFlat, .none:
            return false
        }
    }

    /// 对应的带设备变体；「不归类」没有设备变体。
    var withDevice: MediaFolderGranularity? {
        switch self {
        case .yearMonthDayDevice, .yearMonthDayFlatDevice, .monthDayFlatDevice, .none:
            return nil
        case .yearMonthDay: return .yearMonthDayDevice
        case .yearMonthDayFlat: return .yearMonthDayFlatDevice
        case .monthDayFlat: return .monthDayFlatDevice
        }
    }

    /// 对应的不带设备变体；「不归类」原样返回。
    var withoutDevice: MediaFolderGranularity {
        switch self {
        case .yearMonthDayDevice: return .yearMonthDay
        case .yearMonthDayFlatDevice: return .yearMonthDayFlat
        case .monthDayFlatDevice: return .monthDayFlat
        case .yearMonthDay, .yearMonthDayFlat, .monthDayFlat, .none:
            return self
        }
    }

    /// 由拍摄时间与自定义字段推导目录层级分量。
    ///
    /// 自定义字段为空时叶子目录仅保留「月-日」（如 `03-15`）；
    /// 非空时以连字符拼接（如 `03-15-婚礼`）。调用方负责先净化字段中的分隔符。
    /// 设备目录不在此列：它由 `MediaArchiver.relativePath` 依据 `includesDevice`
    /// 追加在日期层级之后。
    func components(for date: Date,
                    calendar: Calendar = .current,
                    custom: String = "") -> [String] {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        let monthDay = String(format: "%02d-%02d", month, day)
        let leaf = custom.isEmpty ? monthDay : "\(monthDay)-\(custom)"

        switch self {
        case .yearMonthDayDevice, .yearMonthDay:
            return [String(format: "%04d", year),
                    String(format: "%02d", month),
                    leaf]
        case .yearMonthDayFlatDevice, .yearMonthDayFlat:
            return [String(format: "%04d", year), leaf]
        case .monthDayFlatDevice, .monthDayFlat:
            return [leaf]
        case .none:
            return []
        }
    }

    /// 解码时兼容旧版本的档位命名（见 `init(fromLegacyRaw:)`）。
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self.init(fromLegacyRaw: raw)
    }
}

extension MediaFolderGranularity {
    /// 宽容解码：旧版本引入过 year / yearMonth / month / monthDay 等档位，
    /// 这些旧值不再存在，映射到语义最接近的新选项，避免旧任务文件解析失败。
    init(fromLegacyRaw raw: String) {
        switch raw {
        case "yearMonthDay": self = .yearMonthDay
        case "year", "yearMonth": self = .yearMonthDayFlat
        case "month", "monthDay": self = .monthDayFlat
        default: self = MediaFolderGranularity(rawValue: raw) ?? .none
        }
    }
}

/// 视频时间戳的时区语义。
///
/// 现实中的素材存在两种彼此矛盾的习惯：Apple 系设备把容器里的 `creation_time`
/// 按规范写作 UTC；不少相机与安卓设备则把本地时间直接填进该字段。两者无法自动区分，
/// 因此交由用户选择，默认按「本地时间」解释以与照片 EXIF 保持一致——
/// 否则同一次拍摄的静态照片与视频会被分进不同的日期目录。
enum VideoTimeZoneMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 直接把容器时间当作本地时间使用（相机与安卓常见）
    case asLocal
    /// 按 UTC 解释再换算到本机时区（Apple 设备符合此规范）
    case convertFromUTC

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .asLocal: return "按本地时间解释（推荐）"
        case .convertFromUTC: return "按 UTC 换算到本机时区"
        }
    }

    var detail: String {
        switch self {
        case .asLocal:
            return "多数相机与安卓设备把本地时间直接写入容器，用此选项可与照片 EXIF 的日期保持一致。"
        case .convertFromUTC:
            return "符合容器规范的做法。若发现视频日期整体偏移数小时，改用上面的本地时间解释。"
        }
    }
}

/// 媒体预设的归档配置。
struct MediaImportSettings: Codable, Hashable, Sendable {
    /// 是否按拍摄时间重命名文件。关闭后仅做分类归档，文件名保持原样。
    var renameByCaptureTime: Bool = true
    var renameMode: MediaRenameMode = .timestampWithOriginal
    /// 「自定义字段 + …」命名方式里用户填写的自定义前缀，默认留空。
    var customRenamePrefix: String = ""
    /// 归档目录档位。是否按机型分目录由档位本身决定（带「/设备」的变体）。
    var folderGranularity: MediaFolderGranularity = .yearMonthDayDevice
    /// 归档目录的自定义子目录：附加在日期层级之后（如「2024/03/15/婚礼」）。
    /// 默认为空表示不追加；非法字符（/ 与 :）在落盘前会被替换。
    var folderSuffix: String = ""
    /// 照片与视频分别放入独立子目录
    var separateByType: Bool = true
    var photoFolderName: String = "Photos"
    var videoFolderName: String = "Videos"
    /// 元数据中读不到型号时的归置目录名。
    ///
    /// 是否按机型分目录由 `folderGranularity` 的带「/设备」档位决定；
    /// 这里只控制未识别机型的素材归入哪个目录。
    var unknownDeviceFolderName: String = "未知设备"
    /// 各来源路径对应的自定义设备目录名（界面按来源填写）。
    /// 仅当素材读不到真实机型时生效：该来源的无机型文件归入此目录。
    var sourceDeviceNames: [String: String] = [:]
    /// 无法从元数据或文件名得到时间时，回退使用文件修改时间
    var fallbackToFileDate: Bool = true
    /// 是否尝试从文件名中解析时间戳
    var parseFilenameTimestamp: Bool = true
    var videoTimeZone: VideoTimeZoneMode = .asLocal

    static let `default` = MediaImportSettings()

    // MARK: 宽容解码
    //
    // 这份配置会随任务写入磁盘并被跨版本读取。合成的解码器要求所有键都必须存在，
    // 于是任何一次「新增一个字段」都会让旧任务文件整体解析失败——而 `media` 若是
    // 解析失败，连带整个任务列表都读不出来。因此逐字段 decodeIfPresent，
    // 缺失的键回退到默认值。

    private enum CodingKeys: String, CodingKey {
        case renameByCaptureTime, renameMode, customRenamePrefix, folderGranularity, folderSuffix
        case separateByType, photoFolderName, videoFolderName
        case unknownDeviceFolderName
        case sourceDeviceNames
        case fallbackToFileDate, parseFilenameTimestamp, videoTimeZone
    }

    /// 旧版任务文件里的设备分类开关。仅用于读取时迁移档位，不再写盘。
    private enum LegacyCodingKeys: String, CodingKey {
        case classifyByDevice
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = MediaImportSettings()

        renameByCaptureTime = try container.decodeIfPresent(Bool.self, forKey: .renameByCaptureTime)
            ?? fallback.renameByCaptureTime
        renameMode = try container.decodeIfPresent(MediaRenameMode.self, forKey: .renameMode)
            ?? fallback.renameMode
        customRenamePrefix = try container.decodeIfPresent(String.self, forKey: .customRenamePrefix)
            ?? fallback.customRenamePrefix
        folderGranularity = try container.decodeIfPresent(MediaFolderGranularity.self, forKey: .folderGranularity)
            ?? fallback.folderGranularity
        folderSuffix = try container.decodeIfPresent(String.self, forKey: .folderSuffix)
            ?? fallback.folderSuffix
        separateByType = try container.decodeIfPresent(Bool.self, forKey: .separateByType)
            ?? fallback.separateByType
        photoFolderName = try container.decodeIfPresent(String.self, forKey: .photoFolderName)
            ?? fallback.photoFolderName
        videoFolderName = try container.decodeIfPresent(String.self, forKey: .videoFolderName)
            ?? fallback.videoFolderName

        // 迁移：旧版「classifyByDevice 开关 + 不带设备的档位」等价于新版
        // 「对应的带设备档位」。旧文件开着开关但档位不带设备时，升级档位
        // 以保持原有落盘结构；新文件不含该键，无需处理。
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyClassifyByDevice = try legacyContainer.decodeIfPresent(
            Bool.self, forKey: .classifyByDevice) ?? false
        if legacyClassifyByDevice, let upgraded = folderGranularity.withDevice {
            folderGranularity = upgraded
        }

        unknownDeviceFolderName = try container.decodeIfPresent(String.self, forKey: .unknownDeviceFolderName)
            ?? fallback.unknownDeviceFolderName
        sourceDeviceNames = try container.decodeIfPresent([String: String].self, forKey: .sourceDeviceNames)
            ?? fallback.sourceDeviceNames
        fallbackToFileDate = try container.decodeIfPresent(Bool.self, forKey: .fallbackToFileDate)
            ?? fallback.fallbackToFileDate
        parseFilenameTimestamp = try container.decodeIfPresent(Bool.self, forKey: .parseFilenameTimestamp)
            ?? fallback.parseFilenameTimestamp
        videoTimeZone = try container.decodeIfPresent(VideoTimeZoneMode.self, forKey: .videoTimeZone)
            ?? fallback.videoTimeZone
    }

    /// 某一类型的归档目录名，空字符串回退到内置名称。
    func folderName(for kind: MediaKind) -> String {
        let raw = kind == .photo ? photoFolderName : videoFolderName
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return kind == .photo ? "Photos" : "Videos"
        }
        // 路径分隔符会破坏层级意图，统一替换掉。
        return trimmed.replacingOccurrences(of: "/", with: "-")
    }

    /// 设备型号对应的归档目录名。
    ///
    /// 返回 nil 表示本任务不按设备分层——档位不带「/设备」时调用方据此跳过该层级，
    /// 而不是插入一个空目录。
    /// 未识别出型号时归入 `unknownDeviceFolderName`：把这类素材集中在一处，
    /// 比散落在日期目录里更容易事后人工整理。
    func deviceFolderName(for model: String?) -> String? {
        guard folderGranularity.includesDevice else { return nil }
        if let name = Self.normalizedDeviceName(model) {
            return MediaArchiver.sanitize(name)
        }
        let fallback = unknownDeviceFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaArchiver.sanitize(fallback.isEmpty ? "未知设备" : fallback)
    }

    /// 某个来源路径下读不到机型的素材应归入的设备目录名。
    ///
    /// 界面允许为每个来源单独填写设备名：同一台电脑可以同时插两张卡、
    /// 连两台相机，各来源的无机型文件应各回各的目录。
    /// 返回 nil 表示该来源未填写设备名，回落到 `unknownDeviceFolderName`。
    func sourceDeviceFolderName(for sourcePath: String?) -> String? {
        guard let sourcePath,
              let custom = sourceDeviceNames[sourcePath]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !custom.isEmpty else { return nil }
        return MediaArchiver.sanitize(custom)
    }

    /// 把元数据里的原始型号整理成可用于目录名的文本。
    ///
    /// 相机与手机写入的型号常带首尾空白、成对引号，甚至整个字段填 0 或 "unknown"；
    /// 这类占位值若原样建目录，会得到一个毫无信息量的文件夹，因此统一视为未识别。
    static func normalizedDeviceName(_ raw: String?) -> String? {
        guard var value = raw else { return nil }

        value = value.replacingOccurrences(of: "\u{0}", with: " ")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }
        guard !value.isEmpty else { return nil }

        // 占位值与真正的型号无法从字面区分时，宁可归入「未识别」。
        let junk: Set<String> = ["0", "unknown", "n/a", "na", "null", "(null)", "none", "-"]
        guard !junk.contains(value.lowercased()) else { return nil }

        // 目录名的长度由 sanitize 兜底，这里只做一个宽松上限，
        // 避免某些固件把整段日志塞进型号字段。
        if value.count > 64 {
            value = String(value.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return nil }
        }
        return value
    }
}

// MARK: - 任务选项

struct TaskOptions: Codable, Hashable, Sendable {
    /// 逐块增量计算的哈希算法（边拷边算）
    var algorithm: CheckAlgorithm = .xxhash64
    /// 拷贝完成后重新读取目标文件并复核哈希
    var verifyAfterCopy: Bool = true
    /// 目标存在同名文件时的处理策略
    var conflictPolicy: ConflictPolicy = .overwrite
    /// 保留权限位、时间戳与扩展属性
    var preserveMetadata: Bool = true
    /// 是否把符号链接当作目标本身拷贝（false 表示复制链接指向的内容）
    var copySymlinksAsLinks: Bool = false
    /// 并行文件数
    var concurrency: Int = 4
    /// 单次读写缓冲区大小（字节）
    var bufferSize: Int = 4 * 1024 * 1024
    /// 按名称排除的条目（精确匹配文件名）
    var excludedNames: [String] = [
        ".DS_Store", ".Trash", ".Spotlight-V100", ".fseventsd",
        ".DocumentRevisions-V100", ".TemporaryItems", ".AppleDouble"
    ]
    /// 在目标根目录生成 checksums 清单
    var exportManifest: Bool = true
    /// 记录列表中保留的最大明细条数（避免报告体积失控）
    var maxRecordedEntries: Int = 20000
    /// 拷贝完成后的视频转码配置，nil 表示沿用默认值。
    ///
    /// 声明为可选类型用于兼容早期版本写出的任务文件（当时尚无该字段）——
    /// 可选属性在合成解码器中使用 `decodeIfPresent`，缺失时不会导致整个任务列表解析失败。
    /// 对外统一通过 `transcodeSettings` 访问，无需在各处处理 nil。
    var transcode: TranscodeSettings?

    /// 转码配置的非可选访问入口。
    var transcodeSettings: TranscodeSettings {
        get { transcode ?? .default }
        set { transcode = newValue }
    }

    /// 任务预设。声明为可选以兼容早期版本写出的任务文件，缺失时等价于「所有文件拷贝」。
    var preset: CopyPreset?
    /// 媒体预设的归档配置，缺失时沿用默认值。
    var media: MediaImportSettings?

    var copyPreset: CopyPreset {
        get { preset ?? .everything }
        set { preset = newValue }
    }

    var mediaSettings: MediaImportSettings {
        get { media ?? .default }
        set { media = newValue }
    }

    // MARK: 宽容解码
    //
    // 合成的解码器要求所有键都存在，任何一次「新增字段」都会让旧任务文件整体解析失败，
    // 进而连带整个任务列表读不出来。逐字段 decodeIfPresent，缺失的键回退默认值。
    // 解码实现放在扩展里，以保留成员初始化器（`TaskOptions()` 等调用点依赖它）。
    private enum CodingKeys: String, CodingKey {
        case algorithm, verifyAfterCopy, conflictPolicy, preserveMetadata
        case copySymlinksAsLinks, concurrency, bufferSize, excludedNames
        case exportManifest, maxRecordedEntries, transcode, preset, media
    }

    static let `default` = TaskOptions()

    /// 切换预设时同步套用一组经过验证的推荐值。
    ///
    /// 刻意只覆盖与预设语义强相关的项：算法、冲突策略、并发度与转码默认开关。
    /// 保留用户自行调整的缓冲区、排除规则与转码参数，避免一次点击抹掉既有配置。
    static func recommended(for preset: CopyPreset, basedOn current: TaskOptions) -> TaskOptions {
        var options = current
        options.copyPreset = preset

        switch preset {
        case .everything:
            options.algorithm = .xxhash64
            options.conflictPolicy = .overwrite
            options.concurrency = max(options.concurrency, 4)

        case .media:
            // 归档后的文件名由拍摄时间决定，重复导入同一张卡时会得到同名路径，
            // 因此「跳过已存在」是唯一幂等的选择——重跑一次不会产生副本。
            options.conflictPolicy = .skip
            options.algorithm = .xxhash64
            options.concurrency = max(options.concurrency, 6)
            if options.media == nil { options.media = .default }
        }

        return options
    }
}

extension TaskOptions {
    /// 宽容解码：缺失的键一律回退到默认值，避免旧任务文件整体解析失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TaskOptions()

        algorithm = try container.decodeIfPresent(CheckAlgorithm.self, forKey: .algorithm)
            ?? fallback.algorithm
        verifyAfterCopy = try container.decodeIfPresent(Bool.self, forKey: .verifyAfterCopy)
            ?? fallback.verifyAfterCopy
        conflictPolicy = try container.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy)
            ?? fallback.conflictPolicy
        preserveMetadata = try container.decodeIfPresent(Bool.self, forKey: .preserveMetadata)
            ?? fallback.preserveMetadata
        copySymlinksAsLinks = try container.decodeIfPresent(Bool.self, forKey: .copySymlinksAsLinks)
            ?? fallback.copySymlinksAsLinks
        concurrency = try container.decodeIfPresent(Int.self, forKey: .concurrency)
            ?? fallback.concurrency
        bufferSize = try container.decodeIfPresent(Int.self, forKey: .bufferSize)
            ?? fallback.bufferSize
        excludedNames = try container.decodeIfPresent([String].self, forKey: .excludedNames)
            ?? fallback.excludedNames
        exportManifest = try container.decodeIfPresent(Bool.self, forKey: .exportManifest)
            ?? fallback.exportManifest
        maxRecordedEntries = try container.decodeIfPresent(Int.self, forKey: .maxRecordedEntries)
            ?? fallback.maxRecordedEntries
        transcode = try container.decodeIfPresent(TranscodeSettings.self, forKey: .transcode)
        preset = try container.decodeIfPresent(CopyPreset.self, forKey: .preset)
        media = try container.decodeIfPresent(MediaImportSettings.self, forKey: .media)
    }
}

// MARK: - 任务状态

enum TaskState: String, Codable, Sendable {
    case idle
    case running
    case cancelling
    case finished
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .idle: return "待执行"
        case .running: return "进行中"
        case .cancelling: return "正在停止"
        case .finished: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    var isTerminal: Bool {
        self == .finished || self == .failed || self == .cancelled
    }
}

// MARK: - 任务定义

struct CopyTask: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var name: String
    var sources: [String]
    var destination: String
    var options: TaskOptions = .default
    var createdAt: Date = Date()
    var state: TaskState = .idle
    /// 任务类型。声明为可选以兼容早期任务文件，缺失时等价于拷贝任务。
    var kind: TaskKind?
    /// 最近一次执行的报告
    var lastReport: TaskReport?

    /// 任务类型的非可选访问入口。
    var taskKind: TaskKind { kind ?? .copy }

    var sourcesDisplay: String {
        if sources.count == 1 { return (sources[0] as NSString).lastPathComponent }
        return "\(sources.count) 个来源"
    }

    // MARK: 宽容解码
    // 逐字段 decodeIfPresent，缺失的键回退默认值，避免新增字段后旧任务文件解析失败。
    // 解码实现放在扩展里，以保留成员初始化器。
    private enum CodingKeys: String, CodingKey {
        case id, name, sources, destination, options
        case createdAt, state, kind, lastReport
    }
}

extension CopyTask {
    /// 宽容解码：缺失字段回退默认值，宁可读出「信息不全的任务」也不整份任务列表丢失。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名任务"
        sources = try container.decodeIfPresent([String].self, forKey: .sources) ?? []
        destination = try container.decodeIfPresent(String.self, forKey: .destination) ?? ""
        options = try container.decodeIfPresent(TaskOptions.self, forKey: .options) ?? .default
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        state = try container.decodeIfPresent(TaskState.self, forKey: .state) ?? .idle
        kind = try container.decodeIfPresent(TaskKind.self, forKey: .kind)
        lastReport = try container.decodeIfPresent(TaskReport.self, forKey: .lastReport)
    }
}

// MARK: - 单文件记录

enum FileStatus: String, Codable, Sendable {
    case copied
    case skipped
    case failed
    case verified
    case verifyFailed
    case planned

    var displayName: String {
        switch self {
        case .copied: return "已拷贝"
        case .skipped: return "已跳过"
        case .failed: return "失败"
        case .verified: return "校验通过"
        case .verifyFailed: return "校验不一致"
        case .planned: return "待处理"
        }
    }

    var isProblem: Bool {
        self == .failed || self == .verifyFailed
    }
}

struct FileRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var relativePath: String
    var sourcePath: String
    /// 文件最终落盘的位置。
    ///
    /// 注意：在「重命名保留两份」策略下该值可能与计划路径不同，
    /// 因此这里始终记录实际写入成功的路径，而不是规划阶段的预期路径。
    var destinationPath: String
    var size: Int64
    var status: FileStatus
    var sourceDigest: String?
    var destinationDigest: String?
    var duration: TimeInterval = 0
    var bytesPerSecond: Double = 0
    var message: String?
    var verified: Bool = false
    /// 转码阶段结果。仅当启用转码且该文件为候选视频时才有值，缺失表示未参与转码。
    var transcode: TranscodeOutcome?

    // MARK: 媒体归档信息（仅媒体预设下写入）

    /// 归档所用的拍摄时间。
    var captureDate: Date?
    /// 该时间的来源，用于区分权威值与推断值。
    var captureSource: CaptureTimeSource?
    /// 媒体类型归属。
    var mediaKind: MediaKind?
    /// 归档时使用的设备目录名（已规范化、已清理非法字符）。
    ///
    /// 未启用按设备分类时为 nil；启用但元数据中无型号时，记录的是
    /// `MediaImportSettings.unknownDeviceFolderName` 对应的目录名。
    var deviceModel: String?
    /// 归档前的原始文件名。仅在与最终文件名不同时写入。
    var originalName: String?

    /// 归档后的文件名（目标路径的最后一段）。
    var fileName: String { (destinationPath as NSString).lastPathComponent }

    /// 是否发生了重命名。
    var wasRenamed: Bool { originalName != nil }

    // MARK: 宽容解码
    // 明细记录随报告写入任务文件，跨版本读取。逐字段 decodeIfPresent 避免新增字段
    // 导致整条任务记录（乃至整个任务列表）解析失败。解码实现放在扩展里以保留成员初始化器。
    private enum CodingKeys: String, CodingKey {
        case id, relativePath, sourcePath, destinationPath, size, status
        case sourceDigest, destinationDigest, duration, bytesPerSecond, message, verified
        case transcode
        case captureDate, captureSource, mediaKind, deviceModel, originalName
    }
}

extension FileRecord {
    /// 宽容解码：缺失的键回退默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = FileRecord(relativePath: "", sourcePath: "",
                                  destinationPath: "", size: 0, status: .planned)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? fallback.id
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
            ?? fallback.relativePath
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
            ?? fallback.sourcePath
        destinationPath = try container.decodeIfPresent(String.self, forKey: .destinationPath)
            ?? fallback.destinationPath
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? fallback.size
        status = try container.decodeIfPresent(FileStatus.self, forKey: .status) ?? fallback.status
        sourceDigest = try container.decodeIfPresent(String.self, forKey: .sourceDigest)
        destinationDigest = try container.decodeIfPresent(String.self, forKey: .destinationDigest)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
            ?? fallback.duration
        bytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .bytesPerSecond)
            ?? fallback.bytesPerSecond
        message = try container.decodeIfPresent(String.self, forKey: .message)
        verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? fallback.verified
        transcode = try container.decodeIfPresent(TranscodeOutcome.self, forKey: .transcode)
        captureDate = try container.decodeIfPresent(Date.self, forKey: .captureDate)
        captureSource = try container.decodeIfPresent(CaptureTimeSource.self, forKey: .captureSource)
        mediaKind = try container.decodeIfPresent(MediaKind.self, forKey: .mediaKind)
        deviceModel = try container.decodeIfPresent(String.self, forKey: .deviceModel)
        originalName = try container.decodeIfPresent(String.self, forKey: .originalName)
    }
}

// MARK: - 转码结果

/// 单个文件的转码结局。
enum TranscodeStatus: String, Codable, Sendable {
    /// 转码成功并产出了可用的输出文件
    case succeeded
    /// 按规则主动跳过（未变小的压缩结果、无视频轨道、体积低于阈值等）
    case skipped
    /// 执行失败
    case failed

    var displayName: String {
        switch self {
        case .succeeded: return "已转码"
        case .skipped: return "已跳过"
        case .failed: return "转码失败"
        }
    }
}

/// 单文件转码明细。作为 `FileRecord` 的附属信息持久化，因此新增字段一律可选。
struct TranscodeOutcome: Codable, Hashable, Sendable {
    var status: TranscodeStatus
    var presetID: String
    var presetName: String
    /// 输出文件路径；跳过或失败时为 nil，或指向已被回滚删除的文件
    var outputPath: String?
    var inputBytes: Int64 = 0
    var outputBytes: Int64 = 0
    var duration: TimeInterval = 0
    /// 相对素材时长的处理倍速，例如 3.2 表示 3.2 倍速
    var speed: Double = 0
    var videoCodec: String?
    var audioCodec: String?
    var width: Int = 0
    var height: Int = 0
    /// 是否走硬件编码通路
    var usedHardware: Bool = false
    /// 是否使用了「码流直通失败后转码音轨」的兜底重试
    var usedFallback: Bool = false
    /// 是否已删除原始拷贝
    var removedOriginal: Bool = false
    var message: String?

    /// 输出相对输入的体积占比，1.0 表示等大。
    var compressionRatio: Double {
        inputBytes > 0 ? Double(outputBytes) / Double(inputBytes) : 0
    }

    /// 相对输入节省的字节数。
    var savedBytes: Int64 { max(0, inputBytes - outputBytes) }

    /// 分辨率描述，例如 `1920×1080`。
    var resolutionText: String {
        width > 0 && height > 0 ? "\(width)×\(height)" : "—"
    }

    /// 体积占比描述，例如 `原片的 24%`。
    var ratioText: String {
        guard status == .succeeded, inputBytes > 0 else { return "—" }
        return String(format: "原片的 %.0f%%", compressionRatio * 100)
    }
}

// MARK: - 进度快照

/// 任务所处的执行阶段。拷贝与转码是两个串行阶段，各自有独立的进度指标。
enum TaskPhase: String, Equatable, Sendable {
    case idle
    case copying
    case transcoding
    case finalizing

    var displayName: String {
        switch self {
        case .idle: return "待执行"
        case .copying: return "拷贝中"
        case .transcoding: return "转码中"
        case .finalizing: return "汇总中"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "pause.circle"
        case .copying: return "arrow.down.doc"
        case .transcoding: return "film.stack"
        case .finalizing: return "checklist"
        }
    }
}

struct TaskProgress: Equatable, Sendable {
    var phase: TaskPhase = .idle

    var totalFiles: Int = 0
    var completedFiles: Int = 0
    var failedFiles: Int = 0
    var totalBytes: Int64 = 0
    var processedBytes: Int64 = 0
    var currentFile: String = ""
    var bytesPerSecond: Double = 0
    var elapsed: TimeInterval = 0
    var eta: TimeInterval?

    /// 转码阶段的候选文件总数
    var transcodeTotal: Int = 0
    var transcodeCompleted: Int = 0
    var transcodeFailed: Int = 0
    /// 当前正在转码的文件（相对于来源根目录）
    var transcodeCurrent: String = ""
    /// 当前正在转码的文件的完成比例
    var transcodeCurrentFraction: Double = 0
    /// 当前转码速度，单位「倍速」
    var transcodeSpeed: Double = 0

    /// 当前阶段的完成度。
    ///
    /// 刻意按阶段分别计算而非做加权平均：拷贝与转码的耗时量级差异很大，
    /// 任何固定权重都会在某一类素材上失真。界面上以阶段标签消歧。
    var fraction: Double {
        switch phase {
        case .transcoding:
            guard transcodeTotal > 0 else { return 0 }
            let done = Double(transcodeCompleted) + min(1, max(0, transcodeCurrentFraction))
            return min(1, done / Double(transcodeTotal))
        case .finalizing:
            return 1
        case .idle, .copying:
            guard totalBytes > 0 else {
                guard totalFiles > 0 else { return 0 }
                return min(1, Double(completedFiles) / Double(totalFiles))
            }
            return min(1, Double(processedBytes) / Double(totalBytes))
        }
    }

    var isActive: Bool { processedBytes > 0 || completedFiles > 0 }
}

// MARK: - 执行报告

struct TaskReport: Codable, Sendable {
    var taskName: String
    var startedAt: Date
    var finishedAt: Date
    var sourceRoots: [String]
    var destination: String
    var algorithm: CheckAlgorithm
    var conflictPolicy: ConflictPolicy
    var verifyAfterCopy: Bool

    var totalFiles: Int = 0
    var totalBytes: Int64 = 0
    var copiedFiles: Int = 0
    var copiedBytes: Int64 = 0
    var skippedFiles: Int = 0
    var failedFiles: Int = 0
    var verifiedFiles: Int = 0
    var verifyFailedFiles: Int = 0
    var cancelled: Bool = false
    /// 执行期间观测到的峰值吞吐（字节/秒）
    var peakBytesPerSecond: Double = 0
    /// 产出该报告的任务类型。声明为可选以兼容早期报告文件。
    var taskKind: TaskKind?

    // MARK: 转码阶段

    /// 是否启用了转码阶段
    var transcodeEnabled: Bool = false
    /// 实际使用的转码预设名称
    var transcodePresetName: String?
    var transcodedFiles: Int = 0
    var transcodeSkippedFiles: Int = 0
    var transcodeFailedFiles: Int = 0
    var transcodeInputBytes: Int64 = 0
    var transcodeOutputBytes: Int64 = 0
    var transcodeDuration: TimeInterval = 0
    /// 其中走硬件编码的文件数
    var transcodeHardwareFiles: Int = 0
    /// 已删除原始拷贝的文件数
    var transcodeRemovedOriginals: Int = 0
    /// 转码阶段的补充说明（例如「没有匹配的视频文件」）
    var transcodeNote: String?

    // MARK: 归档阶段（仅媒体预设）

    /// 使用的任务预设，存原始标识以保证判断稳定
    var presetID: String?
    /// 因格式不受支持或不属于照片/视频而被排除的文件数
    var filteredOutFiles: Int = 0
    /// 按拍摄时间重命名的文件数
    var renamedFiles: Int = 0
    /// 归档的照片数
    var photoFiles: Int = 0
    /// 归档的视频数
    var videoFiles: Int = 0
    /// 拍摄时间取自 EXIF 或视频容器的文件数（权威来源）
    var captureMetadataFiles: Int = 0
    /// 拍摄时间来自文件名推断或文件修改时间的文件数（非权威来源）
    var captureFallbackFiles: Int = 0
    /// 素材时间范围下界
    var captureEarliest: Date?
    /// 素材时间范围上界
    var captureLatest: Date?
    /// 各归档目录的文件数，键为相对目标根的目录路径；未分类时键为空字符串
    var mediaFolderCounts: [String: Int] = [:]
    /// 各拍摄设备的文件数，键为归档所用的设备目录名。未启用设备分类时为空。
    var deviceCounts: [String: Int] = [:]

    var records: [FileRecord] = []
    var truncatedRecordCount: Int = 0

    // MARK: 宽容解码
    //
    // 报告会被写入任务文件并跨版本读取。为默认值编写逐字段的 decodeIfPresent，
    // 使得新增字段在旧文件缺失时回退到默认值，而不是让整个任务列表解析失败。

    private enum CodingKeys: String, CodingKey {
        case taskName, startedAt, finishedAt, sourceRoots, destination
        case algorithm, conflictPolicy, verifyAfterCopy
        case totalFiles, totalBytes, copiedFiles, copiedBytes
        case skippedFiles, failedFiles, verifiedFiles, verifyFailedFiles
        case cancelled, peakBytesPerSecond, taskKind
        case transcodeEnabled, transcodePresetName, transcodedFiles
        case transcodeSkippedFiles, transcodeFailedFiles
        case transcodeInputBytes, transcodeOutputBytes, transcodeDuration
        case transcodeHardwareFiles, transcodeRemovedOriginals, transcodeNote
        case presetID, filteredOutFiles, renamedFiles
        case photoFiles, videoFiles
        case captureMetadataFiles, captureFallbackFiles
        case captureEarliest, captureLatest, mediaFolderCounts
        case deviceCounts
        case records, truncatedRecordCount
    }

    init(taskName: String,
         startedAt: Date,
         finishedAt: Date,
         sourceRoots: [String],
         destination: String,
         algorithm: CheckAlgorithm,
         conflictPolicy: ConflictPolicy,
         verifyAfterCopy: Bool) {
        self.taskName = taskName
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.sourceRoots = sourceRoots
        self.destination = destination
        self.algorithm = algorithm
        self.conflictPolicy = conflictPolicy
        self.verifyAfterCopy = verifyAfterCopy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        taskName = try container.decodeIfPresent(String.self, forKey: .taskName) ?? "未命名任务"
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt) ?? Date()
        sourceRoots = try container.decodeIfPresent([String].self, forKey: .sourceRoots) ?? []
        destination = try container.decodeIfPresent(String.self, forKey: .destination) ?? ""
        algorithm = try container.decodeIfPresent(CheckAlgorithm.self, forKey: .algorithm) ?? .none
        conflictPolicy = try container.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy) ?? .overwrite
        verifyAfterCopy = try container.decodeIfPresent(Bool.self, forKey: .verifyAfterCopy) ?? false

        totalFiles = try container.decodeIfPresent(Int.self, forKey: .totalFiles) ?? 0
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        copiedFiles = try container.decodeIfPresent(Int.self, forKey: .copiedFiles) ?? 0
        copiedBytes = try container.decodeIfPresent(Int64.self, forKey: .copiedBytes) ?? 0
        skippedFiles = try container.decodeIfPresent(Int.self, forKey: .skippedFiles) ?? 0
        failedFiles = try container.decodeIfPresent(Int.self, forKey: .failedFiles) ?? 0
        verifiedFiles = try container.decodeIfPresent(Int.self, forKey: .verifiedFiles) ?? 0
        verifyFailedFiles = try container.decodeIfPresent(Int.self, forKey: .verifyFailedFiles) ?? 0
        cancelled = try container.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        peakBytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .peakBytesPerSecond) ?? 0
        taskKind = try container.decodeIfPresent(TaskKind.self, forKey: .taskKind)

        transcodeEnabled = try container.decodeIfPresent(Bool.self, forKey: .transcodeEnabled) ?? false
        transcodePresetName = try container.decodeIfPresent(String.self, forKey: .transcodePresetName)
        transcodedFiles = try container.decodeIfPresent(Int.self, forKey: .transcodedFiles) ?? 0
        transcodeSkippedFiles = try container.decodeIfPresent(Int.self, forKey: .transcodeSkippedFiles) ?? 0
        transcodeFailedFiles = try container.decodeIfPresent(Int.self, forKey: .transcodeFailedFiles) ?? 0
        transcodeInputBytes = try container.decodeIfPresent(Int64.self, forKey: .transcodeInputBytes) ?? 0
        transcodeOutputBytes = try container.decodeIfPresent(Int64.self, forKey: .transcodeOutputBytes) ?? 0
        transcodeDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .transcodeDuration) ?? 0
        transcodeHardwareFiles = try container.decodeIfPresent(Int.self, forKey: .transcodeHardwareFiles) ?? 0
        transcodeRemovedOriginals = try container.decodeIfPresent(Int.self, forKey: .transcodeRemovedOriginals) ?? 0
        transcodeNote = try container.decodeIfPresent(String.self, forKey: .transcodeNote)

        presetID = try container.decodeIfPresent(String.self, forKey: .presetID)
        filteredOutFiles = try container.decodeIfPresent(Int.self, forKey: .filteredOutFiles) ?? 0
        renamedFiles = try container.decodeIfPresent(Int.self, forKey: .renamedFiles) ?? 0
        photoFiles = try container.decodeIfPresent(Int.self, forKey: .photoFiles) ?? 0
        videoFiles = try container.decodeIfPresent(Int.self, forKey: .videoFiles) ?? 0
        captureMetadataFiles = try container.decodeIfPresent(Int.self, forKey: .captureMetadataFiles) ?? 0
        captureFallbackFiles = try container.decodeIfPresent(Int.self, forKey: .captureFallbackFiles) ?? 0
        captureEarliest = try container.decodeIfPresent(Date.self, forKey: .captureEarliest)
        captureLatest = try container.decodeIfPresent(Date.self, forKey: .captureLatest)
        mediaFolderCounts = try container.decodeIfPresent([String: Int].self, forKey: .mediaFolderCounts) ?? [:]
        deviceCounts = try container.decodeIfPresent([String: Int].self, forKey: .deviceCounts) ?? [:]

        records = try container.decodeIfPresent([FileRecord].self, forKey: .records) ?? []
        truncatedRecordCount = try container.decodeIfPresent(Int.self, forKey: .truncatedRecordCount) ?? 0
    }

    var elapsed: TimeInterval {
        finishedAt.timeIntervalSince(startedAt)
    }

    var averageBytesPerSecond: Double {
        elapsed > 0 ? Double(copiedBytes) / elapsed : 0
    }

    var success: Bool {
        failedFiles == 0 && verifyFailedFiles == 0 && transcodeFailedFiles == 0 && !cancelled
    }

    var failures: [FileRecord] { records.filter { $0.status == .failed } }
    var mismatches: [FileRecord] { records.filter { $0.status == .verifyFailed } }

    // MARK: 归档派生指标

    var preset: CopyPreset { presetID.flatMap(CopyPreset.init(rawValue:)) ?? .everything }

    /// 是否为照片/视频归档任务。
    var isMediaArchive: Bool { preset == .media }

    /// 素材时间范围描述，例如 `2024-03-01 ~ 2024-04-20`。
    var captureRangeText: String? {
        guard let earliest = captureEarliest, let latest = captureLatest else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if Calendar.current.isDate(earliest, inSameDayAs: latest) {
            return formatter.string(from: earliest)
        }
        return "\(formatter.string(from: earliest)) ~ \(formatter.string(from: latest))"
    }

    /// 归档目录计数按文件数降序，便于报告与界面直接展示。
    var mediaFolderRanking: [(folder: String, count: Int)] {
        mediaFolderCounts
            .map { (folder: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.folder < rhs.folder
            }
    }

    /// 设备分布按文件数降序。
    var deviceRanking: [(device: String, count: Int)] {
        deviceCounts
            .map { (device: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.device < rhs.device
            }
    }

    /// 本次任务是否实际按设备分层。
    var classifiedByDevice: Bool { !deviceCounts.isEmpty }

    // MARK: 转码派生指标

    var transcodeResults: [FileRecord] { records.filter { $0.transcode != nil } }
    var transcodeSuccesses: [FileRecord] { records.filter { $0.transcode?.status == .succeeded } }
    var transcodeSkipped: [FileRecord] { records.filter { $0.transcode?.status == .skipped } }
    var transcodeFailures: [FileRecord] { records.filter { $0.transcode?.status == .failed } }

    /// 转码节省的字节数。
    var transcodeSavedBytes: Int64 { max(0, transcodeInputBytes - transcodeOutputBytes) }

    /// 输出体积相对输入的占比。
    var transcodeCompressionRatio: Double {
        transcodeInputBytes > 0 ? Double(transcodeOutputBytes) / Double(transcodeInputBytes) : 0
    }

    /// 转码阶段整体吞吐（字节/秒，按输出计）。
    var transcodeAverageBytesPerSecond: Double {
        transcodeDuration > 0 ? Double(transcodeOutputBytes) / transcodeDuration : 0
    }

    /// 转码阶段是否产出了可展示的结果。
    var hasTranscodeResults: Bool { transcodeEnabled && transcodeResults.isEmpty == false }

    /// 是否来自独立的转码任务（不含拷贝阶段）。
    /// 报告摘要、详情页与 PDF 导出据此切换展示口径。
    var isTranscodeTask: Bool { taskKind == .transcode }

    // MARK: 结局口径
    //
    // 计数不变量（见 `TaskRunner.append`）：`.verifyFailed` 同时计入 `copiedFiles`
    // 与 `failedFiles`（`isProblem` 含校验不一致），所以这两个数都**包含**
    // `verifyFailedFiles`。任何把「失败」与「校验不一致」并列展示的位置，
    // 都必须先扣除校验不一致，否则各卡片加总会超过「计划文件数」。

    /// 纯「读取或写入错误」的文件数（已扣除校验不一致）。
    /// 与 `PDFReportRenderer.outcomeSegments` 使用同一口径。
    var readWriteFailedFiles: Int { max(0, failedFiles - verifyFailedFiles) }

    /// 真正成功写入目标且未落入校验不一致的文件数（已扣除校验不一致）。
    /// 「已拷贝」原始值含校验不一致，单列该段时必须扣除，才能与其他段互斥且加总等于计划数。
    var succeededCopyFiles: Int { max(0, copiedFiles - verifyFailedFiles) }

    var summaryLine: String {
        if isTranscodeTask {
            let result = success ? "全部完成" : (cancelled ? "已取消" : "存在异常")
            var text = "\(result)：转码 \(transcodedFiles) 个视频，跳过 \(transcodeSkippedFiles)，失败 \(transcodeFailedFiles)"
            if transcodeOutputBytes > 0 {
                text += "，输出 \(Format.bytes(transcodeOutputBytes))"
            }
            return text
        }
        let result = success ? "全部完成" : (cancelled ? "已取消" : "存在异常")
        var text = "\(result)：拷贝 \(copiedFiles) 个文件，跳过 \(skippedFiles)，失败 \(readWriteFailedFiles)，校验不一致 \(verifyFailedFiles)"
        if isMediaArchive && filteredOutFiles > 0 {
            text += "；已排除 \(filteredOutFiles) 个非照片/视频文件"
        }
        if transcodeEnabled {
            text += "；转码 \(transcodedFiles) 个"
            if transcodeFailedFiles > 0 { text += "，转码失败 \(transcodeFailedFiles)" }
            if transcodeSkippedFiles > 0 { text += "，跳过 \(transcodeSkippedFiles)" }
        }
        return text
    }
}

// MARK: - 计划条目

/// 规划阶段产出的单文件计划项。
struct FilePlanItem: Sendable {
    let sourcePath: String
    /// 目标目录内的相对路径。
    ///
    /// 「文件拷贝」下它是「来源根名 + 原有子路径」；「媒体拷贝」下它是
    /// 归档重组后的路径（例如 `Photos/iPhone 15 Pro/2024/03/15/20240315_143022.jpg`），
    /// 两种情形都与目标目录结构一一对应，因此校验清单可直接使用。
    let relativePath: String
    let destinationPath: String
    let size: Int64
    /// 源条目本身是符号链接（仅在「按链接拷贝」模式下为 true）
    let isSymlink: Bool
    /// 符号链接的指向，仅当 isSymlink 为 true 时有值
    let linkTarget: String?
    /// 归档所用的拍摄时间（仅媒体预设）
    let captureDate: Date?
    /// 拍摄时间的来源（仅媒体预设）
    let captureSource: CaptureTimeSource?
    /// 媒体类型（仅媒体预设）
    let mediaKind: MediaKind?
    /// 归档时使用的设备目录名（仅媒体预设且启用设备分类时）
    let deviceModel: String?
    /// 归档前的原始文件名（仅媒体预设且发生重命名时）
    let originalName: String?

    init(sourcePath: String,
         relativePath: String,
         destinationPath: String,
         size: Int64,
         isSymlink: Bool = false,
         linkTarget: String? = nil,
         captureDate: Date? = nil,
         captureSource: CaptureTimeSource? = nil,
         mediaKind: MediaKind? = nil,
         deviceModel: String? = nil,
         originalName: String? = nil) {
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.destinationPath = destinationPath
        self.size = size
        self.isSymlink = isSymlink
        self.linkTarget = linkTarget
        self.captureDate = captureDate
        self.captureSource = captureSource
        self.mediaKind = mediaKind
        self.deviceModel = deviceModel
        self.originalName = originalName
    }
}
