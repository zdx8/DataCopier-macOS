import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let menuBarController = MenuBarController()
    private let windowCloseDelegate = MainWindowCloseDelegate()

    /// 窗口成为 key 的观察者 token；持有它以便退出时移除。
    private var keyWindowObserver: NSObjectProtocol?
    /// 工作表挂载/卸载的观察者；用于在模态期间重新对齐标题栏配色。
    private var sheetObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 通过 SwiftPM 打包的非 Xcode 应用需要显式声明为常规前台应用，
        // 否则从命令行启动时不会出现在 Dock 与程序切换器中。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 菜单栏常驻图标：应用随时可从这里被唤起或退出。
        menuBarController.install()

        // SwiftUI WindowGroup 没有暴露关窗回调，这里在主窗口就绪后挂上关闭拦截
        // delegate。窗口用结构判定（见 MainWindow），不再依赖标题字符串。
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            self.installCloseInterception(on: window)
        }

        // 兜底：观察者注册前窗口可能已就绪，直接尝试挂一次。
        if let window = MainWindow.standard {
            installCloseInterception(on: window)
        }
        // 延迟再对齐一次窗口外观：
        // SwiftUI 在窗口首次上屏后才装配 toolbar，会把 titlebarAppearsTransparent
        // 重新置回 false；只在 didBecomeKey 时设置会被覆盖，故窗口上屏后再对齐几轮。
        for delay in [0.3, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows where MainWindow.isCandidate(window) {
                    self.applyWindowChrome(on: window)
                }
            }
        }


        // 挂上工作表（新建任务 / 设置）时，AppKit 会把父窗口标题栏重新materialize，
        // 顶栏又变回一档更浅的灰。工作表出现与消失时各对齐一次。
        sheetObservers = [
            NotificationCenter.default.addObserver(forName: .init("NSWindowDidAttachSheetNotification"),
                                                   object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                self?.applyWindowChrome(on: window)
            },
            NotificationCenter.default.addObserver(forName: .init("NSWindowDidEndSheetNotification"),
                                                   object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                self?.applyWindowChrome(on: window)
            }
        ]
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
            self.keyWindowObserver = nil
        }
        sheetObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sheetObservers = []
    }

    /// 给主窗口挂关闭拦截；面板与工作表（sheet）跳过。
    private func installCloseInterception(on window: NSWindow) {
        guard MainWindow.isCandidate(window) else { return }
        applyWindowChrome(on: window)
        windowCloseDelegate.attach(to: window)
    }

    /// 让标题栏/工具栏与内容同色。
    ///
    /// 默认情况下 macOS 会给标题栏叠一层外观材料（深色下实测为 #303136），
    /// 与窗口内容的 #000000 明显不同，视觉上像一条「顶栏」。这里把标题栏设为
    /// 透明、窗口底色设成与内容一致的纸面色，并去掉工具栏底部分隔线，
    /// 于是顶栏与主界面自然连成一片。颜色用动态 NSColor，切换浅色/深色自动跟随。
    private func applyWindowChrome(on window: NSWindow) {
        window.backgroundColor = Bencho.nsSurface
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar?.showsBaselineSeparator = false
        // 允许内容延伸到标题栏下方，否则透明标题栏会露出窗口底色与内容之间的接缝。
        window.styleMask.insert(.fullSizeContentView)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关闭行为由设置决定：退出软件时关窗即退出；
        // 最小化模式窗口只隐藏不关闭，本回调不会被触发。
        CloseAction.current == .quit
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 最小化模式下点击 Dock 图标时恢复主窗口。
        if !flag {
            MenuBarController.showMainWindow()
        }
        return true
    }
}
