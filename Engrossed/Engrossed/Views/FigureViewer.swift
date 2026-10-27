import SwiftUI

/// A full-screen figure, zoomable and pannable.
///
/// The important part is not the gesture handling but the re-rendering: the card
/// shows a bitmap rendered at roughly reading width, and magnifying that just
/// magnifies its pixels. Figures in a PDF are almost always vector drawings, so
/// asking PDFKit to draw the same region again at a higher pixel width genuinely
/// recovers detail — axis labels and footnotes that were an unreadable smudge
/// become text. Zooming therefore re-renders rather than scaling up.
struct FigureViewer: View {
    let chunk: Chunk
    let settings: ReadingSettings
    let documentURL: URL?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var image: CGImage?
    @State private var zoom: CGFloat = 1
    @State private var zoomAnchor: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAnchor: CGSize = .zero
    @State private var renderedWidth: Int = 0
    @State private var isRendering = false
    @State private var refineTask: Task<Void, Never>?

    private var theme: PaperTheme { settings.theme }

    /// Beyond about six times you are looking at the limits of the source
    /// artwork, not at the renderer.
    private let maxZoom: CGFloat = 6
    private let minZoom: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                theme.background.ignoresSafeArea()

                figure(in: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(magnify(in: geo.size))
                    .simultaneousGesture(pan(in: geo.size))
                    .onTapGesture(count: 2) { toggleZoom(in: geo.size) }

                controls
            }
            .task(id: chunk.id) { await loadInitial(containerWidth: geo.size.width) }
            .onChange(of: zoom) { _, _ in scheduleRefine(containerWidth: geo.size.width) }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
        .onDisappear { refineTask?.cancel() }
    }

    // MARK: - The image

    @ViewBuilder
    private func figure(in container: CGSize) -> some View {
        if let image {
            Image(decorative: image, scale: displayScale)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(zoom)
                .offset(offset)
                .animation(.smooth(duration: 0.18), value: zoom)
                .animation(.smooth(duration: 0.18), value: offset)
        } else {
            ProgressView().controlSize(.small).tint(theme.faint)
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(theme.ink.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.faint)
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                if isRendering {
                    ProgressView().controlSize(.small).tint(theme.whisper)
                }
            }
            Spacer()

            HStack(spacing: 6) {
                stepButton("minus") { setZoom(zoom / 1.6) }
                Text("\(Int(zoom * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.faint)
                    .frame(width: 52)
                stepButton("plus") { setZoom(zoom * 1.6) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Capsule().fill(theme.ink.opacity(0.06)))
        }
        .padding(18)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.faint)
    }

    // MARK: - Gestures

    private func magnify(in container: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = clampZoom(zoomAnchor * value.magnification)
                offset = clampOffset(offset, in: container)
            }
            .onEnded { _ in
                zoomAnchor = zoom
                offsetAnchor = offset
            }
    }

    private func pan(in container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clampOffset(CGSize(width: offsetAnchor.width + value.translation.width,
                                            height: offsetAnchor.height + value.translation.height),
                                     in: container)
            }
            .onEnded { _ in offsetAnchor = offset }
    }

    private func toggleZoom(in container: CGSize) {
        setZoom(zoom > 1.2 ? 1 : 2.6, in: container)
    }

    private func setZoom(_ value: CGFloat, in container: CGSize = .zero) {
        zoom = clampZoom(value)
        zoomAnchor = zoom
        if zoom <= 1.001 {
            offset = .zero
        } else if container != .zero {
            offset = clampOffset(offset, in: container)
        }
        offsetAnchor = offset
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(maxZoom, max(minZoom, value))
    }

    /// Keeps the picture from being dragged off the screen: once an axis is
    /// smaller than the container there is nothing to pan on that axis, and
    /// otherwise travel stops at the edge of the image.
    private func clampOffset(_ proposed: CGSize, in container: CGSize) -> CGSize {
        guard let image, container.width > 0, container.height > 0 else { return .zero }

        let imageSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        let fit = min(container.width / imageSize.width, container.height / imageSize.height)
        let shown = CGSize(width: imageSize.width * fit * zoom,
                           height: imageSize.height * fit * zoom)

        let slackX = max(0, (shown.width - container.width) / 2)
        let slackY = max(0, (shown.height - container.height) / 2)
        return CGSize(width: min(slackX, max(-slackX, proposed.width)),
                      height: min(slackY, max(-slackY, proposed.height)))
    }

    // MARK: - Rendering

    private func loadInitial(containerWidth: CGFloat) async {
        guard image == nil else { return }
        await render(containerWidth: containerWidth, zoom: 1)
    }

    /// Re-renders after the zoom settles. A pinch emits a continuous stream of
    /// values; kicking off a render for each one would queue dozens of redundant
    /// full-resolution draws.
    private func scheduleRefine(containerWidth: CGFloat) {
        refineTask?.cancel()
        refineTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            await render(containerWidth: containerWidth, zoom: zoom)
        }
    }

    private func render(containerWidth: CGFloat, zoom: CGFloat) async {
        guard let documentURL, let region = chunk.figure, containerWidth > 0 else { return }

        let target = targetPixelWidth(containerWidth: containerWidth, zoom: zoom,
                                      aspect: region.aspectRatio)
        // Only ever go up: dropping back to a coarse bitmap when zooming out
        // would make the picture visibly degrade under your hands.
        guard target > renderedWidth else { return }

        isRendering = true
        let rendered = await FigureCache.shared.image(documentURL: documentURL,
                                                     page: chunk.page,
                                                     region: region,
                                                     pixelWidth: target,
                                                     detail: true)
        isRendering = false
        if let rendered {
            image = rendered
            renderedWidth = target
        }
    }

    /// Enough pixels to be sharp at this zoom, without allocating a bitmap that
    /// would evict everything else on the device.
    private func targetPixelWidth(containerWidth: CGFloat, zoom: CGFloat, aspect: Double) -> Int {
        let wanted = containerWidth * displayScale * zoom
        let hardWidthCap: CGFloat = 3200
        // Tall, narrow figures blow past a pixel budget long before they reach a
        // width cap, so bound the area too. Six megapixels is about 24MB at four
        // bytes a pixel — enough to read the small print on a dense diagram,
        // still modest enough to hold a few of them on a phone.
        let areaCap = sqrt(6_000_000 * max(aspect, 0.05))
        return Int(max(320, min(wanted, min(hardWidthCap, areaCap))))
    }
}
