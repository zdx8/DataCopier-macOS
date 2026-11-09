import SwiftUI
import AppKit

// MARK: - bencho 设计令牌
//
// 取值逐项对应 https://github.com/cabralorenzo/bencho 的 `tokens.css`（MIT）。
// bencho 本身是 React 组件库，无法在 SwiftUI 里「安装」，因此这里按它的令牌
// 与组件规格重新实现一套原生版本：
//
// - 纸面色板：浅色以 #FFFFFF 为底，面板退到 #F7F7F6；深色以纯黑为底，
//   面板升到 #0A0A0A / #262626。层级靠「底色深浅 + 1px 发丝边」表达，
//   而不是投影——bencho 的注释里明确写了「no drop shadows on the bench」。
// - 控件色：`fillSlab`（浅色是纸白、深色是 #262626）作为控件底色，
//   `fillOn` 作为其上的墨色。两者互为反色，所以胶囊、滑块在任何外观下都成立。
// - 圆角：胶囊 999、卡片 22、行 14、勾选块 6。
// - 字阶：标题 14/500/−0.01em，正文 13、元信息 11；数字用 tabular-nums，
//   -0.02em 收字距，大号 30/500。
// - 动效：统一 cubic-bezier(0.22, 1, 0.36, 1)，220ms；按压缩到 0.96。
//
// 所有颜色都用 NSColor 动态提供者，跟随系统外观与应用的「外观」设置。

enum Bencho {

    // MARK: 色板

    /// 页面底色。浅色纸白，深色纯黑。
    static let bg = Color.dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// 面板底色（比页面低一档）。
    static let card = Color.dynamic(light: 0xF7F7F6, dark: 0x0A0A0A)
    /// 次级面板 / 侧栏。
    static let surface = Color.dynamic(light: 0xF7F7F6, dark: 0x0F0F0F)
    /// 再低一档：输入框内衬、未选中的分段。
    static let surface2 = Color.dynamic(light: 0xF1F1F0, dark: 0x181818)
    /// 最深一档：进度条槽、分隔底。
    static let surface3 = Color.dynamic(light: 0xECEBE7, dark: 0x202020)

    /// 主墨色。
    static let ink = Color.dynamic(light: 0x17181A, dark: 0xFFFFFF)
    /// 二级文字（说明、标签）。
    static let ink2 = Color.dynamic(light: 0x3C3B37, dark: 0xB4B4B4)
    /// 三级文字（辅助说明）。
    static let ink3 = Color.dynamic(light: 0x5C5B56, dark: 0x9A9A9A)
    /// 四级文字（占位符）。
    static let ink4 = Color.dynamic(light: 0x6F6E68, dark: 0x828282)
    /// 最弱文字（禁用、极次要）。
    static let ink5 = Color.dynamic(light: 0x85847E, dark: 0x6B6B6B)

    /// 反色块（选中行、主按钮）。浅色近黑，深色近白。
    static let slab = Color.dynamic(light: 0x17181A, dark: 0xFFFFFF)
    /// 反色块上的文字。
    static let onSlab = Color.dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// 控件底色。
    static let fillSlab = Color.dynamic(light: 0xFFFFFF, dark: 0x262626)
    /// 控件上的前景色。
    static let fillOn = Color.dynamic(light: 0x17181A, dark: 0xFFFFFF)

    /// 发丝边（取代投影）。
    static let hairline = Color.dynamicAlpha(light: (0x17181A, 0.09), dark: (0xFFFFFF, 0.10))
    /// 更弱的分隔线。
    static let hairlineSoft = Color.dynamicAlpha(light: (0x17181A, 0.06), dark: (0xFFFFFF, 0.07))

    /// 强调色（bencho 的 signal）。
    static let signal = Color.dynamic(light: 0x2231DD, dark: 0x6E7BFF)
    /// 取色高亮（bencho 的 pick）。
    static let pick = Color.dynamic(light: 0x0D99FF, dark: 0x3AA9FF)

    /// 状态色：直接取 bencho toast 的图标色，不掺透明度。
    static let ok = Color.dynamic(light: 0x15803D, dark: 0x34D17A)
    static let warn = Color.dynamic(light: 0xB45309, dark: 0xE09A12)
    static let danger = Color.dynamic(light: 0xB42318, dark: 0xE5484D)
    static let ember = Color.dynamic(light: 0xB8431C, dark: 0xE8774A)

