import Foundation
import AVFoundation
import VideoToolbox

// MARK: - 硬件能力探测

enum VideoCapability {

    struct EncoderInfo: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let codec: String
        let isHardwareAccelerated: Bool
    }

    /// 枚举系统注册的全部视频编码器。
    ///
    /// 这是判断本机 VideoToolbox 硬件编码可用性的权威来源——只有出现在此列表中
    /// 且 `isHardwareAccelerated == true` 的编码器才真正走硬件通路。
    ///
    /// 结果进程内缓存：该调用会构造整个编码器列表，而界面在每次重绘时都会查询它。
    static func availableEncoders() -> [EncoderInfo] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let list = queryEncoders()
        cached = list
        return list
    }

    private static let lock = NSLock()
    private static var cached: [EncoderInfo]?

    private static func queryEncoders() -> [EncoderInfo] {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr,
              let entries = list as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry -> EncoderInfo? in
            let name = (entry[kVTVideoEncoderList_CodecName as String] as? String)
                ?? (entry[kVTVideoEncoderList_EncoderName as String] as? String)
                ?? "未知编码器"
            let identifier = (entry[kVTVideoEncoderList_EncoderID as String] as? String) ?? name
            let hardware = (entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) ?? false
            return EncoderInfo(
                id: identifier,
                name: name,
                codec: fourCC(from: entry[kVTVideoEncoderList_CodecType as String]),
                isHardwareAccelerated: hardware
            )
        }
        .sorted { lhs, rhs in
            if lhs.isHardwareAccelerated != rhs.isHardwareAccelerated {
                return lhs.isHardwareAccelerated
            }
            return lhs.name < rhs.name
        }
    }

    /// VideoToolbox 的 `CodecType` 是 FourCC 的数值形式而非字符串，
    /// 例如 `1635148593 == 0x61766331 == "avc1"`。少数条目以字符串给出，两种都要兼容。
    private static func fourCC(from value: Any?) -> String {
        if let text = value as? String { return text }
        guard let number = value as? NSNumber else { return "" }

        let raw = number.uint32Value
        let bytes: [UInt8] = [
            UInt8((raw >> 24) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8(raw & 0xFF)
        ]
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "" }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// 是否存在可用的硬件编码通路。FourCC 不可用时回退到名称匹配。
    static func hasHardwareEncoder(for codec: TranscodeVideoCodec) -> Bool {
        guard let hint = codec.hardwareNameHint else { return false }

        return availableEncoders().contains { encoder in
            guard encoder.isHardwareAccelerated else { return false }
            return encoder.name.lowercased().contains(hint)
        }
    }
}

// MARK: - FFmpeg 定位

/// FFmpeg 与 ffprobe 的定位器。
///
/// 采用硬编码候选路径而非搜索 `PATH`：从访达启动的 GUI 应用不继承登录 shell 的
/// 环境变量，`PATH` 里既没有 `/opt/homebrew/bin` 也没有用户自建目录。
enum FFmpegLocator {

    static let overrideDefaultsKey = "FFmpegPathOverride"

