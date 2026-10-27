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
        let size = settings.fontSize * 1.75

        return VStack(spacing: 0) {
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
            .foregroundStyle(theme.ink)
            .padding(.vertical, 16)
            .frame(maxWidth: 560)

            Rectangle().fill(theme.ink.opacity(0.12)).frame(height: 1)
        }
        .frame(maxWidth: 560)
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
                }
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

                Button { nextChunk() } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 13))
                }
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
        guard !words.isEmpty else { return }
        // Skip straight past anything that isn’t prose.
        if let chunk, !chunk.isProse { onAdvance(); return }
        isPlaying = true
        ticker?.cancel()
        ticker = Task { @MainActor in
            while !Task.isCancelled && isPlaying {
                guard words.indices.contains(wordIndex) else { break }
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
                    guard index != before else { isPlaying = false; break }
                    wordIndex = 0
                }
            }
        }
    }

    private func stop() {
        isPlaying = false
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
