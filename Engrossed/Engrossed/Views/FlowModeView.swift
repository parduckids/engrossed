import SwiftUI

/// Flow mode. Continuous text, but only the current chunk is at full contrast —
/// everything else fades back. You keep the sense of a real page while the eye
/// still has exactly one place to be.
struct FlowModeView: View {
    let text: BookText
    /// Read-only, and moved through the callbacks, like every other mode.
    ///
    /// This used to be a `@Binding` that Flow mode wrote to directly, which
    /// quietly skipped `ReaderView.step(to:)`, the only place that saves your
    /// position. An hour of reading in Flow was lost on closing the app: the one
    /// promise this whole app is built on, broken in a third of it.
    let index: Int
    let settings: ReadingSettings
    let documentURL: URL?
    /// Tapping a specific paragraph to move there.
    let onSelect: (Int) -> Void
    /// The Next button. Goes through the same path as Cards, so section
    /// checkpoints still appear in Flow.
    let onAdvance: () -> Void
    let onBack: () -> Void
    /// The reader scrolled themselves. Saves the place without counting as a
    /// step: no haptic per paragraph swept past, no sprint credit for text the
    /// eye never landed on.
    let onScrolled: (Int) -> Void

    /// The topmost visible chunk, reported by the scroll view itself.
    @State private var topChunk: Int?

    private var theme: PaperTheme { settings.theme }

    /// Only render the neighbourhood: a 5,000-chunk book would otherwise try to
    /// lay out an entire novel.
    private var window: [Chunk] {
        let lower = max(0, index - 40)
        let upper = min(text.chunks.count, index + 60)
        return Array(text.chunks[lower..<upper])
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(window) { chunk in
                            CardContent(chunk: chunk, settings: settings, documentURL: documentURL)
                                .opacity(opacity(for: chunk.id))
                                .padding(.top, chunk.startsParagraph ? 20 : 8)
                                .padding(.horizontal, 30)
                                .id(chunk.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(chunk.id)
                                }
                                .background(alignment: .leading) {
                                    if chunk.id == index {
                                        Capsule()
                                            .fill(theme.accent.opacity(0.55))
                                            .frame(width: 3)
                                            .padding(.vertical, 2)
                                            .padding(.leading, 13)
                                    }
                                }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 60)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollPosition(id: $topChunk, anchor: .top)
                .onAppear {
                    proxy.scrollTo(index, anchor: .center)
                }
                .onChange(of: index) { _, new in
                    // Don't fight the reader's own scrolling. When the index
                    // changed *because* they scrolled, the scroll view is
                    // already where it should be, and re-centring it here would
                    // yank the page out from under them mid-drag.
                    guard new != topChunk else { return }
                    withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(new, anchor: .center) }
                }
                .onChange(of: topChunk) { _, new in
                    guard let new, new != index else { return }
                    onScrolled(new)
                }
            }

            controls
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { onAdvance(); return .handled }
        .onKeyPress(.upArrow) { onBack(); return .handled }
        .onKeyPress(.space) { onAdvance(); return .handled }
    }

    /// Flow had no visible way to move on. Scrolling worked, and tapping a
    /// paragraph worked, but nothing on screen said so, and the arrow keys it
    /// did offer do not exist on a phone. Readers reached the bottom of the
    /// window and stopped.
    private var controls: some View {
        HStack(spacing: 10) {
            Button { onBack() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.faint)
            .opacity(index > 0 ? 1 : 0.25)
            .disabled(index == 0)
            .help("Back a paragraph")

            Spacer()

            Button { onAdvance() } label: {
                HStack(spacing: 7) {
                    Text("Next")
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(SoftButtonStyle(theme: theme, prominent: true))
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func opacity(for id: Int) -> Double {
        let distance = abs(id - index)
        switch distance {
        case 0: return 1
        case 1: return 0.42
        case 2: return 0.26
        default: return 0.16
        }
    }
}
