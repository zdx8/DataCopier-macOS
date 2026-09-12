import Foundation

// MARK: - 目标视频编码

/// 转码后的视频编码格式。
enum TranscodeVideoCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case copy
    case h264
    case hevc
    case prores

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copy: return "不重新编码（码流直通）"
        case .h264: return "H.264 / AVC"
        case .hevc: return "H.265 / HEVC"
        case .prores: return "Apple ProRes"
        }
    }

    var shortName: String {
        switch self {
        case .copy: return "copy"
        case .h264: return "H.264"
        case .hevc: return "H.265"
        case .prores: return "ProRes"
        }
    }

    var isReencode: Bool { self != .copy }

    /// FFmpeg 中对应的 VideoToolbox 硬件编码器。ProRes 的硬件通路仅在部分 Apple Silicon 上提供。
    var hardwareEncoder: String? {
        switch self {
        case .copy: return nil
        case .h264: return "h264_videotoolbox"
        case .hevc: return "hevc_videotoolbox"
        case .prores: return "prores_videotoolbox"
        }
    }

    /// 硬件不可用时的软件编码器。
    var softwareEncoder: String? {
        switch self {
        case .copy: return nil
        case .h264: return "libx264"
        case .hevc: return "libx265"
        case .prores: return "prores_ks"
        }
    }

    /// 写入 MP4/MOV 的 FourCC 标记。
    ///
    /// HEVC 在 MP4 中需要显式标记为 `hvc1`，否则 QuickTime 与「照片」等
    /// 系统应用可能只识别为带内参数集格式而拒绝播放。
    var containerTag: String? {
        self == .hevc ? "hvc1" : nil
    }

    /// 在 VideoToolbox 编码器列表里用于名称匹配的线索。
    var hardwareNameHint: String? {
        switch self {
        case .copy: return nil
        case .h264: return "h.264"
        case .hevc: return "hevc"
        case .prores: return "prores"
        }
    }

    /// 是否属于有损压缩编码（用于体积保护判断）。
    var isCompression: Bool {
        self == .h264 || self == .hevc
    }
}

// MARK: - 音频处理

enum TranscodeAudioMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case copy
    case aac128
    case aac192
    case strip

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copy: return "保持原音轨"
        case .aac128: return "AAC 128 kbps"
        case .aac192: return "AAC 192 kbps"
        case .strip: return "移除音轨"
        }
    }

    var isStrip: Bool { self == .strip }

    /// FFmpeg 音频参数。`copy` 返回直通参数。
    var encoderArguments: [String] {
        switch self {
        case .copy: return ["-c:a", "copy"]
        case .aac128: return ["-c:a", "aac", "-b:a", "128k", "-ac", "2"]
        case .aac192: return ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
        case .strip: return ["-an"]
        }
    }

    /// 直通音轨在目标容器中不被支持时的回退方案。
    var containerFriendlyFallback: TranscodeAudioMode {
        self == .copy ? .aac192 : self
    }
}

// MARK: - 容器

enum TranscodeContainer: String, Codable, CaseIterable, Identifiable, Sendable {
    case mp4
    case mov
    case mkv
    case m4a

    var id: String { rawValue }
    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .mkv: return "MKV"
        case .m4a: return "M4A"
        }
    }

    /// MP4 / MOV 需要把索引前置，否则流式播放要等到整个文件下载完。
    var supportsFastStart: Bool { self == .mp4 || self == .mov }

    /// 该容器能否承载 ProRes 编码。
    var supportsProRes: Bool { self == .mov || self == .mkv }
}

// MARK: - 转码预设