    /// 用户在设置页手动指定的 ffmpeg 路径。
    static var overridePath: String? {
        get { UserDefaults.standard.string(forKey: overrideDefaultsKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: overrideDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: overrideDefaultsKey)
            }
            // 换了解释器，之前缓存的编码器清单与探测结果随即失效。
            FFmpegCapability.invalidate()
            invalidateProbe()
        }
    }

    static let candidatePaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]

    static let candidateProbePaths = [
        "/opt/homebrew/bin/ffprobe",
        "/usr/local/bin/ffprobe",
        "/opt/local/bin/ffprobe",
        "/usr/bin/ffprobe"
    ]

    static func locate() -> URL? {
        let fm = FileManager.default

        if let overridePath, fm.isExecutableFile(atPath: overridePath) {
            return URL(fileURLWithPath: overridePath)
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg") {
            return bundled
        }
        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// 定位 ffprobe。优先取与 ffmpeg 同目录的版本，避免两套构建版本不一致导致解析差异。
    static func locateProbe(alongside ffmpeg: URL? = nil) -> URL? {
        let fm = FileManager.default

        if let ffmpeg {
            let sibling = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
            if fm.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffprobe") {
            return bundled
        }
        for path in candidateProbePaths where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var isAvailable: Bool { locate() != nil }

    /// FFmpeg 探测结果（可执行文件路径 + 版本号）。
    struct Probe: Sendable, Equatable {
        var path: String?
        var version: String?
    }

    private static let probeLock = NSLock()
    private static var cachedProbe: Probe?

    /// 探测 FFmpeg 路径与版本，结果带缓存。
    ///
    /// 每次表单出现都重新 fork `ffmpeg -version` 代价明显（切换详情页分区、
    /// 每次打开设置都会触发），而解释器在进程内基本不变，因此缓存首次结果。
    /// - Parameter refresh: 传 `true` 强制重新探测。
    static func probe(refresh: Bool = false) -> Probe {
        probeLock.lock()
        if !refresh, let cachedProbe {
            probeLock.unlock()
            return cachedProbe
        }
        probeLock.unlock()

        let resolved: Probe
        if let url = locate() {
            resolved = Probe(path: url.path, version: version(of: url))
        } else {
            resolved = Probe(path: nil, version: nil)
        }

        probeLock.lock()
        cachedProbe = resolved
        probeLock.unlock()
        return resolved
    }

    /// 清除探测缓存。更换解释器路径后必须调用，否则界面会一直显示旧版本。
    static func invalidateProbe() {
        probeLock.lock()
        cachedProbe = nil
        probeLock.unlock()
    }

    /// 读取 `ffmpeg -version` 首行中的版本号。
    static func version(of executable: URL) -> String? {
        let text = FFmpegRunner.capture(executable: executable, arguments: ["-version"], timeout: 10)
        guard let firstLine = text.split(separator: "\n").first else { return nil }
        // 形如 `ffmpeg version 9.0 Copyright (c) 2000-2025 the FFmpeg developers`
        let parts = firstLine.split(separator: " ")
        if parts.count >= 3, parts[0] == "ffmpeg", parts[1] == "version" {
            return String(parts[2])
        }
        return nil
    }
}

// MARK: - 转码计划

enum TranscodeError: LocalizedError {
    case ffmpegMissing
    case probeMissing
    case unsupportedCodec(String)
    case incompatibleContainer(String, String)
    case outputInvalid(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            return "未找到 FFmpeg，请在设置中指定其路径后再启用转码。"
        case .probeMissing:
            return "未找到 ffprobe，无法读取素材信息。它通常与 FFmpeg 位于同一目录。"
        case .unsupportedCodec(let name):
            return "当前 FFmpeg 构建缺少可用的 \(name) 编码器。"
        case .incompatibleContainer(let codec, let container):
            return "\(codec) 无法写入 \(container) 容器，请改为 MOV 或 MKV。"
        case .outputInvalid(let reason):
            return "转码输出校验失败：\(reason)"
        }
    }
}

/// 由预设解析出的、可直接翻译成 FFmpeg 命令行的一次转码方案。
struct TranscodePlan {
    let preset: TranscodePreset
    let container: TranscodeContainer
    /// nil 表示码流直通（不重新编码视频）
    let videoEncoder: String?
    let audioMode: TranscodeAudioMode
    let usesHardware: Bool
    let scaleFilter: String?

    var isVideoCopy: Bool { videoEncoder == nil }

    /// 人类可读的执行摘要，用于界面提示与报告。
    var pipelineDescription: String {
        var parts: [String] = []
        if preset.isAudioOnly {
            parts.append("仅音轨")
        } else if isVideoCopy {
            parts.append("视频直通")
        } else {
            parts.append("视频 \(preset.videoCodec.shortName)")
        }
        if let videoEncoder {
            parts.append(usesHardware ? "硬件加速 \(videoEncoder)" : "软件编码 \(videoEncoder)")
        }
        if scaleFilter != nil {
            parts.append(preset.resolutionText)
        }
        parts.append("音频 \(audioMode.displayName)")
        return parts.joined(separator: " · ")
    }

    /// 生成长边上限的缩放滤镜。
    ///
    /// 双分支表达式而非固定宽高：横屏素材限制宽度、竖屏素材限制高度，
    /// 且两端都取 `min(原尺寸, 上限)`，因此**小素材不会被放大**。
    /// 表达式内的逗号由单引号保护，FFmpeg 的滤镜图解析器会将其视为字面量。
    static func scaleFilter(maxLongEdge: Int?) -> String? {
        guard let edge = maxLongEdge else { return nil }
        return "scale=w='if(gt(iw,ih),min(iw,\(edge)),-2)':h='if(gt(iw,ih),-2,min(ih,\(edge)))'"
    }

