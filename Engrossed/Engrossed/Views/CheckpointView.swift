import SwiftUI

/// End of a stretch. A five-second prompt to say what you just read.
///
/// This is the one intervention here with strong support behind it: asking
/// readers to check their own understanding mid-text closed the comprehension
/// gap between ADHD and non-ADHD adults, and kept comprehension up even when
/// mind-wandering was high. It works because it makes drift *visible* — you
/// notice you have nothing to say, which is information you didn’t have before.
struct CheckpointView: View {
    let section: Section
    let text: BookText
    let settings: ReadingSettings
    let sprint: Sprint
    let onContinue: () -> Void
    let onReread: () -> Void

    @State private var showRecap = false

    private var theme: PaperTheme { settings.theme }

    /// The opening clause of each card in the stretch — a skeleton of what was
    /// covered, not a summary that would let you skip the thinking.
    private var recapLines: [String] {
        let range = section.firstChunk...section.lastChunk
        return text.chunks[range]
            .filter(\.startsParagraph)
            .prefix(6)
            .map { chunk in
                let words = chunk.text.split(separator: " ").prefix(9)
                return words.joined(separator: " ") + "\u{2026}"
            }
    }

    var body: some View {
        ZStack {
            // Fully opaque. At 0.98 the card underneath showed through the
            // text, which looked like a rendering fault.
            theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                QuietLabel(text: "END OF A STRETCH", theme: theme)

                Text("In one line, what was that about?")
                    .font(.system(size: 26, weight: .medium, design: .serif))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Don’t write it down. Just say it to yourself. If nothing comes, that’s the useful part. It means the last few minutes didn’t land, and it’s cheaper to re-read now than to find out in twenty pages.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(theme.ink.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480, alignment: .leading)

                if showRecap {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(recapLines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(theme.accent.opacity(0.4))
                                    .frame(width: 4, height: 4).padding(.top, 7)
                                Text(line)
                                    .font(.system(size: 13, design: .serif))
                                    .foregroundStyle(theme.ink.opacity(0.6))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .transition(.opacity)
                }

                // Side by side when there is room, stacked when there is not.
                // In a narrow window the labels were wrapping to three lines
                // inside the buttons.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { choices }
                    VStack(alignment: .leading, spacing: 10) { choices }
                }
                .padding(.top, 4)

                Text(tally)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.whisper)
                    .padding(.top, 6)
            }
            .padding(38)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    @ViewBuilder
    private var choices: some View {
        Button("Got it, keep going") { onContinue() }
            .buttonStyle(SoftButtonStyle(theme: theme, prominent: true))
            .keyboardShortcut(.return, modifiers: [])
            .fixedSize()

        Button("Read it again") { onReread() }
            .buttonStyle(SoftButtonStyle(theme: theme))
            .fixedSize()

        if !showRecap && !recapLines.isEmpty {
            Button("Remind me") {
                withAnimation(.smooth(duration: 0.25)) { showRecap = true }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(theme.faint)
            .fixedSize()
        }
    }

    private var tally: String {
        let words = section.wordCount
        let minutes = max(1, Int(Double(words) / 220))
        return "That stretch was about \(words) words \u{00B7} roughly \(minutes) minute\(minutes == 1 ? "" : "s") of reading."
    }
}

/// The sprint ran out. Stopping on purpose beats grinding to a halt.
struct BreakView: View {
    let sprint: Sprint
    let settings: ReadingSettings
    let onResume: () -> Void
    let onStop: () -> Void

    private var theme: PaperTheme { settings.theme }

    var body: some View {
        ZStack {
            // Fully opaque. At 0.98 the card underneath showed through the
            // text, which looked like a rendering fault.
            theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                QuietLabel(text: "SPRINT DONE", theme: theme)

                Text("\(Int(settings.sprintMinutes)) minutes. \(sprint.chunksThisSprint) cards, \(sprint.wordsThisSprint) words.")
                    .font(.system(size: 25, weight: .medium, design: .serif))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Stand up, look at something far away, get water. Five minutes. The next sprint goes better if this one actually ends.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(theme.ink.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440, alignment: .leading)

                HStack(spacing: 10) {
                    Button("Another sprint") { onResume() }
                        .buttonStyle(SoftButtonStyle(theme: theme, prominent: true))
                    Button("Done for now") { onStop() }
                        .buttonStyle(SoftButtonStyle(theme: theme))
                }
                .padding(.top, 6)
            }
            .padding(38)
            .frame(maxWidth: 520, alignment: .leading)
        }
    }
}