/// 一套可复用的转码参数。
///
/// 预设统一以**目标码率**而非恒定质量因子描述画质，原因有两点：
/// 一是输出体积可预期——对以容量规划为目的的数据拷贝工具，这一点比极致画质更重要；
/// 二是硬件与软件两条编码路径对码率参数的解释一致，回退时行为不会突变。
struct TranscodePreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let videoCodec: TranscodeVideoCodec
    /// 长边上限（像素）；nil 表示保持原始分辨率
    ///
    /// 按长边而非高度限制，是为了让竖屏素材（手机拍摄）与横屏素材得到同等对待：
    /// 若按高度限制，2160×3840 的竖屏视频会被压到 1215×2160，而横屏 3840×2160
    /// 只压到 1920×1080，两者观感差异很大。
    let maxLongEdge: Int?
    /// 分辨率档位的展示名，例如 `1080p`
    let resolutionLabel: String
    /// 目标视频码率（bit/s）；码流直通时为 nil
    let videoBitRate: Int?
    let audioMode: TranscodeAudioMode
    let container: TranscodeContainer
    /// 长宽方向的像素格式（ProRes 需要 10bit 422）
    let pixelFormat: String?
    /// 是否参与「输出未变小则保留原文件」的保护判断
    let isCompression: Bool
    /// 仅提取音轨，不输出视频
    let isAudioOnly: Bool

    /// 用于输出文件名，例如 `clip_h265-1080p.mp4`
    var outputSuffix: String { id }

    /// 画质与体积的经验区间描述，仅用于界面提示。
    var estimatedSizeText: String {
        switch id {
        case "remux": return "体积基本不变"
        case "hevc-1080p": return "约为原片 20–35%"
        case "h264-1080p": return "约为原片 35–50%"
        case "h264-720p": return "约为原片 10–20%"
        case "hevc-original": return "约为原片 35–55%"
        case "prores-422": return "约为原片 150–300%"
        case "audio-aac": return "按音轨时长计算"
        default: return "取决于参数"
        }
    }

    var resolutionText: String {
        if isAudioOnly { return "无视频" }
        guard let edge = maxLongEdge else { return "保持原始" }
        return "长边上限 \(edge)（\(resolutionLabel)）"
    }

    /// 一行式参数摘要，用于界面提示。
    var detailLine: String {
        var parts: [String] = []
        if isAudioOnly {
            parts.append("仅保留音轨")
        } else {
            parts.append(videoCodec.displayName)
            parts.append(resolutionText)
        }
        parts.append("音频 \(audioMode.displayName)")
        parts.append(container.displayName)
        return parts.joined(separator: " · ")
    }
}

enum TranscodePresets {

    static let customID = "custom"

    /// 内置预设目录。顺序即界面展示顺序。
    static let all: [TranscodePreset] = [
        TranscodePreset(
            id: "remux",
            name: "原样重封装",
            summary: "只更换容器为 MP4，码流原样复制，画质与体积不变，速度最快。",
            symbol: "shippingbox",
            videoCodec: .copy,
            maxLongEdge: nil,
            resolutionLabel: "保持原始",
            videoBitRate: nil,
            audioMode: .copy,
            container: .mp4,
            pixelFormat: nil,
            isCompression: false,
            isAudioOnly: false
        ),
        TranscodePreset(
            id: "hevc-1080p",
            name: "H.265 压缩 · 1080p",
            summary: "H.265 硬件编码并限制到 1080p，体积与画质平衡最好，适合长期存档。",
            symbol: "arrow.down.right.and.arrow.up.left",
            videoCodec: .hevc,
            maxLongEdge: 1920,
            resolutionLabel: "1080p",
            videoBitRate: 6_000_000,
            audioMode: .aac128,
            container: .mp4,
            pixelFormat: "yuv420p",
            isCompression: true,
            isAudioOnly: false
        ),
        TranscodePreset(
            id: "h264-1080p",
            name: "H.264 兼容 · 1080p",
            summary: "兼容性最好的编码格式，各类播放器与剪辑软件均可直接使用。",
            symbol: "checkmark.seal",
            videoCodec: .h264,
            maxLongEdge: 1920,
            resolutionLabel: "1080p",
            videoBitRate: 8_000_000,
            audioMode: .aac128,
            container: .mp4,
            pixelFormat: "yuv420p",
            isCompression: true,
            isAudioOnly: false
        ),
        TranscodePreset(
            id: "h264-720p",
            name: "H.264 小体积 · 720p",
            summary: "限制到 720p 并大幅压缩，适合网页嵌入、即时通讯与移动端分享。",
            symbol: "bubble.left.and.bubble.right",
            videoCodec: .h264,
            maxLongEdge: 1280,
            resolutionLabel: "720p",
            videoBitRate: 2_500_000,
            audioMode: .aac128,
            container: .mp4,
            pixelFormat: "yuv420p",
            isCompression: true,
            isAudioOnly: false
        ),
        TranscodePreset(
            id: "hevc-original",
            name: "H.265 压缩 · 保持分辨率",
            summary: "不改变分辨率，仅降低码率，适合保留 4K 及以上素材的清晰度。",
            symbol: "4k.tv",
            videoCodec: .hevc,
            maxLongEdge: nil,
            resolutionLabel: "保持原始",
            videoBitRate: 12_000_000,
            audioMode: .aac192,
            container: .mp4,
            pixelFormat: "yuv420p",
            isCompression: true,
            isAudioOnly: false
        ),
        TranscodePreset(
            id: "prores-422",
            name: "ProRes 422 · 剪辑素材",
            summary: "转换为剪辑友好的中间格式，解码负担低、帧精度好，体积明显增大。",
            symbol: "scissors",
            videoCodec: .prores,
            maxLongEdge: nil,
            resolutionLabel: "保持原始",
            videoBitRate: nil,
            audioMode: .copy,
            container: .mov,
            pixelFormat: "yuv422p10le",
            isCompression: false,
            isAudioOnly: false
        ),
        TranscodePreset(
            id: "audio-aac",
            name: "仅提取音频",
            summary: "丢弃视频轨，仅保留音轨并转为 M4A，适合收录会议录音与现场收音。",
            symbol: "waveform",
            videoCodec: .copy,
            maxLongEdge: nil,
            resolutionLabel: "无视频",
            videoBitRate: nil,
            audioMode: .aac192,
            container: .m4a,
            pixelFormat: nil,
            isCompression: false,
            isAudioOnly: true
        )
    ]

