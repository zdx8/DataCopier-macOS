import SwiftUI
import AppKit

/// 界面主题。
///
/// 三档而非「浅色 / 深色」两档：多数用户希望跟随系统，
/// 只有需要固定外观（例如比对照片色彩、或系统定时切换时避免界面突变）时才手动锁定。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// SwiftUI 侧的配色方案覆盖；nil 表示交给系统决定。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// AppKit 侧的外观覆盖。
    ///
    /// 仅设置 `preferredColorScheme` 只能改变 SwiftUI 绘制的部分：窗口标题栏、
    /// 下拉菜单、文件选择面板等原生控件仍沿用系统外观，深色界面下会露出浅色条块。
    /// 因此两处必须同时设置。
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static let storageKey = "AppAppearance"

    static func current(from raw: String) -> AppearanceMode {
        AppearanceMode(rawValue: raw) ?? .system
    }

    /// 把外观应用到整个进程并持久化。
    static func apply(_ mode: AppearanceMode) {
        NSApplication.shared.appearance = mode.appearance
        UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
        // 让已经打开的窗口立即重绘标题栏等原生部件。
        for window in NSApplication.shared.windows {
            window.appearance = mode.appearance
        }
    }
}

/// 设置页的「外观」区域。
struct AppearanceForm: View {
    @AppStorage(AppearanceMode.storageKey) private var raw: String = AppearanceMode.system.rawValue

    var body: some View {
        Section("外观") {
            Picker("界面主题", selection: $raw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.symbol).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Text("「跟随系统」会随 macOS 的外观设置自动切换；浅色与深色为固定外观，便于在稳定光照下比对素材。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
