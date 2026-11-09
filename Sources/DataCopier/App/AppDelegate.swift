import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let menuBarController = MenuBarController()
    private let windowCloseDelegate = MainWindowCloseDelegate()

    /// 窗口成为 key 的观察者 token；持有它以便退出时移除。
    private var keyWindowObserver: NSObjectProtocol?

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
            self.keyWindowObserver = nil
        }
    }

    /// 给主窗口挂关闭拦截；面板与工作表（sheet）跳过。
    private func installCloseInterception(on window: NSWindow) {
        guard MainWindow.isCandidate(window) else { return }
        windowCloseDelegate.attach(to: window)
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
