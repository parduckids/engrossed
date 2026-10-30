import SwiftUI

/// Pace mode: one word at a time in a fixed spot, so your eyes stop travelling.
///
/// Two deliberate departures from the usual speed-reading app:
///
/// 1. The speed tops out at 350 wpm. Comprehension is intact at 250–350 and
///    measurably worse above it, so the slider simply doesn’t go there.
/// 2. The full passage stays on screen underneath, dimmed, with the current word
///    lit. Not being able to look back is the main thing that breaks
///    comprehension in RSVP, so looking back is always one glance away.
struct PaceModeView: View {
    let text: BookText
    @Binding var index: Int
    let settings: ReadingSettings
    let onAdvance: () -> Void
    let onBack: () -> Void
    let documentURL: URL?
    /// The break or a check-in is over the reader. Words must not keep
    /// turning underneath it.
    var covered: Bool = false

    @State private var wordIndex = 0
    @State private var isPlaying = false
    @State private var ticker: Task<Void, Never>?

    @Environment(\.scenePhase) private var scenePhase

    private var theme: PaperTheme { settings.theme }
    private var chunk: Chunk? { text.chunks.indices.contains(index) ? text.chunks[index] : nil }
    private var words: [String] { TextStyling.words(in: chunk?.text ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            if let chunk, !chunk.isProse {
                // Nothing to pace through: a heading or a table is read by
                // looking at it, not one word at a time.
                CardContent(chunk: chunk, settings: settings, documentURL: documentURL)
                    // Its own identity, or two pictures in a row share one
                    // view and the second shows the first one's image.
                    .id(chunk.id)
            } else {
                wordWindow
                    .frame(height: settings.fontSize * 3.4)

                contextStrip
                    .padding(.top, 26)
            }

            Spacer(minLength: 0)

            controls
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { rewind(); return .handled }
        .onKeyPress(.rightArrow) { nextChunk(); return .handled }
        .onChange(of: index) { _, _ in wordIndex = 0 }
        .onChange(of: covered) { _, isCovered in if isCovered { stop() } }
        .onDisappear { stop() }
        .onChange(of: scenePhase) { _, phase in
            // Otherwise the words keep turning over in a pocket, and the reader
            // comes back to find the card has moved on without them.
            if phase != .active { stop() }
        }
    }

    // MARK: - The word

    private var wordWindow: some View {
        let word = words.indices.contains(wordIndex) ? words[wordIndex] : ""
        let pivot = TextStyling.pivotIndex(of: word)
        let head = String(word.prefix(pivot))
        let pivotChar = word.count > pivot ? String(Array(word)[pivot]) : ""
        let tail = word.count > pivot + 1 ? String(Array(word)[(pivot + 1)...]) : ""
        let base = settings.fontSize * 1.75

        return GeometryReader { geo in
        // The pivot letter stays in the middle, so the longer half of the
        // word has to fit in half the width. Long words ("neurotransmitters",
        // "attention—and") used to be cut off with an ellipsis on a phone.
        // Shrink just enough that they fit; a serif letter is under 0.6em.
        let half = (min(geo.size.width, 560) - base * 0.6) / 2
        let longest = CGFloat(max(head.count, tail.count, 1))
        let size = min(base, max(base * 0.45, half / (longest * 0.6)))

        VStack(spacing: 0) {
            // Fixation guides above and below the pivot column.
            Rectangle().fill(theme.ink.opacity(0.12)).frame(height: 1)

            HStack(spacing: 0) {
                Text(head)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(pivotChar)
                    .foregroundStyle(theme.accent)
                Text(tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: size, weight: .medium, design: settings.font.design))
            .lineLimit(1)
            .foregroundStyle(theme.ink)
            .padding(.vertical, 16)
            .frame(maxWidth: 560)

            Rectangle().fill(theme.ink.opacity(0.12)).frame(height: 1)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.accent.opacity(0.35))
                .frame(width: 1, height: 10)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.accent.opacity(0.35))
                .frame(width: 1, height: 10)
        }
    }

    /// The passage, dimmed, current word lit. This is the escape hatch that makes
    /// word-at-a-time reading safe to use.
    private var contextStrip: some View {
        let font = Font.system(size: settings.fontSize * 0.62, design: settings.font.design)
        return Text(attributedContext())
            .font(font)
            .lineSpacing(settings.fontSize * 0.2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: settings.maxTextWidth, alignment: .leading)
            .animation(nil, value: wordIndex)
    }

