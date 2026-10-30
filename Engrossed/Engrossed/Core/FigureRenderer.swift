import Foundation
import PDFKit
import ImageIO
import SwiftUI
import Observation

/// Renders a region of a PDF page, or decodes a picture stored in an EPUB,
/// into an image, and remembers it.
///
/// PDF figures are drawn straight from the document rather than extracted as
/// embedded image files: a chart in a PDF is usually vector drawing commands
/// with text on top, not a picture, so re-rendering the region is the only way
/// to get back what the page actually looked like. An EPUB picture is the
/// opposite case: it is a file in the book, and decoding it is all there is.
@MainActor
final class FigureCache {
    static let shared = FigureCache()

    /// Bounded, and cheap to evict. Zooming a figure produces a bitmap of tens
    /// of megabytes; an unbounded dictionary of those is a straightforward way
    /// to get the app killed for memory after browsing a few diagrams. NSCache
    /// also drops its contents on a memory warning, which a dictionary will not.
    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private let images: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 24
        return cache
    }()

    /// Zoomed renders live apart from the card-sized ones.
    ///
    /// A single detail bitmap is twenty-odd megabytes. Charged into the same
    /// budget it would evict most of the small card images in one go, so closing
    /// the viewer and scrolling back would re-render every figure you had
    /// already passed. Two of them is all a reader can be looking at.
    private let details: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 2
        return cache
    }()

    private var failed: Set<String> = []

    /// Loads already under way, so that two views asking for the same picture
    /// at once share one decode. Cards mode measures a card by building it
    /// twice, and both copies of a figure card would otherwise decode the same
    /// picture side by side.
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    private func key(_ url: URL, _ page: Int, _ region: FigureRegion, _ width: Int) -> String {
        // Int(_: Double) traps above Int.max rather than saturating, and a
        // figure region can carry an absurd size straight from a page whose
        // media box is nonsense. Truncating toward zero keeps parity with the
        // Int() this replaces, so existing cache keys are unchanged.
        func stamp(_ value: Double) -> String {
            value.isFinite ? String(format: "%.0f", value.rounded(.towardZero)) : "x"
        }
        return "\(url.lastPathComponent)|\(page)|\(stamp(region.x)),\(stamp(region.y)),\(stamp(region.width)),\(stamp(region.height))|\(width)"
    }

    /// - Parameter detail: true for the zoom viewer, which needs a much larger
    ///   bitmap and should not compete with the card images for room.
    func image(documentURL: URL, page: Int, region: FigureRegion,
               pixelWidth: Int, detail: Bool = false) async -> CGImage? {
        // Bucket the width so a resizing window doesn’t re-render continuously.
        let bucket = max(240, (pixelWidth / 160) * 160)
        let id = key(documentURL, page, region, bucket)
        return await load(id, detail: detail) {
            FigureCache.render(documentURL: documentURL, page: page,
                               region: region, pixelWidth: bucket)
        }
    }

    /// A picture stored in an EPUB, decoded to about `pixelWidth` across.
    ///
    /// - Parameter archiveURL: the EPUB itself. The picture is read out of it
    ///   each time rather than kept anywhere else, since the book already is
    ///   the copy.
    func image(archiveURL: URL, picture: EmbeddedImage,
               pixelWidth: Int, detail: Bool = false) async -> CGImage? {
        // Rounded up rather than down, and never past the picture's own width.
        // A PDF region can be drawn at any size, but a bitmap has a fixed
        // amount of detail, and a bucket below its width would throw some away.
        var bucket = max(240, ((pixelWidth + 159) / 160) * 160)
        if picture.pixelWidth > 0 { bucket = min(bucket, picture.pixelWidth) }

        // The decoder is limited by the longer side, so a tall picture needs a
        // limit taller than it is wide. A card has no use for one far taller
        // than the screen, though, and a bitmap that size would crowd every
        // other figure out of the cache.
        let aspect = picture.aspectRatio ?? 1
        let longest = aspect >= 1 ? Double(bucket) : Double(bucket) / aspect
        let ceiling = detail ? 8000 : min(4096, bucket * 2)
        let maxPixelSize = max(1, Int(min(longest, Double(ceiling)).rounded()))

        let id = "\(archiveURL.lastPathComponent)|\(picture.path)|\(bucket)"
        return await load(id, detail: detail) {
            FigureCache.decode(archiveURL: archiveURL, path: picture.path, maxPixelSize: maxPixelSize)
        }
    }

    private func load(_ id: String, detail: Bool,
                      make: @escaping @Sendable () -> CGImage?) async -> CGImage? {
        let store = detail ? details : images
        if let cached = store.object(forKey: id as NSString) { return cached.image }
        if failed.contains(id) { return nil }
        let flight = (detail ? "detail|" : "card|") + id
        if let running = inFlight[flight] { return await running.value }

        let task = Task.detached(priority: .userInitiated) { make() }
        inFlight[flight] = task
        let made = await task.value
        inFlight[flight] = nil

        if let made {
            let bytes = made.bytesPerRow * made.height
            store.setObject(Box(made), forKey: id as NSString, cost: bytes)
        } else {
            failed.insert(id)
        }
        return made
    }

    nonisolated static func render(documentURL: URL, page pageIndex: Int,
                                           region: FigureRegion, pixelWidth: Int) -> CGImage? {
        guard let document = PDFDocument(url: documentURL),
              let page = document.page(at: pageIndex) else { return nil }

        // The region is in page space, where characterBounds reported it. But
        // draw(with:to:) does not draw page space as it stands: it first
        // applies the page's display transform, which moves the media box's
        // corner to the origin and turns the page by its rotation. Translating
        // by the region's own origin was therefore right only for an upright
        // page whose media box starts at 0,0; anywhere else it showed some
        // other part of the page. Passing the region through the same
        // transform puts the rectangle and the drawing in one space, and since
        // that space is the page as it is displayed, the figure comes out
        // upright on a rotated page as well.
        let rect = region.rect.applying(page.transform(for: .mediaBox)).standardized
        guard !rect.isNull, rect.width > 1, rect.height > 1,
              rect.width.isFinite, rect.height.isFinite,
              rect.minX.isFinite, rect.minY.isFinite else { return nil }

        // A tall, narrow figure reaches an absurd height long before its width
        // looks large. Shrink to fit rather than refusing to draw it — failing
        // here would leave the reader looking at a permanently blank figure.
        //
        // Every clamp has to happen in floating point, before the conversion:
        // Int(_: Double) traps on anything past Int.max instead of saturating,
        // so clamping the Int afterwards never runs.
        let maxDimension = 8000
        var scale = CGFloat(pixelWidth) / rect.width
        var width = pixelWidth
        var height = max(1, Int(min(CGFloat(maxDimension), (rect.height * scale).rounded())))
        if height >= maxDimension {
            height = maxDimension
            scale = CGFloat(height) / rect.height
            width = max(1, Int(min(CGFloat(maxDimension), (rect.width * scale).rounded())))
        }

        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        // A page only refers weakly to its document, and nothing reads the
        // document after the guard above, so an optimised build is free to
        // release it before the page is drawn. PDFKit then logs that drawing
        // a page without its document is unsupported and may draw nothing.
        withExtendedLifetime(document) {
            page.draw(with: .mediaBox, to: context)
        }
        return context.makeImage()
    }

    nonisolated static func decode(archiveURL: URL, path: String, maxPixelSize: Int) -> CGImage? {
        guard let archive = ZipArchive(url: archiveURL),
              let name = archive.name(matching: path),
              let data = archive.contents(of: name),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // Decoding straight to the size needed is far cheaper than decoding a
        // whole photograph and shrinking it afterwards, and it never enlarges:
        // a small picture comes back at its own size. The transform option
        // applies the EXIF orientation, so a photo shot sideways is upright.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return onWhite(decoded)
    }

    /// The picture laid on a white page.
    ///
    /// Line drawings in books are routinely black ink on a transparent
    /// background, drawn for a white page. On the dark theme's background the
    /// ink would vanish. PDF figures are rendered on white for the same
    /// reason, so this keeps the two kinds alike.
    nonisolated private static func onWhite(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage() ?? image
    }
}

