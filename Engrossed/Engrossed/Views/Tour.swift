import SwiftUI

/// The steps of the walkthrough, in the order they are shown.
enum TourStep: Int, CaseIterable, Identifiable {
    case card, progress, modes, sprint, contents, settings

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .card:     return "One card at a time"
        case .progress: return "Where you are"
        case .modes:    return "Three ways to read"
        case .sprint:   return "A sprint"
        case .contents: return "Chapters"
        case .settings: return "How it looks"
        }
    }

    var detail: String {
        switch self {
        case .card:
            return "Two or three whole sentences, never cut mid-thought. Tap anywhere to move on, and the arrow at the bottom left takes you back."
        case .progress:
            return "Your place in this stretch. Small numbers on purpose: four of eleven is finishable, three per cent of two hundred pages is not."
        case .modes:
            return "Cards, Flow, and Pace. Flow dims everything but your spot. Pace shows one word at a time."
        case .sprint:
            return "Twenty minutes with a visible end, and a real break after it. Tap to pause."
        case .contents:
            return "Jump to any chapter, or to a page by the number printed on it."
        case .settings:
            return "Size, spacing, themes, how much goes on a card. Each setting says whether there is evidence behind it."
        }
    }
}

/// Collects the on-screen rectangle of anything tagged with `.tourAnchor`.
///
/// Anchors rather than hard-coded positions: the spotlight then lands on the
/// real control wherever it actually is, on a phone, on an iPad, after a
/// rotation, or when the toolbar reflows.
struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [TourStep: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourStep: Anchor<CGRect>],
                       nextValue: () -> [TourStep: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func tourAnchor(_ step: TourStep) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [step: $0] }
    }
}

/// Dims the screen, cuts a hole around the control being explained, and puts a
/// short note beside it.
struct TourOverlay: View {
    let step: TourStep
    let spotlight: CGRect?
    let settings: ReadingSettings
    let onNext: () -> Void
    let onSkip: () -> Void

    private var theme: PaperTheme { settings.theme }
    private var isLast: Bool { step == TourStep.allCases.last }

    var body: some View {
        GeometryReader { geo in
            let hole = (spotlight ?? .zero).insetBy(dx: -10, dy: -8)
            let holeInTopHalf = hole.midY < geo.size.height / 2

            ZStack(alignment: .topLeading) {
                // Even-odd fill: one path for the whole screen, one for the
                // hole, and the overlap is left uncovered.
                Canvas { context, size in
                    // Deliberately no .ignoresSafeArea() here. That expands the
                    // canvas past the geometry reader, moving its origin, so the
                    // hole was punched about sixty points above the control it
                    // was meant to be around. Instead the covering rectangle is
                    // simply drawn far outside the bounds, which darkens the
                    // whole screen while keeping one coordinate space.
                    let bleed: CGFloat = 400
                    var path = Path(CGRect(x: -bleed, y: -bleed,
                                           width: size.width + bleed * 2,
                                           height: size.height + bleed * 2))
                    if spotlight != nil {
                        path.addRoundedRect(in: hole, cornerSize: CGSize(width: 13, height: 13))
                    }
                    context.fill(path, with: .color(.black.opacity(0.66)),
                                 style: FillStyle(eoFill: true))
                }
                .allowsHitTesting(false)

                if spotlight != nil {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.9), lineWidth: 2)
                        .frame(width: hole.width, height: hole.height)
                        .offset(x: hole.minX, y: hole.minY)
                        .allowsHitTesting(false)
                }

                bubble(in: geo.size, hole: hole, below: holeInTopHalf)
            }
            .contentShape(Rectangle())
            .onTapGesture { onNext() }
        }
        .transition(.opacity)
    }

    private func bubble(in container: CGSize, hole: CGRect, below: Bool) -> some View {
        let width = min(320, container.width - 40)
        let x = min(max(20, hole.midX - width / 2), max(20, container.width - width - 20))
        let y = below ? hole.maxY + 16 : max(20, hole.minY - 176)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                ForEach(TourStep.allCases) { s in
                    Capsule()
                        .fill(s == step ? theme.accent : theme.ink.opacity(0.18))
                        .frame(width: s == step ? 14 : 5, height: 5)
                }
            }

            Text(step.title)
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(theme.ink)

            Text(step.detail)
                .font(.system(size: 13.5, design: .rounded))
                .foregroundStyle(theme.ink.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(isLast ? "Start reading" : "Next", action: onNext)
                    .buttonStyle(SoftButtonStyle(theme: theme, prominent: true))
                if !isLast {
                    Button("Skip", action: onSkip)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(theme.faint)
                }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.background)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        )
        .offset(x: x, y: y)
    }
}
