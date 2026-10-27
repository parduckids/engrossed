import Foundation
import PDFKit
import SwiftUI
import Observation

/// Renders a region of a PDF page into an image, and remembers it.
///
/// Figures are drawn straight from the document rather than extracted as
/// embedded image files: a chart in a PDF is usually vector drawing commands
/// with text on top, not a picture, so re-rendering the region is the only way
/// to get back what the page actually looked like.
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
        let store = detail ? details : images
        if let cached = store.object(forKey: id as NSString) { return cached.image }
        if failed.contains(id) { return nil }

        let rendered = await Task.detached(priority: .userInitiated) {
            FigureCache.render(documentURL: documentURL, page: page,
                               region: region, pixelWidth: bucket)
        }.value

        if let rendered {
            let bytes = rendered.bytesPerRow * rendered.height
            store.setObject(Box(rendered), forKey: id as NSString, cost: bytes)
        } else {
            failed.insert(id)
        }
        return rendered
    }

    nonisolated static func render(documentURL: URL, page pageIndex: Int,
                                           region: FigureRegion, pixelWidth: Int) -> CGImage? {
        guard let document = PDFDocument(url: documentURL),
              let page = document.page(at: pageIndex) else { return nil }

        let rect = region.rect
        guard rect.width > 1, rect.height > 1,
              rect.width.isFinite, rect.height.isFinite else { return nil }

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
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
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
    private var aspect: Double { chunk.figure?.aspectRatio ?? 1.6 }
    private var canOpen: Bool { image != nil && chunk.figure != nil && documentURL != nil }

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
            .frame(maxWidth: settings.maxTextWidth)
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
            .accessibilityLabel("Figure. Open to zoom.")
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
        guard image == nil, let documentURL, let region = chunk.figure else {
            didFail = chunk.figure == nil
            return
        }
        let width = Int(settings.maxTextWidth * 2)
        let rendered = await FigureCache.shared.image(documentURL: documentURL,
                                                     page: chunk.page,
                                                     region: region,
                                                     pixelWidth: width)
        if let rendered { image = rendered } else { didFail = true }
    }
}