    /// 供 AppKit 侧设置窗口底色，保证标题栏与内容同色。
    static var nsBackground: NSColor {
        NSColor.dynamic(light: 0xFFFFFF, dark: 0x000000, alpha: 1)
    }
    /// 与 `nsBackground` 成对的标题栏/纸面底色（浅色略灰，深色纯黑）。
    static var nsSurface: NSColor {
        NSColor.dynamic(light: 0xF7F7F6, dark: 0x000000, alpha: 1)
    }

    /// 悬停时的淡底（墨色 6%）。
    static let wash = Color.dynamicAlpha(light: (0x17181A, 0.06), dark: (0xFFFFFF, 0.08))
    /// 更实的淡底（墨色 10%）。
    static let washStrong = Color.dynamicAlpha(light: (0x17181A, 0.10), dark: (0xFFFFFF, 0.12))

    // MARK: 圆角与间距

    enum Radius {
        /// 胶囊（按钮、徽标、分段控件）。
        static let pill: CGFloat = 999
        /// 卡片与浮层。
        static let card: CGFloat = 18
        /// 行内方块（列表行、输入框）。
        static let row: CGFloat = 12
        /// 勾选框 / 图标底。
        static let mark: CGFloat = 6
        /// 小胶囊（标签）。
        static let chip: CGFloat = 8
    }

    enum Space {
        static let hair: CGFloat = 4
        static let tight: CGFloat = 8
        static let base: CGFloat = 12
        static let roomy: CGFloat = 16
        static let loose: CGFloat = 24
        static let section: CGFloat = 28
    }

    // MARK: 字阶

    enum Typeface {
        /// 大号数字：30/500，tabular，−0.02em。
        static func number(_ size: CGFloat = 30) -> Font {
            .system(size: size, weight: .medium, design: .default)
        }
        /// 标题：14/500，−0.01em。
        static func title(_ size: CGFloat = 14) -> Font {
            .system(size: size, weight: .medium, design: .default)
        }
        /// 正文：13。
        static func body(_ size: CGFloat = 13) -> Font {
            .system(size: size, weight: .regular, design: .default)
        }
        /// 元信息：11。
        static func meta(_ size: CGFloat = 11) -> Font {
            .system(size: size, weight: .regular, design: .default)
        }
        /// 等宽（路径、哈希）。
        static func mono(_ size: CGFloat = 12) -> Font {
            .system(size: size, weight: .regular, design: .monospaced)
        }
    }

    // MARK: 动效

    enum Motion {
        /// bencho 的默认曲线。
        static let standard = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
        /// 弹入 / 还原（带一点回弹）。
        static let spring = Animation.timingCurve(0.3, 1.2, 0.4, 1, duration: 0.32)
        /// 按压反馈。
        static let press = Animation.timingCurve(0.3, 0.9, 0.4, 1, duration: 0.11)
        /// 数字滚动。
        static let roll = Animation.timingCurve(0.3, 1.1, 0.4, 1, duration: 0.42)
    }
}

// MARK: - 颜色工具

extension Color {

    /// 明暗两套十六进制取值，由 NSColor 动态提供者按当前外观选择。
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor.dynamic(light: light, dark: dark, alpha: 1))
    }

    static func dynamicAlpha(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> Color {
        Color(nsColor: NSColor.dynamic(light: light.0, dark: dark.0, alphaLight: light.1, alphaDark: dark.1))
    }
}

extension NSColor {

    static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat) -> NSColor {
        dynamic(light: light, dark: dark, alphaLight: alpha, alphaDark: alpha)
    }

    static func dynamic(light: UInt32,
                        dark: UInt32,
                        alphaLight: CGFloat,
                        alphaDark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light,
                           alpha: isDark ? alphaDark : alphaLight)
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

// MARK: - 卡片容器

/// 一张 bencho 面板：`fillSlab` 底 + 1px 发丝边，无投影。
struct BenchoPanel<Content: View>: View {
    var fill: Color = Bencho.fillSlab
    var radius: CGFloat = Bencho.Radius.card
    var padding: CGFloat = Bencho.Space.roomy
    var stroke: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if stroke {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Bencho.hairline, lineWidth: 1)
                }
            }
    }
}

extension View {
    /// 平铺面板：用于区块外层。
    func benchoPanel(fill: Color = Bencho.fillSlab,
                     radius: CGFloat = Bencho.Radius.card,
                     padding: CGFloat = Bencho.Space.roomy,
                     stroke: Bool = true) -> some View {
        BenchoPanel(fill: fill, radius: radius, padding: padding, stroke: stroke) { self }
    }
}

