import Foundation
import CoreGraphics
import CoreText

/// 把执行报告渲染成一份带图表的 PDF 报表。
///
/// 关于坐标系：PDF 的原点在左下角，而报表的书写顺序自上而下。
/// 本文件用「自上而下的 top 值」描述版面（`top` 指元素上边缘距页顶的距离），
/// 只在绘制前由 `Layout.rect` 换算到 Core Graphics 坐标。换算集中在一处，
/// 版面代码读起来与人的直觉一致，也不会出现「某一块上下颠倒」。
///
/// 关于文字：绘制走 CoreText 而非 AppKit 的字符串绘制。CoreText 在 y 轴向上的
/// 上下文里直接按「从矩形顶部向下排」布局，不需要额外翻转，并且自带字体级联——
/// 报告里中英混排（中文标签 + 英文路径）无需手工挑字体。
enum PDFReportRenderer {

    enum FontWeight {
        case regular
        case medium
        case bold
    }

    /// 渲染失败的原因。单独定义而不复用报告导出器的错误，
    /// 是为了让调用方能区分「内容生成失败」与「磁盘写入失败」。
    enum RenderError: LocalizedError {
        case cannotCreateConsumer
        case cannotCreateContext
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .cannotCreateConsumer: return "无法创建 PDF 输出目标"
            case .cannotCreateContext: return "无法创建 PDF 绘制上下文"
            case .emptyOutput: return "PDF 报表内容为空"
            }
        }
    }

    // MARK: - 页面几何

    private enum Layout {
        static let pageWidth: CGFloat = 595.276   // A4 纵向（pt）
        static let pageHeight: CGFloat = 841.89
        static let margin: CGFloat = 46
        static var contentWidth: CGFloat { pageWidth - margin * 2 }
        /// 页脚占用的高度，正文不得侵入
        static let footerReserve: CGFloat = 24

        /// 自上而下的矩形换算到 Core Graphics 坐标。
        static func rect(top: CGFloat, height: CGFloat, x: CGFloat, width: CGFloat) -> CGRect {
            CGRect(x: x, y: pageHeight - top - height, width: width, height: height)
        }
    }

    // MARK: - 配色

    /// 报表用于打印与归档，固定浅色主题，不跟随应用外观设置。
    private enum Palette {
        static let ink = CGColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        static let muted = CGColor(red: 0.45, green: 0.47, blue: 0.51, alpha: 1)
        static let onAccent = CGColor(red: 0.90, green: 0.93, blue: 0.99, alpha: 1)
        static let accent = CGColor(red: 0.16, green: 0.42, blue: 0.86, alpha: 1)
        static let good = CGColor(red: 0.13, green: 0.60, blue: 0.36, alpha: 1)
        static let warn = CGColor(red: 0.90, green: 0.58, blue: 0.12, alpha: 1)
        static let bad = CGColor(red: 0.83, green: 0.24, blue: 0.22, alpha: 1)
        static let critical = CGColor(red: 0.55, green: 0.10, blue: 0.10, alpha: 1)
        static let violet = CGColor(red: 0.48, green: 0.34, blue: 0.82, alpha: 1)
        static let rule = CGColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 1)
        static let panel = CGColor(red: 0.965, green: 0.970, blue: 0.978, alpha: 1)
        static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

    /// 多分段图表的循环配色。
    private static let seriesColors: [CGColor] = [
        Palette.accent, Palette.good, Palette.warn, Palette.bad, Palette.violet,
        CGColor(red: 0.16, green: 0.68, blue: 0.72, alpha: 1),
        CGColor(red: 0.72, green: 0.42, blue: 0.62, alpha: 1),
        CGColor(red: 0.42, green: 0.52, blue: 0.30, alpha: 1)
    ]

    // MARK: - 字体与段落

    /// 系统字体在缺字时会自动级联到中文字体，因此无需显式指定 PingFang。
    private static func font(size: CGFloat, weight: FontWeight) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard weight != .regular else { return base }
        let traits: CTFontSymbolicTraits = .traitBold
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    private static func wrapStyle() -> CTParagraphStyle {
        var alignment = CTTextAlignment.left
        var lineBreak = CTLineBreakMode.byWordWrapping
        var lineSpacing: CGFloat = 2

        // 设置项里存的是指针，必须在 `CTParagraphStyleCreate` 读取它之前一直有效，
        // 因此显式嵌套 withUnsafePointer，而不是在数组字面量里写 `&变量`
        // ——后者构造出的指针只在当次 `init` 调用内有效。
        return withUnsafePointer(to: &alignment) { alignmentPointer in
            withUnsafePointer(to: &lineBreak) { lineBreakPointer in
                withUnsafePointer(to: &lineSpacing) { spacingPointer in
                    let settings: [CTParagraphStyleSetting] = [
                        CTParagraphStyleSetting(spec: .alignment,
                                                valueSize: MemoryLayout<CTTextAlignment>.size,
                                                value: alignmentPointer),
                        CTParagraphStyleSetting(spec: .lineBreakMode,
                                                valueSize: MemoryLayout<CTLineBreakMode>.size,
                                                value: lineBreakPointer),
                        CTParagraphStyleSetting(spec: .lineSpacingAdjustment,
                                                valueSize: MemoryLayout<CGFloat>.size,
                                                value: spacingPointer)
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
    }

    // MARK: - 对外入口

    /// 渲染为 PDF 数据。任何一份报告都能产出至少一页合法文档。
    static func data(_ report: TaskReport) -> Data? {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
        var box = CGRect(x: 0, y: 0, width: Layout.pageWidth, height: Layout.pageHeight)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        let canvas = Canvas(context: context)
        render(report, into: canvas)
        canvas.finish()

        return output.length > 0 ? output as Data : nil
    }

    static func write(_ report: TaskReport, to url: URL) throws {
        guard let payload = data(report) else { throw RenderError.emptyOutput }
        try payload.write(to: url, options: .atomic)
    }

    // MARK: - 版面编排

    private static func render(_ report: TaskReport, into canvas: Canvas) {
        canvas.beginPage()
        cover(report, canvas)
        summary(report, canvas)
        outcome(report, canvas)

        if report.isMediaArchive {
            archive(report, canvas)
            devices(report, canvas)
            folders(report, canvas)
        }

        if report.transcodeEnabled {
            transcode(report, canvas)
        }

        if !report.records.isEmpty {
            detail(report, canvas)
        }
        canvas.finish()
    }

    private static func cover(_ report: TaskReport, _ canvas: Canvas) {
        canvas.banner(height: 92) { band in
            band.text(report.isTranscodeTask ? "视频转码报告" : "数据拷贝报告",
                      top: 26, size: 23, weight: .bold,
                      color: Palette.white, x: Layout.margin + 4)
            band.text(report.taskName, top: 58, size: 11.5,
                      color: Palette.onAccent, x: Layout.margin + 4)
        }
        canvas.space(14)
        let subtitle = report.isTranscodeTask
            ? "转码任务　·　预设 \(report.transcodePresetName ?? "—")　·　"
                + "\(Format.timestamp(report.startedAt)) 起，耗时 \(Format.duration(report.elapsed))"
            : "\(report.preset.displayName)　·　"
                + "\(Format.timestamp(report.startedAt)) 起，耗时 \(Format.duration(report.elapsed))"
        canvas.text(subtitle, top: canvas.cursor, size: 9.5, color: Palette.muted)
        canvas.space(14)
    }

    private static func summary(_ report: TaskReport, _ canvas: Canvas) {
        canvas.sectionTitle("执行概况")

        // 独立转码任务没有拷贝口径：卡片与键值行都换成转码视角。
        if report.isTranscodeTask {
            canvas.cardGrid([
                Canvas.Card(title: "来源视频", value: "\(report.totalFiles)", unit: "个"),
                Canvas.Card(title: "已转码", value: "\(report.transcodedFiles)", unit: "个",
                            tint: Palette.good),
                Canvas.Card(title: "跳过", value: "\(report.transcodeSkippedFiles)", unit: "个"),
                Canvas.Card(title: "转码失败", value: "\(report.transcodeFailedFiles)", unit: "个",
                            tint: report.transcodeFailedFiles > 0 ? Palette.bad : Palette.ink),
                Canvas.Card(title: "输入体积", value: Format.bytes(report.transcodeInputBytes)),
                Canvas.Card(title: "输出体积", value: Format.bytes(report.transcodeOutputBytes)),
                Canvas.Card(title: "节省空间", value: Format.bytes(report.transcodeSavedBytes),
                            tint: Palette.good),
                Canvas.Card(title: "硬件加速", value: "\(report.transcodeHardwareFiles)", unit: "个")
            ])
            canvas.space(12)

            canvas.keyValueRows([
                ("输出位置", report.destination),
                ("来源", report.sourceRoots.joined(separator: "　")),
                ("转码预设", report.transcodePresetName ?? "—")
            ])
            canvas.space(16)
            return
        }

        var cards: [Canvas.Card] = [
            Canvas.Card(title: "计划文件", value: "\(report.totalFiles)", unit: "个"),
            Canvas.Card(title: "已拷贝", value: "\(report.copiedFiles)", unit: "个",
                        tint: report.copiedFiles > 0 ? Palette.good : Palette.ink),
            Canvas.Card(title: "跳过", value: "\(report.skippedFiles)", unit: "个"),
            Canvas.Card(title: "失败", value: "\(report.failedFiles)", unit: "个",
                        tint: report.failedFiles > 0 ? Palette.bad : Palette.ink),
            Canvas.Card(title: "校验不一致", value: "\(report.verifyFailedFiles)", unit: "个",
                        tint: report.verifyFailedFiles > 0 ? Palette.bad : Palette.ink),
            Canvas.Card(title: "数据量", value: Format.bytes(report.totalBytes)),
            Canvas.Card(title: "平均速度", value: Format.speed(report.averageBytesPerSecond)),
            Canvas.Card(title: "峰值速度", value: Format.speed(report.peakBytesPerSecond))
        ]

        if report.isMediaArchive {
            cards.append(Canvas.Card(title: "照片", value: "\(report.photoFiles)", unit: "个"))
            cards.append(Canvas.Card(title: "视频", value: "\(report.videoFiles)", unit: "个"))
            cards.append(Canvas.Card(title: "已重命名", value: "\(report.renamedFiles)", unit: "个"))
            if report.classifiedByDevice {
                cards.append(Canvas.Card(title: "涉及设备", value: "\(report.deviceCounts.count)", unit: "种"))
            }
        }

        if report.transcodeEnabled {
            cards.append(Canvas.Card(title: "转码成功", value: "\(report.transcodedFiles)", unit: "个",
                                     tint: Palette.accent))
            cards.append(Canvas.Card(title: "转码节省", value: Format.bytes(report.transcodeSavedBytes),
                                     tint: Palette.good))
        }

        canvas.cardGrid(cards)
        canvas.space(12)

        canvas.keyValueRows([
            ("目标位置", report.destination),
            ("来源", report.sourceRoots.joined(separator: "　")),
            ("校验算法", report.algorithm.shortName
                + (report.verifyAfterCopy ? "（拷贝后复核）" : "（未复核）"))
        ])
        canvas.space(16)
    }

    /// 文件结局的分段构成（标签、数值、配色）。
    ///
    /// 不变量：各段互斥且完备，故占比之和恒为 100%。注意计数口径——
    /// `copiedFiles` 已包含校验不一致的文件，`failedFiles` 同样包含，
    /// 所以必须先把 `verifyFailedFiles` 从两者中扣除，再单列「校验不一致」。
    /// 独立成函数是为了让自检能直接校验这一不变量。
    static func outcomeSegments(for report: TaskReport)
        -> [(label: String, value: Double, color: CGColor)] {
        let verifyFailed = report.verifyFailedFiles
        let succeeded = max(0, report.copiedFiles - verifyFailed)
        let failedOnly = max(0, report.failedFiles - verifyFailed)

        var parts: [(label: String, value: Double, color: CGColor)] = []
        if succeeded > 0 { parts.append(("已拷贝", Double(succeeded), Palette.good)) }
        if report.skippedFiles > 0 { parts.append(("跳过", Double(report.skippedFiles), Palette.warn)) }
        if verifyFailed > 0 { parts.append(("校验不一致", Double(verifyFailed), Palette.critical)) }
        if failedOnly > 0 { parts.append(("失败", Double(failedOnly), Palette.bad)) }
        return parts
    }

    private static func outcome(_ report: TaskReport, _ canvas: Canvas) {
        // 转码任务的结局是转码三态；拷贝任务沿用文件结局口径。
        let segments: [Canvas.Segment]
        if report.isTranscodeTask {
            let raw: [(String, Int, CGColor)] = [
                ("已转码", report.transcodedFiles, Palette.good),
                ("跳过", report.transcodeSkippedFiles, Palette.warn),
                ("转码失败", report.transcodeFailedFiles, Palette.bad)
            ]
            segments = raw.filter { item in item.1 > 0 }
                .map { item in
                    Canvas.Segment(label: item.0, value: Double(item.1), color: item.2)
                }
        } else {
            segments = outcomeSegments(for: report).map {
                Canvas.Segment(label: $0.label, value: $0.value, color: $0.color)
            }
        }
        guard segments.reduce(0, { $0 + $1.value }) > 0 else { return }

        let donutSize: CGFloat = 124
        // 预留整块高度：环形图与右侧图例同高，图例最多四行。
        canvas.ensure(donutSize + 62)
        canvas.sectionTitle(report.isTranscodeTask ? "转码结果分布" : "文件结局分布")

        let outcomeTotal = Int(segments.reduce(0) { $0 + $1.value })
        canvas.donut(segments: segments,
                     top: canvas.cursor,
                     x: Layout.margin,
                     size: donutSize,
                     centerLabel: "\(outcomeTotal)",
                     centerCaption: report.isTranscodeTask ? "个视频" : "个文件")
        canvas.legend(segments: segments,
                      x: Layout.margin + donutSize + 24,
                      top: canvas.cursor + 22)
        canvas.space(donutSize + 14)
    }

    // MARK: 归档

    private static func archive(_ report: TaskReport, _ canvas: Canvas) {
        canvas.ensure(166)
        canvas.sectionTitle("归档结果")

        var rows: [(String, String)] = [
            ("归档规则", archiveRule(report)),
            ("按拍摄时间重命名", "\(report.renamedFiles) 个")
        ]
        if report.filteredOutFiles > 0 {
            rows.append(("已排除的非照片/视频文件", "\(report.filteredOutFiles) 个"))
        }
        if let range = report.captureRangeText {
            rows.append(("素材时间范围", range))
        }
        canvas.keyValueRows(rows)
        canvas.space(14)

        // 时间来源构成：权威值与推断值的比例直接决定归档日期的可信度。
        let authoritative = Double(report.captureMetadataFiles)
        let inferred = Double(report.captureFallbackFiles)
        guard authoritative + inferred > 0 else { return }

        canvas.ensure(126)
        canvas.sectionTitle("拍摄时间来源")
        canvas.stackedBar(segments: [
            Canvas.Segment(label: "EXIF / 容器时间", value: authoritative, color: Palette.good),
            Canvas.Segment(label: "文件名 / 文件时间（推断）", value: inferred, color: Palette.warn)
        ], top: canvas.cursor, height: 22)
        canvas.space(42)

        canvas.paragraph(report.captureFallbackFiles == 0
                         ? "全部文件的拍摄时间取自相机元数据，归档日期可直接采信。"
                         : "其中 \(report.captureFallbackFiles) 个文件的时间由文件名或文件修改时间推断，"
                           + "这部分归档日期可能与实际拍摄日期不符。",
                         size: 9, color: Palette.muted)
        canvas.space(18)
    }

    private static func archiveRule(_ report: TaskReport) -> String {
        var parts = ["按拍摄时间重命名"]
        if report.classifiedByDevice { parts.append("按设备型号分类") }
        var segments: [String] = []
        if report.photoFiles > 0 { segments.append("Photos") }
        if report.videoFiles > 0 { segments.append("Videos") }
        if !segments.isEmpty { parts.append(segments.joined(separator: " / ")) }
        return parts.joined(separator: "　·　")
    }

    private static func devices(_ report: TaskReport, _ canvas: Canvas) {
        guard report.classifiedByDevice else { return }
        canvas.ensure(112)

        canvas.sectionTitle("拍摄设备分布")
        canvas.barChart(entries: report.deviceRanking.map {
            Canvas.Entry(label: $0.device, value: Double($0.count))
        }, total: Double(report.photoFiles + report.videoFiles), distinctColors: true)
        canvas.space(18)
    }

    private static func folders(_ report: TaskReport, _ canvas: Canvas) {
        guard !report.mediaFolderCounts.isEmpty else { return }
        canvas.ensure(126)

        canvas.sectionTitle("归档目录分布")

        let ranking = report.mediaFolderRanking
        let shown = Array(ranking.prefix(10))
        canvas.barChart(entries: shown.map {
            Canvas.Entry(label: $0.folder.isEmpty ? "（目标根目录）" : $0.folder,
                         value: Double($0.count))
        }, total: Double(ranking.reduce(0) { $0 + $1.count }), distinctColors: false)

        if ranking.count > shown.count {
            canvas.space(5)
            canvas.text("另有 \(ranking.count - shown.count) 个目录未在图表中列出。",
                        top: canvas.cursor, size: 9, color: Palette.muted)
            canvas.space(5)
        }
        canvas.space(18)
    }

    // MARK: 转码

    private static func transcode(_ report: TaskReport, _ canvas: Canvas) {
        canvas.ensure(216)
        canvas.sectionTitle("视频转码")

        var rows: [(String, String)] = [
            ("转码预设", report.transcodePresetName ?? "—"),
            ("成功 / 跳过 / 失败",
             "\(report.transcodedFiles) / \(report.transcodeSkippedFiles) / \(report.transcodeFailedFiles)"),
            ("转码耗时", Format.duration(report.transcodeDuration))
        ]
        if report.transcodeHardwareFiles > 0 {
            rows.insert(("硬件加速", "\(report.transcodeHardwareFiles) 个"), at: 2)
        }
        canvas.keyValueRows(rows)
        canvas.space(14)

        let input = report.transcodeInputBytes
        let output = report.transcodeOutputBytes
        guard input > 0 || output > 0 else { return }

        canvas.sectionTitle("输入与输出体积")
        canvas.barChart(entries: [
            Canvas.Entry(label: "转码前", value: Double(input)),
            Canvas.Entry(label: "转码后", value: Double(output))
        ], total: Double(max(input, output)), distinctColors: true,
           valueText: { Format.bytes(Int64($0)) })
        canvas.space(6)
        canvas.text("压缩比 \(Format.percent(report.transcodeCompressionRatio))"
                    + "　·　节省 \(Format.bytes(report.transcodeSavedBytes))",
                    top: canvas.cursor, size: 9, color: Palette.muted)
        canvas.space(18)
    }

    // MARK: 明细

    private static func detail(_ report: TaskReport, _ canvas: Canvas) {
        canvas.ensure(106)
        canvas.sectionTitle("文件明细")
        canvas.text("共 \(report.totalFiles) 个文件"
                    + (report.truncatedRecordCount > 0
                       ? "，其中 \(report.truncatedRecordCount) 条超出记录上限未列出" : ""),
                    top: canvas.cursor, size: 9, color: Palette.muted)
        canvas.space(10)

        let fixed: CGFloat = 58 + 76 + 30
        let flexible = Layout.contentWidth - fixed - 190
        let columns: [Canvas.Column] = [
            Canvas.Column(title: "状态", width: 58),
            Canvas.Column(title: "路径", width: max(160, flexible)),
            Canvas.Column(title: "大小", width: 76, alignment: .right),
            Canvas.Column(title: "说明", width: 190)
        ]
        canvas.table(columns: columns, rows: report.records) { record in
            [
                detailStatusText(record),
                record.relativePath,
                Format.bytes(record.size),
                detailMessageText(record)
            ]
        }
    }

    /// 明细表第一列：转码任务显示转码结局，拷贝任务显示文件状态。
    private static func detailStatusText(_ record: FileRecord) -> String {
        if let transcode = record.transcode {
            return transcode.status.displayName
        }
        return record.status.displayName
    }

    /// 明细表说明列：转码任务优先展示转码引擎给出的原因（跳过/失败）。
    private static func detailMessageText(_ record: FileRecord) -> String {
        if let message = record.transcode?.message { return message }
        return record.message ?? (record.wasRenamed ? "已重命名" : "—")
    }

    // MARK: - 绘制画布

    /// 逐页绘制的画布：维护「自上而下」的游标，并负责分页。
    private final class Canvas {
        struct Card {
            var title: String
            var value: String
            var unit: String = ""
            var tint: CGColor = Palette.ink
        }

        struct Entry {
            var label: String
            var value: Double
        }

        struct Segment {
            var label: String
            var value: Double
            var color: CGColor
        }

        struct Column {
            var title: String
            var width: CGFloat
            var alignment: CTTextAlignment = .left
        }

        private let context: CGContext
        /// 区块标题占用的垂直高度（含标题下方留白）。
        static let sectionTitleHeight: CGFloat = 24
        /// 当前元素上边缘距页顶的距离
        private(set) var cursor: CGFloat = Layout.margin
        private var pageIndex = 0

        init(context: CGContext) {
            self.context = context
        }

        // MARK: 分页

        func beginPage() {
            context.beginPDFPage(nil)
            pageIndex += 1
            cursor = Layout.margin
            context.setFillColor(Palette.white)
            context.fill(CGRect(x: 0, y: 0, width: Layout.pageWidth, height: Layout.pageHeight))
        }

        func endPage() {
            drawFooter()
            context.endPDFPage()
        }

        func finish() {
            endPage()
            context.closePDF()
        }

        private var bodyBottom: CGFloat {
            Layout.pageHeight - Layout.margin - Layout.footerReserve
        }

        /// 剩余高度不足时换页。
        func ensure(_ height: CGFloat) {
            guard cursor + height > bodyBottom else { return }
            endPage()
            beginPage()
            text("（续）", top: cursor, size: 9, color: Palette.muted)
            cursor += 16
        }

        func space(_ delta: CGFloat) {
            cursor += delta
        }

        private func drawFooter() {
            let ruleY = Layout.pageHeight - Layout.margin - 10
            context.setStrokeColor(Palette.rule)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: Layout.margin, y: ruleY))
            context.addLine(to: CGPoint(x: Layout.pageWidth - Layout.margin, y: ruleY))
            context.strokePath()

            let label = "第 \(pageIndex) 页"
            text(label, top: Layout.pageHeight - Layout.margin - 4, size: 8, color: Palette.muted,
                 x: Layout.margin, width: Layout.contentWidth, alignment: .center)
        }

        // MARK: 文字

        /// 单行文本；超宽时按尾部截断并补省略号。
        func text(_ string: String,
                  top: CGFloat,
                  size: CGFloat,
                  weight: FontWeight = .regular,
                  color: CGColor = Palette.ink,
                  x: CGFloat = Layout.margin,
                  width: CGFloat? = nil,
                  alignment: CTTextAlignment = .left) {
            guard !string.isEmpty else { return }
            let available = width ?? (Layout.pageWidth - Layout.margin - x)
            guard available > 4 else { return }

            let face = font(size: size, weight: weight)
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: face,
                kCTForegroundColorAttributeName as NSAttributedString.Key: color
            ]))

            if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(available) {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: face,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: color
                ]))
                if let truncated = CTLineCreateTruncatedLine(line, Double(available), .end, ellipsis) {
                    line = truncated
                }
            }

            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            var offsetX: CGFloat = 0
            switch alignment {
            case .right: offsetX = max(0, available - lineWidth)
            case .center: offsetX = max(0, (available - lineWidth) / 2)
            default: offsetX = 0
            }

            context.saveGState()
            // 以基线定位：把墨迹上缘对齐到 top，用字体上行高度换算，避免不同字号上下漂移。
            let baseline = Layout.pageHeight - top - CTFontGetAscent(face)
            context.textPosition = CGPoint(x: x + offsetX, y: baseline)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        /// 自动换行的段落。高度依赖实际排版结果，因此不走「调用方先算 top」的形式：
        /// 分页判断与游标推进都在内部完成。
        func paragraph(_ string: String, size: CGFloat, color: CGColor) {
            guard !string.isEmpty else { return }
            let attributed = NSAttributedString(string: string, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font(size: size, weight: .regular),
                kCTForegroundColorAttributeName as NSAttributedString.Key: color,
                kCTParagraphStyleAttributeName as NSAttributedString.Key: wrapStyle()
            ])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRangeMake(0, 0), nil,
                CGSize(width: Layout.contentWidth, height: .greatestFiniteMagnitude), nil)
            let height = ceil(measured.height)

            ensure(height + 2)

            let rect = Layout.rect(top: cursor, height: height,
                                   x: Layout.margin, width: Layout.contentWidth)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0),
                                                CGPath(rect: rect, transform: nil), nil)
            context.saveGState()
            CTFrameDraw(frame, context)
            context.restoreGState()

            cursor += height
        }

        // MARK: 版面块

        /// 顶部通栏色带：从页面最顶端起算，不受正文游标影响。
        /// 回调内使用页面绝对坐标。
        func banner(height: CGFloat, draw: (Canvas) -> Void) {
            context.setFillColor(Palette.accent)
            context.fill(CGRect(x: 0, y: Layout.pageHeight - height,
                                width: Layout.pageWidth, height: height))
            draw(self)
            cursor = height
        }

        /// 区块标题：自行推进游标，调用方无需再补留白。
        /// 约束「标题 + 至少一行内容」必须同页，避免标题成为页尾孤行。
        func sectionTitle(_ string: String) {
            ensure(Canvas.sectionTitleHeight + 16)
            let top = cursor
            context.setFillColor(Palette.accent)
            context.fill(Layout.rect(top: top + 1.5, height: 12, x: Layout.margin, width: 2.5))
            text(string, top: top, size: 12.5, weight: .bold, color: Palette.ink,
                 x: Layout.margin + 9)
            cursor += Canvas.sectionTitleHeight
        }

        func cardGrid(_ cards: [Card]) {
            guard !cards.isEmpty else { return }
            let perRow = 4
            let gap: CGFloat = 8
            let cardHeight: CGFloat = 46
            let cardWidth = (Layout.contentWidth - gap * CGFloat(perRow - 1)) / CGFloat(perRow)
            let rows = (cards.count + perRow - 1) / perRow

            ensure(CGFloat(rows) * (cardHeight + gap) + 4)

            for (index, card) in cards.enumerated() {
                let row = index / perRow
                let column = index % perRow
                let x = Layout.margin + (cardWidth + gap) * CGFloat(column)
                let top = cursor + CGFloat(row) * (cardHeight + gap)
                let rect = Layout.rect(top: top, height: cardHeight, x: x, width: cardWidth)

                context.setFillColor(Palette.panel)
                context.fill(rect)
                context.setStrokeColor(Palette.rule)
                context.setLineWidth(0.5)
                context.stroke(rect)

                text(card.title, top: top + 7, size: 8, color: Palette.muted,
                     x: x + 9, width: cardWidth - 18)
                let value = card.unit.isEmpty ? card.value : "\(card.value) \(card.unit)"
                text(value, top: top + 19, size: 14.5, weight: .bold, color: card.tint,
                     x: x + 9, width: cardWidth - 18)
            }

            cursor += CGFloat(rows) * (cardHeight + gap)
        }

        func keyValueRows(_ rows: [(String, String)]) {
            guard !rows.isEmpty else { return }
            ensure(CGFloat(rows.count) * 15 + 6)
            for row in rows {
                text(row.0, top: cursor, size: 9.5, color: Palette.muted, width: 170)
                text(row.1, top: cursor, size: 9.5, color: Palette.ink,
                     x: Layout.margin + 178, width: Layout.contentWidth - 178)
                cursor += 15
            }
        }

        // MARK: 图表

        /// 环形图：按占比把各分段画成圆环。`top` 为环外框上缘距页顶的距离。
        func donut(segments: [Segment],
                   top: CGFloat,
                   x: CGFloat,
                   size: CGFloat,
                   centerLabel: String,
                   centerCaption: String) {
            let total = segments.reduce(0) { $0 + $1.value }
            guard total > 0 else { return }

            let radius = size / 2 - 12
            let center = CGPoint(x: x + size / 2, y: Layout.pageHeight - top - size / 2)
            let lineWidth: CGFloat = 20

            context.saveGState()
            context.setLineWidth(lineWidth)
            context.setLineCap(.butt)
            var start = -Double.pi / 2
            for segment in segments {
                let sweep = segment.value / total * 2 * Double.pi
                context.setStrokeColor(segment.color)
                context.addArc(center: center, radius: radius,
                               startAngle: CGFloat(start), endAngle: CGFloat(start + sweep),
                               clockwise: false)
                context.strokePath()
                start += sweep
            }
            context.restoreGState()

            text(centerLabel, top: top + size / 2 - 18, size: 19, weight: .bold, color: Palette.ink,
                 x: x, width: size, alignment: .center)
            text(centerCaption, top: top + size / 2 + 4, size: 8.5, color: Palette.muted,
                 x: x, width: size, alignment: .center)
        }

        func legend(segments: [Segment], x: CGFloat, top: CGFloat) {
            let total = segments.reduce(0) { $0 + $1.value }
            var rowTop = top

            for segment in segments {
                let share = total > 0 ? segment.value / total : 0
                context.setFillColor(segment.color)
                context.fill(Layout.rect(top: rowTop + 1.5, height: 8, x: x, width: 8))
                text(segment.label, top: rowTop, size: 9.5, color: Palette.ink,
                     x: x + 14, width: Layout.pageWidth - Layout.margin - x - 14 - 110)
                text(String(format: "%.0f 个　%.0f%%", segment.value, share * 100),
                     top: rowTop, size: 9.5, color: Palette.muted,
                     x: Layout.pageWidth - Layout.margin - 110, width: 110, alignment: .right)
                rowTop += 19
            }
        }

        /// 单条堆叠条：展示两部分构成的比例，图例排在条下方。
        func stackedBar(segments: [Segment], top: CGFloat, height: CGFloat) {
            let total = segments.reduce(0) { $0 + $1.value }
            guard total > 0 else { return }
            ensure(height + 46)

            var x = Layout.margin
            for segment in segments {
                let width = Layout.contentWidth * CGFloat(segment.value / total)
                context.setFillColor(segment.color)
                context.fill(Layout.rect(top: top, height: height, x: x, width: width))

                if width > 40 {
                    text(String(format: "%.0f%%", segment.value / total * 100),
                         top: top + (height - 11) / 2, size: 9, weight: .medium,
                         color: Palette.white, x: x + 7, width: width - 14)
                }
                x += width
            }

            var legendX = Layout.margin
            for segment in segments {
                context.setFillColor(segment.color)
                context.fill(Layout.rect(top: top + height + 9, height: 7, x: legendX, width: 7))
                let label = "\(segment.label)　\(Int(segment.value)) 个"
                text(label, top: top + height + 6, size: 8.5, color: Palette.muted,
                     x: legendX + 12, width: 260)
                legendX += 12 + measure(label, size: 8.5) + 24
            }
        }

        /// 横向条形图，条长按组内最大值归一。
        func barChart(entries: [Entry],
                      total: Double,
                      distinctColors: Bool,
                      valueText: ((Double) -> String)? = nil) {
            guard !entries.isEmpty else { return }

            let labelWidth = min(200, Layout.contentWidth * 0.40)
            let valueWidth: CGFloat = 104
            let trackX = Layout.margin + labelWidth + 8
            let trackWidth = Layout.contentWidth - labelWidth - valueWidth - 16
            let maximum = max(entries.map { $0.value }.max() ?? 1, 1)
            let rowHeight: CGFloat = 20

            ensure(CGFloat(entries.count) * rowHeight + 4)

            for (index, entry) in entries.enumerated() {
                let rowTop = cursor + CGFloat(index) * rowHeight
                let color = distinctColors
                    ? seriesColors[index % seriesColors.count]
                    : Palette.accent

                text(entry.label, top: rowTop + 3, size: 9.5, color: Palette.ink, width: labelWidth)

                context.setFillColor(Palette.panel)
                context.fill(Layout.rect(top: rowTop + 4, height: 11, x: trackX, width: trackWidth))

                // 占比为 0 的项仍留 2pt，让「有这一项」这件事本身可见。
                let barWidth = max(2, trackWidth * CGFloat(entry.value / maximum))
                context.setFillColor(color)
                context.fill(Layout.rect(top: rowTop + 4, height: 11, x: trackX, width: barWidth))

                let caption: String
                if let valueText {
                    caption = valueText(entry.value)
                } else if total > 0 {
                    caption = String(format: "%.0f 个　%.0f%%", entry.value, entry.value / total * 100)
                } else {
                    caption = String(format: "%.0f", entry.value)
                }
                text(caption, top: rowTop + 3, size: 9, color: Palette.muted,
                     x: trackX + trackWidth + 6, width: valueWidth - 6)
            }
            cursor += CGFloat(entries.count) * rowHeight
        }

        /// 明细表；跨页时自动重复表头。
        func table(columns: [Column], rows: [FileRecord], fields: (FileRecord) -> [String]) {
            let rowHeight: CGFloat = 17

            func drawHeader() {
                context.setFillColor(Palette.panel)
                context.fill(Layout.rect(top: cursor, height: rowHeight,
                                         x: Layout.margin, width: Layout.contentWidth))
                var x = Layout.margin
                for column in columns {
                    text(column.title, top: cursor + 4, size: 9, weight: .medium,
                         color: Palette.ink, x: x + 5, width: column.width - 10,
                         alignment: column.alignment)
                    x += column.width
                }
                cursor += rowHeight
            }

            ensure(rowHeight + 4)
            drawHeader()

            for row in rows {
                if cursor + rowHeight > bodyBottom {
                    endPage()
                    beginPage()
                    text("（文件明细续）", top: cursor, size: 9, color: Palette.muted)
                    cursor += 16
                    drawHeader()
                }

                context.setStrokeColor(Palette.rule)
                context.setLineWidth(0.4)
                let lineY = Layout.pageHeight - cursor - rowHeight
                context.move(to: CGPoint(x: Layout.margin, y: lineY))
                context.addLine(to: CGPoint(x: Layout.pageWidth - Layout.margin, y: lineY))
                context.strokePath()

                let values = fields(row)
                var x = Layout.margin
                for (index, column) in columns.enumerated() {
                    text(index < values.count ? values[index] : "",
                         top: cursor + 4, size: 8.6, color: Palette.ink,
                         x: x + 5, width: column.width - 10, alignment: column.alignment)
                    x += column.width
                }
                cursor += rowHeight
            }
        }

        private func measure(_ string: String, size: CGFloat) -> CGFloat {
            let attributed = NSAttributedString(string: string, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font(size: size, weight: .regular)
            ])
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed),
                                                      nil, nil, nil))
        }
    }
}