    static func preset(id: String) -> TranscodePreset? {
        all.first { $0.id == id }
    }

    static let `default` = all[1]   // hevc-1080p
}

// MARK: - 用户配置

/// 「自定义」预设对应的可调参数。
struct CustomTranscodeOptions: Codable, Hashable, Sendable {
    var videoCodec: TranscodeVideoCodec = .hevc
    /// 长边上限（像素）；0 表示保持原始分辨率
    var maxLongEdge: Int = 1920
    /// 目标视频码率，单位 Mbps
    var videoBitRateMbps: Double = 6
    var audioMode: TranscodeAudioMode = .aac192
    var container: TranscodeContainer = .mp4

    /// 可选的长边档位，按「横屏等价分辨率」标注，便于理解。
    static let longEdgeChoices: [Int] = [0, 3840, 2560, 1920, 1280, 854]

    static func longEdgeLabel(_ value: Int) -> String {
        switch value {
        case 0: return "保持原始"
        case 3840: return "3840（4K）"
        case 2560: return "2560（1440p）"
        case 1920: return "1920（1080p）"
        case 1280: return "1280（720p）"
        case 854: return "854（480p）"
        default: return "\(value)"
        }
    }

    var resolvedPreset: TranscodePreset {
        let reencoding = videoCodec.isReencode
        // ProRes 无法写入 MP4，自动切换到 MOV，避免生成后才发现容器不兼容。
        let container = (videoCodec == .prores && !self.container.supportsProRes) ? .mov : self.container
        return TranscodePreset(
            id: TranscodePresets.customID,
            name: "自定义参数",
            summary: "按下面的参数执行转码。",
            symbol: "slider.horizontal.3",
            videoCodec: videoCodec,
            maxLongEdge: maxLongEdge == 0 ? nil : maxLongEdge,
            resolutionLabel: maxLongEdge == 0 ? "保持原始" : "\(maxLongEdge)",
            videoBitRate: reencoding ? Int(videoBitRateMbps * 1_000_000) : nil,
            audioMode: audioMode,
            container: container,
            pixelFormat: videoCodec == .prores ? "yuv422p10le" : (reencoding ? "yuv420p" : nil),
            isCompression: videoCodec.isCompression,
            isAudioOnly: false
        )
    }
}

/// 转码阶段的任务级配置。
struct TranscodeSettings: Codable, Hashable, Sendable {
    /// 是否在拷贝完成后执行转码
    var enabled: Bool = false
    /// 选中的预设标识
    var presetID: String = TranscodePresets.default.id
    /// 自定义参数
    var custom: CustomTranscodeOptions = CustomTranscodeOptions()
    /// 优先使用 VideoToolbox 硬件编码，不可用时自动回退到软件编码
    var preferHardwareAcceleration: Bool = true
    /// 转码阶段的并行进程数
    var concurrency: Int = 2
    /// 跳过小于该体积的文件（MB），0 表示不跳过
    var skipFilesSmallerThanMB: Int = 0
    /// 转码成功且校验通过后删除原始拷贝（危险操作，默认关闭）
    var removeSourceAfterSuccess: Bool = false
    /// 压缩类预设输出反而更大时保留原文件
    var discardOutputIfLarger: Bool = true

    static let `default` = TranscodeSettings()

    /// 当前选中的预设（自定义参数即时解析为等价预设）。
    var preset: TranscodePreset {
        if presetID == TranscodePresets.customID { return custom.resolvedPreset }
        return TranscodePresets.preset(id: presetID) ?? TranscodePresets.default
    }

    /// 界面上用于显示的预设名称。
    var presetName: String { preset.name }
}

// MARK: - 视频文件识别

/// 常见视频容器扩展名。仅用于圈定转码候选范围，真正的判定由 ffprobe 完成。
///
/// 刻意不收录 BRAW / R3D / INSV 等厂商私有原始格式：FFmpeg 无法解码它们，
/// 列入候选只会产出必然失败的任务，反过来污染报告的可信度。
enum VideoFileTypes {

    static let extensions: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "avi", "mts", "m2ts", "m2t", "ts",
        "mxf", "webm", "flv", "wmv", "mpg", "mpeg", "mpe", "vob", "ogv",
        "3gp", "3g2", "asf", "dv", "gxf"
    ]

    static func isVideo(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }
}
