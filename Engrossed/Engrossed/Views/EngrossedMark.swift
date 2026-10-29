import SwiftUI

/// The app’s mark: the eye from the icon, breathing very slowly, four seconds
/// in and out. It is the one moving thing in an app that is otherwise
/// deliberately still, so it stays slow enough to be calming rather than
/// another thing pulling at your attention.
///
/// No rings around it. They were the old mark, and the unrelated Engross focus
/// timer’s icon is a ring target.
struct EngrossedMark: View {
    var size: CGFloat = 34
    var tint: Color = .accentColor
    var animated: Bool = true

    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldAnimate: Bool { animated && !reduceMotion }

    var body: some View {
        ZStack {
            EyeShape()
                .fill(tint.opacity(0.92))
                .frame(width: size * 0.9, height: size * 0.48)

            Circle()
                .fill(Color(white: 0.99))
                .frame(width: size * 0.3, height: size * 0.3)
                .offset(x: size * 0.02, y: -size * 0.015)

            Circle()
                .fill(tint)
                .frame(width: size * 0.3, height: size * 0.3)
                .scaleEffect(0.62)
        }
        .frame(width: size, height: size)
        .scaleEffect(breathing ? 1 : 0.94)
        .animation(shouldAnimate ? .easeInOut(duration: 4).repeatForever(autoreverses: true) : nil,
                   value: breathing)
        .onAppear { if shouldAnimate { breathing = true } }
        .accessibilityHidden(true)
    }
}

/// The eye’s outline, as in the icon: two circular arcs meeting in sharp
/// points. Drawn as the overlap of two circles, so the points stay crisp.
struct EyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width / 2
        let h = rect.height / 2
        guard w > 0, h > 0 else { return Path() }
        let r = (w * w + h * h) / (2 * h)
        let top = Path(ellipseIn: CGRect(x: rect.midX - r, y: rect.minY, width: 2 * r, height: 2 * r))
        let bottom = Path(ellipseIn: CGRect(x: rect.midX - r, y: rect.maxY - 2 * r, width: 2 * r, height: 2 * r))
        return top.intersection(bottom)
    }
}
