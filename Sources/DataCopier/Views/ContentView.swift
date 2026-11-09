import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            TaskListView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            Group {
                if let task = model.selectedTask {
                    // `.id` 强制按任务身份重建视图：SwiftUI 会复用同位置的视图，
                    // 否则筛选/分区等 @State 会跨任务残留（在 A 选了「异常」，
                    // 切到无异常的 B 后明细一片空白，容易被误判为「没有记录」）。
                    TaskDetailView(task: task)
                        .id(task.id)
                } else {
                    EmptyStateView()
                }
            }
            .navigationSplitViewColumnWidth(min: 620, ideal: 780)
        }
        // 工具栏按钮统一右对齐：新建任务（放大主按钮）+ 停止全部（多任务运行时）。
        // 声明在根层，与详情列的导出/设置合并到窗口工具栏最右端。
        .toolbar {
            if model.runningCount > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.cancelAll()
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .help("停止全部任务")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showNewTaskSheet = true
                } label: {
                    Label("新建任务", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        // 显式绘制浅蓝底 + 深蓝字，不依赖系统 tint。
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(Color.blue.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .help("新建任务")
            }
        }
        // 提示浮在右上角：避开工具栏与会挡视区，配合自动消失避免长期遮挡。
        .overlay(alignment: .topTrailing) {
            if let banner = model.banner {
                BannerView(message: banner) {
                    model.banner = nil
                }
                .padding(.top, 12)
                .padding(.trailing, 16)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.banner?.id)
        // 同一视图上叠加两个 `.sheet(isPresented:)` 会互相丢弃，并留下未消费的
        // 标志位。这里收敛成单个 `.sheet(item:)`，由 ActiveSheet 决定呈现哪一张。
        // 底层仍复用 model 里既有的两个布尔量，故菜单/通知等调用方无需改动。
        .sheet(item: activeSheet) { sheet in
            switch sheet {
            case .newTask:
                NewTaskSheet()
                    .environmentObject(model)
            case .settings:
                SettingsView()
                    .environmentObject(model)
            }
        }
    }

    /// 当前应呈现的模态表单。
    private enum ActiveSheet: String, Identifiable {
        case newTask
        case settings
        var id: String { rawValue }
    }

    /// 把 model 的两个布尔量映射成单一的可选表单。
    /// 两者同时为真时以「新建任务」优先（主流程）。
    private var activeSheet: Binding<ActiveSheet?> {
        Binding(
            get: {
                if model.showNewTaskSheet { return .newTask }
                if model.showSettings { return .settings }
                return nil
            },
            set: { newValue in
                model.showNewTaskSheet = (newValue == .newTask)
                model.showSettings = (newValue == .settings)
            }
        )
    }
}