// MARK: - 按钮

enum BenchoButtonKind {
    /// 反色实心：一个视图里只该有一个。
    case slab
    /// 墨色淡底：次级操作。
    case wash
    /// 纯文字，悬停才出现淡底。
    case quiet
    /// 破坏性（ember）。
    case destructive
}

struct BenchoButtonStyle: ButtonStyle {
    var kind: BenchoButtonKind = .wash
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        BenchoButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

/// 需要一个独立视图才能拿到 hover 状态——`ButtonStyle` 的 `makeBody` 里没有 `@State`。
struct BenchoButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: BenchoButtonKind
    let compact: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(Bencho.Typeface.title(compact ? 12.5 : 13))
            .tracking(-0.01 * (compact ? 12.5 : 13))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 26 : 32)
            .background(background, in: Capsule())
            .overlay {
                if kind == .wash || kind == .quiet {
                    Capsule().strokeBorder(hovering ? Bencho.hairline : .clear, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Bencho.Motion.press, value: configuration.isPressed)
            .animation(Bencho.Motion.standard, value: hovering)
            .onHover { hovering = $0 }
            .opacity(isEnabled ? 1 : 0.42)
    }

    private var foreground: Color {
        switch kind {
        case .slab: return Bencho.onSlab
        case .wash, .quiet: return Bencho.fillOn
        case .destructive: return Bencho.ember
        }
    }

    private var background: Color {
        switch kind {
        case .slab:
            return Bencho.slab.opacity(hovering ? 0.88 : 1)
        case .wash:
            return hovering ? Bencho.washStrong : Bencho.wash
        case .quiet:
            return hovering ? Bencho.wash : .clear
        case .destructive:
            return hovering ? Bencho.ember.opacity(0.12) : .clear
        }
    }
}

extension ButtonStyle where Self == BenchoButtonStyle {
    static var benchoSlab: BenchoButtonStyle { BenchoButtonStyle(kind: .slab) }
    static var benchoWash: BenchoButtonStyle { BenchoButtonStyle(kind: .wash) }
    static var benchoQuiet: BenchoButtonStyle { BenchoButtonStyle(kind: .quiet) }
    static var benchoDestructive: BenchoButtonStyle { BenchoButtonStyle(kind: .destructive) }
    static var benchoCompact: BenchoButtonStyle { BenchoButtonStyle(kind: .wash, compact: true) }
}

// MARK: - 状态徽标

/// bencho 的状态是「一个实心圆点 + 文字」，不是带色底的胶囊：
/// 色底会把状态色掺进底色，浅色下尤其容易糊成一片。
struct BenchoStatus: View {
    let text: String
    var color: Color = Bencho.ink4
    var dot = true

    var body: some View {
        HStack(spacing: 5) {
            if dot {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(Bencho.Typeface.meta(11.5))
                .tracking(0)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Bencho.wash, in: Capsule())
    }
}

// MARK: - 分段控件

/// 胶囊底 + 反色滑块的 segmented，对应 bencho 的分段选择器。
struct BenchoSegmented<Value: Hashable>: View {
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value
    @Namespace private var slider

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    guard !selected else { return }
                    withAnimation(Bencho.Motion.spring) { selection = option }
                } label: {
                    Text(title(option))
                        .font(Bencho.Typeface.title(12.5))
                        .tracking(-0.01 * 12.5)
                        .foregroundStyle(selected ? Bencho.onSlab : Bencho.ink3)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Bencho.slab)
                                    .matchedGeometryEffect(id: "seg", in: slider)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Bencho.surface2, in: Capsule())
    }
}

// MARK: - 滚动数字

/// bencho 的 rolling-counter：每一位数字是一条竖向纸条，值变化时整条滚动，
/// 而不是整串数字替换。数字列宽固定（tabular），所以过渡时不会左右跳动。
struct RollingNumber: View {
    let text: String
    var size: CGFloat = 30
    var weight: Font.Weight = .medium
    var color: Color = Bencho.ink

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                if let digit = character.wholeNumberValue {
                    RollingDigit(digit: digit, size: size, weight: weight, color: color)
                } else {
                    Text(String(character))
                        .font(.system(size: size, weight: weight))
                        .tracking(-0.02 * size)
                        .monospacedDigit()
                        .foregroundStyle(color)
                }
            }
        }
    }
}

private struct RollingDigit: View {
    let digit: Int
    let size: CGFloat
    let weight: Font.Weight
    let color: Color

    private var cell: CGFloat { size * 1.16 }