    private func attributedContext() -> AttributedString {
        var result = AttributedString()
        for (i, word) in words.enumerated() {
            var piece = AttributedString(word + (i == words.count - 1 ? "" : " "))
            if i == wordIndex {
                piece.foregroundColor = theme.ink
                piece.underlineStyle = .single
            } else if i < wordIndex {
                piece.foregroundColor = theme.ink.opacity(0.34)
            } else {
                piece.foregroundColor = theme.ink.opacity(0.18)
            }
            result.append(piece)
        }
        return result
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Button { rewind() } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 15))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Back ten words")
                .buttonStyle(.plain)
                .foregroundStyle(theme.faint)
                .help("Back ten words")

                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17))
                        .frame(width: 52, height: 40)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.accentFill))
                        .foregroundStyle(theme.onAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                Button { nextChunk() } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 13))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Skip to the next card")
                .buttonStyle(.plain)
                .foregroundStyle(theme.faint)
                .help("Skip to the next card")
            }

            HStack(spacing: 10) {
                Text("\(Int(settings.wordsPerMinute))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.faint)
                    .frame(width: 30, alignment: .trailing)

                Slider(value: Binding(get: { settings.wordsPerMinute },
                                      set: { settings.wordsPerMinute = $0 }),
                       in: 120...350, step: 10)
                    .frame(maxWidth: 240)

                Text("wpm")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.whisper)
            }

            Text(settings.wordsPerMinute > 320
                 ? "Near the top of the range where comprehension still holds."
                 : "Comfortable range.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.whisper)
        }
        .padding(.bottom, 14)
    }

    // MARK: - Timing

    private func togglePlay() {
        if isPlaying { stop() } else { play() }
    }

    private func play() {
        // Play on a picture or a table means "I've looked, carry on": move past
        // it, then keep playing. This used to sit behind a check for empty
        // words, which a picture always has, so Play did nothing at all.
        if let chunk, !chunk.isProse, chunk.kind != .heading {
            let before = index
            onAdvance()
            guard index != before else { return }
            wordIndex = 0
        }
        isPlaying = true
        KeepAwake.set(true)
        ticker?.cancel()
        ticker = Task { @MainActor in
            while !Task.isCancelled && isPlaying {
                if let chunk, !chunk.isProse {
                    // A heading is glanced at and passed. A picture or a table
                    // is something to look at, so playback pauses there and
                    // the button says so, rather than stopping silently with
                    // the pause icon still showing.
                    guard chunk.kind == .heading else { stop(); break }
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    guard !Task.isCancelled, isPlaying else { break }
                    let before = index
                    onAdvance()
                    guard index != before else { stop(); break }
                    wordIndex = 0
                    continue
                }
                guard words.indices.contains(wordIndex) else { stop(); break }
                let base = 60.0 / max(60, settings.wordsPerMinute)
                let dwell = base * TextStyling.dwellMultiplier(for: words[wordIndex])
                try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
                guard !Task.isCancelled, isPlaying else { break }

                if wordIndex + 1 < words.count {
                    wordIndex += 1
                } else {
                    // End of a card: pause a beat, then move on. The pause is
                    // where a sentence actually gets integrated.
                    try? await Task.sleep(nanoseconds: 380_000_000)
                    guard !Task.isCancelled, isPlaying else { break }

                    let before = index
                    onAdvance()
                    // Advancing does not always move: the last card of the book
                    // stays put, and so does a card whose checkpoint is now
                    // waiting for an answer. Without this the same words cycle
                    // forever, or race silently behind the checkpoint.
                    guard index != before else { stop(); break }
                    wordIndex = 0
                }
            }
        }
    }

    private func stop() {
        isPlaying = false
        KeepAwake.set(false)
        ticker?.cancel()
        ticker = nil
    }

    private func rewind() {
        if wordIndex > 0 {
            wordIndex = max(0, wordIndex - 10)
        } else {
            onBack()
        }
    }

    private func nextChunk() {
        stop()
        onAdvance()
        wordIndex = 0
    }
}
