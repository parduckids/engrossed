import SwiftUI

/// End of a part. A five-second prompt to say what you just read.
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
    /// The first check-in of this read, which explains itself. Later ones
    /// only say the short version.
    let isFirst: Bool
    /// The reader chose “Read it again” on this part and has come back to it.
    let isSecondTime: Bool
    /// When a key last reached the reader underneath. Return and Space still
    /// go there while the check-in is up, so a held key keeps arriving; the
    /// check-in only arms once they have stopped for a second.
    let lastKeyAt: Date
    let onContinue: () -> Void
    let onReread: () -> Void

    @State private var showRecap = false
    @State private var armed = false

    private var theme: PaperTheme { settings.theme }

    private var question: String {
        Recap.question(for: section, heading: Recap.heading(for: section, in: text))
    }

    private var bodyText: String {
        if isSecondTime { return Recap.againBody }
        return isFirst ? Recap.firstBody : Recap.shortBody
    }

    /// How each paragraph in the part opened: a skeleton of what was covered,
    /// not a summary that would let you skip the thinking.
    private var recapLines: [String] {
        Recap.openingLines(for: section, in: text)
    }

    var body: some View {
        ZStack {
            // Fully opaque. At 0.98 the card underneath showed through the
            // text, which looked like a rendering fault.
            theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                QuietLabel(text: "QUICK CHECK-IN", theme: theme)

                Text(question)
                    .font(.system(size: 26, weight: .medium, design: .serif))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(bodyText)
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
        .task(id: lastKeyAt) {
            armed = false
            try? await Task.sleep(for: Recap.armDelay)
            if !Task.isCancelled { armed = true }
        }
    }

    @ViewBuilder
    private var choices: some View {
        Button("Got it, keep going") { onContinue() }
            .buttonStyle(SoftButtonStyle(theme: theme, prominent: true))
            // Return turns the cards too, so it only carries on once the
            // check-in has been up long enough to be read.
            .keyboardShortcut(armed ? KeyboardShortcut(.return, modifiers: []) : nil)
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

    private var tally: String { Recap.tally(for: section) }
}

#if DEBUG
extension CheckpointView {
    /// A check-in over a made-up part, for `-debug.screen checkin`. The real
    /// one is only reached by reading to the end of a part, and the guide is
    /// shorter than one part.
    static func debugSample(settings: ReadingSettings, onDone: @escaping () -> Void) -> CheckpointView {
        let paragraphs = [
            "Most advice about reading assumes the problem is time. Find a quiet hour and the pages will follow.",
            "You notice it a page later, when nothing you just read has stayed with you.",
            "A dense page offers the eye hundreds of places to land, and only one of them is where you are.",
            "The page also hides your progress. Ten minutes of effort look exactly like none.",
        ]
        var chunks = [Chunk(id: 0, text: "Why a full page works against you", page: 0, section: 0,
                            startsParagraph: true, wordCount: 7, kind: .heading)]
        for text in paragraphs {
            chunks.append(Chunk(id: chunks.count, text: text, page: 0, section: 0,
                                startsParagraph: true, wordCount: Chunker.wordCount(text)))
        }
        let section = Section(id: 0, firstChunk: 0, lastChunk: chunks.count - 1,
                              wordCount: chunks.reduce(0) { $0 + $1.wordCount }, startPage: 0)
        return CheckpointView(section: section, text: BookText(chunks: chunks, sections: [section]),
                              settings: settings, sprint: Sprint(), isFirst: true, isSecondTime: false,
                              lastKeyAt: .now, onContinue: onDone, onReread: onDone)
    }
}
#endif

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
