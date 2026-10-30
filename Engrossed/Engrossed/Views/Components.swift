import SwiftUI

/// A progress bar that shows position inside the *current stretch*, not the
/// whole book. A bar that barely moves after twenty minutes is discouraging;
/// one that fills every few minutes is not.
struct StretchProgress: View {
    let fraction: Double
    let theme: PaperTheme
    var height: Double = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.ink.opacity(0.1))
                Capsule()
                    .fill(theme.accent.opacity(0.75))
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.35), value: fraction)
    }
}

/// Dots for the cards in this stretch. Small, countable, and visibly finite.
struct StretchDots: View {
    let total: Int
    let current: Int
    let theme: PaperTheme

    private var shown: Int { min(total, 16) }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(shown, 1), id: \.self) { i in
                let mapped = total <= 16 ? i : Int(Double(i) / Double(shown) * Double(total))
                Circle()
                    .fill(mapped <= current ? theme.accent.opacity(0.8) : theme.ink.opacity(0.16))
                    .frame(width: mapped == current ? 7 : 5,
                           height: mapped == current ? 7 : 5)
            }
        }
        .animation(.smooth(duration: 0.25), value: current)
    }
}

struct QuietLabel: View {
    let text: String
    let theme: PaperTheme

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(theme.faint)
    }
}

struct SoftButtonStyle: ButtonStyle {
    let theme: PaperTheme
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(prominent ? theme.accentFill : theme.ink.opacity(0.07))
            )
            .foregroundStyle(prominent ? theme.onAccent : theme.ink.opacity(0.85))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

/// Renders chunk text with the reader’s typography, optionally fixation-bolded.
struct ReadingText: View {
    let text: String
    let settings: ReadingSettings
    var opacity: Double = 1

    var body: some View {
        Group {
            if settings.fixationBolding {
                Text(TextStyling.fixationBolded(text, font: settings.bodyFont))
            } else {
                Text(text).font(settings.bodyFont)
            }
        }
        .lineSpacing(settings.resolvedLineSpacing)
        .foregroundStyle(settings.theme.ink.opacity(opacity))
        .multilineTextAlignment(.leading)
        .frame(maxWidth: settings.maxTextWidth, alignment: .leading)
        // Without this a Text silently truncates to whatever height it is
        // offered and reports that it fits, so the card below could never tell
        // that it needed to scroll.
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

/// Renders a card according to what it actually is. A table shown as prose is
/// unreadable; a table shown *as a table*, labelled and skippable, costs the
/// reader nothing.
struct CardContent: View {
    let chunk: Chunk
    let settings: ReadingSettings
    var documentURL: URL? = nil

    private var theme: PaperTheme { settings.theme }

    var body: some View {
        switch chunk.kind {
        case .prose:
            ReadingText(text: chunk.text, settings: settings)

        case .heading:
            VStack(alignment: .leading, spacing: 10) {
                QuietLabel(text: "NEW SECTION", theme: theme)
                Text(chunk.text)
                    .font(.system(size: settings.fontSize * 1.25, weight: .semibold,
                                  design: settings.font.design))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: settings.maxTextWidth, alignment: .leading)

        case .figure:
            FigureCard(chunk: chunk, settings: settings, documentURL: documentURL)

        case .aside:
            VStack(alignment: .leading, spacing: 12) {
                QuietLabel(text: "NOT PROSE \u{00B7} SKIM OR SKIP", theme: theme)
                Text(chunk.text)
                    .font(.system(size: settings.fontSize * 0.68, design: .monospaced))
                    .foregroundStyle(theme.ink.opacity(0.8))
                    .lineSpacing(settings.fontSize * 0.18)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: settings.maxTextWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.ink.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(theme.ink.opacity(0.1), lineWidth: 1))
            )
        }
    }
}

/// Holds off the screen lock while words or a voice move on by themselves.
/// Without it, Pace and read-aloud stopped every time Auto-Lock dimmed the
/// phone, often after thirty seconds. Only ever on while something is playing,
/// so ordinary reading still locks as normal.
enum KeepAwake {
    @MainActor static func set(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}
