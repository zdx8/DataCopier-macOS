import Foundation

/// 报告的导出格式。
///
/// PDF 排在最前：它是唯一把统计结果图形化并可直接交付/打印的格式，
/// 也是绝大多数用户导出报告的默认意图。其余三种偏向数据再加工，
/// 保留下来是因为它们各自不可替代——CSV 进表格、JSON 进脚本、Markdown 进仓库。
enum ReportExportFormat: String, CaseIterable, Identifiable {
    case pdf
    case markdown
    case csv
    case json

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pdf: return "PDF 报表"
        case .markdown: return "Markdown 报告"
        case .csv: return "CSV 明细表"
        case .json: return "JSON 数据"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .markdown: return "md"
        case .csv: return "csv"
        case .json: return "json"
        }
    }
}

/// 把执行报告导出为可归档、可交付的格式。
enum ReportExporter {

    static func write(_ report: TaskReport, format: ReportExportFormat, to url: URL) throws {
        // PDF 是二进制产出，不走「先拼字符串再写文本」的通道。
        if format == .pdf {
            try PDFReportRenderer.write(report, to: url)
            return
        }

        let content: String
        switch format {
        case .pdf:
            return // 上面已处理，此处仅为穷尽枚举
        case .markdown:
            content = markdown(report)
        case .csv:
            content = csv(report)
        case .json:
            content = try json(report)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 内存中的报告内容。文本格式返回字符串，PDF 返回二进制。
    static func payload(_ report: TaskReport, format: ReportExportFormat) throws -> Data {
        switch format {
        case .pdf:
            guard let data = PDFReportRenderer.data(report) else {
                throw PDFReportRenderer.RenderError.emptyOutput
            }
            return data
        case .markdown:
            return Data(markdown(report).utf8)
        case .csv:
            return Data(csv(report).utf8)
        case .json:
            return Data(try json(report).utf8)
        }
    }

    // MARK: - Markdown

    static func markdown(_ report: TaskReport) -> String {
        // 独立转码任务没有拷贝口径，整份报告单独生成。
        if report.isTranscodeTask {
            return transcodeMarkdown(report)
        }

        var lines: [String] = []
        let outcome = report.success ? "全部完成" : (report.cancelled ? "用户取消" : "存在异常")

        lines.append("# 数据拷贝报告：\(report.taskName)")
        lines.append("")
        lines.append("**总体结果**：\(outcome)")
        lines.append("")
        lines.append("## 任务概要")
        lines.append("")
        lines.append("| 项目 | 内容 |")
        lines.append("| --- | --- |")
        lines.append("| 开始时间 | \(Format.timestamp(report.startedAt)) |")
        lines.append("| 结束时间 | \(Format.timestamp(report.finishedAt)) |")
        lines.append("| 总耗时 | \(Format.duration(report.elapsed)) |")
        lines.append("| 来源 | \(report.sourceRoots.map { "`\($0)`" }.joined(separator: "<br>")) |")
        lines.append("| 目标 | `\(report.destination)` |")
        lines.append("| 校验算法 | \(report.algorithm.displayName) |")
        lines.append("| 拷后复核 | \(report.verifyAfterCopy ? "已启用" : "未启用") |")
        lines.append("| 冲突策略 | \(report.conflictPolicy.displayName) |")
        lines.append("| 拷贝预设 | \(report.preset.displayName) |")
        if report.transcodeEnabled {
            lines.append("| 转码预设 | \(report.transcodePresetName ?? "—") |")
        }
        lines.append("")

        lines.append("## 统计")
        lines.append("")
        lines.append("| 指标 | 数值 |")
        lines.append("| --- | --- |")
        lines.append("| 计划文件数 | \(report.totalFiles) |")
        lines.append("| 计划总大小 | \(Format.bytes(report.totalBytes)) |")
        lines.append("| 成功拷贝 | \(report.copiedFiles) |")
        lines.append("| 成功拷贝字节 | \(Format.bytes(report.copiedBytes)) |")
        lines.append("| 校验通过 | \(report.verifiedFiles) |")
        lines.append("| 校验不一致 | \(report.verifyFailedFiles) |")
        lines.append("| 跳过 | \(report.skippedFiles) |")
        lines.append("| 失败 | \(report.failedFiles) |")
        lines.append("| 平均速度 | \(Format.speed(report.averageBytesPerSecond)) |")
        lines.append("| 峰值速度 | \(Format.speed(report.peakBytesPerSecond)) |")
        if report.truncatedRecordCount > 0 {
            lines.append("| 未记录明细 | \(report.truncatedRecordCount) 条（超出记录上限） |")
        }
        lines.append("")

        if report.isMediaArchive {
            lines.append("## 归档")
            lines.append("")
            lines.append("| 指标 | 数值 |")
            lines.append("| --- | --- |")
            if report.filteredOutFiles > 0 {
                lines.append("| 排除的非照片/视频文件 | \(report.filteredOutFiles) 个 |")
            }
            lines.append("| 按拍摄时间重命名 | \(report.renamedFiles) 个 |")
            lines.append("| 时间取自 EXIF / 容器 | \(report.captureMetadataFiles) 个 |")
            if report.captureFallbackFiles > 0 {
                lines.append("| 时间来自文件名或文件时间（推断值） | \(report.captureFallbackFiles) 个 |")
            }
            if let range = report.captureRangeText {
                lines.append("| 素材时间范围 | \(range) |")
            }
            lines.append("")

            if report.classifiedByDevice {
                lines.append("### 设备分布")
                lines.append("")
                lines.append("| 拍摄设备 | 文件数 |")
                lines.append("| --- | --- |")
                for entry in report.deviceRanking {
                    // 机型来自设备固件，理论上是自由文本，竖线需转义否则会撑破表格。
                    let device = entry.device.replacingOccurrences(of: "|", with: "\\|")
                    lines.append("| \(device) | \(entry.count) |")
                }
                lines.append("")
            }

            if !report.mediaFolderCounts.isEmpty {
                lines.append("### 归档目录分布")
                lines.append("")
                lines.append("| 目录 | 文件数 |")
                lines.append("| --- | --- |")
                for entry in report.mediaFolderRanking.prefix(200) {
                    let folder = entry.folder.isEmpty ? "（目标根目录）" : entry.folder
                    lines.append("| `\(folder)` | \(entry.count) |")
                }
                lines.append("")
            }
        }

        if report.transcodeEnabled {
            lines.append("## 转码")
            lines.append("")
            lines.append("| 指标 | 数值 |")
            lines.append("| --- | --- |")
            lines.append("| 转码预设 | \(report.transcodePresetName ?? "—") |")
            lines.append("| 成功 | \(report.transcodedFiles) 个 |")
            lines.append("| 跳过 | \(report.transcodeSkippedFiles) 个 |")
            lines.append("| 失败 | \(report.transcodeFailedFiles) 个 |")
            lines.append("| 输入总量 | \(Format.bytes(report.transcodeInputBytes)) |")
            lines.append("| 输出总量 | \(Format.bytes(report.transcodeOutputBytes)) |")
            lines.append("| 压缩比 | \(report.transcodeCompressionRatio > 0 ? Format.percent(report.transcodeCompressionRatio) : "—") |")
            lines.append("| 节省空间 | \(Format.bytes(report.transcodeSavedBytes)) |")
            lines.append("| 硬件加速 | \(report.transcodeHardwareFiles) 个 |")
            lines.append("| 转码耗时 | \(Format.duration(report.transcodeDuration)) |")
            if report.transcodeRemovedOriginals > 0 {
                lines.append("| 已删除原始拷贝 | \(report.transcodeRemovedOriginals) 个（源文件未受影响） |")
            }
            if let note = report.transcodeNote {
                lines.append("")
                lines.append("> \(note)")
            }
            lines.append("")

            if !report.transcodeFailures.isEmpty {
                lines.append("### 转码失败明细")
                lines.append("")
                lines.append("| 文件 | 预设 | 原因 |")
                lines.append("| --- | --- | --- |")
                for record in report.transcodeFailures.prefix(200) {
                    let message = (record.transcode?.message ?? "—").replacingOccurrences(of: "|", with: "\\|")
                    lines.append("| `\(record.relativePath)` | \(record.transcode?.presetName ?? "—") | \(message) |")
                }
                lines.append("")
            }

            let succeeded = report.transcodeSuccesses
            if !succeeded.isEmpty {
                lines.append("### 转码结果明细")
                lines.append("")
                lines.append("| 文件 | 输出 | 输入 | 输出 | 压缩比 | 分辨率 | 编码 | 倍速 |")
                lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
                for record in succeeded.prefix(500) {
                    guard let transcode = record.transcode else { continue }
                    let outputName = transcode.outputPath.map { ($0 as NSString).lastPathComponent } ?? "—"
                    let speed = transcode.speed > 0 ? String(format: "%.1f×", transcode.speed) : "—"
                    lines.append("| `\(record.relativePath)` | `\(outputName)` | \(Format.bytes(transcode.inputBytes)) | \(Format.bytes(transcode.outputBytes)) | \(transcode.ratioText) | \(transcode.resolutionText) | \(transcode.videoCodec ?? "—") | \(speed) |")
                }
                lines.append("")
            }
        }

        if !report.mismatches.isEmpty {
            lines.append("## 校验不一致明细")
            lines.append("")
            lines.append("| 文件 | 源摘要 | 目标摘要 |")
            lines.append("| --- | --- | --- |")
            for record in report.mismatches.prefix(200) {
                lines.append("| `\(record.relativePath)` | `\(record.sourceDigest ?? "—")` | `\(record.destinationDigest ?? "—")` |")
            }
            lines.append("")
        }

        if !report.failures.isEmpty {
            lines.append("## 失败明细")
            lines.append("")
            lines.append("| 文件 | 大小 | 原因 |")
            lines.append("| --- | --- | --- |")
            for record in report.failures.prefix(200) {
                lines.append("| `\(record.relativePath)` | \(Format.bytes(record.size)) | \(record.message ?? "—") |")
            }
            lines.append("")
        }

        lines.append("## 完整文件明细")
        lines.append("")
        // 归档任务下文件已被重组，展示「拍摄时间 / 来源 / 类型」比耗时更能说明问题；
        // 普通拷贝任务则关注传输性能，两套表头各自保留各自关心的列。
        let showArchive = report.isMediaArchive
        if showArchive {
            lines.append("| # | 目标文件 | 拍摄时间 | 时间来源 | 类型 | 大小 | 状态 | 摘要 |")
            lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
        } else {
            lines.append("| # | 文件 | 大小 | 状态 | 耗时 | 速度 | 摘要 |")
            lines.append("| --- | --- | --- | --- | --- | --- | --- |")
        }
        for (index, record) in report.records.enumerated() {
            let digest = record.sourceDigest.map { String($0.prefix(16)) } ?? "—"
            if showArchive {
                lines.append("| \(index + 1) | `\(record.relativePath)` | \(captureText(record.captureDate)) | \(record.captureSource?.displayName ?? "—") | \(record.mediaKind?.displayName ?? "—") | \(Format.bytes(record.size)) | \(record.status.displayName) | `\(digest)` |")
            } else {
                lines.append("| \(index + 1) | `\(record.relativePath)` | \(Format.bytes(record.size)) | \(record.status.displayName) | \(Format.duration(record.duration)) | \(Format.speed(record.bytesPerSecond)) | `\(digest)` |")
            }
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    /// 独立转码任务的 Markdown 报告：全部章节围绕转码三态与体积变化展开。
    private static func transcodeMarkdown(_ report: TaskReport) -> String {
        var lines: [String] = []
        let outcome = report.success ? "全部完成" : (report.cancelled ? "用户取消" : "存在异常")

        lines.append("# 视频转码报告：\(report.taskName)")
        lines.append("")
        lines.append("**总体结果**：\(outcome)")
        lines.append("")
        lines.append("## 任务概要")
        lines.append("")
        lines.append("| 项目 | 内容 |")
        lines.append("| --- | --- |")
        lines.append("| 开始时间 | \(Format.timestamp(report.startedAt)) |")
        lines.append("| 结束时间 | \(Format.timestamp(report.finishedAt)) |")
        lines.append("| 总耗时 | \(Format.duration(report.elapsed)) |")
        lines.append("| 来源 | \(report.sourceRoots.map { "`\($0)`" }.joined(separator: "<br>")) |")
        lines.append("| 输出位置 | `\(report.destination)` |")
        lines.append("| 转码预设 | \(report.transcodePresetName ?? "—") |")
        lines.append("")

        lines.append("## 统计")
        lines.append("")
        lines.append("| 指标 | 数值 |")
        lines.append("| --- | --- |")
        lines.append("| 来源视频数 | \(report.totalFiles) |")
        lines.append("| 已转码 | \(report.transcodedFiles) |")
        lines.append("| 跳过 | \(report.transcodeSkippedFiles) |")
        lines.append("| 转码失败 | \(report.transcodeFailedFiles) |")
        lines.append("| 输入总量 | \(Format.bytes(report.transcodeInputBytes)) |")
        lines.append("| 输出总量 | \(Format.bytes(report.transcodeOutputBytes)) |")
        lines.append("| 压缩比 | \(report.transcodeCompressionRatio > 0 ? Format.percent(report.transcodeCompressionRatio) : "—") |")
        lines.append("| 节省空间 | \(Format.bytes(report.transcodeSavedBytes)) |")
        lines.append("| 硬件加速 | \(report.transcodeHardwareFiles) 个 |")
        lines.append("| 转码耗时 | \(Format.duration(report.transcodeDuration)) |")
        if let note = report.transcodeNote {
            lines.append("")
            lines.append("> \(note)")
        }
        lines.append("")

        if !report.transcodeFailures.isEmpty {
            lines.append("## 转码失败明细")
            lines.append("")
            lines.append("| 文件 | 预设 | 原因 |")
            lines.append("| --- | --- | --- |")
            for record in report.transcodeFailures.prefix(200) {
                let message = (record.transcode?.message ?? "—").replacingOccurrences(of: "|", with: "\\|")
                lines.append("| `\(record.relativePath)` | \(record.transcode?.presetName ?? "—") | \(message) |")
            }
            lines.append("")
        }

        let succeeded = report.transcodeSuccesses
        if !succeeded.isEmpty {
            lines.append("## 转码结果明细")
            lines.append("")
            lines.append("| 文件 | 输出 | 输入 | 输出 | 压缩比 | 分辨率 | 编码 | 倍速 |")
            lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
            for record in succeeded.prefix(500) {
                guard let transcode = record.transcode else { continue }
                let outputName = transcode.outputPath.map { ($0 as NSString).lastPathComponent } ?? "—"
                let speed = transcode.speed > 0 ? String(format: "%.1f×", transcode.speed) : "—"
                lines.append("| `\(record.relativePath)` | `\(outputName)` | \(Format.bytes(transcode.inputBytes)) | \(Format.bytes(transcode.outputBytes)) | \(transcode.ratioText) | \(transcode.resolutionText) | \(transcode.videoCodec ?? "—") | \(speed) |")
            }
            lines.append("")
        }

        if !report.records.isEmpty {
            lines.append("## 完整文件明细")
            lines.append("")
            lines.append("| # | 文件 | 大小 | 转码结果 | 输出体积 | 说明 |")
            lines.append("| --- | --- | --- | --- | --- | --- |")
            for (index, record) in report.records.enumerated() {
                let status = record.transcode?.status.displayName ?? record.status.displayName
                let outputBytes = record.transcode.map { Format.bytes($0.outputBytes) } ?? "—"
                let message = (record.transcode?.message ?? record.message ?? "—")
                    .replacingOccurrences(of: "|", with: "\\|")
                lines.append("| \(index + 1) | `\(record.relativePath)` | \(Format.bytes(record.size)) | \(status) | \(outputBytes) | \(message) |")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - CSV

    static func csv(_ report: TaskReport) -> String {
        var lines: [String] = []

        lines.append("# 数据拷贝报告：\(csvEscape(report.taskName))")
        lines.append("# 开始,\(Format.timestamp(report.startedAt)),结束,\(Format.timestamp(report.finishedAt)),总耗时,\(Format.duration(report.elapsed))")
        lines.append("# 拷贝预设,\(csvEscape(report.preset.displayName))")
        lines.append("# 计划文件数,\(report.totalFiles),成功,\(report.copiedFiles),跳过,\(report.skippedFiles),失败,\(report.failedFiles),校验不一致,\(report.verifyFailedFiles)")
        lines.append("# 平均速度,\(Format.speed(report.averageBytesPerSecond)),峰值速度,\(Format.speed(report.peakBytesPerSecond))")
        if report.isMediaArchive {
            lines.append("# 排除非照片/视频,\(report.filteredOutFiles),按拍摄时间重命名,\(report.renamedFiles)")
            lines.append("# 时间取自元数据,\(report.captureMetadataFiles),时间推断,\(report.captureFallbackFiles),素材时间范围,\(csvEscape(report.captureRangeText ?? "—"))")
            if report.classifiedByDevice {
                let summary = report.deviceRanking
                    .map { "\($0.device):\($0.count)" }
                    .joined(separator: " ")
                lines.append("# 设备分布,\(csvEscape(summary))")
            }
        }
        if report.transcodeEnabled {
            lines.append("# 转码预设,\(csvEscape(report.transcodePresetName ?? "—")),成功,\(report.transcodedFiles),跳过,\(report.transcodeSkippedFiles),失败,\(report.transcodeFailedFiles)")
            lines.append("# 转码输入总量,\(report.transcodeInputBytes),输出总量,\(report.transcodeOutputBytes),节省,\(report.transcodeSavedBytes),耗时,\(Format.duration(report.transcodeDuration))")
        }
        lines.append("")

        lines.append("序号,相对路径,源路径,目标路径,大小(字节),大小,状态,拍摄时间,时间来源,媒体类型,设备型号,归档前文件名,耗时(秒),速度(字节/秒),源摘要,目标摘要,是否复核,消息,转码状态,转码预设,输出路径,输出大小(字节),压缩比,输出分辨率,视频编码,是否硬件加速,转码消息")
        for (index, record) in report.records.enumerated() {
            let transcode = record.transcode
            let fields: [String] = [
                String(index + 1),
                record.relativePath,
                record.sourcePath,
                record.destinationPath,
                String(record.size),
                Format.bytes(record.size),
                record.status.displayName,
                captureText(record.captureDate),
                record.captureSource?.displayName ?? "",
                record.mediaKind?.displayName ?? "",
                record.deviceModel ?? "",
                record.originalName ?? "",
                String(format: "%.3f", record.duration),
                String(format: "%.0f", record.bytesPerSecond),
                record.sourceDigest ?? "",
                record.destinationDigest ?? "",
                record.verified ? "是" : "否",
                record.message ?? "",
                transcode?.status.displayName ?? "",
                transcode?.presetName ?? "",
                transcode?.outputPath ?? "",
                transcode.map { String($0.outputBytes) } ?? "",
                transcode.map { String(format: "%.4f", $0.compressionRatio) } ?? "",
                transcode?.resolutionText ?? "",
                transcode?.videoCodec ?? "",
                transcode.map { $0.usedHardware ? "是" : "否" } ?? "",
                transcode?.message ?? ""
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    /// 拍摄时间的可读文本。缺省时返回破折号，避免导出后出现空单元格难以区分
    /// 「没有时间」与「导出失败」。
    private static func captureText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    // MARK: - JSON

    static func json(_ report: TaskReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }

    /// 生成默认文件名，例如 `任务名-report-20260912-1620.md`
    static func suggestedFileName(for report: TaskReport, format: ReportExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let base = Format.safeFileName(report.taskName)
        return "\(base)-report-\(formatter.string(from: report.finishedAt)).\(format.fileExtension)"
    }
}