    /// 解析出实际可执行的方案。
    static func resolve(settings: TranscodeSettings, ffmpeg: URL) throws -> TranscodePlan {
        let preset = settings.preset
        let available = FFmpegCapability.encoders(of: ffmpeg)

        if preset.videoCodec == .prores && !preset.container.supportsProRes {
            throw TranscodeError.incompatibleContainer("ProRes", preset.container.displayName)
        }

        var videoEncoder: String?
        var usesHardware = false

        if preset.videoCodec.isReencode {
            let hardware = preset.videoCodec.hardwareEncoder
            let software = preset.videoCodec.softwareEncoder

            if settings.preferHardwareAcceleration, let hardware, available.contains(hardware) {
                videoEncoder = hardware
                usesHardware = true
            } else if let software, available.contains(software) {
                videoEncoder = software
            } else {
                throw TranscodeError.unsupportedCodec(preset.videoCodec.displayName)
            }
        }

        return TranscodePlan(
            preset: preset,
            container: preset.container,
            videoEncoder: videoEncoder,
            audioMode: preset.audioMode,
            usesHardware: usesHardware,
            scaleFilter: preset.isAudioOnly ? nil : scaleFilter(maxLongEdge: preset.maxLongEdge)
        )
    }

    /// 拼装完整的 FFmpeg 参数列表。
    ///
    /// - Parameter forceAudioReencode: 码流直通失败后的兜底重试标记，
    ///   把音轨直通改为 AAC 重新编码（典型场景是 PCM 音轨无法封装进 MP4）。
    func arguments(input: URL, output: URL, forceAudioReencode: Bool = false) -> [String] {
        var args: [String] = [
            "-y",
            "-hide_banner",
            "-nostdin",
            "-loglevel", "error",
            "-nostats",
            "-progress", "pipe:1"
        ]

        args += ["-i", input.path]

        if preset.isAudioOnly {
            // `?` 让缺失音轨时退化为空映射而不是直接报错，便于给出更准确的提示。
            args += ["-vn", "-map", "0:a:0?"]
        } else if let videoEncoder {
            args += ["-c:v", videoEncoder]
            if let bitRate = preset.videoBitRate {
                args += ["-b:v", String(bitRate)]
                args += ["-maxrate", String(Int(Double(bitRate) * 1.35))]
                args += ["-bufsize", String(bitRate * 2)]
            }
            if let scaleFilter {
                args += ["-vf", scaleFilter]
            }
            // ProRes 硬件编码器自行决定像素格式，显式指定可能导致初始化失败。
            if let pixelFormat = preset.pixelFormat, !(preset.videoCodec == .prores && usesHardware) {
                args += ["-pix_fmt", pixelFormat]
            }
            if let tag = preset.videoCodec.containerTag, container.supportsFastStart {
                args += ["-tag:v", tag]
            }
        } else {
            args += ["-c:v", "copy"]
        }

        if !preset.isAudioOnly {
            let effectiveAudio = forceAudioReencode ? audioMode.containerFriendlyFallback : audioMode
            args += effectiveAudio.encoderArguments
        } else {
            args += audioMode.encoderArguments
        }

        // 转码会丢失部分原始元数据（拍摄时间、机型），显式复制格式级元数据回来。
        args += ["-map_metadata", "0"]

        if container.supportsFastStart {
            args += ["-movflags", "+faststart"]
        }

        args.append(output.path)
        return args
    }
}

// MARK: - 转码执行编排

/// 单个文件的转码编排：探测、执行、输出复核、体积保护与原始文件处置。
enum TranscodeEngine {

    /// 该文件是否需要进入转码阶段。
    ///
    /// 只做零成本的静态判断（状态、扩展名、体积阈值），真正的「是不是视频」
    /// 交给 ffprobe 判定——扩展名与实际内容不一致的素材相当常见。
    /// `planned` 仅出现在独立转码任务中：输入记录就是来源里的原始视频。
    static func isCandidate(record: FileRecord, settings: TranscodeSettings) -> Bool {
        guard settings.enabled else { return false }
        guard record.status == .copied || record.status == .verified || record.status == .planned
        else { return false }
        guard VideoFileTypes.isVideo(record.destinationPath) else { return false }
        if settings.skipFilesSmallerThanMB > 0 {
            let threshold = Int64(settings.skipFilesSmallerThanMB) * 1024 * 1024
            if record.size < threshold { return false }
        }
        return true
    }