    var body: some View {
        let strip = VStack(spacing: 0) {
            ForEach(0...10, id: \.self) { value in
                Text("\(value % 10)")
                    .font(.system(size: size, weight: weight))
                    .tracking(-0.02 * size)
                    .monospacedDigit()
                    .frame(width: size * 0.62, height: cell)
            }
        }
        .offset(y: -CGFloat(digit) * cell)
        .frame(width: size * 0.62, height: cell, alignment: .top)
        .clipped()
        .animation(Bencho.Motion.roll, value: digit)

        return strip.foregroundStyle(color)
    }
}

// MARK: - 进度条

/// 一条 6pt 的墨色胶囊压在浅槽上。bencho 用它代替系统进度条：
/// 没有光泽、没有动画条纹，只有长度在变。
struct BenchoMeter: View {
    let fraction: Double
    var tint: Color = Bencho.ink
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Bencho.surface3)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
                    .animation(Bencho.Motion.standard, value: fraction)
            }
        }
        .frame(height: height)
    }
}

// MARK: - 开关

/// 胶囊轨道 + 反色滑块。开启时轨道变成墨色，滑块变成纸色——
/// 这是 bencho 里 slab/ink 互为反色的同一套规则。
///
/// 关闭态必须看得出来：`.disabled(true)` 的开关（例如没选哈希算法时的「拷后复核」）
/// 若与可用态长得一样，用户会一直点它而得不到反馈。
struct BenchoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BenchoToggleBody(configuration: configuration)
    }
}

struct BenchoToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Bencho.Motion.spring) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: Bencho.Space.base) {
                configuration.label
                    .font(Bencho.Typeface.body(13))
                    .foregroundStyle(isEnabled ? Bencho.fillOn : Bencho.ink5)
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn
                              ? Bencho.slab.opacity(isEnabled ? 1 : 0.4)
                              : Bencho.surface3)
                        .frame(width: 38, height: 22)
                    Circle()
                        .fill(configuration.isOn ? Bencho.onSlab : Bencho.fillSlab)
                        .frame(width: 18, height: 18)
                        .padding(2)
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                }
                .animation(Bencho.Motion.spring, value: configuration.isOn)
            }
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering && isEnabled ? Bencho.wash : .clear)
                    .padding(.horizontal, -6)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .onHover { hovering = $0 }
        .animation(Bencho.Motion.standard, value: hovering)
    }
}

extension ToggleStyle where Self == BenchoToggleStyle {
    static var bencho: BenchoToggleStyle { BenchoToggleStyle() }
}

// MARK: - 滑块确认

/// 破坏性操作的确认不是「再点一次」，而是把滑块推到对岸：
/// 手势本身就是决定，误触的价格是完整的拖动距离。
struct SlideToConfirm: View {
    let title: String
    var confirmedTitle = "已确认"
    var tint: Color = Bencho.ember
    let onConfirm: () -> Void

    @State private var offset: CGFloat = 0
    @State private var done = false
    /// 提交后若面板被 Esc 或点击外部关掉，延迟回调不能再执行删除。
    @State private var cancelled = false

    private let height: CGFloat = 52
    private let knob: CGFloat = 44

    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - knob - 8)
            ZStack(alignment: .leading) {
                Capsule().fill(Bencho.fillSlab)

                // 文字必须画在填充条**下面**：bencho 的滑块确认是「推进的胶囊把字吃掉」，
                // 盖在字上面就变成了深字压在暖色块上，对比度不成立。
                Text(done ? confirmedTitle : title)
                    .font(Bencho.Typeface.title(13))
                    .tracking(-0.01 * 13)
                    .foregroundStyle(done ? Bencho.onSlab : Bencho.ink3)
                    .frame(maxWidth: .infinity)

                Capsule()
                    .fill(done ? tint : tint.opacity(0.92))
                    .frame(width: max(knob + 4, offset + knob + 4), height: height - 8)
                    .offset(x: 5)

                Circle()
                    .fill(done ? Bencho.onSlab : tint)
                    .frame(width: knob, height: knob)
                    .overlay {
                        Image(systemName: done ? "checkmark" : "arrow.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(done ? tint : Bencho.onSlab)
                    }
                    .padding(4)
                    .offset(x: offset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard !done else { return }
                                offset = min(travel, max(0, value.translation.width))
                            }
                            .onEnded { _ in
                                guard !done else { return }
                                if offset >= travel * 0.82 {
                                    withAnimation(Bencho.Motion.spring) {
                                        offset = travel
                                        done = true
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                        guard !cancelled else { return }
                                        onConfirm()
                                    }
                                } else {
                                    withAnimation(Bencho.Motion.spring) { offset = 0 }
                                }
                            }
                    )
            }
            .frame(height: height)
            .overlay {
                Capsule().strokeBorder(Bencho.hairline, lineWidth: 1)
            }
            .onDisappear { cancelled = true }
        }
        .frame(height: height)
    }
}

