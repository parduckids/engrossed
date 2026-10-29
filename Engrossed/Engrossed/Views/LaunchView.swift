import SwiftUI

/// The opening moment: the icon’s eye opening on the app’s own red, printed
/// in halftone like the icon. It runs for well under two seconds and a tap
/// skips it, because an animation you cannot get past is just a delay wearing
/// a costume.
struct LaunchView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var lidOpen = false
    @State private var irisIn = false
    @State private var wordIn = false
    @State private var leaving = false

    private let deep = Color(red: 0.353, green: 0.106, blue: 0.169)
    private let rose = Color(red: 0.820, green: 0.376, blue: 0.451)
    private let cream = Color(red: 0.988, green: 0.961, blue: 0.945)
    private let iris = Color(red: 0.796, green: 0.376, blue: 0.455)

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let mark = size * 0.62

            ZStack {
                LinearGradient(colors: [rose, deep],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                Halftone(dot: deep)
                    .ignoresSafeArea()

                // The eye, opening. The pupil sits slightly off a rose pass,
                // as in the icon, like a two-colour print.
                ZStack {
                    EyeShape()
                        .fill(cream)
                        .frame(width: mark, height: mark * 0.533)
                        .scaleEffect(y: lidOpen ? 1 : 0.04, anchor: .center)

                    ZStack {
                        Circle()
                            .fill(iris)
                            .offset(x: mark * 0.027, y: -mark * 0.018)
                        Circle()
                            .fill(deep)
                    }
                    .frame(width: mark * 0.35, height: mark * 0.35)
                    .scaleEffect(irisIn ? 1 : 0.2)
                    .opacity(irisIn ? 1 : 0)
                }

                Text("Engrossed")
                    .font(.custom("InstrumentSerif-Regular", size: size * 0.13))
                    .foregroundStyle(cream)
                    .opacity(wordIn ? 1 : 0)
                    .offset(y: mark * 0.62 + (wordIn ? 0 : 10))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(leaving ? 1.12 : 1)
            .opacity(leaving ? 0 : 1)
            .contentShape(Rectangle())
            .onTapGesture { finish() }
            .onAppear(perform: begin)
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("Engrossed")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double tap to skip")
    }

    private func begin() {
        guard !reduceMotion else {
            lidOpen = true
            irisIn = true
            wordIn = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { finish() }
            return
        }

        withAnimation(.smooth(duration: 0.55).delay(0.12)) { lidOpen = true }
        withAnimation(.smooth(duration: 0.4).delay(0.5)) { irisIn = true }
        withAnimation(.smooth(duration: 0.5).delay(0.72)) { wordIn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) { finish() }
    }

    @State private var finished = false

    private func finish() {
        guard !finished else { return }
        finished = true
        withAnimation(.easeIn(duration: reduceMotion ? 0.15 : 0.32)) { leaving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.16 : 0.33)) { onFinish() }
    }
}

/// The icon’s dot screen: plum dots on a fixed grid, growing towards the dark
/// corner. Drawn once; it does not move.
private struct Halftone: View {
    let dot: Color

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 16
            let span = size.width + size.height
            var y: CGFloat = 0
            var row = 0
            while y <= size.height + step {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : step / 2
                while x <= size.width + step {
                    let r = 1.5 + 5.5 * (x + y) / span
                    context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(dot.opacity(0.42)))
                    x += step
                }
                y += step
                row += 1
            }
        }
        .accessibilityHidden(true)
    }
}
