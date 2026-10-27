import SwiftUI

/// The opening moment: an eye opening inside expanding rings, on the app's own
/// red. It runs for well under two seconds and a tap skips it, because an
/// animation you cannot get past is just a delay wearing a costume.
struct LaunchView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var ringPhase = false
    @State private var lidOpen = false
    @State private var irisIn = false
    @State private var wordIn = false
    @State private var leaving = false

    private let deep = Color(red: 0.353, green: 0.106, blue: 0.169)
    private let rose = Color(red: 0.820, green: 0.376, blue: 0.451)
    private let cream = Color(red: 0.988, green: 0.961, blue: 0.945)

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let mark = size * 0.34

            ZStack {
                LinearGradient(colors: [rose, deep],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                // Breath: rings travelling outward and thinning as they go.
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .strokeBorder(cream.opacity(ringPhase ? 0 : 0.30), lineWidth: 1.6)
                        .frame(width: mark * (ringPhase ? 3.2 : 0.9),
                               height: mark * (ringPhase ? 3.2 : 0.9))
                        .animation(reduceMotion ? nil :
                                    .easeOut(duration: 2.2)
                                    .repeatForever(autoreverses: false)
                                    .delay(Double(i) * 0.55),
                                   value: ringPhase)
                }

                // The eye, opening.
                ZStack {
                    EyeShape()
                        .fill(cream)
                        .frame(width: mark, height: mark * 0.6)
                        .scaleEffect(y: lidOpen ? 1 : 0.04, anchor: .center)

                    Circle()
                        .fill(deep)
                        .frame(width: mark * 0.2, height: mark * 0.2)
                        .overlay(alignment: .topLeading) {
                            Circle()
                                .fill(cream.opacity(0.9))
                                .frame(width: mark * 0.045, height: mark * 0.045)
                                .offset(x: mark * 0.035, y: mark * 0.035)
                        }
                        .scaleEffect(irisIn ? 1 : 0.2)
                        .opacity(irisIn ? 1 : 0)
                }

                Text("Engrossed")
                    .font(.system(size: size * 0.085, weight: .semibold, design: .serif))
                    .foregroundStyle(cream)
                    .opacity(wordIn ? 1 : 0)
                    .offset(y: mark * 0.95 + (wordIn ? 0 : 10))
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

        ringPhase = true
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
