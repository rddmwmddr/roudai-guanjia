import SwiftUI

/// 扫描中的精致动画：向外扩散的涟漪光环 + 中心脉动徽标 + 环绕旋转的闪光。
/// 全部用 SwiftUI 声明式动画驱动（无 Timer / 无定时器残留），视图消失即自动停止，不会泄漏。
struct ScanningAnimation: View {
    var size: CGFloat = 120
    var caption: String?

    @State private var animate = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                // 三圈错相位涟漪
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(
                            LinearGradient(colors: [Brand.blue, Brand.mint],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 3
                        )
                        .scaleEffect(animate ? 1.0 : 0.35)
                        .opacity(animate ? 0.0 : 0.8)
                        .animation(
                            .easeOut(duration: 1.8)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.6),
                            value: animate
                        )
                }

                // 环绕旋转的闪光
                ForEach(0..<6, id: \.self) { i in
                    Image(systemName: "sparkle")
                        .font(.system(size: size * 0.11))
                        .foregroundStyle(Brand.blue.opacity(0.7))
                        .offset(y: -size * 0.46)
                        .rotationEffect(.degrees(Double(i) / 6 * 360))
                        .scaleEffect(animate ? 1.0 : 0.5)
                        .opacity(animate ? 1.0 : 0.3)
                        .animation(
                            .easeInOut(duration: 1.2)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.15),
                            value: animate
                        )
                }
                .rotationEffect(.degrees(animate ? 360 : 0))
                .animation(.linear(duration: 8).repeatForever(autoreverses: false), value: animate)

                // 中心脉动徽标
                Circle()
                    .fill(
                        RadialGradient(colors: [Brand.blue, Brand.blueDeep],
                                       center: .topLeading, startRadius: 2, endRadius: size * 0.6)
                    )
                    .frame(width: size * 0.5, height: size * 0.5)
                    .overlay(
                        Image(systemName: "sparkles")
                            .font(.system(size: size * 0.22, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: Brand.blue.opacity(0.4), radius: 12, y: 4)
                    .scaleEffect(animate ? 1.06 : 0.94)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: animate)
            }
            .frame(width: size, height: size)

            if let caption {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .onAppear { animate = true }
    }
}

/// 小号忙碌指示（行内用），同样无 Timer
struct BusyDots: View {
    @State private var animate = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Brand.blue)
                    .frame(width: 7, height: 7)
                    .scaleEffect(animate ? 1.0 : 0.5)
                    .opacity(animate ? 1.0 : 0.4)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(i) * 0.18),
                               value: animate)
            }
        }
        .onAppear { animate = true }
    }
}
