// 引擎自检程序。
//
// 覆盖两类验证：
//  1. 正确性——xxHash64 / SHA-256 / MD5 与公开测试向量逐字节比对，
//     并校验流式分块结果与一次性计算结果一致。
//  2. 端到端——真实创建文件、执行拷贝任务，再用系统 shasum 独立复核结果，
//     同时检查元数据保留、冲突策略、清单文件与取消行为。
//
// 运行方式见 Scripts/run_selfcheck.sh

import Foundation
import ImageIO
import CoreGraphics

// MARK: - 断言脚手架

var failures: [String] = []
var checks = 0

func expect(_ condition: Bool, _ label: String, detail: String = "") {
    checks += 1
    if condition {
        print("  [通过] \(label)")
    } else {
        failures.append(label)
        print("  [失败] \(label)\(detail.isEmpty ? "" : "  →  \(detail)")")
    }
}

func hex64(_ value: UInt64) -> String {
    String(format: "%016llx", value)
}

/// 在读取线程与调用线程之间传递结果的容器。
private final class ShellResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

/// 执行一个子进程并收集输出。
///
/// 两个细节是必须的，缺一个都可能让整轮自检无声挂死：
///  - 读取与等待必须并发。子进程输出超过管道缓冲（本机 16 KB）后会阻塞在 write 上，
///    若调用方先 `waitUntilExit` 再读，双方互锁。
///  - 必须有超时兜底。夹具生成依赖外部二进制，一旦它在当前环境下无法正常启动，
///    进程可能既不退出也不产出；`terminate()` 至少能让自检继续跑完其余用例。
@discardableResult
func shell(_ path: String,
           _ arguments: [String],
           cwd: String? = nil,
           timeout: TimeInterval = 120) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    process.standardInput = FileHandle.nullDevice

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
    } catch {
        return (-1, "启动失败：\(error.localizedDescription)")
    }

    let collected = ShellResultBox()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue(label: "com.datacopier.selfcheck.shell").async {
        collected.value = pipe.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    let timedOut = process.isRunning
    if timedOut { process.terminate() }

    _ = drained.wait(timeout: .now() + 5)
    process.waitUntilExit()

    let text = String(decoding: collected.value, as: UTF8.self)
    return (process.terminationStatus, timedOut ? text + "\n[超时终止]" : text)
}

// MARK: - 1. 哈希正确性

func checkHashing() {
    print("\n[1/6] 哈希算法正确性")

    let xxVectors: [(input: String, expected: String)] = [
        ("", "ef46db3751d8e999"),
        ("a", "d24ec4f1a98c6e5b"),
        ("abc", "44bc2cf5ad770999"),
        ("Nobody inspects the spammish repetition", "fbcea83c8a378bf1")
    ]
    for vector in xxVectors {
        let actual = hex64(XXHash64.hash([UInt8](vector.input.utf8)))
        expect(actual == vector.expected,
               "xxHash64(\"\(vector.input)\")",
               detail: "得到 \(actual)，期望 \(vector.expected)")
    }

    // 流式分块必须与一次性计算一致（覆盖 32 字节 block 边界与尾部分支）
    let payload = [UInt8]((0..<200_000).map { UInt8($0 % 251) })
    let oneShot = XXHash64.hash(payload)
    var streaming = XXHash64()
    let chunkSizes = [1, 3, 31, 32, 33, 4096, 65_536, 7, 64]
    var offset = 0
    var index = 0
    while offset < payload.count {
        let size = min(chunkSizes[index % chunkSizes.count], payload.count - offset)
        streaming.update(Array(payload[offset..<(offset + size)]))
        offset += size
        index += 1
    }
    expect(streaming.finalize() == oneShot,
           "xxHash64 流式分块与一次性结果一致",
           detail: "\(hex64(oneShot)) vs \(hex64(streaming.finalize()))")

    var sha = StreamingHasher(algorithm: .sha256)
    sha.update(Data("abc".utf8))
    let shaHex = sha.digestHex() ?? ""
    expect(shaHex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
           "SHA-256(\"abc\")",
           detail: shaHex)

    var md5 = StreamingHasher(algorithm: .md5)
    md5.update(Data("abc".utf8))
    let md5Hex = md5.digestHex() ?? ""
    expect(md5Hex == "900150983cd24fb0d6963f7d28e17f72", "MD5(\"abc\")", detail: md5Hex)

    // 与系统 shasum 交叉验证一个大文件
    let probeURL = URL(fileURLWithPath: "/tmp/dc_selfcheck_probe.bin")
    var generator = SystemRandomNumberGenerator()
    let randomBytes = (0..<(3 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255, using: &generator) }
    try? Data(randomBytes).write(to: probeURL)

    var streamHasher = StreamingHasher(algorithm: .sha256)
    streamHasher.update(try! Data(contentsOf: probeURL))
    let ours = streamHasher.digestHex() ?? ""
    let system = shell("/usr/bin/shasum", ["-a", "256", probeURL.path]).output
        .split(separator: " ").first.map(String.init) ?? ""
    expect(ours == system, "SHA-256 与系统 shasum 结果一致", detail: "\(ours) vs \(system)")
    try? FileManager.default.removeItem(at: probeURL)
}

// MARK: - 2. 端到端拷贝

func checkEndToEnd() {
    print("\n[2/6] 端到端拷贝 / 校验 / 报告")

    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/tmp/dc_selfcheck")
    try? fm.removeItem(at: root)
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("destination")
    try? fm.createDirectory(at: source, withIntermediateDirectories: true)

    var generator = SystemRandomNumberGenerator()

    func makeFile(_ relative: String, size: Int, permissions: Int? = nil) {
        let url = source.appendingPathComponent(relative)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = (0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) }
        try? Data(bytes).write(to: url)
        if let permissions {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    makeFile("small.bin", size: 4_096)
    makeFile("empty.dat", size: 0)
    makeFile("nested/deep/medium.bin", size: 3 * 1024 * 1024, permissions: 0o600)
    makeFile("nested/large.bin", size: 24 * 1024 * 1024)
    makeFile("中文名称 测试.txt", size: 1_024)
    makeFile("excluded/.DS_Store", size: 32)

    // 扩展属性，用于验证元数据保留
    let xattrTarget = source.appendingPathComponent("small.bin").path
    let marker = "com.datacopier.selfcheck"
    let markerBytes = Array("1".utf8)
    _ = xattrTarget.withCString { pathPointer in
        marker.withCString { namePointer in
            markerBytes.withUnsafeBytes { raw in
                setxattr(pathPointer, namePointer, raw.baseAddress, markerBytes.count, 0, 0)
            }
        }
    }

    // 统计预期文件数（排除 .DS_Store）
    var expectedFiles = 0
    var expectedBytes: Int64 = 0
    if let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            if url.lastPathComponent == ".DS_Store" { continue }
            expectedFiles += 1
            expectedBytes += Int64(values.fileSize ?? 0)
        }
    }

    var options = TaskOptions.default
    options.algorithm = .sha256
    options.verifyAfterCopy = true
    options.conflictPolicy = .overwrite
    options.concurrency = 4
    options.bufferSize = 1024 * 1024
    options.exportManifest = true

    let task = CopyTask(name: "自检任务", sources: [source.path], destination: destination.path, options: options)

    func runTask(_ task: CopyTask) -> TaskReport? {
        let runner = TaskRunner()
        let semaphore = DispatchSemaphore(value: 0)
        var captured: TaskReport?
        runner.run(task: task) { _ in
        } completion: { report in
            captured = report
            semaphore.signal()
        }
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if semaphore.wait(timeout: .now() + 0.05) == .success { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return captured
    }

    guard let report = runTask(task) else {
        expect(false, "任务执行返回报告")
        return
    }

    expect(report.totalFiles == expectedFiles,
           "计划文件数与预期一致",
           detail: "计划 \(report.totalFiles)，预期 \(expectedFiles)")
    expect(report.totalBytes == expectedBytes,
           "计划总字节与预期一致",
           detail: "计划 \(report.totalBytes)，预期 \(expectedBytes)")
    expect(report.failedFiles == 0, "无失败文件", detail: "\(report.failedFiles) 个失败")
    expect(report.verifyFailedFiles == 0, "无校验不一致", detail: "\(report.verifyFailedFiles) 处不一致")
    expect(report.copiedFiles == expectedFiles,
           "成功拷贝文件数正确",
           detail: "拷贝 \(report.copiedFiles)，预期 \(expectedFiles)")
    expect(report.verifiedFiles == expectedFiles,
           "全部文件通过拷后复核",
           detail: "复核通过 \(report.verifiedFiles)")
    expect(report.success, "报告判定为成功")
    expect(report.records.count == expectedFiles, "明细记录完整")
    expect(report.peakBytesPerSecond > 0, "采集到吞吐数据")

    // 目录结构必须完整保留（来源文件夹名作为顶层目录，嵌套层级不得被拍平）
    let copiedRoot = destination.appendingPathComponent(source.lastPathComponent)
    expect(fm.fileExists(atPath: copiedRoot.appendingPathComponent("nested/deep/medium.bin").path),
           "嵌套目录结构已保留")
    expect(report.records.contains { $0.relativePath == "source/nested/deep/medium.bin" },
           "相对路径包含完整层级")

    // 排除规则生效
    expect(!fm.fileExists(atPath: copiedRoot.appendingPathComponent("excluded/.DS_Store").path),
           "排除规则过滤 .DS_Store")

    // 系统 shasum 独立复核每一个目标文件
    var mismatchCount = 0
    var checkedPairs = 0
    for record in report.records {
        guard let expectedDigest = record.sourceDigest else { continue }
        let sourceOut = shell("/usr/bin/shasum", ["-a", "256", record.sourcePath]).output
            .split(separator: " ").first.map(String.init) ?? ""
        let destinationOut = shell("/usr/bin/shasum", ["-a", "256", record.destinationPath]).output
            .split(separator: " ").first.map(String.init) ?? ""
        checkedPairs += 1
        if sourceOut != destinationOut || sourceOut != expectedDigest { mismatchCount += 1 }
    }
    expect(checkedPairs == expectedFiles, "使用系统 shasum 复核了全部文件",
           detail: "复核 \(checkedPairs)，预期 \(expectedFiles)")
    expect(mismatchCount == 0, "系统 shasum 复核：源与目标逐字节一致",
           detail: "\(mismatchCount) 个文件不一致")

    // 元数据保留
    let mediumSource = source.appendingPathComponent("nested/deep/medium.bin")
    let mediumDestination = copiedRoot.appendingPathComponent("nested/deep/medium.bin")
    let sourceAttrs = try? fm.attributesOfItem(atPath: mediumSource.path)
    let destinationAttrs = try? fm.attributesOfItem(atPath: mediumDestination.path)
    expect((sourceAttrs?[.posixPermissions] as? Int) == (destinationAttrs?[.posixPermissions] as? Int),
           "权限位已保留",
           detail: "\(String(describing: sourceAttrs?[.posixPermissions])) vs \(String(describing: destinationAttrs?[.posixPermissions]))")

    let xattrCheck = copiedRoot.appendingPathComponent("small.bin").path
    let xattrSize = xattrCheck.withCString { pathPointer in
        marker.withCString { namePointer in
            getxattr(pathPointer, namePointer, nil, 0, 0, 0)
        }
    }
    expect(xattrSize > 0, "扩展属性已保留")

    // 清单文件
    let manifestURL = destination.appendingPathComponent(ChecksumManifest.fileName(for: task))
    expect(fm.fileExists(atPath: manifestURL.path), "校验清单已生成")
    if fm.fileExists(atPath: manifestURL.path) {
        let parsed = (try? ChecksumManifest.parse(manifestURL)) ?? [:]
        expect(parsed.count == expectedFiles, "清单条目数正确", detail: "\(parsed.count) 条")
        let verifyResult = shell("/usr/bin/shasum", ["-a", "256", "-c", manifestURL.path], cwd: destination.path)
        expect(verifyResult.status == 0,
               "系统 shasum -c 校验清单通过",
               detail: verifyResult.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(160).description)
    }

    // 冲突策略：skip 应当全部跳过
    var skipOptions = options
    skipOptions.conflictPolicy = .skip
    skipOptions.verifyAfterCopy = false
    var skipTask = task
    skipTask.options = skipOptions
    if let skipReport = runTask(skipTask) {
        expect(skipReport.skippedFiles == expectedFiles, "冲突策略 skip 全部跳过",
               detail: "跳过 \(skipReport.skippedFiles)，预期 \(expectedFiles)")
        expect(skipReport.copiedFiles == 0, "skip 策略下不产生新拷贝")
    } else {
        expect(false, "skip 任务执行返回报告")
    }

    // 冲突策略：rename 应当生成带序号的新文件
    var renameOptions = options
    renameOptions.conflictPolicy = .rename
    renameOptions.verifyAfterCopy = false
    var renameTask = task
    renameTask.options = renameOptions
    if let renameReport = runTask(renameTask) {
        expect(renameReport.copiedFiles == expectedFiles, "冲突策略 rename 全部拷贝",
               detail: "拷贝 \(renameReport.copiedFiles)")
        expect(fm.fileExists(atPath: copiedRoot.appendingPathComponent("small 2.bin").path),
               "rename 策略生成带序号的新文件")
    } else {
        expect(false, "rename 任务执行返回报告")
    }

    // 取消行为
    var cancelOptions = options
    cancelOptions.algorithm = .sha256
    var cancelTask = task
    cancelTask.options = cancelOptions
    cancelTask.destination = root.appendingPathComponent("cancel_target").path
    let cancelRunner = TaskRunner()
    let cancelSemaphore = DispatchSemaphore(value: 0)
    var cancelReport: TaskReport?
    cancelRunner.run(task: cancelTask) { _ in
    } completion: { report in
        cancelReport = report
        cancelSemaphore.signal()
    }
    Thread.sleep(forTimeInterval: 0.01)
    cancelRunner.cancel()
    let cancelDeadline = Date().addingTimeInterval(60)
    while Date() < cancelDeadline {
        if cancelSemaphore.wait(timeout: .now() + 0.05) == .success { break }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    expect(cancelReport?.cancelled == true, "取消操作被正确上报")
    let leftovers = (try? fm.contentsOfDirectory(atPath: cancelTask.destination)) ?? []
    let tempLeftovers = leftovers.filter { $0.hasSuffix(".datacopier-tmp") }
    expect(tempLeftovers.isEmpty, "取消后未残留临时文件", detail: tempLeftovers.joined(separator: ", "))

    // 报告导出
    let mdURL = root.appendingPathComponent("report.md")
    let csvURL = root.appendingPathComponent("report.csv")
    let jsonURL = root.appendingPathComponent("report.json")
    do {
        try ReportExporter.write(report, format: .markdown, to: mdURL)
        try ReportExporter.write(report, format: .csv, to: csvURL)
        try ReportExporter.write(report, format: .json, to: jsonURL)
        expect(true, "三种格式报告均导出成功")
        let md = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
        expect(md.contains("数据拷贝报告"), "Markdown 报告内容非空")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try? decoder.decode(TaskReport.self, from: Data(contentsOf: jsonURL))
        expect(restored?.copiedFiles == report.copiedFiles, "JSON 报告可被反序列化还原")
    } catch {
        expect(false, "报告导出", detail: error.localizedDescription)
    }
}

// MARK: - 3. 任务校验与安全护栏

func checkGuards() {
    print("\n[3/6] 配置校验与安全护栏")

    // 目标位于来源内部必须被拒绝
    let root = URL(fileURLWithPath: "/tmp/dc_selfcheck")
    let source = root.appendingPathComponent("source")
    var nested = CopyTask(name: "非法", sources: [source.path], destination: source.appendingPathComponent("inner").path)
    do {
        try FilePlanner.validate(nested)
        expect(false, "拒绝目标位于来源内部")
    } catch {
        expect(true, "拒绝目标位于来源内部")
    }

    // 来源不存在必须被拒绝
    nested.destination = root.appendingPathComponent("ok").path
    nested.sources = ["/tmp/definitely-not-exists-\(UUID().uuidString)"]
    do {
        try FilePlanner.validate(nested)
        expect(false, "拒绝不存在的来源")
    } catch {
        expect(true, "拒绝不存在的来源")
    }

    // 空来源必须被拒绝
    nested.sources = []
    do {
        try FilePlanner.validate(nested)
        expect(false, "拒绝空来源列表")
    } catch {
        expect(true, "拒绝空来源列表")
    }

    // 重命名冲突解析
    let occupied = "/tmp/dc_selfcheck/destination/source/small.bin"
    if FileManager.default.fileExists(atPath: occupied) {
        let unique = ConflictResolver.uniquePath(for: occupied)
        expect(unique != occupied && unique.contains("small"), "重命名冲突解析生成新路径",
               detail: unique)
    } else {
        expect(false, "重命名冲突解析（前置条件缺失）")
    }
}

// MARK: - 4. 视频转码能力探测

func checkVideoCapability() {
    print("\n[4/6] 视频转码硬件能力探测")

    let encoders = VideoCapability.availableEncoders()
    expect(!encoders.isEmpty, "VTCopyVideoEncoderList 返回编码器列表",
           detail: "共 \(encoders.count) 个")

    let hardware = encoders.filter { $0.isHardwareAccelerated }
    print("       硬件加速编码器：\(hardware.count) 个")
    for encoder in hardware.prefix(8) {
        let fourCC = encoder.codec.isEmpty ? "—" : encoder.codec
        print("         · \(encoder.name)  [\(fourCC)]")
    }

    expect(VideoCapability.hasHardwareEncoder(for: .h264), "H.264 硬件编码通路可用")
    expect(VideoCapability.hasHardwareEncoder(for: .hevc), "HEVC 硬件编码通路可用")
    expect(encoders.contains { $0.codec == "avc1" }, "H.264 的 FourCC 解析正确（avc1）")
    print("       FFmpeg：\(FFmpegLocator.locate()?.path ?? "未检测到")")
}

// MARK: - 5. 转码流水线

/// 并发安全的进度累积器：进度回调在 FFmpeg 的输出读取线程上触发。
final class ProgressTally: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum = 0.0
    private var calls = 0
    private var peakSpeed = 0.0

    func update(_ snapshot: TranscodeProgress) {
        lock.lock()
        calls += 1
        if snapshot.fraction > maximum { maximum = snapshot.fraction }
        if snapshot.speed > peakSpeed { peakSpeed = snapshot.speed }
        lock.unlock()
    }

    var maxFraction: Double {
        lock.lock(); defer { lock.unlock() }
        return maximum
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    var speed: Double {
        lock.lock(); defer { lock.unlock() }
        return peakSpeed
    }
}

/// 把独立线程上的转码结果安全地交回主线程。
final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TranscodeOutcome?
    private var elapsed: TimeInterval = 0

    func store(_ outcome: TranscodeOutcome, elapsed: TimeInterval) {
        lock.lock()
        value = outcome
        self.elapsed = elapsed
        lock.unlock()
    }

    var outcome: TranscodeOutcome? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return elapsed
    }
}

