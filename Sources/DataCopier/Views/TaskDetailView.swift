import SwiftUI

private enum DetailSection: String, CaseIterable, Identifiable {
    case overview = "概览"
    case records = "文件明细"
    case options = "任务配置"
    var id: String { rawValue }
}

private enum RecordFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case problems = "异常"
    case transcoded = "已转码"
    case copied = "已拷贝"
    case skipped = "已跳过"
    var id: String { rawValue }
}

struct TaskDetailView: View {
    let task: CopyTask

    /// 与设置页共享同一存储键：这里一键切换主题后，设置页的外观
    /// 选择器会同步显示为对应档位。
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw: String = AppearanceMode.system.rawValue

    @EnvironmentObject private var model: AppModel
    @State private var section: DetailSection = .overview
    @State private var filter: RecordFilter = .all

    private var progress: TaskProgress? { model.progress[task.id] }
    private var running: Bool { model.isRunning(task.id) }

    var body: some View {
        VStack(spacing: 0) {
            header

            if running, let progress {
                ProgressPanel(progress: progress, state: task.state)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
            }

            HStack {
                BenchoSegmented(options: DetailSection.allCases,
                                title: { $0.rawValue },
                                selection: $section)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Bencho.hairline)
                .frame(height: 1)

            switch section {
            case .overview:
                overview
            case .records:
                records
            case .options:
                optionsPane
            }
        }
        .background(Bencho.bg)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: taskTypeSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Bencho.onSlab)
                    .frame(width: 38, height: 38)
                    .background(Bencho.slab, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(task.name)
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.01 * 17)
                        .foregroundStyle(Bencho.ink)
                        .lineLimit(1)
                        .help(task.name)

