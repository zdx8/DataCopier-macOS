import SwiftUI
import AppKit

struct TaskListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var scope: TaskListScope = .all
    @State private var selectedTaskIDs: Set<CopyTask.ID> = []
    @State private var taskIDsPendingDeletion: Set<CopyTask.ID> = []
    @State private var isDeleteSheetPresented = false

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            searchAndFilter

            if model.tasks.isEmpty {
                emptyState
            } else if filteredTasks.isEmpty {
                noMatchState
            } else {
                taskScroll
            }
        }
        .background(Bencho.surface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Bencho.hairline)
                .frame(width: 1)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
        .onAppear {
            selectedTaskIDs = model.selection.map { [$0] } ?? []
        }
        .onChange(of: model.selection) { _, id in
            guard let id else {
                if !selectedTaskIDs.isEmpty { selectedTaskIDs = [] }
                return
            }
            // 外部切换到多选集合中的任意一项时，不要把另外的选中项清掉。
            if !selectedTaskIDs.contains(id) {
                selectedTaskIDs = [id]
            }
        }
        // 删除走「滑块确认」而不是再点一次按钮：手势本身就是决定，
        // 误触的价格是完整的拖动距离，而文案与按钮位置都不必变化。
        .sheet(isPresented: $isDeleteSheetPresented) {
            deleteSheet
        }
    }

    /// 删除确认面板。
    private var deleteSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(deletionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.01 * 15)
                    .foregroundStyle(Bencho.ink)
                Text("只移除任务记录，不会删除已经拷贝的文件或已生成的报告。")
                    .font(Bencho.Typeface.body(12.5))
                    .foregroundStyle(Bencho.ink4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SlideToConfirm(title: "向右拖动以删除",
                           confirmedTitle: "已删除",
                           tint: Bencho.ember) {
                let ids = taskIDsPendingDeletion
                model.remove(ids)
                selectedTaskIDs = []
                taskIDsPendingDeletion = []
                isDeleteSheetPresented = false
            }

            HStack {
                Spacer()
                Button("取消") {
                    taskIDsPendingDeletion = []
                    isDeleteSheetPresented = false
                }
                .buttonStyle(BenchoButtonStyle(kind: .quiet, compact: true))
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(Bencho.bg)
        .onDisappear {
            // 面板被 Esc 或点击外部关掉时清掉待删集合，避免下次误删。
            taskIDsPendingDeletion = []
        }
    }

    // MARK: - 列表

    private var taskScroll: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(filteredTasks) { task in
                    let running = model.isRunning(task.id)
                    let deletionIDs = selectedTaskIDs.contains(task.id)
                        ? selectedTaskIDs
                        : Set([task.id])

                    TaskRow(task: task,
                            progress: model.progress[task.id],
                            isRunning: running,
                            isSelected: selectedTaskIDs.contains(task.id),
                            startAction: { model.start(task.id) },
                            stopAction: { model.cancel(task.id) })
                        .contentShape(Rectangle())
                        .onTapGesture {
                            select(task.id)
                        }
                        .contextMenu {
                            Button("开始") { model.start(task.id) }
                                .disabled(model.isRunning(task.id))
                            Button("停止") { model.cancel(task.id) }
                                .disabled(!model.isRunning(task.id))
                            Divider()
                            Button("复制为副本") { model.duplicate(task.id) }
                            Button("在访达中显示目标") { model.revealDestination(task.id) }
                            Divider()
                            Button(deletionIDs.count > 1 ? "删除所选任务" : "删除", role: .destructive) {
                                taskIDsPendingDeletion = deletionIDs
                                isDeleteSheetPresented = true
                            }
                            .disabled(deletionIDs.contains(where: model.isRunning))
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
    }

    /// ⌘ / ⇧ 点击做累积选择，普通点击回到单选。
    private func select(_ id: CopyTask.ID) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selectedTaskIDs.contains(id) {
                selectedTaskIDs.remove(id)
            } else {
                selectedTaskIDs.insert(id)
            }
            model.selection = selectedTaskIDs.contains(id) ? id : selectedTaskIDs.first
        } else {
            selectedTaskIDs = [id]
            model.selection = id
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Bencho.ink5)
            Text("还没有任务")
                .font(Bencho.Typeface.title(13))
                .foregroundStyle(Bencho.ink3)
            Button("新建任务") { model.showNewTaskSheet = true }
                .buttonStyle(BenchoButtonStyle(kind: .wash, compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Bencho.ink5)
            Text("没有符合条件的任务")
                .font(Bencho.Typeface.body(12.5))
                .foregroundStyle(Bencho.ink4)
            Button("清除筛选") {
                searchText = ""
                scope = .all
            }
            .buttonStyle(BenchoButtonStyle(kind: .quiet, compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部状态栏

    private var footer: some View {
        HStack(spacing: 10) {
            if selectedTaskIDs.isEmpty {
                Text(model.tasks.isEmpty ? "0 个任务" : "共 \(model.tasks.count) 个任务")
                    .font(Bencho.Typeface.meta(11))
                    .foregroundStyle(Bencho.ink4)
            } else {
                Text("已选 \(selectedTaskIDs.count) 个")
                    .font(Bencho.Typeface.meta(11))
                    .foregroundStyle(Bencho.fillOn)
            }
            Spacer()
            if model.runningCount > 1 {
                Button("停止全部") { model.cancelAll() }
                    .buttonStyle(BenchoButtonStyle(kind: .quiet, compact: true))
                    .help("停止全部任务")
            }
            // 设置入口常驻侧栏底部：没有选中任务时详情页不显示，放在这里才不会失联。
            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Bencho.ink4)
                    .frame(width: 24, height: 24)
                    .background(Bencho.wash, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("默认选项与运行环境")
            .accessibilityLabel("设置")
            if model.runningCount > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Bencho.signal)
                        .frame(width: 5, height: 5)
                    Text("\(model.runningCount) 个进行中")
                        .font(Bencho.Typeface.meta(11))
                        .foregroundStyle(Bencho.ink4)
                }
            }
            if !selectedTaskIDs.isEmpty {
                Button("删除所选") {
                    taskIDsPendingDeletion = selectedTaskIDs
                    isDeleteSheetPresented = true
                }
                .buttonStyle(BenchoButtonStyle(kind: .destructive, compact: true))
                .disabled(!canDeleteSelection)
                .help(canDeleteSelection ? "删除已选择的 \(selectedTaskIDs.count) 个任务" : "请先停止运行中的任务")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Bencho.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Bencho.hairline).frame(height: 1)
        }
    }

    // MARK: - 头部

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Bencho.slab)
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Bencho.onSlab)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text("数据拷贝")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.01 * 15)
                        .foregroundStyle(Bencho.ink)
                    Text("批量搬运 · 逐文件校验")
                        .font(Bencho.Typeface.meta(11))
                        .foregroundStyle(Bencho.ink4)
                }
                Spacer(minLength: 0)

                Button {
                    model.showNewTaskSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Bencho.fillOn)
                        .frame(width: 26, height: 26)
                        .background(Bencho.wash, in: Circle())
                        .overlay(Circle().strokeBorder(Bencho.hairline, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("新建任务")
                .accessibilityLabel("新建任务")
            }

            HStack(spacing: 6) {
                SidebarMetric(value: model.runningCount, title: "进行中", tint: Bencho.signal)
                SidebarMetric(value: finishedCount, title: "已完成", tint: Bencho.ok)
                SidebarMetric(value: attentionCount,
                              title: "需关注",
                              tint: attentionCount > 0 ? Bencho.danger : Bencho.ink5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var searchAndFilter: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Bencho.ink5)
                TextField("搜索任务、来源或目标", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Bencho.Typeface.body(12.5))
                    .foregroundStyle(Bencho.fillOn)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Bencho.ink5)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Bencho.surface2, in: Capsule())

            Menu {
                Picker("筛选任务", selection: $scope) {
                    ForEach(TaskListScope.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
            } label: {
                Image(systemName: scope.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(scope == .all ? Bencho.ink4 : Bencho.fillOn)
                    .frame(width: 30, height: 30)
                    .background(scope == .all ? Bencho.surface2 : Bencho.washStrong, in: Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("筛选：\(scope.title)")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - 派生数据

    private var filteredTasks: [CopyTask] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.tasks.filter { task in
            let matchesScope: Bool
            switch scope {
            case .all:
                matchesScope = true
            case .running:
                matchesScope = task.state == .running || task.state == .cancelling
            case .finished:
                matchesScope = task.state == .finished
            case .attention:
                matchesScope = task.state == .failed || task.state == .cancelled
            }
            guard matchesScope else { return false }
            guard !query.isEmpty else { return true }
            return task.name.lowercased().contains(query)
                || task.sourcesDisplay.lowercased().contains(query)
                || task.destination.lowercased().contains(query)
        }
    }

    private var finishedCount: Int {
        model.tasks.filter { $0.state == .finished }.count
    }

    private var attentionCount: Int {
        model.tasks.filter { $0.state == .failed || $0.state == .cancelled }.count
    }

    private var deletionTitle: String {
        if taskIDsPendingDeletion.count == 1,
           let task = model.tasks.first(where: { taskIDsPendingDeletion.contains($0.id) }) {
            return "删除任务「\(task.name)」？"
        }
        if taskIDsPendingDeletion.count > 1 {
            return "删除所选的 \(taskIDsPendingDeletion.count) 个任务？"
        }
        return "删除任务？"
    }

    private var canDeleteSelection: Bool {
        !selectedTaskIDs.isEmpty && selectedTaskIDs.allSatisfy { !model.isRunning($0) }
    }
}

private enum TaskListScope: String, CaseIterable, Identifiable {
    case all
    case running
    case finished
    case attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部任务"
        case .running: return "进行中"
        case .finished: return "已完成"
        case .attention: return "需关注"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .finished: return "checkmark.circle"
        case .attention: return "exclamationmark.triangle"
        }
    }
}

private struct SidebarMetric: View {
    let value: Int
    let title: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(title)
                .font(Bencho.Typeface.meta(10))
                .foregroundStyle(Bencho.ink5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Bencho.fillSlab, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Bencho.hairline, lineWidth: 1)
        }
    }
}

