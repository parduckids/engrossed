import SwiftUI

/// The app’s mark: an open eye inside rings that expand and fade on a slow
/// four-second cycle — the pace of a deliberate breath. It is the one moving
/// thing in an app that is otherwise deliberately still, so it stays slow enough
/// to be calming rather than another thing pulling at your attention.
struct EngrossedMark: View {
    var size: CGFloat = 34
    var tint: Color = .accentColor
    var animated: Bool = true

    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldAnimate: Bool { animated && !reduceMotion }

    var body: some View {
        ZStack {
            ForEach(Array([0.94, 0.72].enumerated()), id: \.offset) { index, scale in
                Circle()
                    .strokeBorder(tint.opacity(breathing ? 0.10 : 0.30), lineWidth: size * 0.028)
                    .frame(width: size * scale, height: size * scale)
                    .scaleEffect(breathing ? 1.06 : 0.9)
                    .animation(shouldAnimate
                               ? .easeInOut(duration: 3.6)
                                   .repeatForever(autoreverses: true)
                                   .delay(Double(index) * 0.5)
                               : nil,
                               value: breathing)
            }

            EyeShape()
                .fill(tint.opacity(0.92))
                .frame(width: size * 0.56, height: size * 0.34)

            Circle()
                .fill(Color(white: 0.99))
                .frame(width: size * 0.145, height: size * 0.145)

            Circle()
                .fill(tint)
                .frame(width: size * 0.075, height: size * 0.075)
        }
        .frame(width: size, height: size)
        .onAppear { if shouldAnimate { breathing = true } }
        .accessibilityHidden(true)
    }
}

/// A lens: two curves meeting at the corners.
struct EyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = CGPoint(x: rect.minX, y: rect.midY)
        let right = CGPoint(x: rect.maxX, y: rect.midY)
        let pull = rect.width * 0.28

        path.move(to: left)
        path.addCurve(to: right,
                      control1: CGPoint(x: rect.minX + pull, y: rect.minY),
                      control2: CGPoint(x: rect.maxX - pull, y: rect.minY))
        path.addCurve(to: left,
                      control1: CGPoint(x: rect.maxX - pull, y: rect.maxY),
                      control2: CGPoint(x: rect.minX + pull, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