                    HStack(spacing: 7) {
                        TaskStatusBadge(state: task.state)
                        Text(taskTypeTitle)
                            .font(Bencho.Typeface.meta(11.5))
                            .foregroundStyle(Bencho.ink3)
                    }
                }

                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if let report = task.lastReport {
                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text(Format.timestamp(report.finishedAt))
                                .font(Bencho.Typeface.meta(11))
                                .monospacedDigit()
                        }
                        .foregroundStyle(Bencho.ink5)
                    }
                    exportMenu
                    iconButton("circle.lefthalf.filled", help: "切换浅色 / 深色主题") {
                        let isDark = NSApp.effectiveAppearance
                            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        let target: AppearanceMode = isDark ? .light : .dark
                        appearanceRaw = target.rawValue
                        AppearanceMode.apply(target)
                    }
                    iconButton("gearshape", help: "默认选项与硬件能力") {
                        model.showSettings = true
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                PathRow(icon: "tray.full", label: "来源", paths: task.sources)
                PathRow(icon: task.taskKind == .transcode ? "film.stack" : "arrow.down.doc",
                        label: task.taskKind == .transcode ? "输出" : "目标",
                        paths: [task.destination]) {
                    model.revealDestination(task.id)
                }
            }
        }
        .padding(16)
        .background(Bencho.card, in: RoundedRectangle(cornerRadius: Bencho.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Bencho.Radius.card, style: .continuous)
                .strokeBorder(Bencho.hairline, lineWidth: 1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    private var taskTypeTitle: String {
        if task.taskKind == .transcode { return "视频转码" }
        return task.options.copyPreset == .media ? "媒体归档" : "文件拷贝"
    }

    // MARK: - 头部动作

    /// 图标按钮：胶囊淡底，悬停加深。取代原来的原生工具栏项。
    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Bencho.ink3)
                .frame(width: 28, height: 28)
                .background(Bencho.wash, in: Circle())
                .overlay(Circle().strokeBorder(Bencho.hairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var exportMenu: some View {
        let canExport = task.lastReport != nil && !model.isExportingReport

        return Menu {
            ForEach(ReportExportFormat.allCases) { format in
                Button(format.displayName) {
                    model.exportReport(for: task.id, format: format)
                }
                .disabled(model.isExportingReport)
            }
            if task.taskKind != .transcode {
                Divider()
                Button("导出校验清单") { model.exportManifest(for: task.id) }
                Button(model.verifyingTaskID == task.id
                       ? "正在复核清单…"
                       : "按校验清单复核…") {
                    model.verifyAgainstManifest(for: task.id)
                }
                .disabled(model.verifyingTaskID != nil)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.isExportingReport ? "hourglass" : "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                Text(model.isExportingReport ? "正在生成…" : "导出")
                    .font(Bencho.Typeface.title(12.5))
                    .tracking(-0.01 * 12.5)
            }
            .foregroundStyle(Bencho.fillOn)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Bencho.wash, in: Capsule())
            .overlay(Capsule().strokeBorder(Bencho.hairline, lineWidth: 1))
            .opacity(canExport ? 1 : 0.45)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!canExport)
        .help("导出统计报告")
    }

    private var taskTypeSymbol: String {
        if task.taskKind == .transcode { return TaskKind.transcode.symbol }
        return task.options.copyPreset.symbol
    }

    // MARK: - 概览

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let report = task.lastReport {
                    summaryGrid(report)

                    if !report.mismatches.isEmpty {
                        problemBox(
                            title: "校验不一致（\(report.mismatches.count)）",
                            tint: Bencho.danger,
                            lines: report.mismatches.prefix(6).map {
                                "\($0.relativePath)　源 \(display($0.sourceDigest)) → 目标 \(display($0.destinationDigest))"
                            }
                        )
                    }

                    if !report.failures.isEmpty {
                        problemBox(
                            title: "拷贝失败（\(report.failures.count)）",
                            tint: Bencho.warn,
                            lines: report.failures.prefix(6).map {
                                "\($0.relativePath)　\($0.message ?? "未知原因")"
                            }
                        )
                    }

                    if report.isMediaArchive {
                        archiveBox(report)
                    }

                    if report.transcodeEnabled {
                        transcodeBox(report)
                    }

                    if report.truncatedRecordCount > 0 {
                        Text("另有 \(report.truncatedRecordCount) 条明细未记录（超过上限 \(task.options.maxRecordedEntries) 条）。")
                            .font(Bencho.Typeface.meta(11))
                            .foregroundStyle(Bencho.ink4)
                    }
                } else {
                    ContentUnavailableView(
                        running ? "任务正在执行" : "尚无执行记录",
                        systemImage: running ? "arrow.triangle.2.circlepath" : "chart.bar.doc.horizontal",
                        description: Text(running
                            ? "完成后这里会自动生成统计报告，期间可在上方查看实时进度。"
                            : "点击左侧任务卡片右侧的「开始」按钮，完成后这里会显示统计报告。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .padding(16)
        }
    }

    private func summaryGrid(_ report: TaskReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
            if report.isTranscodeTask {
                // 独立转码任务没有拷贝口径，直接按转码三态与体积变化汇总。
                StatCard(title: "已转码", value: "\(report.transcodedFiles)",
                         tint: report.transcodeFailedFiles > 0 ? Bencho.warn : Bencho.ok,
                         caption: report.transcodePresetName ?? "—")
                StatCard(title: "跳过", value: "\(report.transcodeSkippedFiles)", caption: "无增益或低于阈值")
                StatCard(title: "转码失败", value: "\(report.transcodeFailedFiles)",
                         tint: report.transcodeFailedFiles > 0 ? Bencho.danger : Bencho.fillOn, caption: "详见转码阶段区块")
                StatCard(title: "输入体积", value: Format.bytes(report.transcodeInputBytes), caption: "原始视频")
                StatCard(title: "输出体积", value: Format.bytes(report.transcodeOutputBytes),
                         caption: report.transcodeCompressionRatio > 0
                            ? "原片的 " + Format.ratio(report.transcodeCompressionRatio)
                            : "—")
                StatCard(title: "节省空间", value: Format.bytes(report.transcodeSavedBytes),
                         tint: report.transcodeSavedBytes > 0 ? Bencho.ok : Bencho.fillOn,
                         caption: "转码耗时 " + Format.duration(report.transcodeDuration))
                StatCard(title: "硬件加速", value: "\(report.transcodeHardwareFiles)", caption: "个文件走硬件编码")
                StatCard(title: "总耗时", value: Format.duration(report.elapsed),
                         caption: "计划 \(report.totalFiles) 个视频")
            } else {
                StatCard(title: "成功拷贝", value: "\(report.succeededCopyFiles)", caption: Format.bytes(report.copiedBytes))
                StatCard(title: "校验通过", value: "\(report.verifiedFiles)", tint: Bencho.ok,
                         caption: report.verifyAfterCopy ? "已启用复核" : "未启用复核")
                StatCard(title: "跳过", value: "\(report.skippedFiles)", caption: "按冲突策略")
                StatCard(title: "失败", value: "\(report.readWriteFailedFiles)",
                         tint: report.readWriteFailedFiles > 0 ? Bencho.danger : Bencho.fillOn, caption: "读取或写入错误")
                StatCard(title: "校验不一致", value: "\(report.verifyFailedFiles)",
                         tint: report.verifyFailedFiles > 0 ? Bencho.danger : Bencho.fillOn, caption: "数据可能损坏")
                StatCard(title: "平均速度", value: Format.speed(report.averageBytesPerSecond),
                         caption: "峰值 " + Format.speed(report.peakBytesPerSecond))
                StatCard(title: "总耗时", value: Format.duration(report.elapsed),
                         caption: "计划 \(report.totalFiles) 个文件")
                StatCard(title: "数据量", value: Format.bytes(report.totalBytes),
                         caption: "算法 " + report.algorithm.shortName)

                if report.isMediaArchive {
                    StatCard(title: "照片", value: "\(report.photoFiles)", caption: "按拍摄时间归档")
                    StatCard(title: "视频", value: "\(report.videoFiles)", caption: "按拍摄时间归档")
                    StatCard(title: "已重命名", value: "\(report.renamedFiles)", caption: "时间戳命名")
                    if report.filteredOutFiles > 0 {
                        StatCard(title: "已排除", value: "\(report.filteredOutFiles)",
                                 tint: Bencho.warn, caption: "非照片/视频文件")
                    }
                }

                if report.transcodeEnabled {
                    StatCard(title: "转码成功", value: "\(report.transcodedFiles)",
                             tint: report.transcodeFailedFiles > 0 ? Bencho.warn : Bencho.ok,
                             caption: report.transcodePresetName ?? "—")
                    StatCard(title: "转码后体积", value: Format.bytes(report.transcodeOutputBytes),
                             caption: report.transcodeCompressionRatio > 0
                                ? "原片的 " + Format.ratio(report.transcodeCompressionRatio)
                                : "—")
                    StatCard(title: "节省空间", value: Format.bytes(report.transcodeSavedBytes),
                             tint: report.transcodeSavedBytes > 0 ? Bencho.ok : Bencho.fillOn,
                             caption: "转码耗时 " + Format.duration(report.transcodeDuration))
                }
            }
        }
    }

    /// 归档阶段的汇总区块：时间来源分布与目录分布。
    ///
    /// 时间来源单独列出是有意为之：EXIF / 容器时间是权威值，而文件名与文件修改时间
    /// 属于推断——后者数量偏高时，归档结果的日期可信度需要打折扣。
    private func archiveBox(_ report: TaskReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(Bencho.ink4)
                Text("归档　\(report.preset.displayName)")
                    .font(Bencho.Typeface.title(13))
                Spacer()
                if let range = report.captureRangeText {
                    Text("素材时间 \(range)")
                        .font(Bencho.Typeface.meta(10.5))
                        .foregroundStyle(Bencho.ink4)
                }
            }

            HStack(spacing: 18) {
                metric("照片", "\(report.photoFiles)")
                metric("视频", "\(report.videoFiles)")
                metric("已重命名", "\(report.renamedFiles)")
                metric("时间取自元数据", "\(report.captureMetadataFiles)")
                metric("时间推断", "\(report.captureFallbackFiles)",
                       tint: report.captureFallbackFiles > 0 ? Bencho.warn : Bencho.fillOn)
                if report.classifiedByDevice {
                    metric("涉及设备", "\(report.deviceCounts.count)")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Bencho.fillSlab, in: RoundedRectangle(cornerRadius: Bencho.Radius.row, style: .continuous))

            if report.classifiedByDevice {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设备分布")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Bencho.ink4)
                    ForEach(report.deviceRanking.prefix(8), id: \.device) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "camera")
                                .font(Bencho.Typeface.meta(10.5))
                                .foregroundStyle(Bencho.ink4)
                            Text(entry.device)
                                .font(Bencho.Typeface.mono(11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry.device)
                            Spacer(minLength: 8)
                            Text("\(entry.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Bencho.ink4)
                        }
                    }
                    if report.deviceCounts.count > 8 {
                        Text("另有 \(report.deviceCounts.count - 8) 种设备未显示")
                            .font(Bencho.Typeface.meta(10.5))
                            .foregroundStyle(Bencho.ink4)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Bencho.fillSlab, in: RoundedRectangle(cornerRadius: Bencho.Radius.row, style: .continuous))
            }

            if !report.mediaFolderCounts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("目录分布")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Bencho.ink4)
                    ForEach(report.mediaFolderRanking.prefix(8), id: \.folder) { entry in
                        HStack(spacing: 8) {
                            Text(entry.folder.isEmpty ? "（目标根目录）" : entry.folder)
                                .font(Bencho.Typeface.mono(11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text("\(entry.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Bencho.ink4)
                        }
                    }
                    if report.mediaFolderCounts.count > 8 {
                        Text("另有 \(report.mediaFolderCounts.count - 8) 个目录未显示")
                            .font(Bencho.Typeface.meta(10.5))
                            .foregroundStyle(Bencho.ink4)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Bencho.fillSlab, in: RoundedRectangle(cornerRadius: Bencho.Radius.row, style: .continuous))
            }

            if report.filteredOutFiles > 0 {
                Text("已排除 \(report.filteredOutFiles) 个非照片/视频文件。")
                    .font(Bencho.Typeface.meta(11))
                    .foregroundStyle(Bencho.ink4)
            }
        }
    }

    /// 转码阶段的汇总区块。
    private func transcodeBox(_ report: TaskReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "film.stack")
                    .foregroundStyle(Bencho.ink4)
                Text("转码阶段　\(report.transcodePresetName ?? "—")")
                    .font(Bencho.Typeface.title(13))
                Spacer()
                if report.transcodeHardwareFiles > 0 {
                    BenchoStatus(text: "硬件加速 \(report.transcodeHardwareFiles) 个",
                                 color: Bencho.ok,
                                 dot: false)
                }
            }

            HStack(spacing: 18) {
                metric("成功", "\(report.transcodedFiles)")
                metric("跳过", "\(report.transcodeSkippedFiles)")
                metric("失败", "\(report.transcodeFailedFiles)",
                       tint: report.transcodeFailedFiles > 0 ? Bencho.danger : Bencho.fillOn)
                metric("输入总量", Format.bytes(report.transcodeInputBytes))
                metric("输出总量", Format.bytes(report.transcodeOutputBytes))
                metric("压缩比", report.transcodeCompressionRatio > 0
                       ? Format.ratio(report.transcodeCompressionRatio) : "—")
                metric("耗时", Format.duration(report.transcodeDuration))
            }

            if let note = report.transcodeNote {
                Text(note)
                    .font(Bencho.Typeface.meta(11))
                    .foregroundStyle(Bencho.ink4)
            }

            if report.transcodeRemovedOriginals > 0 {
                Text("已删除 \(report.transcodeRemovedOriginals) 个原始拷贝文件（源文件未受影响）。")
                    .font(Bencho.Typeface.meta(11))
                    .foregroundStyle(Bencho.warn)
            }

            if !report.transcodeFailures.isEmpty {
                Rectangle().fill(Bencho.hairline).frame(height: 1)
                ForEach(report.transcodeFailures.prefix(6)) { record in
                    Text("\(record.relativePath)　\(record.transcode?.message ?? "未知原因")")
                        .font(Bencho.Typeface.mono(11))
                        .foregroundStyle(Bencho.danger)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            if !report.transcodeSkipped.isEmpty {
                Rectangle().fill(Bencho.hairline).frame(height: 1)
                ForEach(skipReasons(report), id: \.reason) { item in
                    Text("跳过 \(item.count) 个：\(item.reason)")
                        .font(Bencho.Typeface.meta(11))
                        .foregroundStyle(Bencho.ink4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Bencho.fillSlab, in: RoundedRectangle(cornerRadius: Bencho.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Bencho.Radius.row, style: .continuous)
                .strokeBorder(Bencho.hairline, lineWidth: 1)
        )
    }

    /// 按原因归并跳过项，避免逐个文件铺满界面。
    private func skipReasons(_ report: TaskReport) -> [(reason: String, count: Int)] {
        var tally: [String: Int] = [:]
        for record in report.transcodeSkipped {
            let reason = record.transcode?.message ?? "未说明原因"
            tally[reason, default: 0] += 1
        }
        return tally
            .map { (reason: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private func metric(_ title: String, _ value: String, tint: Color = Bencho.fillOn) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Bencho.Typeface.meta(10.5))
                .foregroundStyle(Bencho.ink4)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }

    private func problemBox(title: String, tint: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(Bencho.Typeface.title(13))
                .foregroundStyle(tint)

            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(Bencho.Typeface.mono(11))
                    .foregroundStyle(Bencho.ink4)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Bencho.fillSlab, in: RoundedRectangle(cornerRadius: Bencho.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Bencho.Radius.row, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
    }

    private func display(_ digest: String?) -> String {
        guard let digest else { return "—" }
        return String(digest.prefix(12))
    }

    // MARK: - 文件明细

    private var records: some View {
        let rows = filteredRecords(task.lastReport?.records ?? [])

        return VStack(spacing: 0) {
            if let report = task.lastReport, !report.records.isEmpty {
                HStack {
                    BenchoSegmented(options: RecordFilter.allCases,
                                    title: { $0.rawValue },
                                    selection: $filter)

                    Spacer()

                    Text("\(rows.count) 条")
                        .font(Bencho.Typeface.meta(11))
                        .foregroundStyle(Bencho.ink4)
                        .monospacedDigit()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

                recordTable(rows, isMediaArchive: report.isMediaArchive)
                    .background(Bencho.bg)
            } else {
                // 待执行的任务还没有明细数据。空态视图必须显式占满整个视区，
                // 否则会被外层 VStack 挤到左上角，界面看起来像排版错乱。
                ContentUnavailableView(
                    running ? "正在处理文件" : "没有文件明细",
                    systemImage: running ? "arrow.triangle.2.circlepath" : "list.bullet.rectangle",
                    description: Text(running
                        ? "任务完成后，这里会列出每个文件的处理结果与校验值。"
                        : "任务执行完成后，这里会列出每个文件的处理结果与校验值。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 文件明细表。
    ///
    /// 分作两支而非使用条件列——`Table` 的条件化列需要 macOS 14.4，
    /// 而本应用最低支持 14.0。两种预设关注的信息本就不同：
    /// 归档任务关心「什么时候拍的、落在哪里」，普通拷贝任务关心传输速度与校验值。
    @ViewBuilder
    private func recordTable(_ rows: [FileRecord], isMediaArchive: Bool) -> some View {
        if isMediaArchive {
            Table(rows) {
                TableColumn("状态") { record in
                    FileStatusBadge(status: record.status)
                }
                .width(84)

                TableColumn("拍摄时间") { record in
                    Text(captureText(record.captureDate))
                        .font(Bencho.Typeface.mono(11))
                        // 推断时间（文件名 / 文件修改时间）用橙色标注，
                        // 让用户一眼看出哪些日期并非相机记录。
                        .foregroundStyle(record.captureSource?.isAuthoritative == true
                                         ? Bencho.fillOn : Bencho.warn)
                        .help(record.captureSource?.displayName ?? "无时间信息")
                }
                .width(146)

                TableColumn("类型") { record in
                    Text(record.mediaKind?.displayName ?? "—")
                        .foregroundStyle(Bencho.ink4)
                }
                .width(54)

                // 归档位置里已含设备目录，但那一列常因过长而被截断；
                // 单独列出机型，才能一眼看出某个文件为何落在「未知设备」下。
                TableColumn("设备") { record in
                    Text(record.deviceModel ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(record.deviceModel ?? "未按设备分类")
                }
                .width(min: 88, ideal: 120)

                TableColumn("归档位置") { record in
                    Text(record.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(record.relativePath)
                }
                .width(min: 180, ideal: 280)

                TableColumn("原文件名") { record in
                    Text(record.originalName ?? "—")
                        .font(Bencho.Typeface.mono(11))
                        .foregroundStyle(Bencho.ink4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(record.originalName ?? "未重命名")
                }
                .width(min: 100, ideal: 170)

                TableColumn("大小") { record in
                    Text(Format.bytes(record.size))
                        .monospacedDigit()
                }
                .width(84)

                TableColumn("说明") { record in
                    Text(record.message ?? "—")
                        .foregroundStyle(record.status.isProblem ? Bencho.danger : Bencho.ink4)
                        .lineLimit(1)
                        .help(record.message ?? "")
                }
            }
        } else {
            Table(rows) {
                TableColumn("状态") { record in
                    FileStatusBadge(status: record.status)
                }
                .width(84)

                TableColumn("转码") { record in
                    TranscodeCell(transcode: record.transcode)
                }
                .width(150)

                TableColumn("相对路径") { record in
                    Text(record.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(record.relativePath)
                }
                .width(min: 180, ideal: 300)

                TableColumn("大小") { record in
                    Text(Format.bytes(record.size))
                        .monospacedDigit()
                }
                .width(84)

                TableColumn("耗时") { record in
                    Text(Format.duration(record.duration))
                        .monospacedDigit()
                }
                .width(72)

                TableColumn("速度") { record in
                    Text(Format.speed(record.bytesPerSecond))
                        .monospacedDigit()
                }
                .width(88)

                TableColumn("校验值") { record in
                    Text(record.sourceDigest.map { String($0.prefix(12)) } ?? "—")
                        .font(Bencho.Typeface.mono(11))
                        .foregroundStyle(Bencho.ink4)
                }
                .width(120)

                TableColumn("说明") { record in
                    Text(record.message ?? "—")
                        .foregroundStyle(record.status.isProblem ? Bencho.danger : Bencho.ink4)
                        .lineLimit(1)
                }
            }
        }
    }

    private func captureText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.captureFormatter.string(from: date)
    }

    private static let captureFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func filteredRecords(_ records: [FileRecord]) -> [FileRecord] {
        switch filter {
        case .all:
            return records
        case .problems:
            // 转码失败也应归入「异常」：只看拷贝结果会漏掉后半段的真实问题。
            return records.filter { $0.status.isProblem || $0.transcode?.status == .failed }
        case .transcoded:
            return records.filter { $0.transcode != nil }
        case .copied:
            return records.filter { $0.status == .copied || $0.status == .verified }
        case .skipped:
            return records.filter { $0.status == .skipped }
        }
    }

    // MARK: - 任务配置

    @ViewBuilder
    private var optionsPane: some View {
        if task.taskKind == .transcode {
            // 转码任务只展示转码配置，拷贝相关的预设与选项毫无意义。
            BenchoForm {
                TranscodeForm(settings: Binding(
                    get: { task.options.transcodeSettings },
                    set: { newValue in
                        model.editOptions(task.id) { $0.transcodeSettings = newValue }
                    }
                ), standalone: true)
            }
        } else {
            copyOptionsPane
        }
    }

    private var copyOptionsPane: some View {
        let binding = Binding(
            get: { task.options },
            set: { newValue in
                // 基于 AppModel 里的**最新**记录改选项，而不是视图渲染时的快照，
                // 避免把运行中/刚完成的回调写入的 state、lastReport 覆盖掉。
                model.editOptions(task.id) { $0 = newValue }
            }
        )

        return BenchoForm {
            CopyPresetPicker(options: binding)

            if binding.wrappedValue.copyPreset == .media {
                MediaImportForm(settings: Binding(
                    get: { binding.wrappedValue.mediaSettings },
                    set: { binding.wrappedValue.mediaSettings = $0 }
                ))

                // 与新建任务表单一致：转码模块只在媒体拷贝预设下提供。
                TranscodeForm(settings: Binding(
                    get: { binding.wrappedValue.transcodeSettings },
                    set: { newValue in
                        model.editOptions(task.id) { $0.transcodeSettings = newValue }
                    }
                ))
            }

            OptionsForm(options: binding)

            // 与新建任务表单一致：低频内容（可选细化、格式说明）沉到表单最底部。
            if binding.wrappedValue.copyPreset == .media {
                MediaExtrasForm(settings: Binding(
                    get: { binding.wrappedValue.mediaSettings },
                    set: { binding.wrappedValue.mediaSettings = $0 }
                ))
            }
        }
    }
}

// MARK: - 明细表中的转码单元格

private struct TranscodeCell: View {
    let transcode: TranscodeOutcome?

    var body: some View {
        if let transcode {
            VStack(alignment: .leading, spacing: 1) {
                TranscodeStatusBadge(status: transcode.status)
                if transcode.status == .succeeded {
                    Text("\(transcode.ratioText)　\(transcode.resolutionText)")
                        .font(Bencho.Typeface.meta(10.5))
                        .foregroundStyle(Bencho.ink4)
                        .lineLimit(1)
                }
            }
            .help(tooltip(transcode))
        } else {
            Text("—")
                .foregroundStyle(Bencho.ink5)
        }
    }

    private func tooltip(_ transcode: TranscodeOutcome) -> String {
        var lines: [String] = ["预设：\(transcode.presetName)"]
        if let outputPath = transcode.outputPath {
            lines.append("输出：\(outputPath)")
        }
        if transcode.status == .succeeded {
            lines.append("编码：\(transcode.videoCodec ?? "—")　音频：\(transcode.audioCodec ?? "—")")
            lines.append("体积：\(Format.bytes(transcode.inputBytes)) → \(Format.bytes(transcode.outputBytes))")
            if transcode.speed > 0 {
                lines.append("倍速：\(String(format: "%.1f×", transcode.speed))")
            }
            if transcode.usedHardware { lines.append("使用硬件编码") }
            if transcode.usedFallback { lines.append("音轨经兜底重编码") }
        }
        if let message = transcode.message { lines.append(message) }
        return lines.joined(separator: "\n")
    }
}
