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
                    TaskDetailView(task: task)
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
        .sheet(isPresented: $model.showNewTaskSheet) {
            NewTaskSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .environmentObject(model)
        }
    }
}
