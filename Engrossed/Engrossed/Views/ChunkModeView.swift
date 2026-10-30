import SwiftUI

/// Cards mode. One chunk on screen, a whisper of the previous one above it for
/// continuity, and a very large tap target to move on.
///
/// The empty space is not wasted — it’s the feature. A page of dense text offers
/// your eyes a hundred places to land; this offers one.
struct ChunkModeView: View {
    let text: BookText
    @Binding var index: Int
    let settings: ReadingSettings
    let narrator: Narrator
    let resumedAt: Int?
    let documentURL: URL?
    let onAdvance: () -> Void
    let onBack: () -> Void

    private var theme: PaperTheme { settings.theme }
    private var chunk: Chunk? { text.chunks.indices.contains(index) ? text.chunks[index] : nil }
    private var previous: Chunk? { index > 0 ? text.chunks[index - 1] : nil }

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                if resumedAt != nil {
                    Text("Backed up one card so you land in context")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.accent.opacity(0.8))
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }

                // A faded tail of the previous card. Just enough thread to hold.
                if let previous, resumedAt == nil, previous.isProse, chunk?.isProse == true {
                    Text(tail(of: previous.text))
                        .font(.system(size: settings.fontSize * 0.72, design: settings.font.design))
                        .foregroundStyle(theme.ink.opacity(0.22))
                        .lineLimit(2)
                        .frame(maxWidth: settings.maxTextWidth, alignment: .leading)
                        .padding(.bottom, 18)
                        .allowsHitTesting(false)
                }

                if let chunk {
                    // Fits or scrolls. A card is meant to be small, but the
                    // chunker splits on sentences, and one long sentence at a
                    // large text size can still overflow the screen. It used to
                    // be truncated with an ellipsis and the rest of it was
                    // simply unreachable, which is the one thing a reader can
                    // neither notice nor work around.
                    //
                    // Figures are left on the direct path: ViewThatFits builds
                    // both branches to measure them, and a figure card would
                    // render its bitmap twice.
                    Group {
                        if chunk.figure == nil && chunk.image == nil {
                            ViewThatFits(in: .vertical) {
                                CardContent(chunk: chunk, settings: settings,
                                            documentURL: documentURL)
                                ScrollView(.vertical) {
                                    CardContent(chunk: chunk, settings: settings,
                                                documentURL: documentURL)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .scrollBounceBehavior(.basedOnSize)
                                .scrollIndicators(.visible)
                            }
                        } else {
                            CardContent(chunk: chunk, settings: settings,
                                        documentURL: documentURL)
                        }
                    }
                    .id(chunk.id)
                    .tourAnchor(.card)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 10)),
                        removal: .opacity))
                }

                Spacer(minLength: 0)

                controls
            }
            .padding(.horizontal, 30)
            // Centred, not leading. On a 1032pt iPad a leading-aligned column
            // leaves 400pt of dead space down the right and drags the whole
            // page off balance, which is the opposite of what this app is for.
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .animation(.smooth(duration: 0.24), value: index)
        .contentShape(Rectangle())
        .onTapGesture { onAdvance() }
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.width < -50 { onAdvance() }
                    else if value.translation.width > 50 { onBack() }
                }
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { onAdvance(); return .handled }
        .onKeyPress(.rightArrow) { onAdvance(); return .handled }
        .onKeyPress(.downArrow) { onAdvance(); return .handled }
        .onKeyPress(.return) { onAdvance(); return .handled }
        .onKeyPress(.leftArrow) { onBack(); return .handled }
        .onKeyPress(.upArrow) { onBack(); return .handled }
        .onChange(of: index) { _, _ in speakIfNeeded() }
        // Read-aloud moves on by itself, so the screen must not lock under it.
        .onChange(of: narrator.isSpeaking) { _, speaking in KeepAwake.set(speaking) }
        .onDisappear { KeepAwake.set(false) }
        .onAppear {
            narrator.onFinish = {
                if settings.speechEnabled { onAdvance() }
            }
            speakIfNeeded()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Why the ElevenLabs voice stepped aside, said once and quietly, by
            // the speaker it concerns. An alert would stop the reading to say
            // something that needs no answer; this lets the reader carry on
            // with the built-in voice and read it when they glance down.
            if settings.speechEnabled, let notice = narrator.notice {
                Text(notice)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            buttons
        }
        .padding(.top, 34)
        .padding(.bottom, 12)
        .frame(maxWidth: settings.maxTextWidth, alignment: .leading)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button { onBack() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    // The glyph stays small; the place to tap does not. A thumb
                    // that missed a 13pt arrow landed on the card, which turns
                    // the page forward: the opposite of what was meant.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.faint)
            .opacity(index > 0 ? 1 : 0.25)
            .disabled(index == 0)
            .help("Back a card")
            .accessibilityLabel("Back a card")

            if settings.speechEnabled {
                Button {
                    if narrator.isSpeaking { narrator.stop() } else { speakIfNeeded(force: true) }
                } label: {
                    Image(systemName: narrator.isSpeaking ? "speaker.wave.2.fill" : "speaker")
                        .font(.system(size: 12))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(narrator.isSpeaking ? theme.accent : theme.faint)
                .accessibilityLabel(narrator.isSpeaking ? "Stop reading aloud" : "Read this card aloud")
            }

            Spacer()

            Button { onAdvance() } label: {
                HStack(spacing: 7) {
                    Text(chunk?.kind == .aside ? "Skip this" : "Next")
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(SoftButtonStyle(theme: theme, prominent: true))
        }
    }

    private func tail(of text: String) -> String {
        let words = text.split(separator: " ")
        guard words.count > 14 else { return text }
        return "\u{2026} " + words.suffix(14).joined(separator: " ")
    }

    private func speakIfNeeded(force: Bool = false) {
        // Reading a table of numbers aloud helps nobody.
        guard settings.speechEnabled || force, let chunk, chunk.isProse else {
            // Nothing is read on this card, so an ElevenLabs card still on its
            // way for the card before must not start over this one. That holds
            // when read aloud was switched off in Settings while it was on its
            // way, too. Does nothing for the built-in voice.
            narrator.dropPendingAudio()
            return
        }
        // The next card lets an ElevenLabs voice start it without a pause for
        // the network. Ignored by the built-in voice.
        narrator.speak(chunk.text, rate: settings.speechRate, next: nextSpokenCard?.text)
    }

    /// The card the voice will move on to by itself when this one ends, if
    /// any. Only that card is ever fetched ahead, because a card fetched and
    /// never heard is paid for all the same. So: not one past a table or a
    /// figure, where auto-advance stops and the reader decides; and not the
    /// first card after a checkpoint, which stops the voice and may well send
    /// the reader back to reread instead.
    private var nextSpokenCard: Chunk? {
        let next = index + 1
        guard text.chunks.indices.contains(next), text.chunks[next].isProse else { return nil }
        if settings.checkpointsEnabled,
           let section = text.section(containing: index),
           index == section.lastChunk {
            return nil
        }
        return text.chunks[next]
    }
}