/// A figure card. Shows the picture at the width the reader is using, with the
/// same "you may skip this" framing as other non-prose.
struct FigureCard: View {
    let chunk: Chunk
    let settings: ReadingSettings
    let documentURL: URL?

    @State private var image: CGImage?
    @State private var didFail = false
    @State private var showViewer = false

    private var theme: PaperTheme { settings.theme }
    private var hasSource: Bool { chunk.figure != nil || chunk.image != nil }
    private var canOpen: Bool { image != nil && hasSource && documentURL != nil }

    /// The shape the card holds. Once the picture is here it is the picture's
    /// own: a figure from a rotated page is turned upright, so the shape of
    /// its region on the page is the wrong way round.
    private var aspect: Double {
        if let image, image.width > 0, image.height > 0 {
            return Double(image.width) / Double(image.height)
        }
        return chunk.image?.aspectRatio ?? chunk.figure?.aspectRatio ?? 1.6
    }

    /// An EPUB picture is never stretched past one point per pixel. A small
    /// engraving blown up to the full reading width is a blur, and the book
    /// meant it to sit small on the page.
    private var pictureWidth: CGFloat {
        guard let picture = chunk.image, picture.pixelWidth > 0 else { return settings.maxTextWidth }
        return min(settings.maxTextWidth, CGFloat(picture.pixelWidth))
    }