/// 用 FFmpeg 自身生成带音轨的测试素材。
///
/// `crf` 控制源素材的压缩程度：数值越小画质越高、文件越大。需要「可被有效压缩的
/// 高码率素材」时传入较小值，否则合成图案极易压缩，重编码后反而会变大。
@discardableResult
func makeTestClip(_ path: String,
                  width: Int,
                  height: Int,
                  seconds: Double,
                  fps: Int,
                  ffmpeg: String,
                  crf: Int = 23) -> Bool {
    let result = shell(ffmpeg, [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc=size=\(width)x\(height):rate=\(fps)",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
        "-t", String(format: "%.2f", seconds),
        "-c:v", "libx264", "-preset", "ultrafast", "-crf", String(crf),
        "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "128k",
        path
    ])
    return result.status == 0 && FileManager.default.fileExists(atPath: path)
}

func fileSize(of path: String) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

/// 构造一条已成功拷贝的文件记录，用于直接驱动转码引擎。
func makeRecord(for path: String, root: String) -> FileRecord {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    var relative = path
    if relative.hasPrefix(root + "/") { relative = String(relative.dropFirst(root.count + 1)) }
    return FileRecord(relativePath: relative,
                      sourcePath: path,
                      destinationPath: path,
                      size: size,
                      status: .verified)
}

/// 参数列表中是否存在相邻的 `flag value` 组合。
func hasAdjacent(_ arguments: [String], _ flag: String, _ value: String) -> Bool {
    guard arguments.count >= 2 else { return false }
    for index in 0..<(arguments.count - 1) where arguments[index] == flag {
        if arguments[index + 1] == value { return true }
    }
    return false
}

func containsArgument(_ arguments: [String], _ value: String) -> Bool {
    arguments.contains(value)
}