    /// 执行单文件转码。任何失败都收敛为一个 `TranscodeOutcome`，绝不抛出——
    /// 转码失败不应中断整个批次，也不能污染已完成的拷贝结果。
    ///
    /// - Parameter outputDirectory: 输出目录。`nil` 表示与输入文件同目录
    ///   （拷贝后转码的默认行为）；独立转码任务传入任务的目标目录。
    static func process(record: FileRecord,
                        settings: TranscodeSettings,
                        cancellation: Cancellation,
                        outputDirectory: String? = nil,
                        progress: @escaping (TranscodeProgress) -> Void) -> TranscodeOutcome {
        let preset = settings.preset
        let fm = FileManager.default

        var outcome = TranscodeOutcome(status: .skipped,
                                       presetID: preset.id,
                                       presetName: preset.name,
                                       inputBytes: record.size)

        let inputURL = URL(fileURLWithPath: record.destinationPath)
        guard fm.fileExists(atPath: inputURL.path) else {
            outcome.status = .failed
            outcome.message = "拷贝后的文件不存在，无法转码"
            return outcome
        }

        guard let ffmpeg = FFmpegLocator.locate() else {
            outcome.status = .failed
            outcome.message = TranscodeError.ffmpegMissing.errorDescription
            return outcome
        }

        let plan: TranscodePlan
        do {
            plan = try TranscodePlan.resolve(settings: settings, ffmpeg: ffmpeg)
        } catch {
            outcome.status = .failed
            outcome.message = error.localizedDescription
            return outcome
        }

        // 默认输出与输入同目录，文件名带预设后缀，避免覆盖原始素材；
        // 独立转码任务则统一输出到任务的目标目录。
        let directory: URL
        if let outputDirectory {
            let target = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } catch {
                outcome.status = .failed
                outcome.message = "无法创建输出目录：\(error.localizedDescription)"
                return outcome
            }
            directory = target
        } else {
            directory = inputURL.deletingLastPathComponent()
        }
        let baseName = inputURL.deletingPathExtension().lastPathComponent
        var outputURL = directory
            .appendingPathComponent("\(baseName)_\(preset.outputSuffix)")
            .appendingPathExtension(container: plan.container)
        if fm.fileExists(atPath: outputURL.path) {
            outputURL = URL(fileURLWithPath: ConflictResolver.uniquePath(for: outputURL.path))
        }

        guard let probe = FFmpegLocator.locateProbe(alongside: ffmpeg) else {
            outcome.status = .failed
            outcome.message = TranscodeError.probeMissing.errorDescription
            return outcome
        }

        let info = FFmpegProbe.inspect(inputURL, executable: probe)
        if let info {
            if preset.isAudioOnly {
                guard info.hasAudio else {
                    outcome.message = "素材不含音频轨道，无法提取音频"
                    return outcome
                }
            } else {
                guard info.hasVideo else {
                    outcome.message = "素材不含视频轨道，已跳过"
                    return outcome
                }
            }
        } else {
            // 探测失败不阻断转码，但要如实标注，避免用户以为一切正常。
            outcome.message = "无法预读素材信息，转码已按默认参数执行"
        }

        if cancellation.isCancelled {
            outcome.message = "任务取消，未执行转码"
            return outcome
        }

        let startedAt = Date()
        var usedFallback = false
        var diagnostics = ""