// MARK: - 区块标题

/// 表单里的分组标题：11pt、加宽字距、全大写，与正文拉开层级。
struct BenchoSectionHeader: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.08 * 10.5)
                .foregroundStyle(Bencho.ink4)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(Bencho.Typeface.meta(11))
                    .foregroundStyle(Bencho.ink5)
            }
        }
    }
}

/// 一组控件，包在面板里。
struct BenchoSection<Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Bencho.Space.base) {
            BenchoSectionHeader(text: title)
            VStack(alignment: .leading, spacing: Bencho.Space.base) {
                content
            }
            .benchoPanel(fill: Bencho.card, padding: Bencho.Space.roomy)
            .toggleStyle(.bencho)
            .textFieldStyle(.benchoField)
            if let caption {
                Text(caption)
                    .font(Bencho.Typeface.meta(11.5))
                    .foregroundStyle(Bencho.ink4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 输入框

/// 纸面内衬 + 1px 发丝边的单行输入框。聚焦时不加描边色——
/// bencho 的 field 只把边从 32% 墨提到全墨，这里用同样的规则。
struct BenchoTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(Bencho.Typeface.body(12.5))
            .foregroundStyle(Bencho.fillOn)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Bencho.fillSlab, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Bencho.hairline, lineWidth: 1)
            }
    }
}

extension TextFieldStyle where Self == BenchoTextFieldStyle {
    static var benchoField: BenchoTextFieldStyle { BenchoTextFieldStyle() }
}

// MARK: - 表单行

/// 表单的滚动容器：自上而下一列区块，区块间距 26。替代 SwiftUI `Form`，
/// 因为 `Form` 的分组样式（圆角卡片 + 系统灰底）无法改成 bencho 的纸面。
struct BenchoForm<Content: View>: View {
    var spacing: CGFloat = 26
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Bencho.bg)
        .toggleStyle(.bencho)
        .textFieldStyle(.benchoField)
    }
}

/// 左标签右控件的一行，用于替代 Form 的 LabeledContent。
struct BenchoFieldRow<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Bencho.Space.base) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Bencho.Typeface.body(13))
                    .foregroundStyle(Bencho.fillOn)
                if let hint {
                    Text(hint)
                        .font(Bencho.Typeface.meta(11))
                        .foregroundStyle(Bencho.ink5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            content
        }
    }
}

// MARK: - 空态

struct BenchoEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Bencho.Space.roomy) {
            ZStack {
                RoundedRectangle(cornerRadius: Bencho.Radius.card, style: .continuous)
                    .fill(Bencho.card)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: Bencho.Radius.card, style: .continuous)
                    .strokeBorder(Bencho.hairline, lineWidth: 1)
                    .frame(width: 76, height: 76)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Bencho.ink3)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .tracking(-0.01 * 16)
                    .foregroundStyle(Bencho.ink)
                Text(message)
                    .font(Bencho.Typeface.body(13))
                    .foregroundStyle(Bencho.ink4)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(BenchoButtonStyle(kind: .slab))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Bencho.bg)
    }
}

// MARK: - 提示条

/// bencho 的 toast：纸片 + 发丝边，状态色只落在图标上，不铺底。
struct BenchoToast: View {
    let kind: AppModel.BannerMessage.Kind
    let text: String
    let caption: String?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Bencho.Space.base) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(Bencho.Typeface.title(13))
                    .tracking(-0.01 * 13)
                    .foregroundStyle(Bencho.fillOn)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(Bencho.Typeface.meta(11.5))
                        .foregroundStyle(Bencho.ink4)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Bencho.ink4)
                    .frame(width: 22, height: 22)
                    .background(Bencho.wash, in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Bencho.fillSlab, in: RoundedRectangle(cornerRadius: Bencho.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Bencho.Radius.card, style: .continuous)
                .strokeBorder(Bencho.hairline, lineWidth: 1)
        }
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: return Bencho.ink3
        case .success: return Bencho.ok
        case .warning: return Bencho.warn
        case .error: return Bencho.danger
        }
    }
}