struct TaskRow: View {
    let task: CopyTask
    let progress: TaskProgress?
    let isRunning: Bool
    var isSelected = false
    var startAction: (() -> Void)?
    var stopAction: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Bencho.onSlab : tint)
                .frame(width: 22, height: 22)
                .background(isSelected ? Color.white.opacity(0.14) : Bencho.wash,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(task.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .tracking(-0.01 * 12.5)
                        .foregroundStyle(isSelected ? Bencho.onSlab : Bencho.ink)
                        .lineLimit(1)
                    // 任务类型一目了然：两种任务的执行内容与报告口径完全不同。
                    if task.taskKind == .transcode {
                        Image(systemName: TaskKind.transcode.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(isSelected ? Bencho.onSlab.opacity(0.7) : Bencho.ink5)
                            .help("转码任务")
                    } else if task.options.copyPreset == .media {
                        Image(systemName: CopyPreset.media.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(isSelected ? Bencho.onSlab.opacity(0.7) : Bencho.ink5)
                            .help(CopyPreset.media.displayName)
                    }
                    Spacer(minLength: 4)
                    if !isSelected {
                        TaskStatusBadge(state: task.state)
                    }
                }

                Text(subtitle)
                    .font(Bencho.Typeface.meta(10.5))
                    .foregroundStyle(isSelected ? Bencho.onSlab.opacity(0.62) : Bencho.ink5)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isRunning, let progress {
                    BenchoMeter(fraction: progress.fraction,
                                tint: isSelected ? Bencho.onSlab : tint,
                                height: 3)
                        .padding(.top, 1)
                    HStack(spacing: 5) {
                        Text(Format.percent(progress.fraction))
                            .foregroundStyle(isSelected ? Bencho.onSlab.opacity(0.8) : tint)
                        Text("·")
                        if task.taskKind == .transcode {
                            // 转码速度按「倍速」呈现，字节吞吐对视频编码没有参考意义。
                            Text("\(progress.completedFiles)/\(progress.totalFiles)")
                            if progress.transcodeSpeed > 0 {
                                Text("·")
                                Text(String(format: "%.1f×", progress.transcodeSpeed))
                            }
                        } else {
                            Text(Format.speed(progress.bytesPerSecond))
                            Text("·")
                            Text("\(progress.completedFiles)/\(progress.totalFiles)")
                        }
                    }
                    .font(Bencho.Typeface.meta(10))
                    .foregroundStyle(isSelected ? Bencho.onSlab.opacity(0.62) : Bencho.ink5)
                    .monospacedDigit()
                } else if let report = task.lastReport {
                    HStack(spacing: 5) {
                        if task.taskKind == .transcode {
                            // 报告没有单独的「参与转码总数」字段，用三态之和还原。
                            Text("\(report.transcodedFiles)/\(report.transcodedFiles + report.transcodeSkippedFiles + report.transcodeFailedFiles) 已转码")
                            if report.transcodeSkippedFiles > 0 {
                                Text("·")
                                Text("跳过 \(report.transcodeSkippedFiles)")
                            }
                            if report.transcodeFailedFiles > 0 {
                                Text("·")
                                Text("失败 \(report.transcodeFailedFiles)")
                                    .foregroundStyle(isSelected ? Bencho.onSlab : Bencho.danger)
                            }
                        } else {
                            Text(Format.bytes(report.copiedBytes))
                            Text("·")
                            if report.isMediaArchive {
                                Text("\(report.photoFiles) 照片 / \(report.videoFiles) 视频")
                            } else {
                                Text("\(report.copiedFiles) 个文件")
                            }
                            // failedFiles 已含校验不一致的记录（见 TaskRunner.append），
                            // 因此这里不能再加 verifyFailedFiles，否则异常数被重复累计。
                            if report.failedFiles > 0 {
                                Text("·")
                                Text("异常 \(report.failedFiles)")
                                    .foregroundStyle(isSelected ? Bencho.onSlab : Bencho.danger)
                            }
                        }
                    }
                    .font(Bencho.Typeface.meta(10))
                    .foregroundStyle(isSelected ? Bencho.onSlab.opacity(0.62) : Bencho.ink5)
                    .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.leading, 10)
        // 右侧预留按钮宽度，避免标题与状态徽标被悬浮按钮遮住。
        .padding(.trailing, 40)
        .overlay(alignment: .trailing) {
            rowButton
        }
        .background {
            RoundedRectangle(cornerRadius: Bencho.Radius.row, style: .continuous)
                .fill(isSelected ? Bencho.slab : (isHovered ? Bencho.wash : .clear))
        }
        .overlay {
            if !isSelected && isHovered {
                RoundedRectangle(cornerRadius: Bencho.Radius.row, style: .continuous)
                    .strokeBorder(Bencho.hairline, lineWidth: 1)
            }
        }
        .onHover { isHovered = $0 }
        .animation(Bencho.Motion.standard, value: isHovered)
        .animation(Bencho.Motion.standard, value: isSelected)
    }

    /// 任务条尾部的启停按钮。运行中显示停止，否则显示开始。
    ///
    /// 选中态是反色实心块，按钮改成「描边胶囊」：开始用墨色描边、停止用 ember，
    /// 在深色选中块上仍然读得清。
    private var rowButton: some View {
        Button {
            if isRunning { stopAction?() } else { startAction?() }
        } label: {
            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(buttonTint)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(isSelected ? Color.white.opacity(0.14) : Bencho.wash)
                )
                .overlay {
                    Circle().strokeBorder(
                        isSelected ? Color.white.opacity(0.22) : Bencho.hairline,
                        lineWidth: 1
                    )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isRunning ? "停止" : "开始")
        .accessibilityLabel(isRunning ? "停止任务" : "开始任务")
        .padding(.trailing, 10)
    }

    private var buttonTint: Color {
        if isSelected { return Bencho.onSlab }
        return isRunning ? Bencho.ember : Bencho.ok
    }

    private var subtitle: String {
        "\(task.sourcesDisplay) → \((task.destination as NSString).lastPathComponent)"
    }

    private var icon: String {
        switch task.state {
        case .running, .cancelling: return "arrow.triangle.2.circlepath"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle.fill"
        case .idle: return "circle.dashed"
        }
    }

    private var tint: Color {
        switch task.state {
        case .running, .cancelling: return Bencho.signal
        case .finished: return Bencho.ok
        case .failed: return Bencho.danger
        case .cancelled: return Bencho.warn
        case .idle: return Bencho.ink5
        }
    }
}