        do {
            var result = try FFmpegRunner.run(
                executable: ffmpeg,
                arguments: plan.arguments(input: inputURL, output: outputURL),
                expectedDuration: info?.duration,
                cancellation: cancellation,
                onProgress: progress
            )

            // 码流直通最常见的中断原因是原始音轨无法封装进目标容器
            // （例如 MOV 里的 PCM 音轨写不进 MP4）。此时只重编音轨再试一次，
            // 视频码流仍然直通，既解决问题又不引入画质损失。
            if result.code != 0, plan.isVideoCopy, !plan.preset.isAudioOnly, plan.audioMode == .copy {
                try? fm.removeItem(atPath: outputURL.path)
                usedFallback = true
                diagnostics = result.diagnostics
                result = try FFmpegRunner.run(
                    executable: ffmpeg,
                    arguments: plan.arguments(input: inputURL, output: outputURL, forceAudioReencode: true),
                    expectedDuration: info?.duration,
                    cancellation: cancellation,
                    onProgress: progress
                )
            }

            outcome.duration = Date().timeIntervalSince(startedAt)
            outcome.usedFallback = usedFallback

            guard result.code == 0 else {
                try? fm.removeItem(atPath: outputURL.path)
                outcome.status = .failed
                outcome.message = "FFmpeg 退出码 \(result.code)：\(condense(result.diagnostics))"
                return outcome
            }
        } catch is OperationCancelled {
            outcome.usedFallback = usedFallback
            outcome.duration = Date().timeIntervalSince(startedAt)
            try? fm.removeItem(atPath: outputURL.path)
            outcome.message = "任务取消，未完成转码"
            return outcome
        } catch let error as FFmpegRunner.RunnerError {
            outcome.duration = Date().timeIntervalSince(startedAt)
            outcome.usedFallback = usedFallback
            if case .cancelled = error {
                try? fm.removeItem(atPath: outputURL.path)
                outcome.message = "任务取消，未完成转码"
                return outcome
            }
            try? fm.removeItem(atPath: outputURL.path)
            outcome.status = .failed
            var text = error.localizedDescription
            if usedFallback, !diagnostics.isEmpty {
                text += "；首次尝试：\(condense(diagnostics))"
            }
            outcome.message = text
            return outcome
        } catch {
            outcome.duration = Date().timeIntervalSince(startedAt)
            try? fm.removeItem(atPath: outputURL.path)
            outcome.status = .failed
            outcome.message = error.localizedDescription
            return outcome
        }

        // 输出复核：仅凭退出码为 0 不足以下结论，必须确认产物可读且含预期的轨道。
        let producedBytes = fileSize(of: outputURL)
        outcome.outputPath = outputURL.path
        outcome.outputBytes = producedBytes
        outcome.usedHardware = plan.usesHardware

        let outputInfo = FFmpegProbe.inspect(outputURL, executable: probe)
        outcome.videoCodec = outputInfo?.videoCodec
        outcome.audioCodec = outputInfo?.audioCodec
        outcome.width = outputInfo?.width ?? 0
        outcome.height = outputInfo?.height ?? 0

        guard producedBytes > 0 else {
            try? fm.removeItem(atPath: outputURL.path)
            outcome.status = .failed
            outcome.outputPath = nil
            outcome.outputBytes = 0
            outcome.message = "转码输出为空文件，已删除"
            return outcome
        }

        if let outputInfo, !preset.isAudioOnly, !outputInfo.hasVideo {
            try? fm.removeItem(atPath: outputURL.path)
            outcome.status = .failed
            outcome.outputPath = nil
            outcome.outputBytes = 0
            outcome.message = "转码输出不含视频轨道，已删除"
            return outcome
        }

        if let inputDuration = info?.duration, inputDuration > 0, outcome.duration > 0 {
            outcome.speed = inputDuration / outcome.duration
        }

        // 体积保护：压缩类预设若产出反而更大，说明该素材已高度压缩，
        // 保留原文件才是正确选择，此时删除输出并如实标注。
        if preset.isCompression, settings.discardOutputIfLarger,
           outcome.inputBytes > 0, producedBytes >= outcome.inputBytes {
            try? fm.removeItem(atPath: outputURL.path)
            outcome.status = .skipped
            outcome.outputPath = nil
            outcome.outputBytes = 0
            outcome.message = "压缩后体积未减小（\(Format.bytes(outcome.inputBytes)) → \(Format.bytes(producedBytes))），已丢弃输出并保留原文件"
            return outcome
        }

        outcome.status = .succeeded

        if settings.removeSourceAfterSuccess {
            do {
                try fm.removeItem(at: inputURL)
                outcome.removedOriginal = true
            } catch {
                outcome.removedOriginal = false
                outcome.message = "转码成功，但删除原始文件失败：\(error.localizedDescription)"
            }
        }

        if usedFallback {
            let note = "原音轨无法封装进 \(plan.container.displayName)，已改为重新编码音轨（视频仍为直通）"
            outcome.message = outcome.message.map { "\($0)；\(note)" } ?? note
        }

        return outcome
    }

    // MARK: - 工具

    private static func fileSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// FFmpeg 的错误输出可能很长，仅保留最关键的一行用于展示。
    private static func condense(_ diagnostics: String) -> String {
        let lines = diagnostics
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return "无错误输出" }
        return last.count > 300 ? String(last.prefix(300)) + "…" : last
    }
}

private extension URL {
    /// `appendingPathExtension` 的同义封装，便于在链式表达式中使用枚举值。
    func appendingPathExtension(container: TranscodeContainer) -> URL {
        appendingPathExtension(container.fileExtension)
    }
}