func checkTranscodePipeline() {
    print("\n[5/6] 转码流水线")

    let fm = FileManager.default
    guard let ffmpegURL = FFmpegLocator.locate() else {
        expect(false, "定位 FFmpeg 可执行文件", detail: "未找到，后续转码检查全部跳过")
        return
    }
    let ffmpeg = ffmpegURL.path

    guard let probeURL = FFmpegLocator.locateProbe(alongside: ffmpegURL) else {
        expect(false, "定位 ffprobe 可执行文件", detail: "未找到")
        return
    }

    expect(true, "定位 FFmpeg 与 ffprobe", detail: ffmpeg)

    if let version = FFmpegLocator.version(of: ffmpegURL) {
        expect(true, "解析 FFmpeg 版本", detail: version)
    } else {
        expect(false, "解析 FFmpeg 版本")
    }

    let encoders = FFmpegCapability.encoders(of: ffmpegURL)
    expect(encoders.contains("libx264"), "编码器清单含 libx264", detail: "共 \(encoders.count) 个")
    expect(encoders.contains("libx265"), "编码器清单含 libx265")
    let hasVideoToolboxEncoder = encoders.contains { $0.hasSuffix("_videotoolbox") }
    expect(hasVideoToolboxEncoder, "编码器清单含 VideoToolbox 硬件编码器")

    // ---- 进度行解析（纯函数，先验证再依赖） ----
    if case .time(let seconds)? = FFmpegRunner.parse(line: "out_time_us=2500000") {
        expect(abs(seconds - 2.5) < 0.0001, "解析 out_time_us 进度行", detail: "\(seconds)s")
    } else {
        expect(false, "解析 out_time_us 进度行")
    }
    if case .speed(let speed)? = FFmpegRunner.parse(line: "speed=3.25x") {
        expect(abs(speed - 3.25) < 0.0001, "解析 speed 进度行", detail: "\(speed)x")
    } else {
        expect(false, "解析 speed 进度行")
    }
    expect(FFmpegRunner.parse(line: "progress=continue") == nil, "忽略非进度行")
    if let timecode = FFmpegRunner.parseTimecode("01:02:03.5") {
        expect(abs(timecode - 3723.5) < 0.0001, "解析 HH:MM:SS 时间码", detail: "\(timecode)s")
    } else {
        expect(false, "解析 HH:MM:SS 时间码")
    }

    // ---- 测试素材 ----
    let root = URL(fileURLWithPath: "/tmp/dc_transcode")
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)

    let small = root.appendingPathComponent("small.mp4").path
    guard makeTestClip(small, width: 640, height: 360, seconds: 1.2, fps: 15, ffmpeg: ffmpeg) else {
        expect(false, "生成测试素材（640×360）", detail: "FFmpeg 生成失败")
        return
    }
    expect(true, "生成测试素材（640×360，含 AAC 音轨）")

    // ---- 参数生成 ----
    var hevcSettings = TranscodeSettings()
    hevcSettings.enabled = true
    hevcSettings.presetID = "hevc-1080p"

    let hevcPlan: TranscodePlan
    do {
        hevcPlan = try TranscodePlan.resolve(settings: hevcSettings, ffmpeg: ffmpegURL)
    } catch {
        expect(false, "解析 H.265 1080p 预设", detail: error.localizedDescription)
        return
    }
    expect(hevcPlan.usesHardware ? hevcPlan.videoEncoder == "hevc_videotoolbox"
                                 : hevcPlan.videoEncoder == "libx265",
           "选择可用的 HEVC 编码器",
           detail: hevcPlan.videoEncoder ?? "无")

    let hevcArguments = hevcPlan.arguments(input: URL(fileURLWithPath: small),
                                           output: URL(fileURLWithPath: small + ".out.mp4"))
    expect(hasAdjacent(hevcArguments, "-b:v", "6000000"), "写入目标码率参数", detail: "6000000")
    expect(hasAdjacent(hevcArguments, "-tag:v", "hvc1"), "HEVC 写入 hvc1 标记")
    expect(hasAdjacent(hevcArguments, "-movflags", "+faststart"), "MP4 写入 faststart 标记")
    expect(hasAdjacent(hevcArguments, "-progress", "pipe:1"), "启用机器可读进度输出")
    expect(containsArgument(hevcArguments, "-nostdin"), "禁用 stdin 交互")
    let scaleFilter = hevcPlan.scaleFilter ?? ""
    expect(scaleFilter.contains("min(iw,1920)") && scaleFilter.contains("min(ih,1920)"),
           "缩放滤镜同时限制长边且不放大", detail: scaleFilter)

    var remuxSettings = TranscodeSettings()
    remuxSettings.enabled = true
    remuxSettings.presetID = "remux"
    if let remuxPlan = try? TranscodePlan.resolve(settings: remuxSettings, ffmpeg: ffmpegURL) {
        let arguments = remuxPlan.arguments(input: URL(fileURLWithPath: small),
                                           output: URL(fileURLWithPath: small + ".remux.mp4"))
        expect(remuxPlan.isVideoCopy, "重封装预设不重新编码视频")
        expect(hasAdjacent(arguments, "-c:v", "copy"), "重封装使用视频码流直通")
        expect(!containsArgument(arguments, "-vf"), "重封装不施加缩放滤镜")
        expect(hasAdjacent(arguments, "-c:a", "copy"), "重封装保持原音轨")
    } else {
        expect(false, "解析重封装预设")
    }

    var audioSettings = TranscodeSettings()
    audioSettings.enabled = true
    audioSettings.presetID = "audio-aac"
    if let audioPlan = try? TranscodePlan.resolve(settings: audioSettings, ffmpeg: ffmpegURL) {
        let arguments = audioPlan.arguments(input: URL(fileURLWithPath: small),
                                           output: URL(fileURLWithPath: small + ".m4a"))
        expect(containsArgument(arguments, "-vn"), "仅提取音频时丢弃视频轨")
        expect(!hasAdjacent(arguments, "-movflags", "+faststart"), "M4A 容器不写 faststart")
    } else {
        expect(false, "解析仅提取音频预设")
    }

    var proresSettings = TranscodeSettings()
    proresSettings.enabled = true
    proresSettings.presetID = "prores-422"
    if let proresPlan = try? TranscodePlan.resolve(settings: proresSettings, ffmpeg: ffmpegURL) {
        expect(proresPlan.container == .mov, "ProRes 使用 MOV 容器")
        if !proresPlan.usesHardware {
            expect(hasAdjacent(proresPlan.arguments(input: URL(fileURLWithPath: small),
                                                    output: URL(fileURLWithPath: small + ".mov")),
                               "-pix_fmt", "yuv422p10le"),
                   "软件 ProRes 使用 10bit 422 像素格式")
        } else {
            expect(proresPlan.videoEncoder == "prores_videotoolbox", "选用 ProRes 硬件编码器")
        }
    } else {
        expect(false, "解析 ProRes 预设")
    }

    // ---- 真实转码：H.265 压缩 ----
    //
    // 合成素材体积很小、极易压缩，按 6 Mbps 目标码率重编码后会明显变大，
    // 因此这里关闭体积保护，以便检查编码结果本身；体积保护另有专门用例覆盖。
    hevcSettings.discardOutputIfLarger = false

    let tally = ProgressTally()
    let hevcRecord = makeRecord(for: small, root: root.path)
    let hevcOutcome = TranscodeEngine.process(record: hevcRecord,
                                              settings: hevcSettings,
                                              cancellation: Cancellation()) { snapshot in
        tally.update(snapshot)
    }

    expect(hevcOutcome.status == .succeeded, "H.265 转码执行成功",
           detail: hevcOutcome.message ?? "—")
    expect(tally.callCount > 0, "转码过程中回报了进度", detail: "\(tally.callCount) 次")
    expect(tally.maxFraction > 0.9, "进度最终推进到接近完成",
           detail: String(format: "%.2f", tally.maxFraction))

    if let outputPath = hevcOutcome.outputPath {
        expect(fm.fileExists(atPath: outputPath), "转码输出文件已落盘")
        expect(outputPath.hasSuffix("_hevc-1080p.mp4"), "输出文件名带预设后缀",
               detail: (outputPath as NSString).lastPathComponent)

        let info = FFmpegProbe.inspect(URL(fileURLWithPath: outputPath), executable: probeURL)
        expect(info?.videoCodec == "hevc", "输出视频编码确为 HEVC", detail: info?.videoCodec ?? "—")
        expect(info?.hasAudio == true, "输出保留音轨", detail: info?.audioCodec ?? "—")
        // 源素材长边仅 640，低于 1920 上限，必须原样保留而不是被放大。
        expect(info?.width == 640 && info?.height == 360, "小素材未被放大",
               detail: info?.resolutionText ?? "—")
        expect(hevcOutcome.usedHardware == hevcPlan.usesHardware, "硬件标记与实际编码器一致")

        let outputAttributes = try? fm.attributesOfItem(atPath: outputPath)
        let outputSize = (outputAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        expect(outputSize == hevcOutcome.outputBytes, "输出体积与磁盘实际一致")
        try? fm.removeItem(atPath: outputPath)
    } else {
        expect(false, "转码输出文件已落盘")
    }

    // ---- 缩小分辨率：1080p 源 + 720p 预设 ----
    let large = root.appendingPathComponent("large.mp4").path
    if makeTestClip(large, width: 1920, height: 1080, seconds: 1.0, fps: 15, ffmpeg: ffmpeg) {
        var downscaleSettings = TranscodeSettings()
        downscaleSettings.enabled = true
        downscaleSettings.presetID = "h264-720p"
        let outcome = TranscodeEngine.process(record: makeRecord(for: large, root: root.path),
                                              settings: downscaleSettings,
                                              cancellation: Cancellation()) { _ in }
        if let outputPath = outcome.outputPath,
           let info = FFmpegProbe.inspect(URL(fileURLWithPath: outputPath), executable: probeURL) {
            expect(info.width == 1280 && info.height == 720, "1080p 素材被缩放到 720p",
                   detail: info.resolutionText)
            try? fm.removeItem(atPath: outputPath)
        } else {
            expect(false, "1080p 素材被缩放到 720p", detail: outcome.message ?? "无输出")
        }
    } else {
        expect(false, "生成测试素材（1920×1080）")
    }

    // ---- 主用途回归：高码率素材应被真正压缩（体积保护保持默认开启） ----
    let big = root.appendingPathComponent("big.mp4").path
    if makeTestClip(big, width: 1920, height: 1080, seconds: 3.0, fps: 25, ffmpeg: ffmpeg, crf: 6) {
        let inputSize = fileSize(of: big)
        var compressSettings = TranscodeSettings()
        compressSettings.enabled = true
        compressSettings.presetID = "hevc-1080p"   // 体积保护维持默认开启

        let outcome = TranscodeEngine.process(record: makeRecord(for: big, root: root.path),
                                              settings: compressSettings,
                                              cancellation: Cancellation()) { _ in }
        expect(outcome.status == .succeeded, "高码率素材压缩成功",
               detail: outcome.message ?? "—")
        expect(outcome.outputBytes < inputSize, "压缩后体积确实小于原文件",
               detail: "\(Format.bytes(inputSize)) → \(Format.bytes(outcome.outputBytes))")
        expect(outcome.compressionRatio < 0.7, "压缩比达到预设预期区间",
               detail: String(format: "%.0f%%", outcome.compressionRatio * 100))
        expect(outcome.usedHardware == hevcPlan.usesHardware, "压缩走预期的编码通路",
               detail: outcome.usedHardware ? "硬件" : "软件")
        print(String(format: "       1920×1080 三秒素材：%@ → %@（%.0f%%），%@，倍速 %.1f×",
                     Format.bytes(inputSize),
                     Format.bytes(outcome.outputBytes),
                     outcome.compressionRatio * 100,
                     outcome.usedHardware ? "硬件编码" : "软件编码",
                     outcome.speed))
        if let outputPath = outcome.outputPath {
            try? fm.removeItem(atPath: outputPath)
        }
    } else {
        expect(false, "生成高码率测试素材（1920×1080）")
    }

    // ---- 体积保护：压缩后反而更大时应保留原文件 ----
    //
    // 这是数据安全性的关键一环：对小体积高压缩率素材套用高码率预设时，
    // 若无条件接受输出，用户会「压缩」出更大的文件。此处刻意不关闭该开关。
    var guardSettings = TranscodeSettings()
    guardSettings.enabled = true
    guardSettings.presetID = "hevc-1080p"
    guardSettings.discardOutputIfLarger = true

    let guardOutcome = TranscodeEngine.process(record: makeRecord(for: small, root: root.path),
                                               settings: guardSettings,
                                               cancellation: Cancellation()) { _ in }
    expect(guardOutcome.status == .skipped, "输出未变小时转为跳过而非失败",
           detail: guardOutcome.status.displayName)
    expect(guardOutcome.message?.contains("未减小") == true, "体积保护给出明确原因",
           detail: guardOutcome.message ?? "—")
    expect(guardOutcome.outputPath == nil, "体积保护不登记输出文件")
    let guardedOutput = small.replacingOccurrences(of: ".mp4", with: "_hevc-1080p.mp4")
    expect(!fm.fileExists(atPath: guardedOutput), "体积保护已回滚输出文件")
    expect(fm.fileExists(atPath: small), "体积保护保留原文件")

    // ---- 重封装：码流必须保持一致 ----
    var remuxRun = TranscodeSettings()
    remuxRun.enabled = true
    remuxRun.presetID = "remux"
    let remuxOutcome = TranscodeEngine.process(record: makeRecord(for: small, root: root.path),
                                               settings: remuxRun,
                                               cancellation: Cancellation()) { _ in }
    if let outputPath = remuxOutcome.outputPath,
       let info = FFmpegProbe.inspect(URL(fileURLWithPath: outputPath), executable: probeURL) {
        expect(info.videoCodec == "h264", "重封装后视频编码与源一致（未重编码）",
               detail: info.videoCodec ?? "—")
        expect(info.width == 640 && info.height == 360, "重封装不改变分辨率")
        try? fm.removeItem(atPath: outputPath)
    } else {
        expect(false, "重封装输出可读", detail: remuxOutcome.message ?? "无输出")
    }

    // ---- 仅提取音频 ----
    var audioRun = TranscodeSettings()
    audioRun.enabled = true
    audioRun.presetID = "audio-aac"
    let audioOutcome = TranscodeEngine.process(record: makeRecord(for: small, root: root.path),
                                               settings: audioRun,
                                               cancellation: Cancellation()) { _ in }
    if let outputPath = audioOutcome.outputPath,
       let info = FFmpegProbe.inspect(URL(fileURLWithPath: outputPath), executable: probeURL) {
        expect(!info.hasVideo, "音频提取结果不含视频轨")
        expect(info.hasAudio, "音频提取结果含音轨", detail: info.audioCodec ?? "—")
        try? fm.removeItem(atPath: outputPath)
    } else {
        expect(false, "音频提取输出可读", detail: audioOutcome.message ?? "无输出")
    }

    // ---- 端到端任务：转码阶段与拷贝阶段协同 ----
    checkTranscodeStageInTask(ffmpeg: ffmpeg, root: root)

    // ---- 取消行为 ----
    checkTranscodeCancellation(ffmpeg: ffmpeg, root: root)
}

