import AppKit

// MARK: - 关闭行为

/// 点击窗口关闭按钮时的行为。
///
/// - `quit`：维持 macOS 常见默认——关窗即退出应用；
/// - `minimize`：窗口仅隐藏（orderOut），应用与菜单栏图标继续常驻，
///   适合把 DataCopier 当作「插上卡就导入」的后台工具使用。
enum CloseAction: String {
    case quit
    case minimize

    /// 偏好存储键。设置页通过 @AppStorage 写入同一个键，
    /// 两侧无需互相持有引用即可保持一致。
    static let storageKey = "DataCopier.closeAction"

    static var current: CloseAction {
        CloseAction(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .quit
    }
}

// MARK: - 菜单栏常驻

/// 系统菜单栏（任务栏）常驻图标与菜单。
final class MenuBarController: NSObject {

    private var statusItem: NSStatusItem?

    /// 安装菜单栏图标。重复调用只安装一次。
    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "arrow.down.doc.fill",
                                   accessibilityDescription: "DataCopier")
        }

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "打开 DataCopier",
                                  action: #selector(showMainWindow),
                                  keyEquivalent: "")
        openItem.target = self
        let newTaskItem = NSMenuItem(title: "新建拷贝任务",
                                     action: #selector(newCopyTask),
                                     keyEquivalent: "")
        newTaskItem.target = self
        let quitItem = NSMenuItem(title: "退出 DataCopier",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(openItem)
        menu.addItem(newTaskItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    @objc private func showMainWindow() {
        Self.showMainWindow()
    }

    @objc private func newCopyTask() {
        Self.showMainWindow()
        NotificationCenter.default.post(name: .dataCopierNewTask, object: nil)
    }

    /// 把主窗口带到前台。最小化模式下窗口只是被 orderOut，
    /// 仍在 NSApp.windows 中，直接 makeKeyAndOrderFront 即可恢复。
    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        MainWindow.standard?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 主窗口识别

/// 主窗口的统一识别入口。
///
/// 不再用标题字符串匹配：`WindowGroup(" ")` 的标题是单个空格，
/// 且会随系统本地化变化，靠它做标识必然失效。这里改为结构判定 ——
/// 是普通窗口（非面板）、不是附着的工作表、且承载内容视图控制器。
enum MainWindow {

    /// 是否为候选主窗口。
    static func isCandidate(_ window: NSWindow) -> Bool {
        !window.isKind(of: NSPanel.self)
            && !window.isSheet
            && window.sheetParent == nil
            && window.contentViewController != nil
    }

    /// 当前进程内的主窗口；若结构判定落空，回退到首个非面板、非工作表的窗口。
    static var standard: NSWindow? {
        NSApp.windows.first(where: isCandidate)
            ?? NSApp.windows.first { !$0.isKind(of: NSPanel.self) && $0.sheetParent == nil }
    }
}

// MARK: - 关闭拦截

/// 主窗口的关闭拦截。
///
/// SwiftUI 的 WindowGroup 没有提供「关窗回调」，因此通过 NSWindowDelegate
/// 的 windowShouldClose 实现：最小化模式下不真正关闭，只把窗口隐藏。
///
/// 注意：SwiftUI 会给窗口挂上自己的 delegate（实测为 `AppKitWindowController`），
/// 直接覆写会丢掉它的窗口管理行为。这里保存原 delegate，未由本类处理的消息
/// 一律转发回去；`NSWindow.delegate` 是弱引用，故用强引用持有以免其被回收。
final class MainWindowCloseDelegate: NSObject, NSWindowDelegate {

    /// 被覆写的原 delegate（SwiftUI 的窗口控制器）。强引用以保活。
    private var forwardee: NSWindowDelegate?

    /// 把关闭拦截挂到窗口上。重复调用只挂一次。
    func attach(to window: NSWindow) {
        guard !(window.delegate is MainWindowCloseDelegate) else { return }
        if let existing = window.delegate {
            forwardee = existing
        }
        window.delegate = self
    }

    // 未实现的可选 delegate 方法：声明响应并转发给原 delegate，
    // 否则 AppKit 会因为「本对象不响应」而彻底跳过这些回调。
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forwardee?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) { return nil }
        guard let forwardee, forwardee.responds(to: aSelector) else { return nil }
        return forwardee
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard CloseAction.current == .minimize else {
            // 退出模式：把裁决权交回原 delegate（若有），默认放行。
            return forwardee?.windowShouldClose?(sender) ?? true
        }
        sender.orderOut(nil)
        // 隐藏窗口后把焦点还给其他应用，避免留下一个无窗口的「前台应用」。
        NSApp.hide(nil)
        return false
    }
}

extension Notification.Name {
    /// 菜单栏「新建拷贝任务」通知。由 DataCopierApp 监听并打开新建任务表单。
    static let dataCopierNewTask = Notification.Name("DataCopier.NewTask")
    /// 检测到可移除存储（USB 相机卡 / U 盘）挂载的通知。由 AppModel 发出。
    static let dataCopierUSBMounted = Notification.Name("DataCopier.USBMounted")
}
