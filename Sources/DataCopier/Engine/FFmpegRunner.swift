import Foundation

// MARK: - 媒体信息

/// 由 ffprobe 解析出的素材概要。
struct MediaInfo: Sendable, Equatable {
    var duration: Double = 0
    var hasVideo: Bool = false
    var hasAudio: Bool = false
    var videoCodec: String?
    var audioCodec: String?
    var width: Int = 0
    var height: Int = 0

    var resolutionText: String {
        width > 0 && height > 0 ? "\(width)×\(height)" : "—"
    }
}

// MARK: - ffprobe 探测

enum FFmpegProbe {

    /// 读取素材的时长与流信息。失败时返回 nil（不抛出），调用方据此跳过该文件。
    static func inspect(_ url: URL, executable: URL) -> MediaInfo? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }

        let output = FFmpegRunner.capture(executable: executable, arguments: [
            "-hide_banner", "-v", "error",
            "-show_entries", "format=duration:stream=codec_type,codec_name,width,height",
            "-of", "json", url.path
        ])
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var info = MediaInfo()

        if let format = root["format"] as? [String: Any],
           let durationText = format["duration"] as? String,
           let duration = Double(durationText) {
            info.duration = duration.isFinite ? max(0, duration) : 0
        }

        if let streams = root["streams"] as? [[String: Any]] {
            for stream in streams {
                let type = stream["codec_type"] as? String ?? ""
                let codec = stream["codec_name"] as? String
                switch type {
                case "video":
                    // 部分素材（如带封面图的音频）会把静态图标记为视频流，
                    // 这里保留原始信息，由上层结合时长与编码格式判断。
                    if !info.hasVideo {
                        info.hasVideo = true
                        info.videoCodec = codec
                        info.width = stream["width"] as? Int ?? 0
                        info.height = stream["height"] as? Int ?? 0
                    }
                case "audio":
                    if !info.hasAudio {
                        info.hasAudio = true
                        info.audioCodec = codec
                    }
                default:
                    break
                }
            }
        }

        return info
    }
}

// MARK: - 能力查询

/// FFmpeg 构建所包含的编码器清单。解析结果进程内缓存——`ffmpeg -encoders`
/// 每次调用都要启动一个约 50 MB 的进程，放在循环里查询会显著拖慢流水线。
enum FFmpegCapability {

    private static let lock = NSLock()
    private static var cache: [String: Set<String>] = [:]

    /// 指定 ffmpeg 可执行文件所支持的编码器名集合。
    static func encoders(of executable: URL) -> Set<String> {
        lock.lock()
        if let cached = cache[executable.path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let text = FFmpegRunner.capture(executable: executable, arguments: [
            "-hide_banner", "-encoders"
        ])

        var names = Set<String>()
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 形如：` V....D h264_videotoolbox   VideoToolbox H.264 Encoder (codec h264)`
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let flags = parts[0]
            guard flags.count == 6 else { continue }
            let name = String(parts[1])
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            names.insert(name)
        }

        lock.lock()
        cache[executable.path] = names
        lock.unlock()
        return names
    }

    static func has(_ encoder: String, in executable: URL) -> Bool {
        encoders(of: executable).contains(encoder)
    }

    /// 清空缓存，供设置页在用户更换 FFmpeg 路径后重新探测。
    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}

// MARK: - 转码进度

/// FFmpeg 单次转码的即时进度。
struct TranscodeProgress: Sendable, Equatable {
    /// 已处理时长占素材总时长的比例（0–1）
    var fraction: Double = 0
    /// 已处理的素材时间点（秒）
    var processedSeconds: Double = 0
    /// 处理倍速，例如 3.2 表示每秒处理 3.2 秒素材
    var speed: Double = 0
}

// MARK: - 进程执行器

/// 线程安全的可变容器。
///
/// 用于在并发读取线程与调用线程之间传递结果。直接让闭包捕获并修改局部变量
/// 在 Swift 并发检查下会被判为并发可变捕获，故显式封装。
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    var wrappedValue: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

/// FFmpeg 子进程的启动、进度解析与取消处理。
///
/// 进度来源是 `-progress pipe:1` 输出的键值流而非解析 stderr 的统计行：
/// 前者是 FFmpeg 为程序化消费设计的稳定接口，后者是给人看的、格式随版本变化。
enum FFmpegRunner {