/// 任务级端到端：目录中混有视频与非视频文件，验证只有视频进入转码，
/// 且报告与导出内容如实反映转码阶段。
func checkTranscodeStageInTask(ffmpeg: String, root: URL) {
    let fm = FileManager.default
    let source = root.appendingPathComponent("task_source")
    let destination = root.appendingPathComponent("task_destination")
    try? fm.removeItem(at: source)
    try? fm.removeItem(at: destination)
    try? fm.createDirectory(at: source, withIntermediateDirectories: true)

    guard makeTestClip(source.appendingPathComponent("clip.mp4").path,
                       width: 640, height: 360, seconds: 1.2, fps: 15, ffmpeg: ffmpeg) else {
        expect(false, "端到端：生成视频素材")
        return
    }
    try? Data(repeating: 0x41, count: 2048).write(to: source.appendingPathComponent("notes.txt"))
    try? Data(repeating: 0x42, count: 8192).write(to: source.appendingPathComponent("data.bin"))

    var options = TaskOptions.default
    options.algorithm = .sha256
    options.verifyAfterCopy = true
    options.conflictPolicy = .overwrite
    options.concurrency = 2
    options.exportManifest = true

    var settings = TranscodeSettings()
    settings.enabled = true
    settings.presetID = "h264-720p"
    settings.concurrency = 1
    // 合成素材体积极小，按 2.5 Mbps 重编码后未必更小，这里关闭体积保护，
    // 以便断言「转码阶段被正确执行」；体积保护本身由独立用例覆盖。
    settings.discardOutputIfLarger = false
    options.transcodeSettings = settings

    let task = CopyTask(name: "转码端到端自检", sources: [source.path], destination: destination.path, options: options)

    let runner = TaskRunner()
    let semaphore = DispatchSemaphore(value: 0)
    var captured: TaskReport?

    runner.run(task: task) { _ in
        // 进度在此测试中不需要断言，仅确认回调可正常送达。
    } completion: { report in
        captured = report
        semaphore.signal()
    }

    while semaphore.wait(timeout: .now() + 0.05) != .success {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    guard let report = captured else {
        expect(false, "端到端：任务返回报告")
        return
    }

    expect(report.copiedFiles == 3, "端到端：三个文件全部拷贝", detail: "\(report.copiedFiles)")
    expect(report.transcodeEnabled, "端到端：报告标记已启用转码")
    expect(report.transcodePresetName == "H.264 小体积 · 720p", "端到端：报告记录预设名称",
           detail: report.transcodePresetName ?? "—")
    expect(report.transcodedFiles == 1, "端到端：仅视频文件被转码", detail: "\(report.transcodedFiles)")
    expect(report.transcodeFailedFiles == 0, "端到端：无转码失败")
    expect(report.transcodeInputBytes > 0 && report.transcodeOutputBytes > 0,
           "端到端：记录了转码前后体积")
    expect(report.success, "端到端：整体判定为成功")

    let videoRecord = report.records.first { $0.relativePath.hasSuffix("clip.mp4") }
    let textRecord = report.records.first { $0.relativePath.hasSuffix("notes.txt") }
    expect(videoRecord?.transcode?.status == .succeeded, "端到端：视频记录携带转码结果")
    expect(textRecord?.transcode == nil, "端到端：非视频文件未进入转码")
    expect(report.transcodeResults.count == 1, "端到端：转码结果条目数与预期一致",
           detail: "\(report.transcodeResults.count)")

    if let outputPath = videoRecord?.transcode?.outputPath {
        expect(fm.fileExists(atPath: outputPath), "端到端：转码输出存在于目标目录")
        expect(outputPath.contains("task_destination"), "端到端：输出写在目标目录内")
        if let destinationRecordPath = videoRecord?.destinationPath {
            expect(fm.fileExists(atPath: destinationRecordPath), "端到端：原始拷贝仍保留")
        }
    } else {
        expect(false, "端到端：转码输出存在于目标目录")
    }

    // 报告导出的三种格式都应带上转码信息
    let markdown = ReportExporter.markdown(report)
    expect(markdown.contains("## 转码"), "Markdown 报告含转码章节")
    expect(markdown.contains("转码结果明细"), "Markdown 报告含转码结果明细")

    let csv = ReportExporter.csv(report)
    expect(csv.contains("转码状态"), "CSV 明细含转码状态列")
    expect(csv.contains("输出路径") && csv.contains("是否硬件加速"), "CSV 明细含转码输出与编码器列")

    // 宽容解码的回归验证：报告经 JSON 往返后字段不丢
    let isoDecoder = JSONDecoder()
    isoDecoder.dateDecodingStrategy = .iso8601
    if let json = try? ReportExporter.json(report),
       let restored = try? isoDecoder.decode(TaskReport.self, from: Data(json.utf8)) {
        expect(restored.transcodedFiles == report.transcodedFiles, "JSON 往返保留转码计数")
        expect(restored.transcodePresetName == report.transcodePresetName, "JSON 往返保留预设名称")
        expect(restored.records.count == report.records.count, "JSON 往返保留文件记录数")
        expect(restored.records.first { $0.relativePath.hasSuffix("clip.mp4") }?.transcode?.outputPath
               == videoRecord?.transcode?.outputPath,
               "JSON 往返保留转码输出路径")
    } else {
        expect(false, "JSON 往返保留转码计数")
    }

    // 缺少转码字段的旧报告必须仍能解析（否则升级后整个任务列表会丢失）
    let legacy = """
    {"taskName":"旧版本报告","startedAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:01:00Z",
     "sourceRoots":["/tmp/a"],"destination":"/tmp/b","algorithm":"sha256","conflictPolicy":"overwrite",
     "verifyAfterCopy":true,"totalFiles":1,"totalBytes":100,"copiedFiles":1,"copiedBytes":100,
     "skippedFiles":0,"failedFiles":0,"verifiedFiles":1,"verifyFailedFiles":0,"cancelled":false,
     "peakBytesPerSecond":10,"records":[],"truncatedRecordCount":0}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let legacyReport = try? decoder.decode(TaskReport.self, from: Data(legacy.utf8)) {
        expect(legacyReport.copiedFiles == 1, "旧版报告（无转码字段）仍可解析")
        expect(legacyReport.transcodeEnabled == false, "旧版报告转码字段回退为默认值")
    } else {
        expect(false, "旧版报告（无转码字段）仍可解析")
    }
}

/// 取消行为：既覆盖「开始前已取消」的短路，也覆盖「转码进行中取消」的清理。
func checkTranscodeCancellation(ffmpeg: String, root: URL) {
    let fm = FileManager.default
    let clip = root.appendingPathComponent("cancel_input.mp4").path

    // ---- 场景一：进入转码前已取消 ----
    guard makeTestClip(clip, width: 640, height: 360, seconds: 1.0, fps: 15, ffmpeg: ffmpeg) else {
        expect(false, "取消场景：生成素材")
        return
    }

    var settings = TranscodeSettings()
    settings.enabled = true
    settings.presetID = "h264-720p"

    let preCancelled = Cancellation()
    preCancelled.cancel()
    let outcome = TranscodeEngine.process(record: makeRecord(for: clip, root: root.path),
                                          settings: settings,
                                          cancellation: preCancelled) { _ in }
    expect(outcome.status != .succeeded, "已取消的任务不产生转码结果")
    expect(outcome.outputPath == nil, "已取消的任务不登记输出文件")

    // ---- 场景二：转码进行中取消 ----
    // 用软件编码 + 较长素材拉长执行时间，确保取消发生在编码中途。
    let long = root.appendingPathComponent("cancel_long.mp4").path
    guard makeTestClip(long, width: 480, height: 270, seconds: 300, fps: 10, ffmpeg: ffmpeg) else {
        expect(false, "取消场景：生成长素材")
        return
    }

    var slowSettings = TranscodeSettings()
    slowSettings.enabled = true
    slowSettings.presetID = "h264-1080p"
    slowSettings.preferHardwareAcceleration = false   // 软件编码，耗时可控且够长

    let cancelSettings = slowSettings
    let cancellation = Cancellation()
    let outcomeBox = OutcomeBox()
    let started = Date()

    // 转码必须放在独立线程上：主线程需要在编码进行中发出取消信号。
    let worker = Thread {
        let value = TranscodeEngine.process(record: makeRecord(for: long, root: root.path),
                                            settings: cancelSettings,
                                            cancellation: cancellation) { _ in }
        outcomeBox.store(value, elapsed: Date().timeIntervalSince(started))
    }
    worker.start()

    Thread.sleep(forTimeInterval: 1.0)
    cancellation.cancel()

    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline && outcomeBox.outcome == nil {
        Thread.sleep(forTimeInterval: 0.05)
    }

    guard let outcome2 = outcomeBox.outcome else {
        expect(false, "取消后转码线程及时返回", detail: "超过 15 秒仍未结束")
        return
    }

    let spent = outcomeBox.duration
    expect(outcome2.status != .succeeded, "取消后不产生成功结果", detail: outcome2.status.displayName)
    expect(spent < 8, "取消后立即终止子进程而非等待其跑完",
           detail: String(format: "%.1fs", spent))

    let leftover = long.replacingOccurrences(of: ".mp4", with: "_h264-1080p.mp4")
    expect(!fm.fileExists(atPath: leftover), "取消后不残留半成品输出文件")
}

// MARK: - 6. 拷贝预设：照片 / 视频归档

/// 同步执行一个任务并等待报告。
func runTaskSync(_ task: CopyTask, timeout: TimeInterval = 180) -> TaskReport? {
    let runner = TaskRunner()
    let semaphore = DispatchSemaphore(value: 0)
    var captured: TaskReport?

    runner.run(task: task) { _ in
    } completion: { report in
        captured = report
        semaphore.signal()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if semaphore.wait(timeout: .now() + 0.05) == .success { break }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return captured
}

/// 生成一张带 EXIF 拍摄时间与（可选）机型标签的 JPEG。
///
/// 用 ImageIO 而非外部工具写元数据，是为了顺带确认「写入」与「读取」使用同一套键名——
/// 若素材来源与解析路径不一致，测试会以假通过的形式掩盖真实缺陷。
/// 机型写在 TIFF 段的 `Model` 上，与相机固件的实际做法一致。
@discardableResult
func makePhotoWithEXIF(_ path: String, exifDate: String?, model: String? = nil) -> Bool {
    let width = 64
    let height = 48
    guard let context = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return false
    }
    context.setFillColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return false }

    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                           "public.jpeg" as CFString,
                                                           1,
                                                           nil) else {
        return false
    }

    var properties: [CFString: Any] = [:]
    if let exifDate {
        properties[kCGImagePropertyExifDictionary] = [
            kCGImagePropertyExifDateTimeOriginal: exifDate
        ] as [CFString: String]
    }
    var tiff: [CFString: Any] = [:]
    if let exifDate { tiff[kCGImagePropertyTIFFDateTime] = exifDate }
    if let model { tiff[kCGImagePropertyTIFFModel] = model }
    if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }

    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination)
}

/// 生成带容器创建时间与（可选）`©mod` 机型标签的视频。
///
/// 机型标签只在 QuickTime 容器里可靠落地：FFmpeg 把 `model` 写成 `udta` 下的
/// `©mod` 文本原子，而写成 MP4 时会丢弃该字段。因此需要验证机型时用 .mov。
@discardableResult
func makeVideoWithCreationTime(_ path: String,
                               creationTime: String,
                               ffmpeg: String,
                               model: String? = nil) -> Bool {
    var arguments = [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc=size=64x48:rate=10:duration=1",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
        "-metadata", "creation_time=\(creationTime)"
    ]
    if let model { arguments.append(contentsOf: ["-metadata", "model=\(model)"]) }
    arguments.append(path)

    let result = shell(ffmpeg, arguments)
    return result.status == 0 && FileManager.default.fileExists(atPath: path)
}

func checkCopyPresets() {
    print("\n[6/6] 拷贝预设：照片 / 视频归档")

    let fm = FileManager.default
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current

    // ---- 格式识别 ----
    for ext in ["JPG", "jpeg", "heic", "heif", "dng", "cr3", "nef", "arw", "tiff", "webp", "avif"] {
        expect(MediaFileTypes.kind(forExtension: ext) == .photo, "识别照片格式 .\(ext)")
    }
    for ext in ["MP4", "mov", "MTS", "m2ts", "mkv", "avi", "braw", "insv", "mxf"] {
        expect(MediaFileTypes.kind(forExtension: ext) == .video, "识别视频格式 .\(ext)")
    }
    for ext in ["txt", "pdf", "dmg", "zip", "psd", "svg", "mp3", "docx"] {
        expect(MediaFileTypes.kind(forExtension: ext) == nil, "不把 .\(ext) 归为照片或视频")
    }

    // ---- EXIF 时间解析 ----
    let exifParts = MediaMetadata.parseExifDate("2024:03:15 14:30:22")
        .map { calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0) }
    expect(exifParts?.year == 2024 && exifParts?.month == 3 && exifParts?.day == 15
           && exifParts?.hour == 14 && exifParts?.minute == 30 && exifParts?.second == 22,
           "解析 EXIF 时间 `2024:03:15 14:30:22`")
    expect(MediaMetadata.parseExifDate("0000:00:00 00:00:00") == nil, "拒绝 EXIF 全零占位时间")
    expect(MediaMetadata.parseExifDate("2024:02:30 10:00:00") == nil, "拒绝不存在的 2 月 30 日")
    expect(MediaMetadata.parseExifDate("2024:13:01 10:00:00") == nil, "拒绝非法月份 13")
    expect(MediaMetadata.parseExifDate("") == nil, "拒绝空 EXIF 时间")

    // ---- 文件名时间戳 ----
    let nameCases: [(name: String, hasTimestamp: Bool)] = [
        ("IMG_20240315_143022.JPG", true),
        ("VID_20240315_143022.mp4", true),
        ("PXL_20240315_143022123.jpg", true),
        ("2024-03-15 14.30.22.jpg", true),
        ("DSC_1234.JPG", false),
        ("IMG_2049.JPG", false),
        ("P1040123.MP4", false)
    ]
    for item in nameCases {
        let parsed = MediaMetadata.filenameDate(item.name)
        expect((parsed != nil) == item.hasTimestamp,
               "文件名时间戳 \(item.name) → \(item.hasTimestamp ? "识别" : "忽略")",
               detail: parsed.map { "\($0)" } ?? "nil")
    }

    // ---- 归档命名 ----
    guard let sampleDate = MediaMetadata.makeLocalDate(year: 2024, month: 3, day: 15,
                                                       hour: 14, minute: 30, second: 22) else {
        expect(false, "构造测试用拍摄时间")
        return
    }

    var settings = MediaImportSettings()
    let combo = MediaArchiver.fileName(originalName: "IMG_1234.JPG", captureDate: sampleDate, settings: settings)
    expect(combo == "20240315_143022_IMG_1234.JPG", "重命名：时间戳 + 原文件名", detail: combo)

    settings.renameMode = .timestampOnly
    let stampOnly = MediaArchiver.fileName(originalName: "IMG_1234.JPG", captureDate: sampleDate, settings: settings)
    expect(stampOnly == "20240315_143022.JPG", "重命名：仅时间戳", detail: stampOnly)

    settings.renameMode = .timestampWithOriginal
    let alreadyStamped = MediaArchiver.fileName(originalName: "IMG_20240315_143022.jpg",
                                               captureDate: sampleDate,
                                               settings: settings)
    expect(alreadyStamped == "IMG_20240315_143022.jpg", "原名已含同一时间戳时不重复前缀", detail: alreadyStamped)

    settings.renameMode = .customWithTimestamp
    settings.customRenamePrefix = "婚礼"
    let customNamed = MediaArchiver.fileName(originalName: "IMG_1234.JPG", captureDate: sampleDate, settings: settings)
    expect(customNamed == "婚礼_20240315_143022.JPG", "重命名：自定义字段 + 拍摄时间", detail: customNamed)

    settings.customRenamePrefix = " "
    let blankCustom = MediaArchiver.fileName(originalName: "IMG_1234.JPG", captureDate: sampleDate, settings: settings)
    expect(blankCustom == "20240315_143022.JPG", "自定义字段为空白时回退到纯时间戳", detail: blankCustom)

    settings.customRenamePrefix = "a/b:c"
    let sanitizedCustom = MediaArchiver.fileName(originalName: "IMG_1234.JPG", captureDate: sampleDate, settings: settings)
    expect(sanitizedCustom == "a-b-c_20240315_143022.JPG", "自定义字段中的非法字符被替换", detail: sanitizedCustom)

    settings.renameByCaptureTime = false
    let kept = MediaArchiver.fileName(originalName: "IMG_1234.JPG", captureDate: sampleDate, settings: settings)
    expect(kept == "IMG_1234.JPG", "关闭重命名后保留原文件名", detail: kept)

    expect(MediaArchiver.sanitize("a:b/c\\d") == "a-b-c-d", "文件名中的冒号与斜杠被替换")

    // ---- 归档路径 ----
    settings = MediaImportSettings()
    let deepPath = MediaArchiver.relativePath(kind: .photo, captureDate: sampleDate,
                                              fileName: "x.jpg", settings: settings)
    expect(deepPath == "Photos/2024/03/15/x.jpg", "归档路径：类型 / 年 / 月 / 日", detail: deepPath)

    settings.folderGranularity = .yearMonth
    let monthPath = MediaArchiver.relativePath(kind: .video, captureDate: sampleDate,
                                               fileName: "x.mp4", settings: settings)
    expect(monthPath == "Videos/2024/03/x.mp4", "归档路径：按年月", detail: monthPath)

    settings.folderGranularity = .year
    let yearPath = MediaArchiver.relativePath(kind: .video, captureDate: sampleDate,
                                              fileName: "x.mp4", settings: settings)
    expect(yearPath == "Videos/2024/x.mp4", "归档路径：按年", detail: yearPath)

    settings.folderGranularity = .month
    let monthOnlyPath = MediaArchiver.relativePath(kind: .video, captureDate: sampleDate,
                                                   fileName: "x.mp4", settings: settings)
    expect(monthOnlyPath == "Videos/03/x.mp4", "归档路径：按月（不带年份）", detail: monthOnlyPath)

    settings.folderGranularity = .monthDay
    let monthDayPath = MediaArchiver.relativePath(kind: .photo, captureDate: sampleDate,
                                                  fileName: "x.jpg", settings: settings)
    expect(monthDayPath == "Photos/03/15/x.jpg", "归档路径：按月 / 日（不带年份）", detail: monthDayPath)

    settings.folderGranularity = .none
    settings.separateByType = false
    let flatPath = MediaArchiver.relativePath(kind: .video, captureDate: sampleDate,
                                              fileName: "x.mp4", settings: settings)
    expect(flatPath == "x.mp4", "归档路径：关闭分类后平铺", detail: flatPath)

    settings.separateByType = true
    settings.photoFolderName = "  相册/精选  "
    expect(settings.folderName(for: .photo) == "相册-精选", "自定义目录名会去除分隔符与空白")
    settings.photoFolderName = ""
    expect(settings.folderName(for: .photo) == "Photos", "自定义目录名为空时回退到默认名称")

    // ---- 容器时间戳换算 ----
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var reference = DateComponents()
    reference.year = 1904
    reference.month = 1
    reference.day = 1
    var target = DateComponents()
    target.year = 2024
    target.month = 3
    target.day = 15
    target.hour = 6
    target.minute = 30
    target.second = 22

    if let referenceDate = utcCalendar.date(from: reference),
       let targetDate = utcCalendar.date(from: target) {
        let seconds = Int64(targetDate.timeIntervalSince(referenceDate))
        let asLocal = MediaMetadata.makeContainerDate(secondsSince1904: seconds, mode: .asLocal)
        let parts = asLocal.map { calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                          from: $0) }
        expect(parts?.year == 2024 && parts?.month == 3 && parts?.day == 15
               && parts?.hour == 6 && parts?.minute == 30 && parts?.second == 22,
               "容器时间按本地时间解释时字段原样保留")

        let asUTC = MediaMetadata.makeContainerDate(secondsSince1904: seconds, mode: .convertFromUTC)
        expect(asUTC == targetDate, "容器时间按 UTC 解释时等于绝对时刻")
    } else {
        expect(false, "构造容器时间换算基准")
    }

    expect(MediaMetadata.makeContainerDate(secondsSince1904: 0, mode: .asLocal) == nil,
           "拒绝容器时间的 0 占位值")
    expect(MediaMetadata.makeContainerDate(secondsSince1904: Int64.max, mode: .asLocal) == nil,
           "拒绝越界的容器时间")

    // ---- 端到端归档 ----
    let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("datacopier-preset-\(UUID().uuidString.prefix(8))")
    let source = sandbox.appendingPathComponent("source")
    let photos = source.appendingPathComponent("photos")
    let videos = source.appendingPathComponent("videos")
    let destination = sandbox.appendingPathComponent("destination")

    do {
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        try fm.createDirectory(at: videos, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    } catch {
        expect(false, "创建归档测试目录", detail: error.localizedDescription)
        return
    }
    defer { try? fm.removeItem(at: sandbox) }

    // 两张同一秒拍摄、同机型的照片：用于验证同秒撞名时的唯一化
    expect(makePhotoWithEXIF(photos.appendingPathComponent("a.jpg").path,
                             exifDate: "2024:03:15 14:30:22", model: "iPhone 15 Pro"),
           "生成带 EXIF 与机型的照片 a.jpg")
    // 同名且同秒同机型：这是真正会撞名的情形——相机连拍或双机位同步都可能出现。
    try? fm.createDirectory(at: photos.appendingPathComponent("dup"), withIntermediateDirectories: true)
    expect(makePhotoWithEXIF(photos.appendingPathComponent("dup/a.jpg").path,
                             exifDate: "2024:03:15 14:30:22", model: "iPhone 15 Pro"),
           "生成同名同秒同机型的照片 dup/a.jpg")
    // 同一秒、不同机型：设备层级应当把两者分开，无需加序号。
    expect(makePhotoWithEXIF(photos.appendingPathComponent("IMG_9999.JPG").path,
                             exifDate: "2024:03:15 14:30:22", model: "ILCE-7M4"),
           "生成同秒不同机型的照片 IMG_9999.JPG")
    // 无 EXIF、无机型：时间只能由文件名给出，机型归入未识别
    expect(makePhotoWithEXIF(photos.appendingPathComponent("IMG_20230601_101112.png").path, exifDate: nil),
           "生成无 EXIF 的照片 IMG_20230601_101112.png")
    try? "本文件不是媒体".write(to: photos.appendingPathComponent("README.txt"),
                             atomically: true, encoding: .utf8)

    let ffmpegPath = FFmpegLocator.locate()?.path
    var videoCreated = false
    var modelVideoCreated = false
    if let ffmpegPath {
        videoCreated = makeVideoWithCreationTime(videos.appendingPathComponent("clip.mp4").path,
                                                creationTime: "2024-05-20T08:15:30Z",
                                                ffmpeg: ffmpegPath)
        modelVideoCreated = makeVideoWithCreationTime(videos.appendingPathComponent("phone.mov").path,
                                                      creationTime: "2024-05-20T08:15:30Z",
                                                      ffmpeg: ffmpegPath,
                                                      model: "iPhone 15 Pro")
    }
    if ffmpegPath != nil {
        expect(videoCreated, "生成带容器创建时间的 MP4")
        expect(modelVideoCreated, "生成带 ©mod 机型标签的 MOV")
    } else {
        print("  [跳过] 未检测到 FFmpeg，视频相关用例不参与")
    }

    // ---- 设备型号提取 ----
    let modelRead = MediaMetadata.read(forPath: photos.appendingPathComponent("a.jpg").path,
                                       kind: .photo,
                                       settings: MediaImportSettings(),
                                       probe: nil,
                                       modifiedDate: Date())
    expect(modelRead.deviceModel == "iPhone 15 Pro", "从 EXIF 读出机型",
           detail: modelRead.deviceModel ?? "nil")

    let noModelRead = MediaMetadata.read(forPath: photos.appendingPathComponent("IMG_20230601_101112.png").path,
                                         kind: .photo,
                                         settings: MediaImportSettings(),
                                         probe: nil,
                                         modifiedDate: Date())
    expect(noModelRead.deviceModel == nil, "无机型标签时返回 nil",
           detail: noModelRead.deviceModel ?? "nil")

    if modelVideoCreated, let probeURL = FFmpegLocator.locateProbe() {
        // 关掉设备分类时不应为 ISO BMFF 视频额外起 ffprobe，机型取自字节解析。
        var noDeviceSettings = MediaImportSettings()
        noDeviceSettings.classifyByDevice = false
        let byteRead = MediaMetadata.read(forPath: videos.appendingPathComponent("phone.mov").path,
                                          kind: .video,
                                          settings: noDeviceSettings,
                                          probe: probeURL,
                                          modifiedDate: Date())
        expect(byteRead.deviceModel == "iPhone 15 Pro",
               "从容器 ©mod 字节直接读出机型（零进程路径）",
               detail: byteRead.deviceModel ?? "nil")
    }

    // ---- 设备名规范化 ----
    expect(MediaImportSettings.normalizedDeviceName("  iPhone 15 Pro  ") == "iPhone 15 Pro",
           "机型名首尾空白被去除")
    expect(MediaImportSettings.normalizedDeviceName("\"Canon EOS R5\"") == "Canon EOS R5",
           "机型名成对引号被去除")
    expect(MediaImportSettings.normalizedDeviceName("DIGITAL  CAMERA") == "DIGITAL CAMERA",
           "机型名内部连续空白被折叠")
    expect(MediaImportSettings.normalizedDeviceName("ILCE-7M4") == "ILCE-7M4",
           "正常机型名保持原样")
    for junk in ["", "   ", "unknown", "N/A", "0", "(null)", "None", "-"] {
        expect(MediaImportSettings.normalizedDeviceName(junk) == nil,
               "占位机型 `\(junk)` 视为未识别")
    }
    expect(MediaImportSettings.normalizedDeviceName(nil) == nil, "缺失机型视为未识别")
    if let truncated = MediaImportSettings.normalizedDeviceName(String(repeating: "M", count: 100)) {
        expect(truncated.count == 64, "超长机型名被截断", detail: "\(truncated.count) 字符")
    } else {
        expect(false, "超长机型名被截断")
    }

    // ---- 设备目录名 ----
    var deviceSettings = MediaImportSettings()
    expect(deviceSettings.deviceFolderName(for: "iPhone 15 Pro") == "iPhone 15 Pro",
           "已知机型直接作为目录名")
    expect(deviceSettings.deviceFolderName(for: nil) == "未知设备",
           "未识别机型归入默认目录",
           detail: deviceSettings.deviceFolderName(for: nil) ?? "nil")
    expect(deviceSettings.deviceFolderName(for: "Acme/Cam 2000") == "Acme-Cam 2000",
           "机型名里的分隔符被替换")
    deviceSettings.unknownDeviceFolderName = "  其他  "
    expect(deviceSettings.deviceFolderName(for: "unknown") == "其他",
           "未识别目录名可自定义并去除空白",
           detail: deviceSettings.deviceFolderName(for: "unknown") ?? "nil")
    deviceSettings.unknownDeviceFolderName = ""
    expect(deviceSettings.deviceFolderName(for: nil) == "未知设备",
           "未识别目录名为空时回退到默认值")
    deviceSettings.classifyByDevice = false
    expect(deviceSettings.deviceFolderName(for: "iPhone 15 Pro") == nil,
           "关闭设备分类后不产生设备层级")

    // ---- 归档路径中的设备层级 ----
    var pathSettings = MediaImportSettings()
    let devicePath = MediaArchiver.relativePath(kind: .photo, captureDate: sampleDate,
                                                fileName: "x.jpg", settings: pathSettings,
                                                deviceModel: "iPhone 15 Pro")
    expect(devicePath == "Photos/iPhone 15 Pro/2024/03/15/x.jpg",
           "归档路径：类型 / 设备 / 年 / 月 / 日", detail: devicePath)

    pathSettings.separateByType = false
    let noTypePath = MediaArchiver.relativePath(kind: .photo, captureDate: sampleDate,
                                                fileName: "x.jpg", settings: pathSettings,
                                                deviceModel: "ILCE-7M4")
    expect(noTypePath == "ILCE-7M4/2024/03/15/x.jpg",
           "关闭类型分类后设备成为顶层目录", detail: noTypePath)

    pathSettings.separateByType = true
    pathSettings.folderGranularity = .none
    let flatDevicePath = MediaArchiver.relativePath(kind: .photo, captureDate: sampleDate,
                                                    fileName: "x.jpg", settings: pathSettings,
                                                    deviceModel: "iPhone 15 Pro")
    expect(flatDevicePath == "Photos/iPhone 15 Pro/x.jpg",
           "日期层级关闭后设备目录仍在", detail: flatDevicePath)

    pathSettings = MediaImportSettings()
    let noDevicePath = MediaArchiver.relativePath(kind: .photo, captureDate: sampleDate,
                                                  fileName: "x.jpg", settings: pathSettings)
    expect(noDevicePath == "Photos/2024/03/15/x.jpg",
           "不传机型时退回原有路径结构", detail: noDevicePath)

    // ---- 容器 ©mod 字节解析 ----
    func quickTimeBytes(_ model: String) -> [UInt8] {
        var bytes: [UInt8] = [0xA9, 0x6D, 0x6F, 0x64]        // ©mod
        let payload = Array(model.utf8)
        bytes.append(UInt8(payload.count >> 8))
        bytes.append(UInt8(payload.count & 0xFF))
        bytes.append(contentsOf: [0x55, 0xC4])               // QuickTime 语言码
        bytes.append(contentsOf: payload)
        return bytes
    }

    func ilstBytes(_ model: String) -> [UInt8] {
        let payload = Array(model.utf8)
        let dataBoxSize = 16 + payload.count
        var bytes: [UInt8] = []
        // 条目长度。本实现不读取它，这里只是为了在字节流里保持真实布局。
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x20])
        bytes.append(contentsOf: [0xA9, 0x6D, 0x6F, 0x64])   // ©mod
        bytes.append(contentsOf: [
            UInt8((dataBoxSize >> 24) & 0xFF), UInt8((dataBoxSize >> 16) & 0xFF),
            UInt8((dataBoxSize >> 8) & 0xFF), UInt8(dataBoxSize & 0xFF)
        ])
        bytes.append(contentsOf: Array("data".utf8))
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x01])   // 版本与类型
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])   // 语言
        bytes.append(contentsOf: payload)
        return bytes
    }

    let quickTimeData = Data(quickTimeBytes("iPhone 15 Pro"))
    expect(MediaMetadata.findDeviceModel(in: quickTimeData) == "iPhone 15 Pro",
           "解析 QuickTime 文本原子形式的 ©mod",
           detail: MediaMetadata.findDeviceModel(in: quickTimeData) ?? "nil")

    let ilstData = Data(ilstBytes("Canon EOS R5"))
    expect(MediaMetadata.findDeviceModel(in: ilstData) == "Canon EOS R5",
           "解析 ilst data 盒子形式的 ©mod",
           detail: MediaMetadata.findDeviceModel(in: ilstData) ?? "nil")

    expect(MediaMetadata.findDeviceModel(in: Data([0x00, 0x01, 0x02, 0x03])) == nil,
           "无 ©mod 标记时返回 nil")

    // 压缩数据里偶然出现的标记字节会解出控制字符，必须被拒绝而不是建出乱码目录。
    var noisy: [UInt8] = [0xA9, 0x6D, 0x6F, 0x64, 0x00, 0x14, 0x55, 0xC4]
    noisy.append(contentsOf: Array(repeating: 0x01, count: 20))
    expect(MediaMetadata.findDeviceModel(in: Data(noisy)) == nil,
           "标记字节后的不可打印内容被拒绝")

    // 第一个候选无效、第二个有效时应继续搜索，而不是就地放弃。
    var mixed = noisy
    mixed.append(contentsOf: quickTimeBytes("Pixel 8"))
    expect(MediaMetadata.findDeviceModel(in: Data(mixed)) == "Pixel 8",
           "跳过无效候选后继续命中后续 ©mod",
           detail: MediaMetadata.findDeviceModel(in: Data(mixed)) ?? "nil")

    // ---- ffprobe 字段解析 ----
    let probeFields = MediaMetadata.parseProbeFields("""
    TAG:creation_time=2024-05-20T08:15:30.000000Z
    TAG:model=iPhone 15 Pro
    TAG:encoder=N/A
    com.apple.quicktime.model=iPhone 15 Pro Max
    """)
    expect(probeFields["creation_time"] == "2024-05-20T08:15:30.000000Z",
           "解析 ffprobe 输出中的创建时间", detail: probeFields["creation_time"] ?? "nil")
    expect(probeFields["model"] == "iPhone 15 Pro", "解析 ffprobe 输出中的机型",
           detail: probeFields["model"] ?? "nil")
    expect(probeFields["com.apple.quicktime.model"] == "iPhone 15 Pro Max",
           "带 Apple 前缀的机型键独立成项")
    expect(probeFields["encoder"] == nil, "N/A 取值被忽略")

    let bareFields = MediaMetadata.parseProbeFields("model=ILCE-7M4\ncreation_time=2024-01-02T03:04:05Z")
    expect(bareFields["model"] == "ILCE-7M4", "无 TAG 前缀的键值同样可解析")

    // ---- 时间来源判定 ----
    let photoRead = MediaMetadata.captureTime(forPath: photos.appendingPathComponent("a.jpg").path,
                                              kind: .photo,
                                              settings: MediaImportSettings(),
                                              probe: nil,
                                              modifiedDate: Date())
    expect(photoRead.source == .exif, "照片时间来源标记为 EXIF",
           detail: photoRead.source?.displayName ?? "nil")
    expect(photoRead.source?.isAuthoritative == true, "EXIF 时间被判定为权威来源")

    let fallbackRead = MediaMetadata.captureTime(forPath: photos.appendingPathComponent("IMG_20230601_101112.png").path,
                                                 kind: .photo,
                                                 settings: MediaImportSettings(),
                                                 probe: nil,
                                                 modifiedDate: Date())
    expect(fallbackRead.source == .filename, "无 EXIF 时改用文件名时间戳",
           detail: fallbackRead.source?.displayName ?? "nil")

    if videoCreated, let probeURL = FFmpegLocator.locateProbe() {
        let videoRead = MediaMetadata.captureTime(forPath: videos.appendingPathComponent("clip.mp4").path,
                                                  kind: .video,
                                                  settings: MediaImportSettings(),
                                                  probe: probeURL,
                                                  modifiedDate: Date())
        expect(videoRead.source == .container, "视频时间来源标记为容器",
               detail: videoRead.source?.displayName ?? "nil")
        let videoParts = videoRead.date.map {
            calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0)
        }
        expect(videoParts?.year == 2024 && videoParts?.month == 5 && videoParts?.day == 20
               && videoParts?.hour == 8 && videoParts?.minute == 15 && videoParts?.second == 30,
               "容器时间按本地时间解释为 2024-05-20 08:15:30",
               detail: videoRead.date.map { "\($0)" } ?? "未解析")
    }

    // ---- 执行媒体归档任务 ----
    var options = TaskOptions.default
    options.copyPreset = .media
    options.conflictPolicy = .skip
    options.algorithm = .sha256
    options.exportManifest = true

    let mediaTask = CopyTask(name: "归档自检",
                             sources: [source.path],
                             destination: destination.path,
                             options: options)

    guard let report = runTaskSync(mediaTask) else {
        expect(false, "媒体归档任务执行完成")
        return
    }

    // 预期落盘：4 张照片（分属 3 台设备）+ 2 个视频（分属 2 台设备，其中一个无机型）
    let expectedPhotos = 4
    let expectedVideos = modelVideoCreated ? 2 : (videoCreated ? 1 : 0)
    let expectedTotal = expectedPhotos + expectedVideos

    expect(report.preset == .media, "报告记录了媒体归档预设")
    expect(report.copiedFiles == expectedTotal, "归档文件数与预期一致",
           detail: "拷贝 \(report.copiedFiles)，预期 \(expectedTotal)")
    expect(report.filteredOutFiles == 1, "非媒体文件被排除",
           detail: "排除 \(report.filteredOutFiles)")
    expect(report.photoFiles == expectedPhotos, "照片计数正确", detail: "\(report.photoFiles)")
    if expectedVideos > 0 {
        expect(report.videoFiles == expectedVideos, "视频计数正确", detail: "\(report.videoFiles)")
    }

    let mediaRoot = destination
    func exists(_ relative: String) -> Bool {
        fm.fileExists(atPath: mediaRoot.appendingPathComponent(relative).path)
    }

    expect(exists("Photos/iPhone 15 Pro/2024/03/15/20240315_143022_a.jpg"),
           "机型目录 + EXIF 时间驱动目录与命名（a.jpg）")
    expect(exists("Photos/iPhone 15 Pro/2024/03/15/20240315_143022_a.jpg")
           && exists("Photos/iPhone 15 Pro/2024/03/15/20240315_143022_a_2.jpg"),
           "同一秒的同名同机型文件自动加序号而非互相覆盖")
    expect(exists("Photos/ILCE-7M4/2024/03/15/20240315_143022_IMG_9999.JPG"),
           "同一秒的不同机型分入各自目录，无需加序号")
    expect(exists("Photos/未知设备/2023/06/01/IMG_20230601_101112.png"),
           "未识别机型归入未知设备目录，文件名时间戳回退到对应日期")
    expect(!exists("Photos/README.txt") && !exists("README.txt") && !exists("source/photos/README.txt"),
           "非媒体文件未出现在目标目录任何位置")

    if videoCreated {
        expect(exists("Videos/未知设备/2024/05/20/20240520_081530_clip.mp4"),
               "无机型的视频按容器时间归档到未识别设备目录")
    }
    if modelVideoCreated {
        expect(exists("Videos/iPhone 15 Pro/2024/05/20/20240520_081530_phone.mov"),
               "带 ©mod 的 MOV 归入机型目录")
    }

    // 设备分布：机型目录与文件数应当一一对应。
    let expectedDevices: [String: Int] = {
        var map = ["iPhone 15 Pro": 2, "ILCE-7M4": 1, "未知设备": 1]
        if videoCreated { map["未知设备", default: 0] += 1 }
        if modelVideoCreated { map["iPhone 15 Pro", default: 0] += 1 }
        return map
    }()
    expect(report.deviceCounts == expectedDevices, "设备分布统计与预期一致",
           detail: report.deviceRanking.map { "\($0.device):\($0.count)" }.joined(separator: " "))
    expect(report.classifiedByDevice, "报告标记为已按设备分类")
    expect(report.deviceCounts.values.reduce(0, +) == report.copiedFiles,
           "设备分布之和等于归档文件数")

    let expectedRenamed = expectedPhotos - 1 + expectedVideos   // 仅 IMG_20230601_101112.png 保留原名
    expect(report.renamedFiles == expectedRenamed, "重命名计数正确",
           detail: "\(report.renamedFiles)，预期 \(expectedRenamed)")
    // 4 张照片中只有 3 张带 EXIF 时间：IMG_20230601_101112.png 的时间来自文件名，
    // 属于推断值而非权威值。
    let authoritativePhotos = expectedPhotos - 1
    expect(report.captureMetadataFiles == authoritativePhotos + expectedVideos,
           "权威时间计数正确",
           detail: "\(report.captureMetadataFiles)，预期 \(authoritativePhotos + expectedVideos)")
    expect(report.captureFallbackFiles == 1, "推断时间计数正确",
           detail: "\(report.captureFallbackFiles)")
    expect(report.mediaFolderCounts.count >= 3, "归档目录分布已统计",
           detail: "\(report.mediaFolderCounts.count) 个目录")
    expect(report.photoFiles + report.videoFiles == report.copiedFiles,
           "照片与视频计数之和等于归档文件数")
    expect(report.failedFiles == 0, "归档过程无失败文件")
    expect(report.verifyFailedFiles == 0, "归档过程无校验不一致")

    // 源素材必须原封不动
    expect(fm.fileExists(atPath: photos.appendingPathComponent("a.jpg").path),
           "归档不移动或删除源文件")

    // 校验清单里的路径是归档后的路径，因此可在目标目录直接复核
    let manifestPath = destination.appendingPathComponent("归档自检.checksums.txt").path
    if fm.fileExists(atPath: manifestPath) {
        let verify = shell("/usr/bin/shasum", ["-a", "256", "-c", manifestPath], cwd: destination.path)
        expect(verify.status == 0, "归档结果的校验清单可被 shasum 复核通过",
               detail: verify.output.split(separator: "\n").prefix(2).joined(separator: " "))
    } else {
        expect(false, "归档任务生成了校验清单")
    }

    // ---- 报告格式 ----
    let markdown = ReportExporter.markdown(report)
    expect(markdown.contains("## 归档"), "Markdown 报告含归档章节")
    expect(markdown.contains("归档目录分布"), "Markdown 报告含目录分布")
    expect(markdown.contains("### 设备分布"), "Markdown 报告含设备分布")
    expect(markdown.contains("iPhone 15 Pro"), "Markdown 报告列出具体机型")
    expect(markdown.contains("拍摄时间"), "Markdown 明细含拍摄时间列")

    let csv = ReportExporter.csv(report)
    expect(csv.contains("拍摄时间"), "CSV 明细含拍摄时间列")
    expect(csv.contains("拷贝预设"), "CSV 头部记录了拷贝预设")
    expect(csv.contains("设备型号"), "CSV 明细含设备型号列")
    expect(csv.contains("# 设备分布"), "CSV 头部记录了设备分布")

    // ---- PDF 报表 ----
    //
    // 样张写到固定目录而不是沙箱：沙箱在用例结束时会被清空，
    // 而报表的排版与图表只能靠人眼确认，留一份可供随时查看。
    let reportSamples = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("datacopier-report-samples")
    try? fm.createDirectory(at: reportSamples, withIntermediateDirectories: true)

    expect(ReportExportFormat.allCases.first == .pdf, "PDF 是导出的首个格式（默认）")
    expect(ReportExportFormat.pdf.fileExtension == "pdf", "PDF 格式使用 .pdf 扩展名")

    if let pdfData = try? ReportExporter.payload(report, format: .pdf) {
        expect(pdfData.count > 3000, "PDF 报表体积合理（非空壳）",
               detail: "\(pdfData.count) 字节")
        expect(pdfData.prefix(5).elementsEqual("%PDF-".utf8), "PDF 文件头正确")

        let pdfPath = reportSamples.appendingPathComponent("归档自检.pdf")
        do {
            try pdfData.write(to: pdfPath)
            expect(true, "PDF 报表写入磁盘")
        } catch {
            expect(false, "PDF 报表写入磁盘", detail: error.localizedDescription)
        }

        if let document = CGPDFDocument(pdfPath as CFURL) {
            expect(document.numberOfPages >= 1, "PDF 可被解析且至少一页",
                   detail: "\(document.numberOfPages) 页")
        } else {
            expect(false, "PDF 可被解析")
        }

        // 明细跨页：构造一份记录很多的报告，确认会自动分页而不是把内容截断。
        var bulky = report
        bulky.records = (0..<160).map { index in
            FileRecord(relativePath: "Photos/iPhone 15 Pro/2024/03/15/20240315_143022_\(index).jpg",
                       sourcePath: "/Volumes/Card/DCIM/IMG_\(index).JPG",
                       destinationPath: "/tmp/dest/IMG_\(index).JPG",
                       size: Int64(index) * 1024,
                       status: .copied,
                       message: nil,
                       captureDate: report.captureEarliest,
                       captureSource: .exif,
                       mediaKind: .photo,
                       deviceModel: "iPhone 15 Pro",
                       originalName: "IMG_\(index).JPG")
        }
        bulky.totalFiles = 160

        if let bulkyData = try? ReportExporter.payload(bulky, format: .pdf) {
            let bulkyPath = reportSamples.appendingPathComponent("批量.pdf")
            try? bulkyData.write(to: bulkyPath)
            if let document = CGPDFDocument(bulkyPath as CFURL) {
                expect(document.numberOfPages >= 3, "记录较多时 PDF 自动分页",
                       detail: "\(document.numberOfPages) 页")
            } else {
                expect(false, "批量 PDF 可被解析")
            }
        } else {
            expect(false, "批量报告可渲染为 PDF")
        }
    } else {
        expect(false, "报告可渲染为 PDF")
    }

    // 全量预设的报告同样应当能出 PDF：没有归档与转码区块时版面依然成立。
    var plainReportForPDF = report
    plainReportForPDF.presetID = CopyPreset.everything.rawValue
    plainReportForPDF.deviceCounts = [:]
    plainReportForPDF.mediaFolderCounts = [:]
    plainReportForPDF.transcodeEnabled = false
    if let simplePDF = try? ReportExporter.payload(plainReportForPDF, format: .pdf) {
        let path = sandbox.appendingPathComponent("全量.pdf")
        try? simplePDF.write(to: path)
        if let document = CGPDFDocument(path as CFURL) {
            expect(document.numberOfPages >= 1, "无归档区块的报告同样能出 PDF",
                   detail: "\(document.numberOfPages) 页")
        } else {
            expect(false, "无归档区块的 PDF 可被解析")
        }
    } else {
        expect(false, "无归档区块的报告可渲染为 PDF")
    }

    // ---- 结局分布的不变量 ----
    //
    // 报表里的环形图是「占比分布」，各段必须互斥且完备，否则占比之和会超过 100%。
    // 这里锁死计数口径：copiedFiles 与 failedFiles 都包含校验不一致的文件，
    // 直接拿来当分段就会重复计数，必须先扣除再单列。
    do {
        var partition = report
        partition.totalFiles = 9
        partition.copiedFiles = 8        // 其中 2 个校验不一致
        partition.verifyFailedFiles = 2
        partition.failedFiles = 2        // 即那 2 个校验不一致，不存在纯失败
        partition.skippedFiles = 1

        let parts = PDFReportRenderer.outcomeSegments(for: partition)
        var byLabel: [String: Double] = [:]
        for part in parts { byLabel[part.label] = part.value }
        let sum = parts.reduce(0) { $0 + $1.value }

        expect(parts.count == Set(parts.map { $0.label }).count,
               "结局分布各段标签互不重复")
        expect(sum == Double(partition.totalFiles), "结局分布各段之和等于文件总数",
               detail: "\(Int(sum)) / \(partition.totalFiles)")
        expect(byLabel["已拷贝"] == 6, "已拷贝段已扣除校验不一致的文件",
               detail: "\(byLabel["已拷贝"].map { String(Int($0)) } ?? "缺失")")
        expect(byLabel["校验不一致"] == 2, "校验不一致单独成段",
               detail: "\(byLabel["校验不一致"].map { String(Int($0)) } ?? "缺失")")
        expect(byLabel["跳过"] == 1, "跳过段数值正确",
               detail: "\(byLabel["跳过"].map { String(Int($0)) } ?? "缺失")")
        expect(byLabel["失败"] == nil, "纯失败为 0 时不产生空段")

        var mixed = report
        mixed.totalFiles = 12
        mixed.copiedFiles = 9            // 7 成功 + 2 校验不一致
        mixed.verifyFailedFiles = 2
        mixed.failedFiles = 5            // 2 校验不一致 + 3 纯失败
        mixed.skippedFiles = 0
        let mixedParts = PDFReportRenderer.outcomeSegments(for: mixed)
        var mixedByLabel: [String: Double] = [:]
        for part in mixedParts { mixedByLabel[part.label] = part.value }
        let mixedSum = mixedParts.reduce(0) { $0 + $1.value }

        expect(mixedSum == Double(mixed.totalFiles), "含纯失败的结局分布之和仍等于文件总数",
               detail: "\(Int(mixedSum)) / \(mixed.totalFiles)")
        expect(mixedByLabel["已拷贝"] == 7 && mixedByLabel["校验不一致"] == 2
               && mixedByLabel["失败"] == 3, "成功 / 校验不一致 / 失败三段各自独立计数",
               detail: "\(Int(mixedByLabel["已拷贝"] ?? -1)) / "
                       + "\(Int(mixedByLabel["校验不一致"] ?? -1)) / "
                       + "\(Int(mixedByLabel["失败"] ?? -1))")
        let naiveSum = Double(mixed.copiedFiles + mixed.skippedFiles
                              + mixed.failedFiles + mixed.verifyFailedFiles)
        expect(mixedSum != naiveSum, "结局分布之和未沿用「各计数直接相加」的错误口径",
               detail: "\(Int(mixedSum)) ≠ \(Int(naiveSum))")
        expect(mixedParts.first?.label == "已拷贝", "成功段排在环形图首位")
    }

    // 只含单段的样张看不出图例与占比的排布，另留一份四段齐全的样张供人眼确认。
    do {
        var mixedSample = report
        mixedSample.taskName = "结局分布样张"
        mixedSample.totalFiles = 15
        mixedSample.copiedFiles = 9        // 7 成功 + 2 校验不一致
        mixedSample.verifyFailedFiles = 2
        mixedSample.failedFiles = 5        // 2 校验不一致 + 3 纯失败
        mixedSample.skippedFiles = 3
        if let data = try? ReportExporter.payload(mixedSample, format: .pdf) {
            try? data.write(to: reportSamples.appendingPathComponent("结局分布.pdf"))
            expect(true, "多段结局样张渲染成功")
        } else {
            expect(false, "多段结局样张渲染成功")
        }
    }

    // 宽容解码回归：新增的归档字段不应破坏旧报告的解析
    if let json = try? ReportExporter.json(report) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try? decoder.decode(TaskReport.self, from: Data(json.utf8))
        expect(restored?.photoFiles == report.photoFiles
               && restored?.filteredOutFiles == report.filteredOutFiles
               && restored?.mediaFolderCounts == report.mediaFolderCounts,
               "归档报告可经 JSON 往返还原")
    } else {
        expect(false, "归档报告可导出为 JSON")
    }

    // 宽容解码回归：旧任务文件没有 customRenamePrefix 字段时回退默认值
    do {
        let legacy = """
        {"renameByCaptureTime":true,"renameMode":"timestampOnly"}
        """
        let restored = try? JSONDecoder().decode(MediaImportSettings.self, from: Data(legacy.utf8))
        expect(restored?.customRenamePrefix == MediaImportSettings().customRenamePrefix,
               "旧媒体配置缺失自定义字段时回退默认前缀",
               detail: restored?.customRenamePrefix ?? "nil")
    }

    // ---- 回归：所有文件拷贝不受影响 ----
    let plainDestination = sandbox.appendingPathComponent("plain")
    try? fm.createDirectory(at: plainDestination, withIntermediateDirectories: true)

    var plainOptions = TaskOptions.default
    plainOptions.copyPreset = .everything
    plainOptions.algorithm = .xxhash64
    let plainTask = CopyTask(name: "全量自检",
                             sources: [source.path],
                             destination: plainDestination.path,
                             options: plainOptions)

    let plainExpected = 5 + expectedVideos
    if let plainReport = runTaskSync(plainTask) {
        expect(plainReport.preset == .everything, "全量任务报告记录预设")
        expect(plainReport.filteredOutFiles == 0, "所有文件拷贝不排除任何文件")
        expect(plainReport.renamedFiles == 0, "所有文件拷贝不改名")
        expect(plainReport.photoFiles == 0 && plainReport.videoFiles == 0, "全量任务不做媒体计数")
        expect(plainReport.copiedFiles == plainExpected, "全量任务拷贝了包括非媒体在内的全部文件",
               detail: "拷贝 \(plainReport.copiedFiles)，预期 \(plainExpected)")
        expect(fm.fileExists(atPath: plainDestination.appendingPathComponent("source/photos/README.txt").path),
               "全量任务保留来源目录结构")
        expect(fm.fileExists(atPath: plainDestination.appendingPathComponent("source/photos/a.jpg").path),
               "全量任务不改动文件名")
        expect(!(plainReport.isMediaArchive), "全量任务不判定为归档")
    } else {
        expect(false, "全量拷贝任务执行完成")
    }

    // ---- 仅时间戳模式：同一秒必然撞名，只能靠序号区分 ----
    var stampSettings = MediaImportSettings()
    stampSettings.renameMode = .timestampOnly

    var stampOptions = TaskOptions.default
    stampOptions.copyPreset = .media
    stampOptions.mediaSettings = stampSettings

    let stampDestination = sandbox.appendingPathComponent("stamponly")
    try? fm.createDirectory(at: stampDestination, withIntermediateDirectories: true)

    let stampTask = CopyTask(name: "仅时间戳",
                             sources: [photos.path],
                             destination: stampDestination.path,
                             options: stampOptions)

    if let stampPlan = try? FilePlanner.plan(stampTask, cancellation: Cancellation()) {
        let paths = Set(stampPlan.items.map { $0.relativePath })
        let names = Set(paths.map { ($0 as NSString).lastPathComponent })

        expect(names.contains("20240315_143022.jpg") && names.contains("20240315_143022_2.jpg"),
               "仅时间戳模式下同一秒的同机型照片分别落盘",
               detail: names.sorted().joined(separator: "、"))

        // 同一秒但不同机型：设备目录不同，因此两边都应保留无序号的文件名。
        // 这正是设备分层顺带解决的撞名问题。
        expect(paths.contains("Photos/iPhone 15 Pro/2024/03/15/20240315_143022.jpg")
               && paths.contains("Photos/ILCE-7M4/2024/03/15/20240315_143022.JPG"),
               "不同机型的同秒素材各自落在机型目录下且不加序号",
               detail: paths.sorted().joined(separator: "、"))
    } else {
        expect(false, "仅时间戳模式规划成功")
    }

    // ---- 边界：纯非媒体来源 ----
    let textOnly = sandbox.appendingPathComponent("textonly")
    try? fm.createDirectory(at: textOnly, withIntermediateDirectories: true)
    try? "note".write(to: textOnly.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

    var textOptions = TaskOptions.default
    textOptions.copyPreset = .media
    let textTask = CopyTask(name: "无媒体",
                            sources: [textOnly.path],
                            destination: destination.path,
                            options: textOptions)
    do {
        _ = try FilePlanner.plan(textTask, cancellation: Cancellation())
        expect(false, "纯非媒体来源在媒体预设下应明确报错")
    } catch let error as PlannerError {
        if case .noMediaFiles = error {
            expect(true, "纯非媒体来源在媒体预设下明确报错")
        } else {
            expect(false, "纯非媒体来源在媒体预设下明确报错", detail: "\(error)")
        }
    } catch {
        expect(false, "纯非媒体来源在媒体预设下明确报错", detail: "\(error)")
    }

    // ---- 边界：关闭时间回退时应跳过而非静默丢弃 ----
    let noTimeSource = sandbox.appendingPathComponent("notime")
    try? fm.createDirectory(at: noTimeSource, withIntermediateDirectories: true)
    expect(makePhotoWithEXIF(noTimeSource.appendingPathComponent("plain.png").path, exifDate: nil),
           "生成无时间信息的图片 plain.png")

    var strictSettings = MediaImportSettings()
    strictSettings.fallbackToFileDate = false
    strictSettings.parseFilenameTimestamp = false

    var strictOptions = TaskOptions.default
    strictOptions.copyPreset = .media
    strictOptions.mediaSettings = strictSettings
    strictOptions.algorithm = .xxhash64

    let strictDestination = sandbox.appendingPathComponent("strict")
    try? fm.createDirectory(at: strictDestination, withIntermediateDirectories: true)

    let strictTask = CopyTask(name: "严格时间",
                              sources: [noTimeSource.path],
                              destination: strictDestination.path,
                              options: strictOptions)

    if let strictReport = runTaskSync(strictTask) {
        expect(strictReport.skippedFiles == 1, "无法确定时间的文件被记为跳过",
               detail: "跳过 \(strictReport.skippedFiles)")
        expect(strictReport.copiedFiles == 0, "无法确定时间的文件未进入目标目录")
        expect(strictReport.records.contains { $0.message?.contains("拍摄时间") == true },
               "跳过记录说明了原因是无法确定拍摄时间")
        expect(!fm.fileExists(atPath: strictDestination.appendingPathComponent("Photos/未知设备/plain.png").path),
               "被跳过的文件确实没有落盘")
    } else {
        expect(false, "严格时间任务执行完成")
    }

    // ---- 关闭设备分类：应退回「类型 / 日期」结构 ----
    var noDeviceSettings = MediaImportSettings()
    noDeviceSettings.classifyByDevice = false

    var noDeviceOptions = TaskOptions.default
    noDeviceOptions.copyPreset = .media
    noDeviceOptions.mediaSettings = noDeviceSettings
    noDeviceOptions.algorithm = .xxhash64

    let noDeviceDestination = sandbox.appendingPathComponent("nodevice")
    try? fm.createDirectory(at: noDeviceDestination, withIntermediateDirectories: true)

    let noDeviceTask = CopyTask(name: "不按设备分类",
                                sources: [photos.path],
                                destination: noDeviceDestination.path,
                                options: noDeviceOptions)

    if let noDeviceReport = runTaskSync(noDeviceTask) {
        expect(noDeviceReport.deviceCounts.isEmpty, "关闭设备分类后设备统计为空",
               detail: "\(noDeviceReport.deviceCounts)")

        // 直接看目录：关了分类之后 Photos 下只应剩年份层，不该出现任何机型目录。
        let photoRoot = noDeviceDestination.appendingPathComponent("Photos")
        let topLevel = (try? fm.contentsOfDirectory(atPath: photoRoot.path))?.sorted() ?? []
        expect(topLevel == ["2023", "2024"], "关闭设备分类后 Photos 下只有年份目录",
               detail: topLevel.joined(separator: "、"))

        expect(fm.fileExists(atPath: noDeviceDestination
                .appendingPathComponent("Photos/2024/03/15/20240315_143022_a.jpg").path),
               "关闭设备分类后回到「类型 / 年 / 月 / 日」路径")
        expect(fm.fileExists(atPath: noDeviceDestination
                .appendingPathComponent("Photos/2024/03/15/20240315_143022_a_2.jpg").path),
               "关闭设备分类后同秒同名仍需序号区分")
    } else {
        expect(false, "不按设备分类的任务执行完成")
    }

    // ---- 规划吞吐：真实相机卡规模 ----
    //
    // 归档的规划阶段要逐个读取拍摄时间，这是整个流程新增的一次遍历。
    // 用数百张照片量级实测，确认它不会成为导入的瓶颈（只测规划，不执行拷贝）。
    let bulkSource = sandbox.appendingPathComponent("bulk")
    try? fm.createDirectory(at: bulkSource, withIntermediateDirectories: true)

    let bulkCount = 300
    var bulkCreated = 0
    for index in 0..<bulkCount {
        let name = String(format: "IMG_%04d.jpg", index)
        if makePhotoWithEXIF(bulkSource.appendingPathComponent(name).path,
                             exifDate: "2024:07:04 09:00:00") {
            bulkCreated += 1
        }
    }
    expect(bulkCreated == bulkCount, "生成 \(bulkCount) 张测试照片", detail: "生成 \(bulkCreated) 张")

    if bulkCreated == bulkCount {
        var bulkOptions = TaskOptions.default
        bulkOptions.copyPreset = .media
        let bulkDestination = sandbox.appendingPathComponent("bulkdest")
        try? fm.createDirectory(at: bulkDestination, withIntermediateDirectories: true)

        let bulkTask = CopyTask(name: "批量规划",
                                sources: [bulkSource.path],
                                destination: bulkDestination.path,
                                options: bulkOptions)

        let planningStart = Date()
        let bulkPlan = try? FilePlanner.plan(bulkTask, cancellation: Cancellation())
        let planningElapsed = Date().timeIntervalSince(planningStart)

        expect(bulkPlan?.items.count == bulkCount, "批量规划产出完整清单",
               detail: "\(bulkPlan?.items.count ?? -1) 项")

        let perFile = planningElapsed / Double(bulkCount) * 1000
        print(String(format: "       %d 张照片规划耗时 %.2fs（%.2f ms/文件）",
                     bulkCount, planningElapsed, perFile))
        expect(planningElapsed < 15, "批量元数据读取未成为规划瓶颈",
               detail: String(format: "%.2fs", planningElapsed))
    }

    // ---- 独立转码任务：端到端 ----
    //
    // 新建任务分为拷贝与转码两类后，转码任务走「扫描来源 → 直接转码 → 输出到
    // 目标目录」的独立路径。用真实 FFmpeg 跑通全链路并锁死报告口径。
    if let ffmpegPath {
        let tcSource = sandbox.appendingPathComponent("tc-source")
        try? fm.createDirectory(at: tcSource, withIntermediateDirectories: true)
        let clipMade = makeTestClip(tcSource.appendingPathComponent("clip_a.mov").path,
                                    width: 640, height: 360, seconds: 1.0, fps: 24,
                                    ffmpeg: ffmpegPath, crf: 6)
        expect(clipMade, "生成转码测试素材")
        // 混入一个非视频文件，确认扫描只挑出视频。
        try? "笔记".write(to: tcSource.appendingPathComponent("notes.txt"),
                          atomically: true, encoding: .utf8)

        let tcDestination = sandbox.appendingPathComponent("tc-dest")
        try? fm.createDirectory(at: tcDestination, withIntermediateDirectories: true)

        var tcOptions = TaskOptions.default
        tcOptions.transcodeSettings.enabled = true
        let tcTask = CopyTask(name: "独立转码",
                              sources: [tcSource.path],
                              destination: tcDestination.path,
                              options: tcOptions,
                              kind: .transcode)

        if let tcReport = runTaskSync(tcTask) {
            expect(tcReport.taskKind == .transcode, "转码任务报告标记任务类型")
            expect(tcReport.copiedFiles == 0 && !tcReport.isMediaArchive, "转码任务无拷贝口径")
            expect(tcReport.transcodedFiles == 1, "转码任务成功转码 1 个视频",
                   detail: "成功 \(tcReport.transcodedFiles)，"
                           + "跳过 \(tcReport.transcodeSkippedFiles)，"
                           + "失败 \(tcReport.transcodeFailedFiles)")
            let outputs = (try? fm.contentsOfDirectory(atPath: tcDestination.path)) ?? []
            expect(!outputs.isEmpty, "转码输出落在任务目标目录",
                   detail: outputs.joined(separator: ", "))
            expect(tcReport.records.first?.transcode != nil, "输入记录挂上了转码结果")
            expect(tcReport.transcodeFailures.isEmpty, "转码任务无失败明细")

            // 报告出口按任务类型切换口径。
            expect(ReportExporter.markdown(tcReport).contains("视频转码报告"),
                   "转码任务 Markdown 报告使用转码口径")
            if let data = try? ReportExporter.payload(tcReport, format: .pdf) {
                try? data.write(to: reportSamples.appendingPathComponent("独立转码.pdf"))
                expect(true, "转码任务报告可渲染为 PDF")
            } else {
                expect(false, "转码任务报告可渲染为 PDF")
            }
        } else {
            expect(false, "独立转码任务执行完成")
        }

        // 宽容解码：早期任务文件没有 kind 字段，必须等价于拷贝任务。
        let legacy = CopyTask(name: "旧结构", sources: ["/a"], destination: "/b", options: .default)
        if let data = try? JSONEncoder().encode([legacy]),
           let restored = try? JSONDecoder().decode([CopyTask].self, from: data) {
            expect(restored.first?.taskKind == .copy, "缺 kind 字段的旧任务解析为拷贝任务")
        } else {
            expect(false, "缺 kind 字段的旧任务可解析")
        }

        // 转码任务经 JSON 往返后类型保持。
        if let data = try? JSONEncoder().encode([tcTask]),
           let restored = try? JSONDecoder().decode([CopyTask].self, from: data) {
            expect(restored.first?.taskKind == .transcode, "转码任务类型可经 JSON 往返保持")
        } else {
            expect(false, "转码任务可经 JSON 往返")
        }
    }

    // ---- 预设文案回归 ----
    expect(CopyPreset.everything.displayName == "文件拷贝", "预设更名为「文件拷贝」")
    expect(CopyPreset.media.displayName == "媒体拷贝", "媒体预设名称保持「媒体拷贝」")
}

// MARK: - 主流程

print("数据拷贝引擎自检")
print(String(repeating: "=", count: 52))

/// 按需运行部分分组。
///
/// 用法：`selfcheck [组号…]`，组号取 1–6，缺省表示全部运行。
/// 存在的意义是迭代效率：转码分组要真实编码视频，整轮耗时以十分钟计，
/// 而改动往往只影响其中一组，没必要每次都等全量。
let requestedGroups = Set(CommandLine.arguments.dropFirst())
func shouldRun(_ group: Int) -> Bool {
    requestedGroups.isEmpty || requestedGroups.contains("\(group)")
}

if requestedGroups.isEmpty {
    print("数据拷贝引擎自检（全部 6 组）")
} else {
    print("数据拷贝引擎自检（仅第 \(requestedGroups.sorted().joined(separator: "、")) 组）")
}
print(String(repeating: "=", count: 52))

if shouldRun(1) { checkHashing() }
if shouldRun(2) { checkEndToEnd() }
if shouldRun(3) { checkGuards() }
if shouldRun(4) { checkVideoCapability() }
if shouldRun(5) { checkTranscodePipeline() }
if shouldRun(6) { checkCopyPresets() }

print(String(repeating: "=", count: 52))
print("共 \(checks) 项检查，失败 \(failures.count) 项")
if !failures.isEmpty {
    print("失败列表：")
    for item in failures { print("  - \(item)") }
    exit(1)
}
print("全部通过")
exit(0)