    private var caption: String { chunk.image?.caption ?? "" }

    private var accessibilityText: String {
        guard var description = [chunk.image?.alt ?? "", caption].first(where: { !$0.isEmpty })
        else { return "Figure. Open to zoom." }
        while let last = description.last, ".:;,".contains(last) { description.removeLast() }
        return "Figure: \(description). Open to zoom."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuietLabel(text: "FIGURE", theme: theme)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.ink.opacity(0.04))

                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if didFail {
                    Text("This figure couldn’t be drawn.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.faint)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: pictureWidth)
            .overlay(alignment: .bottomTrailing) {
                // A quiet affordance. Dense diagrams are unreadable at reading
                // width, and nothing else on the card says it can be opened.
                if canOpen {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.ink.opacity(0.5))
                        .padding(6)
                        .background(Circle().fill(theme.background.opacity(0.8)))
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
            // High priority so it beats the card's own tap-to-advance (Cards
            // mode) and tap-to-select (Flow mode). Nested tap gestures otherwise
            // resolve by SwiftUI's own rules, and a tap on a figure skipping the
            // card instead of opening it would be baffling.
            .highPriorityGesture(TapGesture().onEnded {
                if canOpen { showViewer = true }
            })
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityText)

            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: settings.fontSize * 0.72, design: settings.font.design))
                    .foregroundStyle(theme.ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: settings.maxTextWidth, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: settings.maxTextWidth, alignment: .leading)
        .task(id: chunk.id) {
            await load()
            #if DEBUG
            // Lets a script open the zoom viewer, which is otherwise only
            // reachable by tapping. Debug builds only.
            if UserDefaults.standard.string(forKey: "debug.screen") == "figure", canOpen {
                showViewer = true
            }
            #endif
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showViewer) {
            FigureViewer(chunk: chunk, settings: settings, documentURL: documentURL)
        }
        #else
        .sheet(isPresented: $showViewer) {
            FigureViewer(chunk: chunk, settings: settings, documentURL: documentURL)
        }
        #endif
    }

    private func load() async {
        guard image == nil, let documentURL, hasSource else {
            didFail = !hasSource
            return
        }
        let width = Int(settings.maxTextWidth * 2)
        let rendered: CGImage?
        if let picture = chunk.image {
            rendered = await FigureCache.shared.image(archiveURL: documentURL,
                                                     picture: picture,
                                                     pixelWidth: width)
        } else if let region = chunk.figure {
            rendered = await FigureCache.shared.image(documentURL: documentURL,
                                                     page: chunk.page,
                                                     region: region,
                                                     pixelWidth: width)
        } else {
            rendered = nil
        }
        if let rendered { image = rendered } else { didFail = true }
    }
}
