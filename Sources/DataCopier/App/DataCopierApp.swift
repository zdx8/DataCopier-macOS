import SwiftUI

@main
struct DataCopierApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    /// 界面主题。设置页改动此值后，这里同步把外观应用到整个进程。
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw: String = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode { AppearanceMode.current(from: appearanceRaw) }

    var body: some Scene {
        // 标题用空白占位：不显示「数据拷贝」文字，同时保留标准标题栏机制，
        // 保证工具栏 primaryAction 按钮正常右对齐（hiddenTitleBar 会使按钮错误地靠左）。
        WindowGroup(" ") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 680)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear { AppearanceMode.apply(appearance) }
                .onChange(of: appearanceRaw) { _, newValue in
                    AppearanceMode.apply(AppearanceMode.current(from: newValue))
                }
                // 菜单栏图标的「新建拷贝任务」走通知进来：AppDelegate 不持有
                // model，跨层用通知解耦，避免把状态对象塞进单例。
                .onReceive(NotificationCenter.default.publisher(for: .dataCopierNewTask)) { _ in
                    model.showNewTaskSheet = true
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建拷贝任务") { model.showNewTaskSheet = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("任务") {
                Button("开始选中任务") {
                    if let id = model.selection { model.start(id) }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("停止选中任务") {
                    if let id = model.selection { model.cancel(id) }
                }
                .keyboardShortcut(".", modifiers: .command)

                Divider()

                Button("按校验清单复核…") {
                    if let id = model.selection { model.verifyAgainstManifest(for: id) }
                }
            }
        }
    }
}
