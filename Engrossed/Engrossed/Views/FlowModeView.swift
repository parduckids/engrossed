import SwiftUI

/// Flow mode. Continuous text, but only the current chunk is at full contrast —
/// everything else fades back. You keep the sense of a real page while the eye
/// still has exactly one place to be.
///
/// The view only watches the scroll, the way the Chrome extension does. Three
/// things made it lurch under a finger before, and each is now ruled out:
/// - The place was the paragraph leaving the top edge, so the text being read
///   in the middle of the screen was faded. Now it is the paragraph crossing a
///   reading line a little above the middle.
/// - The rows drawn were a window that slid with every paragraph scrolled past,
///   so rows came and went above the screen mid-drag. Now the block of rows is
///   stable and only ever grows.
/// - Its own scrolls (Next, a tap, opening) were taken for the reader’s, and
///   moved the place they had just set. Now reports are held back while one of
///   its own scrolls is moving.
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

    /// The rows drawn. Starts as a block around the place and only grows, so
    /// nothing above the screen changes while the reader is scrolling.
    @State private var rows: Range<Int> = 0..<0
    /// The chunk this view last reported, so an index change it caused itself
    /// is not scrolled to again.
    @State private var reported: Int?
    /// Until then, the page is moving because this view moved it.
    @State private var quietUntil = Date.distantPast

    private var theme: PaperTheme { settings.theme }

    /// Where the place is read from, as a fraction of the visible height. A
    /// little above the middle, which is where the eye rests when reading down
    /// a page.
    private static let line: CGFloat = 0.45
    private static let lineAnchor = UnitPoint(x: 0.5, y: line)
    /// Rows drawn on each side of the place at first. A web article fits whole;
    /// a book gets about an hour of reading either way, then grows.
    private static let block = 600
    private static let space = "flow"

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { outer in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(text.chunks[rows]) { chunk in
                                row(chunk)
                                    .background {
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: RowFrames.self,
                                                value: [chunk.id: geo.frame(in: .named(Self.space))])
                                        }
                                    }
                            }
                        }
                        // Room above the first paragraph and below the last, so
                        // both can reach the reading line and be read, and a
                        // book read to the end in Flow is actually finished.
                        .padding(.vertical, outer.size.height * Self.line)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .coordinateSpace(name: Self.space)
                    .onPreferenceChange(RowFrames.self) { frames in
                        readingLineMoved(frames, height: outer.size.height, proxy: proxy)
                    }
                    .onAppear {
                        rows = Self.block(around: index, count: text.chunks.count)
                        move(to: index, proxy: proxy, animated: false)
                    }
                    .onChange(of: index) { _, new in
                        // An index this view reported came from the reader’s
                        // own scrolling, and the page is already there.
                        guard new != reported else { return }
                        move(to: new, proxy: proxy, animated: true)
                    }
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

    private func row(_ chunk: Chunk) -> some View {
        CardContent(chunk: chunk, settings: settings, documentURL: documentURL)
            .opacity(opacity(for: chunk.id))
            .padding(.top, chunk.startsParagraph ? 20 : 8)
            .padding(.horizontal, 30)
            .id(chunk.id)
            .contentShape(Rectangle())
            .onTapGesture { onSelect(chunk.id) }
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

    /// Brings a chunk to the reading line: Next, Back, a tap, the contents,
    /// a checkpoint, or opening the book. The reports the scroll produces on
    /// the way are ignored, so they cannot move the place it is going to.
    private func move(to target: Int, proxy: ScrollViewProxy, animated: Bool) {
        if !rows.contains(target) {
            rows = Self.block(around: target, count: text.chunks.count)
        }
        reported = target
        quietUntil = .now.addingTimeInterval(animated ? 0.6 : 0.35)
        if animated {
            withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(target, anchor: Self.lineAnchor) }
        } else {
            // On appear the rows are not laid out yet; the second pass lands
            // on the measured position rather than an estimate.
            proxy.scrollTo(target, anchor: Self.lineAnchor)
            DispatchQueue.main.async { proxy.scrollTo(target, anchor: Self.lineAnchor) }
        }
    }

    /// The reader scrolled: the paragraph crossing the reading line is now the
    /// place, the same rule as the extension’s chunkAtCentre.
    private func readingLineMoved(_ frames: [Int: CGRect], height: CGFloat, proxy: ScrollViewProxy) {
        guard height > 0, !frames.isEmpty, Date.now >= quietUntil else { return }
        let line = height * Self.line
        let current = frames.first(where: { $0.value.minY <= line && $0.value.maxY > line })?.key
            ?? frames.min(by: { abs($0.value.midY - line) < abs($1.value.midY - line) })?.key
        guard let current, current != reported else { return }
        reported = current
        onScrolled(current)
        grow(near: current, proxy: proxy)
    }

    /// Adds rows before the reader runs out of them. Growing downwards adds
    /// nothing above the screen, so the page does not move. Growing upwards
    /// does, so the paragraph being read is put straight back on the line.
    private func grow(near current: Int, proxy: ScrollViewProxy) {
        let count = text.chunks.count
        if current > rows.upperBound - 60, rows.upperBound < count {
            rows = rows.lowerBound..<min(count, rows.upperBound + Self.block)
        }
        if current < rows.lowerBound + 60, rows.lowerBound > 0 {
            rows = max(0, rows.lowerBound - Self.block)..<rows.upperBound
            quietUntil = .now.addingTimeInterval(0.35)
            DispatchQueue.main.async { proxy.scrollTo(current, anchor: Self.lineAnchor) }
        }
    }

    private static func block(around index: Int, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let clamped = min(max(0, index), count - 1)
        return max(0, clamped - block)..<min(count, clamped + block)
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
                    // The glyph stays small; the place to tap does not.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.faint)
            .opacity(index > 0 ? 1 : 0.25)
            .disabled(index == 0)
            .help("Back a paragraph")
            .accessibilityLabel("Back a paragraph")

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

/// Each visible row’s frame in the scroll view’s own space. A lazy stack only
/// builds the rows on screen, so this stays small however long the book is.
private struct RowFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
