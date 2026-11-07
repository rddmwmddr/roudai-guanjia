import SwiftUI

// MARK: - 品牌色（肉呆蓝 + 暖色背景）

enum Brand {
    static let blue      = Color(red: 0.29, green: 0.63, blue: 0.93)
    static let blueDeep  = Color(red: 0.16, green: 0.43, blue: 0.78)
    static let mint      = Color(red: 0.58, green: 0.90, blue: 0.85)
    static let cream     = Color(red: 1.00, green: 0.97, blue: 0.92)
    static let blush     = Color(red: 1.00, green: 0.80, blue: 0.84)
}

// MARK: - 全局背景（暖色渐变，让玻璃材质更通透）

struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    /// 深色模式下文字是白的，浅色的奶油渐变会让它们看不清，要换一组深色
    private var colors: [Color] {
        if colorScheme == .dark {
            return [Color(red: 0.12, green: 0.13, blue: 0.15),
                    Color(red: 0.10, green: 0.17, blue: 0.18),
                    Color(red: 0.09, green: 0.15, blue: 0.23)]
        }
        return [Brand.cream, Brand.mint.opacity(0.35), Brand.blue.opacity(0.18)]
    }

    var body: some View {
        LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// MARK: - 液态玻璃容器：26+ 用真·Liquid Glass，旧系统直接透传

struct GlassContainer<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - 玻璃卡片：26+ 液态玻璃，旧系统回退到材质

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// 带淡色染色的玻璃（用于强调卡片，如磁盘条/拖拽区）
struct TintedGlassCard: ViewModifier {
    var tint: Color
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint.opacity(0.18)), in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - 通用排序控件（下拉选键 + 升降序）

struct SortBar<K: Hashable>: View {
    let options: [(label: String, key: K)]
    @Binding var key: K
    @Binding var ascending: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.arrow.down").font(.caption).foregroundStyle(.secondary)
            Picker("排序", selection: $key) {
                ForEach(options, id: \.key) { opt in Text(opt.label).tag(opt.key) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            Button { ascending.toggle() } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .help(ascending ? "升序" : "降序")
        }
    }
}

// MARK: - 自动换行流式布局（用于权限徽标等）

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxRowWidth: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            maxRowWidth = max(maxRowWidth, x - spacing)   // 去掉行尾多算的一个 spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : maxRowWidth, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

extension View {
    /// 版本无关的 onChange：macOS 14+ 用新两参 API，13 用旧 API（避免弃用警告）
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, perform: @escaping (V) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in perform(newValue) }
        } else {
            self.onChange(of: value, perform: perform)
        }
    }

    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
    func tintedGlassCard(_ tint: Color, cornerRadius: CGFloat = 16) -> some View {
        modifier(TintedGlassCard(tint: tint, cornerRadius: cornerRadius))
    }

    /// 玻璃按钮：26+ 用 .glass / .glassProminent，旧系统回退 bordered
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) }
            else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) }
            else { self.buttonStyle(.bordered) }
        }
    }
}