    enum RunnerError: LocalizedError {
        case launchFailed(String, String)
        case cancelled
        case failed(code: Int32, diagnostics: String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let path, let reason):
                return "无法启动 FFmpeg（\(path)）：\(reason)"
            case .cancelled:
                return "任务已取消"
            case .failed(let code, let diagnostics):
                let detail = diagnostics.isEmpty ? "无错误输出" : diagnostics
                return "FFmpeg 退出码 \(code)：\(detail)"
            }
        }
    }

    /// `-progress` 输出中的一行。
    enum ProgressLine: Equatable {
        case time(seconds: Double)
        case speed(Double)
    }

    /// 同步执行一个进程并把全部输出作为字符串返回，用于探测类短命令。
    ///
    /// 超时保护是必要的：素材位于离线外置卷或网络卷时，ffprobe 可能长时间挂起，
    /// 而转码阶段是在工作线程池里串行推进的，一次挂起会拖住整个任务。
    static func capture(executable: URL,
                        arguments: [String],
                        timeout: TimeInterval = 20) -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ""
        }

        // 先并发读取，避免管道缓冲区写满导致子进程阻塞在 write 上。
        let box = ResultBox(Data())
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue(label: "com.datacopier.ffmpeg.capture").async {
            box.wrappedValue = pipe.fileHandleForReading.readDataToEndOfFile()
            semaphore.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
        }
        _ = semaphore.wait(timeout: .now() + 3)
        process.waitUntilExit()

        let text = String(decoding: box.wrappedValue, as: UTF8.self)
        return timedOut ? text + "\n[超时终止]" : text
    }

    /// 执行一次转码，返回终止码与 stderr 尾部。
    ///
    /// 取消通过 `Cancellation` 的回调直接终止子进程：FFmpeg 收到 SIGTERM 后会
    /// 自行清理未写完的输出，比让工作线程空等更快也更干净。
    static func run(executable: URL,
                    arguments: [String],
                    expectedDuration: Double?,
                    cancellation: Cancellation,
                    onProgress: @escaping (TranscodeProgress) -> Void) throws -> (code: Int32, diagnostics: String) {

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw RunnerError.launchFailed(executable.path, error.localizedDescription)
        }

        let token = cancellation.addHandler { [process] in
            if process.isRunning { process.terminate() }
        }

        // 进度流：逐行解析 `key=value`，两条信息合并成一份快照后再上报。
        let progressDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "com.datacopier.ffmpeg.progress").async {
            var buffer = Data()
            var lastSeconds = 0.0
            var lastSpeed = 0.0
            let handle = stdoutPipe.fileHandleForReading

            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let line = String(data: lineData, encoding: .utf8),
                          let parsed = parse(line: line) else { continue }
                    switch parsed {
                    case .time(let seconds):
                        lastSeconds = seconds
                    case .speed(let speed):
                        lastSpeed = speed
                    }
                    var first: Double = 0
                    if let expectedDuration, expectedDuration > 0 {
                        first = min(1, max(0, lastSeconds / expectedDuration))
                    }
                    onProgress(TranscodeProgress(fraction: first,
                                                 processedSeconds: lastSeconds,
                                                 speed: lastSpeed))
                }
            }
            progressDone.signal()
        }

        // 诊断信息：stderr 仅保留尾部若干千字节，足以给出根因又不会撑爆内存。
        let diagnosticsBox = ResultBox("")
        let errorDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "com.datacopier.ffmpeg.stderr").async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            diagnosticsBox.wrappedValue = text.count > 8000 ? String(text.suffix(8000)) : text
            errorDone.signal()
        }

        process.waitUntilExit()
        cancellation.removeHandler(token)

        // 子进程退出后管道会关闭，两个读取线程随之结束。
        _ = progressDone.wait(timeout: .now() + 5)
        _ = errorDone.wait(timeout: .now() + 5)

        if cancellation.isCancelled {
            throw RunnerError.cancelled
        }
        let diagnostics = diagnosticsBox.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, diagnostics)
    }

    // MARK: - 进度行解析

    /// 解析 `-progress` 输出中的一行。非进度行返回 nil。
    static func parse(line: String) -> ProgressLine? {
        let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        let key = String(pair[0])
        let value = String(pair[1]).trimmingCharacters(in: .whitespaces)

        switch key {
        case "out_time_us", "out_time_ms":
            // FFmpeg 出于历史原因把微秒值同时写进这两个键，单位都是微秒。
            guard let micros = Double(value), micros.isFinite else { return nil }
            return .time(seconds: max(0, micros / 1_000_000))

        case "out_time":
            // 形如 `00:01:23.456789`
            guard let seconds = parseTimecode(value) else { return nil }
            return .time(seconds: seconds)

        case "speed":
            // 形如 `3.2x`，素材尚未开始处理时为 `N/A`
            let trimmed = value.hasSuffix("x") ? String(value.dropLast()) : value
            guard let speed = Double(trimmed), speed.isFinite else { return nil }
            return .speed(speed)

        default:
            return nil
        }
    }

    /// 解析 `HH:MM:SS.ffffff` 形式的时间码。
    static func parseTimecode(_ text: String) -> Double? {
        let components = text.split(separator: ":")
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
