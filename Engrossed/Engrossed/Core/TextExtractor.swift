import Foundation
import PDFKit
import CoreGraphics

/// Pulls prose out of a PDF.
///
/// The naive approach — `page.string`, split on newlines — throws away the two
/// things that actually mark a paragraph in a typeset book: the indent on its
/// first line and the extra space above it. Without those, paragraphs merge, and
/// a reading card ends up containing the tail of one thought and the head of the
/// next. That is precisely the cognitive load this app exists to remove, so the
/// extractor works from layout geometry instead and falls back to plain text
/// only when a PDF won’t give it any.
enum TextExtractor {

    /// One unit of a page, in reading order. Figures have to sit in this stream
    /// rather than be collected separately — a diagram is only useful next to the
    /// sentence that refers to it.
    enum Block {
        case paragraph(String)
        /// A chapter or section title. Set apart from the prose it introduces so
        /// the contents list has something real to point at, and so the reader
        /// can show it as a title rather than welding it onto the first sentence.
        case heading(String)
        /// Region of the page, in the page’s own coordinate space.
        case figure(CGRect)
    }

    struct PageText {
        let pageIndex: Int
        let blocks: [Block]

        init(pageIndex: Int, blocks: [Block]) {
            self.pageIndex = pageIndex
            self.blocks = blocks
        }

        init(pageIndex: Int, paragraphs: [String]) {
            self.init(pageIndex: pageIndex, blocks: paragraphs.map { .paragraph($0) })
        }

        var paragraphs: [String] {
            blocks.compactMap {
                switch $0 {
                case .paragraph(let text), .heading(let text): return text
                case .figure: return nil
                }
            }
        }
    }

    private struct Line {
        var rect: CGRect
        var text: String
        /// The most common glyph height on the line: its x-height, in practice,
        /// since most letters have neither an ascender nor a descender.
        ///
        /// This is the one measurement on a line that tracks its font size and
        /// nothing else, which is what makes it possible to tell a heading from
        /// body text. The two obvious alternatives both fail:
        ///
        /// The line's own box is the union of its glyphs, so it only reaches
        /// full height when something on it has a descender. "Properties of
        /// Water" measures 25% taller than "Water Is Cohesive" in the same font,
        /// purely because of the "p" — a bigger difference than the one between
        /// a heading and body text.
        ///
        /// The tallest glyph fails too, because brackets and parentheses are
        /// drawn taller than any letter. It reads an ordinary sentence with a
        /// citation in it as a heading.
        ///
        /// The mode is immune to both. Ascenders, descenders and punctuation are
        /// all minorities on a line of text; the plain letters are not.
        ///
        /// It is still only ever a hint, because the mode is x-height only while
        /// lowercase letters are the majority: on a line of capitals, digits or
        /// code it rises to cap height in the very same font. `heights` is kept
        /// so the heading test can check that directly.
        var glyphHeight: CGFloat
        /// Every glyph box on the line, for tests the mode cannot answer.
        var heights: [CGFloat]
        /// The runs of glyphs on the line, left to right, wherever they are
        /// separated by far more than a word space. Empty for a line that is a
        /// single run, which is nearly every line.
        ///
        /// A caption printed beside the text, the way a browser prints a
        /// floated picture, sits at the same height as a line of the body and
        /// is grouped into it. Keeping the runs apart is what lets the figure
        /// finder take the caption back out, rather than leaving it spliced into
        /// the middle of a sentence.
        var pieces: [Piece] = []

        /// The line's runs, or the whole line when it is one run.
        var parts: [CGRect] { pieces.isEmpty ? [rect] : pieces.map(\.rect) }
    }

    private struct Piece {
        var rect: CGRect
        var heights: [CGFloat]
    }

    private struct Metrics {
        var bodyLeft: CGFloat
        var bodyRight: CGFloat
        var lineGap: CGFloat
        /// The height of an ordinary line of body text. Anything appreciably
        /// taller is set in a bigger font, which is what a heading is.
        var bodyHeight: CGFloat = 0

        var bodyWidth: CGFloat { max(1, bodyRight - bodyLeft) }
    }

    // MARK: - Entry point

    static func extract(from document: PDFDocument,
                        progress: ((Double) -> Void)? = nil) -> [PageText] {
        let count = document.pageCount
        guard count > 0 else { return [] }

        var pageLines: [[Line]] = []
        pageLines.reserveCapacity(count)

        for i in 0..<count {
            guard let page = document.page(at: i) else {
                pageLines.append([])
                continue
            }
            pageLines.append(lines(of: page))
            progress?(Double(i + 1) / Double(count) * 0.8)
        }

        let documentWide = measure(pageLines)
        let furniture = furnitureLines(pageLines, in: document)

        var bodies: [[Line]] = []
        var furnitures: [[Line]] = []
        bodies.reserveCapacity(count)
        furnitures.reserveCapacity(count)
        for (i, lines) in pageLines.enumerated() {
            let page = document.page(at: i)
            // Page numbers are only page numbers when they sit at the edge of
            // the page. Applied everywhere, this would eat a line of body text
            // that happens to read "42", or a Python `None`.
            //
            // "At the edge" is measured two ways, because a fixed fraction of
            // the page height is not enough on its own: books set their folios
            // at wildly different distances from the trim, and one 228-page
            // book in the corpus put 164 page numbers just inside the band,
            // every one of which became a reading card that said "11". So a
            // bare number is also furniture when it is simply the topmost or
            // bottommost line on its page, whatever the margin happens to be.
            let box = page?.bounds(for: .mediaBox) ?? .zero
            let band = box.height * 0.12
            let outermost = Set([lines.max(by: { $0.rect.midY < $1.rect.midY })?.rect.midY,
                                 lines.min(by: { $0.rect.midY < $1.rect.midY })?.rect.midY]
                                    .compactMap { $0 })
            let isFurniture = { (line: Line) in
                if furniture.contains(signature(of: line)) { return true }
                guard box.height > 0, isPageNumber(line.text) else { return false }
                let inMargin = line.rect.midY > box.maxY - band || line.rect.midY < box.minY + band
                return inMargin || outermost.contains(line.rect.midY)
            }
            bodies.append(lines.filter { !isFurniture($0) })
            furnitures.append(lines.filter(isFurniture))
        }

        // A page with no text of its own is shown as a picture: a plate, a
        // chapter-opener illustration, a slide that is only an image. But when
        // no page in the document has any text, it is a scan, and a book of
        // several hundred picture cards would hide the one thing worth saying,
        // which is that it needs OCR before it can be read. Leaving those pages
        // empty keeps the library's "scanned PDF" message.
        let hasText = bodies.contains { !$0.isEmpty }

        var result: [PageText] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let page = document.page(at: i)
            let body = bodies[i]
            let furnitureOnPage = furnitures[i]
            // Margins are measured per page. Books are printed with mirrored
            // margins — the inner edge swaps sides on facing pages — so a single
            // document-wide right margin is wrong for half the book, and every
            // full line on those pages looks short enough to end a paragraph.
            let metrics = pageMetrics(for: body, fallback: documentWide)
            var area = CGRect.null
            if let page {
                // A plate with nothing printed around it often bleeds to the
                // edge, and the usual margin would cut its top and bottom off.
                area = body.isEmpty && furnitureOnPage.isEmpty
                    ? page.bounds(for: .mediaBox)
                    : bodyArea(of: page, furniture: furnitureOnPage)
            }
            result.append(PageText(pageIndex: i,
                                   blocks: blocks(from: body, furniture: furnitureOnPage,
                                                  metrics: metrics, documentWide: documentWide,
                                                  page: page, contentArea: area,
                                                  picturesAlone: hasText)))
            progress?(0.8 + Double(i + 1) / Double(count) * 0.2)
        }
        return result
    }

    // MARK: - Lines

    /// Groups characters into visual lines by their vertical position, then asks
    /// PDFKit for the text inside each line’s box. Going through selection rather
    /// than character indices matters: in justified text the character index and
    /// the `string` index drift apart, and reading text by index returns it
    /// scrambled.
    private static func lines(of page: PDFPage) -> [Line] {
        let charCount = page.numberOfCharacters
        guard charCount > 0 else { return fallbackLines(of: page) }

        struct Row {
            var rect: CGRect
            var heights: [CGFloat]
            /// Kept only while the page is being read, to find the wide gaps
            /// that separate a line's pieces. `heights` is parallel to it.
            var glyphs: [CGRect]

            mutating func absorb(_ other: Row) {
                rect = rect.union(other.rect)
                heights.append(contentsOf: other.heights)
                glyphs.append(contentsOf: other.glyphs)
            }
        }

        var rows: [Row] = []
        rows.reserveCapacity(64)

        for i in 0..<charCount {
            let bounds = page.characterBounds(at: i)
            guard bounds.height > 0.5, bounds.width.isFinite, bounds.origin.y.isFinite else { continue }
            let glyph = Row(rect: bounds, heights: [bounds.height], glyphs: [bounds])
            if let last = rows.last, sharesLine(last.rect, bounds) {
                rows[rows.count - 1].absorb(glyph)
            } else {
                rows.append(glyph)
            }
        }

        // PDFKit can hand back one visual line as several runs, especially in
        // justified text. Overlapping runs are the same line; leaving them apart
        // would read as an indent and invent a paragraph break mid-sentence.
        var merged: [Row] = []
        for row in rows {
            if let last = merged.last, sharesLine(last.rect, row.rect) {
                merged[merged.count - 1].absorb(row)
            } else {
                merged.append(row)
            }
        }
        rows = merged

        let result: [Line] = rows.compactMap { row in
            guard let text = selectedText(in: row.rect, of: page) else { return nil }
            return Line(rect: row.rect, text: text,
                        glyphHeight: modalHeight(row.heights), heights: row.heights,
                        pieces: pieces(of: row.glyphs))
        }

        return result.isEmpty ? fallbackLines(of: page) : result
    }

    /// The text PDFKit selects inside a box on the page.
    ///
    /// A slight outset stops the selection from clipping ascenders and the
    /// first glyph of the line. The right edge is given a whole character of
    /// room: a mark that ends a line, an ideographic full stop in particular,
    /// sits right on the boundary and is otherwise left out, so the sentence
    /// loses the thing that ends it. `reach` caps that room when something
    /// that is not part of this text starts just to the right of it.
    private static func selectedText(in rect: CGRect, of page: PDFPage,
                                     reach: CGFloat? = nil) -> String? {
        var probe = rect.insetBy(dx: -1.5, dy: -1.5)
        probe.size.width += max(0, min(rect.height, reach ?? rect.height))
        guard let raw = page.selection(for: probe)?.string else { return nil }
        let text = collapseWhitespace(raw)
        return text.isEmpty ? nil : text
    }

    /// Splits a line's glyphs wherever the gap between them is far wider than
    /// any word space, or returns nothing when the line is one run.
    ///
    /// The bar is about two and a half x-heights, which is wider than the
    /// loosest justified word space and narrower than the gutter between a
    /// column of text and a picture set beside it. A split costs nothing on its
    /// own: the line is still read as one line, and the pieces only matter
    /// once a picture has been found next to them.
    private static func pieces(of glyphs: [CGRect]) -> [Piece] {
        guard glyphs.count > 1 else { return [] }
        let limit = max(modalHeight(glyphs.map(\.height)) * 2.5, 11)
        // A box far wider than it is tall is not a letter. PDFKit hands back
        // the space it puts between two runs of text as one that spans the
        // whole gap, and the last glyph of a justified line can carry the
        // line's slack, either of which would bridge the very gap being looked
        // for.
        let ordered = glyphs.filter { $0.width <= max($0.height * 2, 12) }
            .sorted { $0.minX < $1.minX }
        guard ordered.count > 1 else { return [] }

        var result: [Piece] = []
        var current = Piece(rect: ordered[0], heights: [ordered[0].height])
        for glyph in ordered.dropFirst() {
            if glyph.minX - current.rect.maxX > limit {
                result.append(current)
                current = Piece(rect: glyph, heights: [glyph.height])
            } else {
                current.rect = current.rect.union(glyph)
                current.heights.append(glyph.height)
            }
        }
        result.append(current)
        return result.count > 1 ? result : []
    }

    /// Two boxes belong to the same line when their vertical extents overlap for
    /// most of the shorter one’s height. Comparing centres instead breaks on
    /// fragments with no ascenders or descenders.
    private static func sharesLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard overlap > 0 else { return false }
        if overlap >= min(a.height, b.height) * 0.5 { return true }

        // Punctuation can have a tiny ink box sitting low on the line: an
        // ideographic full stop is a dot in the corner of its square, and it
        // covers so little of the line's height that the test above rejects it.
        // It then becomes a line of its own, is discarded as a one-character
        // stray, and the sentence silently loses the mark that ends it.
        let taller = a.height >= b.height ? a : b
        let shorter = a.height >= b.height ? b : a
        return shorter.minY >= taller.minY - 1 && shorter.maxY <= taller.maxY + 1
    }

    /// For PDFs that report no character geometry. No indent information, so
    /// paragraph detection falls back to short-line heuristics alone.
    private static func fallbackLines(of page: PDFPage) -> [Line] {
        guard let raw = page.string else { return [] }
        let split = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Synthesise geometry: width proportional to character count, stacked
        // downward, so the same paragraph rules still apply.
        let widest = max(1, split.map(\.count).max() ?? 1)
        return split.enumerated().map { index, text in
            Line(rect: CGRect(x: 0,
                              y: CGFloat(-index) * 14,
                              width: CGFloat(text.count) / CGFloat(widest) * 450,
                              height: 12),
                 text: text,
                 // No geometry to measure, so every line counts as body text
                 // and the heading test never fires. Better than guessing.
                 glyphHeight: 12,
                 heights: [])
        }
    }

    // MARK: - Page metrics

    private static func measure(_ pageLines: [[Line]]) -> Metrics {
        let all = pageLines.flatMap { $0 }
        guard !all.isEmpty else { return Metrics(bodyLeft: 0, bodyRight: 1, lineGap: 14) }

        let lefts = all.map(\.rect.minX).sorted()
        let rights = all.map(\.rect.maxX).sorted()

        // Percentiles rather than extremes, so one stray pull-quote or a wide
        // figure caption doesn’t redefine the margins.
        let bodyLeft = lefts[Int(Double(lefts.count) * 0.12)]
        let bodyRight = rights[Int(Double(rights.count) * 0.88)]

        var gaps: [CGFloat] = []
        for lines in pageLines where lines.count > 1 {
            for i in 1..<lines.count {
                let gap = abs(lines[i - 1].rect.midY - lines[i].rect.midY)
                if gap > 0.5 && gap < 200 { gaps.append(gap) }
            }
        }
        // The most common gap, not the median.
        //
        // Lines inside a paragraph are set on a fixed leading, so that gap
        // repeats almost exactly and is by far the most frequent value.
        // Paragraph breaks, headings and figures are all varied, so they spread
        // out and never form a peak. A median works on ordinary prose but drifts
        // upward in a document of short paragraphs, where paragraph breaks are
        // nearly as common as line breaks, until a heading stops clearing the
        // threshold and gets glued to the text beneath it.
        let lineGap = mostCommonGap(gaps) ?? 14

        // Body text vastly outnumbers headings, so the peak of the distribution
        // is the body's own size however many titles a book has.
        let bodyHeight = modalHeight(all.map(\.glyphHeight).filter { $0 > 0.5 })

        return Metrics(bodyLeft: bodyLeft, bodyRight: bodyRight,
                       lineGap: lineGap, bodyHeight: bodyHeight)
    }

    /// Per-page margins, falling back to the document’s when a page has too few
    /// lines to measure reliably (a chapter opener, a figure page).
    private static func pageMetrics(for lines: [Line], fallback: Metrics) -> Metrics {
        guard lines.count >= 5 else { return fallback }
        let lefts = lines.map(\.rect.minX).sorted()
        let rights = lines.map(\.rect.maxX).sorted()
        return Metrics(bodyLeft: lefts[Int(Double(lefts.count) * 0.12)],
                       bodyRight: rights[Int(Double(rights.count) * 0.88)],
                       lineGap: fallback.lineGap,
                       bodyHeight: fallback.bodyHeight)
    }

    /// The peak of a line's glyph heights, to the nearest quarter point.
    ///
    /// Ties fall to the smaller height, which keeps the heading test cautious:
    /// a line only counts as a heading when its letters are unambiguously
    /// larger than the body's.
    private static func modalHeight(_ heights: [CGFloat]) -> CGFloat {
        guard !heights.isEmpty else { return 0 }
        var counts: [Int: Int] = [:]
        for height in heights where height > 0.5 {
            counts[Int((height * 4).rounded()), default: 0] += 1
        }
        guard let peak = counts.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) else {
            return 0
        }
        return CGFloat(peak.key) / 4
    }

    /// The peak of the gap distribution, to the nearest half point.
    private static func mostCommonGap(_ gaps: [CGFloat]) -> CGFloat? {
        guard !gaps.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for gap in gaps {
            counts[Int((gap * 2).rounded()), default: 0] += 1
        }
        guard let peak = counts.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) else {
            return nil
        }
        return CGFloat(peak.key) / 2
    }

    // MARK: - Headers and footers

    /// A line is furniture if it sits in the top or bottom margin band and the
    /// same text shows up there on most pages. Both halves matter: position
    /// alone would delete the first line of every chapter, and repetition alone
    /// would delete a sentence a book happens to use twice.
    private static func furnitureLines(_ pageLines: [[Line]], in document: PDFDocument) -> Set<String> {
        let count = pageLines.count
        guard count >= 4 else { return [] }

        var frequency: [String: Int] = [:]
        for (i, lines) in pageLines.enumerated() {
            guard let page = document.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let topBand = bounds.maxY - bounds.height * 0.09
            let bottomBand = bounds.minY + bounds.height * 0.09

            var seen = Set<String>()
            for line in lines where line.text.count <= 90 {
                guard line.rect.midY >= topBand || line.rect.midY <= bottomBand else { continue }
                seen.insert(signature(of: line))
            }
            for key in seen { frequency[key, default: 0] += 1 }
        }

        // Books change the running head per chapter, so it never reaches half the
        // pages. A handful of repeats inside the margin band is already enough
        // evidence — body text does not repeat itself up there.
        let threshold = max(3, min(count / 2, 6))
        return Set(frequency.filter { $0.value >= threshold }.keys)
    }

    /// Page numbers differ on every page, so collapse digits before counting:
    /// "Chapter 3 · 14" and "Chapter 3 · 15" become the same signature.
    private static func signature(of line: Line) -> String {
        String(line.text.map { $0.isNumber ? "#" : $0 }).lowercased()
    }

    /// A line that is nothing but a page number.
    ///
    /// Front matter is numbered in roman numerals, so "vii" on its own is a
    /// page number, not a chapter title. Without this it survives as a heading
    /// and the reader gets a card that says, in full, "vii".
    private static func isPageNumber(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard !stripped.isEmpty else { return false }
        if stripped.count <= 4, stripped.allSatisfy(\.isNumber) { return true }
        return isRomanNumeral(stripped)
    }

    private static func isRomanNumeral(_ text: String) -> Bool { romanValue(text) != nil }

    /// The value of a roman numeral, or nil if the string is not a well-formed
    /// one. Used here to recognise a page number, and by ContentsBuilder to read
    /// the numbering of books that count in roman rather than arabic.
    static func romanValue(_ text: String) -> Int? {
        let lower = text.lowercased()
        guard !lower.isEmpty, lower.count <= 7 else { return nil }

        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50,
                                        "c": 100, "d": 500, "m": 1000]
        var total = 0
        var highest = 0
        for character in lower.reversed() {
            guard let value = values[character] else { return nil }
            if value < highest { total -= value } else { total += value; highest = value }
        }
        guard total > 0, total < 4000 else { return nil }
        // Round-trip, so malformed strings like "iiii" or "vx" are rejected.
        guard romanNumeral(total) == lower else { return nil }
        return total
    }

    private static func romanNumeral(_ number: Int) -> String {
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
                                      (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
                                      (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var remaining = number
        var result = ""
        for (value, symbol) in table {
            while remaining >= value { result += symbol; remaining -= value }
        }
        return result
    }

    // MARK: - Paragraphs

    /// - Parameter picturesAlone: whether a page with no text of its own may
    ///   still be shown as a picture. False for a document with no text at
    ///   all, which is a scan.
    private static func blocks(from lines: [Line], furniture: [Line], metrics: Metrics,
                               documentWide: Metrics, page: PDFPage?, contentArea: CGRect,
                               picturesAlone: Bool) -> [Block] {
        var lines = lines
        var figures: [Figure] = []
        // Lines synthesised from plain text have no real geometry, so there is
        // nothing to measure a picture against.
        let measured = !lines.contains { $0.heights.isEmpty }
        if let page, !contentArea.isNull, measured, picturesAlone || !lines.isEmpty {
            figures = findFigures(on: page, lines: &lines, furniture: furniture,
                                  metrics: metrics, documentWide: documentWide,
                                  contentArea: contentArea)
        }
        guard !lines.isEmpty else { return figures.map { .figure($0.rect) } }

        var blocks: [Block] = []
        // Where each block starts on the page: the top of its first line, or
        // nil for a figure. A picture set beside the text has no gap of its own
        // in the flow, and this is how it finds the paragraph break to sit at.
        var tops: [CGFloat?] = []
        var current = ""
        var currentIsHeading = false
        var currentTop: CGFloat = 0
        // The left edge of the paragraph being built. Indents are judged against
        // this rather than the page margin, so an abstract or a block quote —
        // indented on every line — isn’t read as one paragraph per line.
        var blockLeft = CGFloat.greatestFiniteMagnitude
        var placed = Array(repeating: false, count: figures.count)

        func flush() {
            let trimmed = strippingFootnoteMarkers(current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 1 {
                blocks.append(currentIsHeading ? .heading(trimmed) : .paragraph(trimmed))
                tops.append(currentTop)
            }
            current = ""
            currentIsHeading = false
            blockLeft = .greatestFiniteMagnitude
        }

        func place(_ chosen: [Int]) {
            for k in chosen.sorted(by: { figures[$0].rect.maxY > figures[$1].rect.maxY }) {
                blocks.append(.figure(figures[k].rect))
                tops.append(nil)
                placed[k] = true
            }
        }

        // A figure sitting in the gap between two lines goes in at that gap.
        // It has to overlap them horizontally as well: on a page set in two
        // columns, a picture in the right-hand one lies level with a gap in the
        // left-hand one too, and that is no place to break a paragraph.
        func waiting(between above: Line, and below: Line) -> [Int] {
            figures.indices.filter { k in
                let rect = figures[k].rect
                guard !placed[k], !figures[k].isFloat,
                      rect.midY < above.rect.midY, rect.midY > below.rect.midY else { return false }
                return rect.minX < max(above.rect.maxX, below.rect.maxX)
                    && rect.maxX > min(above.rect.minX, below.rect.minX)
            }
        }

        // A title is set in a larger font than the text it introduces, and that
        // is often the only thing separating the two: books routinely set a
        // heading tight above its first paragraph, with no more space than an
        // ordinary line break. Going on spacing alone welds the title onto the
        // first sentence, which loses the chapter list and starts every chapter
        // mid-thought. Height is measured from the glyph boxes we already have.
        //
        // Three guards, because a tall line is not always a heading:
        //   - it must stop short of the right margin (a drop cap makes the first
        //     line of a chapter tall, but that line still runs the full measure);
        //   - it must have more than ordinary leading above it (a superscript or
        //     an inline fraction makes a line mid-paragraph tall);
        //   - it must be short enough to be a title at all.
        //
        // The threshold is low because the two populations barely overlap. A
        // full line of body text spans its font's whole ascender-to-descender
        // box, so it lands on the modal height almost exactly; only a larger
        // font clears it.
        func isHeadingLine(at i: Int) -> Bool {
            let line = lines[i]
            guard metrics.bodyHeight > 0.5,
                  line.glyphHeight > metrics.bodyHeight * 1.10,
                  metrics.bodyRight - line.rect.maxX > metrics.bodyWidth * 0.06
            else { return false }

            if i > 0 {
                let gap = abs(lines[i - 1].rect.midY - line.rect.midY)
                guard gap > metrics.lineGap * 1.15 else { return false }
            }

            // A line set in a larger font has NO body-sized letters left on it.
            // A line that merely *contains* something tall — a displayed
            // formula, a line of code, a citation, a run of capitals — keeps
            // plenty of them, and it was those tall glyphs that lifted its modal
            // height in the first place. This is the test that separates the two,
            // and it is the one that matters: without it the detector reads a
            // third of a maths book's display algebra as chapter titles, and
            // cuts the sentence introducing each one in half.
            //
            // Punctuation is excluded before the ratio is taken, because its ink
            // box is tiny at every font size and would otherwise count as
            // body-sized on a heading.
            let counted = line.heights.filter { $0 >= metrics.bodyHeight * 0.5 }
            if !counted.isEmpty {
                let bodySized = counted.filter { $0 <= metrics.bodyHeight * 1.10 }.count
                if Double(bodySized) / Double(counted.count) > 0.15 { return false }
            }

            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2, text.count <= 120,
                  text.contains(where: { $0.isLetter }) else { return false }

            // A title is words. Anything this sparse is a stripped equation, a
            // table row or a data line — the same measure the chunker already
            // uses to recognise non-prose.
            guard Chunker.letterDensity(text) >= 0.62 else { return false }

            // A title is capitalised. A line starting lowercase is the middle of
            // a sentence, which is how a page-opening continuation slips in:
            // the leading test is skipped for the first line of a page.
            return !(text.first(where: \.isLetter)?.isLowercase ?? false)
        }

        // A figure can sit above the first line.
        place(figures.indices.filter { k in
            !figures[k].isFloat && figures[k].rect.midY > lines[0].rect.maxY
        })

        for (i, line) in lines.enumerated() {
            let heading = isHeadingLine(at: i)
            if i > 0 {
                let between = waiting(between: lines[i - 1], and: line)
                if !between.isEmpty {
                    flush()
                    place(between)
                } else if heading != currentIsHeading
                            || startsNewParagraph(previous: lines[i - 1],
                                                  current: line,
                                                  blockLeft: blockLeft,
                                                  metrics: metrics) {
                    // Crossing into or out of a heading always ends the block.
                    // Two headings in a row are told apart by the ordinary
                    // spacing rules, so a title that wraps onto a second line
                    // stays whole while a section title following a chapter
                    // title becomes its own entry.
                    flush()
                }
            }
            if current.isEmpty {
                currentIsHeading = heading
                currentTop = line.rect.maxY
            }
            append(line.text, to: &current)
            blockLeft = min(blockLeft, line.rect.minX)
        }
        flush()

        // A figure can sit below the last line.
        if let last = lines.last {
            place(figures.indices.filter { k in
                !placed[k] && !figures[k].isFloat && figures[k].rect.midY < last.rect.minY
            })
        }

        // Everything else, a picture set beside the text above all, goes in at
        // the first paragraph that starts level with its top or below it, so it
        // sits next to the text it was printed next to without ever breaking a
        // sentence in two. Taken from the top down, so two pictures that land
        // at the same break keep the order they have on the page.
        //
        // Never ahead of the page's first paragraph, nor behind an unfinished
        // last one: those are how a sentence carries over from one page to the
        // next, and the chunker can only join the two halves when nothing
        // stands between them.
        let rest = figures.indices.filter { !placed[$0] }
            .sorted { figures[$0].rect.maxY > figures[$1].rect.maxY }
        for k in rest {
            let reach = figures[k].rect.maxY + metrics.lineGap * 0.5
            let first = tops.firstIndex { $0 != nil } ?? 0
            var at = tops.indices.first { i in
                i > first && (tops[i].map { $0 <= reach } ?? false)
            } ?? blocks.count
            if at == blocks.count, let last = blocks.indices.last, last > first,
               case .paragraph(let text) = blocks[last], !endsSentence(text) {
                at = last
            }
            blocks.insert(.figure(figures[k].rect), at: at)
            tops.insert(nil, at: at)
        }
        return blocks
    }

    private static func overlapFraction(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? area / smaller : 0
    }

    // MARK: - Figures

    /// The part of a page that holds body content.
    ///
    /// Measured from the running heads and page numbers actually found rather
    /// than from a fixed margin: books place their furniture at very different
    /// distances from the edge, and a fixed band leaves the running head sitting
    /// inside the first figure of the chapter.
    private static func bodyArea(of page: PDFPage, furniture: [Line]) -> CGRect {
        let box = page.bounds(for: .mediaBox)
        let middle = box.midY
        var top = box.maxY
        var bottom = box.minY

        for line in furniture {
            // Only what sits out towards the edges. A lone number anywhere on
            // the page has the same shape as a page number and is set aside
            // with them, and a tick on a chart's axis taken as the bottom of
            // the body would cut the chart, and everything under it, off.
            let fromEdge = min(line.rect.midY - box.minY, box.maxY - line.rect.midY)
            guard fromEdge < box.height * 0.2 else { continue }
            if line.rect.midY > middle {
                top = min(top, line.rect.minY - 3)
            } else {
                bottom = max(bottom, line.rect.maxY + 3)
            }
        }

        // Nothing found, or something implausible: fall back to a modest margin.
        guard top - bottom > box.height * 0.5 else {
            return box.insetBy(dx: 0, dy: box.height * 0.07)
        }
        return CGRect(x: box.minX, y: bottom, width: box.width, height: top - bottom)
    }

    /// A picture found on a page, in the page’s own coordinate space.
    private struct Figure {
        var rect: CGRect
        /// Set beside the text rather than between its lines, the way a picture
        /// floated to one side of a column is. It has no gap of its own in the
        /// flow, so it goes in at the nearest paragraph break instead.
        var isFloat: Bool
    }

    /// What a line of text is, as far as finding pictures goes.
    private enum Role {
        /// Short and unfinished: a tick on an axis, a legend, a place name on a
        /// map. Text like this inside a drawing, or right against it, is part
        /// of the drawing.
        case label
        /// Anything that reads as sentences. A picture does not contain prose,
        /// so prose over ink means a tinted box or a page background.
        case prose
        /// Set larger than the body. Never taken into a picture, so a chapter
        /// title printed over an illustration still reaches the contents.
        case title
    }

    private static func role(of line: Line, metrics: Metrics) -> Role {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if metrics.bodyHeight > 0.5, line.glyphHeight > metrics.bodyHeight * 1.10,
           text.contains(where: \.isLetter), Chunker.letterDensity(text) >= 0.62 {
            return .title
        }
        if endsSentence(text) || Chunker.wordCount(text) > 8 { return .prose }
        return .label
    }

    /// Finds the pictures on a page, and takes out of `lines` the text that
    /// belongs to them: the labels inside a chart, the ticks along its axes,
    /// the caption of a picture printed beside the text.
    ///
    /// The page is drawn once, small, with every line of text painted out, so
    /// what remains is ink that is not text. That is gathered into blobs, and a
    /// blob that is big enough and solid enough is a picture wherever it sits:
    /// between paragraphs, beside a column, or alone on the page.
    ///
    /// Looking only in the vertical gaps between one line and the next, as this
    /// used to, missed three things. A chart with labels in it is cut into
    /// slivers by its own text, none of them tall enough to count. A picture
    /// beside the text leaves no gap at all. And a page that is only a picture
    /// has no lines to look between.
    private static func findFigures(on page: PDFPage, lines: inout [Line], furniture: [Line],
                                    metrics: Metrics, documentWide: Metrics,
                                    contentArea: CGRect) -> [Figure] {
        let alone = lines.isEmpty

        // Every run of text on the page, and the line it belongs to.
        struct Part {
            let line: Int
            let rect: CGRect
        }
        var parts: [Part] = []
        var firstPart: [Int] = []
        for (i, line) in lines.enumerated() {
            firstPart.append(parts.count)
            for rect in line.parts { parts.append(Part(line: i, rect: rect)) }
        }
        let roles = lines.map { role(of: $0, metrics: metrics) }

        // Where to look. With text on the page, across the text block and a
        // little either side, so a thumb tab or a scanner's shadow in the
        // margin is never taken for a picture. Without, the whole content area.
        var area = contentArea
        var textWidth = contentArea.width
        if !alone {
            let left = min(parts.map(\.rect.minX).min() ?? metrics.bodyLeft,
                           metrics.bodyLeft, documentWide.bodyLeft)
            let right = max(parts.map(\.rect.maxX).max() ?? metrics.bodyRight,
                            metrics.bodyRight, documentWide.bodyRight)
            textWidth = max(1, right - left)
            area = CGRect(x: left - textWidth * 0.04, y: contentArea.minY,
                          width: textWidth * 1.08, height: contentArea.height)
                .intersection(contentArea)
        }
        let masks = parts.map(\.rect) + furniture.flatMap(\.parts)
        guard let ink = InkMap(page: page, area: area, masking: masks) else { return [] }

        let lineGap = max(metrics.lineGap, 1)
        let minimumHeight = max(lineGap * 3.2, 58)

        func covered(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let shared = a.intersection(b)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        func isInside(_ part: Part, _ rect: CGRect) -> Bool {
            covered(part.rect, rect) >= part.rect.width * part.rect.height * 0.6
        }
        // The share of a rectangle taken up by text. A drawing carries a few
        // labels; a box this full of text is text with a tint behind it.
        func textCover(_ rect: CGRect) -> CGFloat {
            let size = rect.width * rect.height
            guard size > 0 else { return 0 }
            return parts.filter { isInside($0, rect) }
                .reduce(0) { $0 + covered($1.rect, rect) } / size
        }
        func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
            max(0, b.minX - a.maxX, a.minX - b.maxX, b.minY - a.maxY, a.minY - b.maxY)
        }
        // How many runs of text sit level with a rectangle, off to one side.
        func besideCount(_ rect: CGRect, _ ids: [Int]) -> Int {
            ids.filter { k in
                let r = parts[k].rect
                let level = min(r.maxY, rect.maxY) - max(r.minY, rect.minY)
                let across = min(r.maxX, rect.maxX) - max(r.minX, rect.minX)
                return level >= r.height * 0.5 && across <= 0
            }.count
        }
        // The caption under a picture: at most four lines, each inside the
        // picture's width, close under it and under one another. A longer run
        // is the text of a column, not a caption, and is left alone.
        //
        // A caption printed beside the text shares its row with a line of the
        // body, across the gutter. A row that carries on just to the side of
        // the picture instead, as the rows of a table under it do, ends the
        // caption there.
        func caption(below rect: CGRect, among ids: [Int]) -> [Int] {
            func within(_ r: CGRect) -> Bool { r.minX >= rect.minX - 6 && r.maxX <= rect.maxX + 6 }
            let candidates = ids.filter { k in
                within(parts[k].rect) && parts[k].rect.maxY <= rect.minY + 2
            }.sorted { parts[$0].rect.maxY > parts[$1].rect.maxY }
            var run: [Int] = []
            var rows: [CGFloat] = []
            var edge = rect.minY
            for k in candidates {
                let r = parts[k].rect
                guard edge - r.maxY <= lineGap * 1.3 else { break }
                let line = parts[k].line
                let crowded = (firstPart[line]..<firstPart[line] + lines[line].parts.count).contains { j in
                    let other = parts[j].rect
                    return !within(other) && other.maxX > rect.minX - 8 && other.minX < rect.maxX + 8
                }
                guard !crowded else { break }
                run.append(k)
                if !rows.contains(where: { abs($0 - r.midY) < lineGap * 0.5 }) { rows.append(r.midY) }
                edge = min(edge, r.minY)
            }
            return rows.count <= 4 ? run : []
        }
        // Whether a label sits right against a drawing: tick labels beside an
        // axis or under it, a legend, an axis title. Numbers may hang a little
        // further off than words, since a word that far below a picture is as
        // likely to be the first line of the text.
        func adjoins(_ line: Line, _ rect: CGRect) -> Bool {
            let r = line.rect
            let across = min(r.maxX, rect.maxX) - max(r.minX, rect.minX)
            let level = min(r.maxY, rect.maxY) - max(r.minY, rect.minY)
            let vertical = max(rect.minY - r.maxY, r.minY - rect.maxY)
            let horizontal = max(rect.minX - r.maxX, r.minX - rect.maxX)
            let numeric = Chunker.letterDensity(line.text) < 0.62
            if across >= r.width * 0.5, vertical <= lineGap * (numeric ? 1.0 : 0.6) { return true }
            return level >= r.height * 0.5 && horizontal <= lineGap * (numeric ? 1.6 : 1.0)
                && r.width <= textWidth * 0.25
        }

        // Blobs that make one picture are joined: the bars of a chart drawn
        // without axes, a legend beside its plot, a row of photographs. They
        // are never joined across prose or a title, which is what stops a
        // picture beside a column from swallowing the column; nor to a closed
        // frame, which would wrap everything inside it, captions included,
        // into one picture; nor into a box that is mostly text.
        var groups: [[Int]] = []
        var rects: [CGRect] = []
        for (b, blob) in ink.blobs.enumerated() where blob.count >= 3 {
            let rect = ink.rect(of: blob)
            if !alone, !blob.hollow, textCover(rect) >= 0.18 { continue }
            groups.append([b])
            rects.append(rect)
        }
        if groups.count > 120 {
            // A page of speckle. Only the biggest blobs can be pictures anyway.
            let keep = groups.indices.sorted { ink.blobs[groups[$0][0]].count > ink.blobs[groups[$1][0]].count }
                .prefix(120)
            groups = keep.map { groups[$0] }
            rects = keep.map { rects[$0] }
        }
        func blocked(_ rect: CGRect) -> Bool {
            parts.contains { roles[$0.line] != .label && isInside($0, rect) }
        }
        func framed(_ group: [Int]) -> Bool {
            group.count == 1 && ink.blobs[group[0]].hollow && ink.blobs[group[0]].closed
        }
        var joined = true
        while joined {
            joined = false
            var a = 0
            while a < groups.count {
                var b = a + 1
                while b < groups.count {
                    let union = rects[a].union(rects[b])
                    let join = alone || (distance(rects[a], rects[b]) <= lineGap * 2
                                         && !framed(groups[a]) && !framed(groups[b])
                                         && !blocked(union) && textCover(union) < 0.18)
                    if join {
                        groups[a] += groups[b]
                        rects[a] = union
                        groups.remove(at: b)
                        rects.remove(at: b)
                        joined = true
                    } else {
                        b += 1
                    }
                }
                a += 1
            }
        }

        var taken = Set<Int>()
        var figures: [Figure] = []
        for g in groups.indices.sorted(by: { rects[$0].maxY > rects[$1].maxY }) {
            let stats = ink.stats(of: groups[g])
            let drawn = stats.rect
            // The drawing itself has to be the size a figure has always had to
            // be. Labels taken in below can make it bigger, never big enough.
            guard drawn.height >= minimumHeight * 0.55, drawn.width > 40, stats.count >= 12
            else { continue }
            let free = parts.indices.filter { !taken.contains($0) }
            let within = free.filter { isInside(parts[$0], drawn.insetBy(dx: -2, dy: -2)) }

            // Rules are no picture: an empty frame, the lines of a table.
            if stats.hollow {
                // An empty frame beside the text is a picture that never
                // printed: a web page saved before its images had loaded is
                // full of them. There is nothing to show, but its caption still
                // has to come out of the sentence it was printed beside. Its
                // outline is often so light that only two sides count as ink,
                // so rules running the full height and the full width of the
                // box are taken as enough of a frame.
                if !alone, within.isEmpty, stats.interiorInk <= 2,
                   stats.rows >= 0.9, stats.columns >= 0.9,
                   besideCount(drawn, free) >= 2 {
                    taken.formUnion(caption(below: drawn, among: free))
                }
                continue
            }
            // Nor is ink that reaches across only a sliver of its own box, which
            // is what a few stray marks a long way apart look like.
            guard stats.rows >= 0.25, stats.columns >= 0.25 else { continue }
            // Nor is ink with prose over it.
            let prose = within.filter { roles[parts[$0].line] == .prose }
            guard prose.count < 3, textCover(drawn) < 0.18 else { continue }

            var rect = drawn
            var claimed = Set(within.filter { roles[parts[$0].line] != .title })
            for k in claimed { rect = rect.union(parts[k].rect) }

            // Labels just outside the drawing are part of it. A few rounds, so
            // an axis title under a row of tick labels comes along too; past
            // the first, only something as short as an axis title, so a stack
            // of short lines under a picture is not reeled in one at a time.
            for round in 0..<3 {
                var grew = false
                for i in lines.indices where roles[i] == .label {
                    let ids = firstPart[i]..<firstPart[i] + lines[i].parts.count
                    guard ids.allSatisfy({ !taken.contains($0) && !claimed.contains($0) }),
                          round == 0 || lines[i].rect.width <= drawn.width * 0.4,
                          adjoins(lines[i], rect) else { continue }
                    claimed.formUnion(ids)
                    rect = rect.union(lines[i].rect)
                    grew = true
                }
                if !grew { break }
            }

            let isFloat = !alone && besideCount(rect, free.filter { !claimed.contains($0) }) >= 2
            if isFloat {
                // Beside the text a picture has to be a real one. A drop cap or
                // an icon by a note is ink beside text too.
                guard drawn.height >= minimumHeight * 0.8,
                      drawn.width >= max(40, textWidth * 0.12) else { continue }
                let below = caption(below: rect, among: free.filter { !claimed.contains($0) })
                claimed.formUnion(below)
                for k in below { rect = rect.union(parts[k].rect) }
            }
            guard rect.height >= minimumHeight * 0.55, rect.width > 40 else { continue }

            // Text that stays text has to stay outside the picture. A line that
            // runs right through it means this was never a picture: the bullets
            // down the side of a list, say, lined up into something the size of
            // one. A title is the exception, since it is allowed to sit on top.
            let standing = free.filter { !claimed.contains($0) && roles[parts[$0].line] != .title }
            let crossed = standing.contains { k in
                let shared = parts[k].rect.intersection(rect)
                return !shared.isNull && shared.width >= 6
                    && shared.height >= parts[k].rect.height * 0.5
            }
            guard !crossed else { continue }

            // A little air around it, but never over text that stays text.
            rect = rect.insetBy(dx: -4, dy: -4).intersection(area)
            for k in standing {
                let r = parts[k].rect
                guard !rect.isNull, r.intersects(rect),
                      min(r.maxX, rect.maxX) - max(r.minX, rect.minX) > r.width * 0.3 else { continue }
                if r.midY > rect.midY {
                    rect.size.height = max(0, r.minY - 1 - rect.minY)
                } else {
                    let top = rect.maxY
                    rect.origin.y = r.maxY + 1
                    rect.size.height = max(0, top - rect.origin.y)
                }
            }
            guard !rect.isNull, rect.height >= minimumHeight * 0.5 else { continue }
            taken.formUnion(claimed)
            figures.append(Figure(rect: rect, isFloat: isFloat))
        }

        // Two finds that overlap are one picture.
        var merged: [Figure] = []
        for figure in figures {
            if let k = merged.firstIndex(where: { overlapFraction($0.rect, figure.rect) > 0.3 }) {
                merged[k].rect = merged[k].rect.union(figure.rect)
                merged[k].isFloat = merged[k].isFloat || figure.isFloat
            } else {
                merged.append(figure)
            }
        }

        // Take what the pictures claimed out of the text. A line that keeps
        // some of its pieces is read again piece by piece, so none of what was
        // taken comes back with it.
        if !taken.isEmpty {
            lines = lines.enumerated().compactMap { i, line in
                let kept = line.parts.indices.filter { !taken.contains(firstPart[i] + $0) }
                if kept.count == line.parts.count { return line }
                guard !kept.isEmpty, !line.pieces.isEmpty else { return nil }
                let pieces = kept.map { line.pieces[$0] }
                let texts: [String] = kept.compactMap { k in
                    let piece = line.pieces[k]
                    let reach = k + 1 < line.pieces.count
                        ? line.pieces[k + 1].rect.minX - piece.rect.maxX - 3 : nil
                    return selectedText(in: piece.rect, of: page, reach: reach)
                }
                guard !texts.isEmpty else { return nil }
                let heights = pieces.flatMap(\.heights)
                return Line(rect: pieces.dropFirst().reduce(pieces[0].rect) { $0.union($1.rect) },
                            text: texts.joined(separator: " "),
                            glyphHeight: modalHeight(heights), heights: heights,
                            pieces: pieces.count > 1 ? pieces : [])
            }
        }
        return merged
    }

    /// The ink on part of a page that is not text, drawn small.
    private struct InkMap {
        struct Blob {
            var minX: Int, minY: Int, maxX: Int, maxY: Int
            var count: Int
            /// Pixels that are not part of a thin straight rule. See `mass`.
            var mass: Int
            /// Inked along at least three of its four edges, as a frame is. One
            /// edge is allowed to be missing: a box that runs on to the next
            /// page loses its bottom, and a very light rule can fall just short
            /// of counting as ink on one side.
            var closed = false

            /// Made of nothing but thin straight rules: an empty frame, a row of
            /// them, the rules of a table, an axis drawn on its own.
            var hollow: Bool { InkMap.isRuled(count: count, mass: mass) }
        }

        struct Stats {
            var rect: CGRect
            var count: Int
            /// The share of the rows, and of the columns, of the bounding box
            /// that have ink in them.
            var rows: Double
            var columns: Double
            var hollow: Bool
            /// Ink of any kind across the middle of the bounding box.
            var interiorInk: Int
        }

        let area: CGRect
        let width: Int
        let height: Int
        let scale: CGFloat
        /// Row-major, with row 0 along the bottom of `area`.
        private let dark: [Bool]
        /// Ink that is solid, filling the pixels all round it, or that runs
        /// only a short way in both directions: a photograph, the bars of a
        /// chart, a plotted line crossing at an angle, a dot, the shapes of a
        /// map. The rest is rules: long thin runs, and the corners where they
        /// meet.
        private let mass: [Bool]
        /// The blob each dark pixel belongs to.
        private var owner: [Int32] = []
        private(set) var blobs: [Blob] = []

        init?(page: PDFPage, area: CGRect, masking: [CGRect]) {
            // Bounded as well as finite. Nothing rejects an absurd media box — a
            // page can declare itself 1e20 points tall and PDFKit reports it
            // back verbatim — and every size below is derived from this one.
            guard !area.isNull, area.width.isFinite, area.height.isFinite,
                  area.width > 1, area.height > 1,
                  area.width < 20_000, area.height < 20_000,
                  let pageRef = page.pageRef else { return nil }

            // The map is about three points to a pixel, which keeps grouping
            // ink cheap. The page is drawn at three times that and each block
            // of nine keeps its darkest pixel: drawn straight at the coarse
            // size, a one-point grey rule averages out to almost white, and the
            // frame of a picture vanishes.
            let fold = 3
            let scale = min(1.0 / 3.0, 700 / max(area.width, area.height))
            let width = max(1, Int((area.width * scale).rounded(.up)))
            let height = max(1, Int((area.height * scale).rounded(.up)))
            let fineWidth = width * fold
            let fineHeight = height * fold
            guard let context = CGContext(data: nil, width: fineWidth, height: fineHeight,
                                          bitsPerComponent: 8, bytesPerRow: fineWidth,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }

            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: fineWidth, height: fineHeight))
            context.scaleBy(x: scale * CGFloat(fold), y: scale * CGFloat(fold))
            context.translateBy(x: -area.minX, y: -area.minY)
            // Drawn in page space, the space character bounds are measured in.
            // `PDFPage.draw(with:to:)` turns the page by its /Rotate and moves
            // the media box to the origin, so on a rotated page, or one whose
            // media box does not start at zero, the ink it found was somewhere
            // else entirely from the text it was being compared with.
            context.saveGState()
            context.drawPDFPage(pageRef)
            context.restoreGState()

            // Paint the text out, a little generously: glyph boxes do not always
            // cover a glyph's whole extent, and a link's underline sits just
            // below the line.
            context.setFillColor(gray: 1, alpha: 1)
            for rect in masking where rect.width.isFinite && rect.height.isFinite {
                context.fill(rect.insetBy(dx: -1.5, dy: -max(1.5, rect.height * 0.3)))
            }

            guard let data = context.data else { return nil }
            let pixels = data.bindMemory(to: UInt8.self, capacity: fineWidth * fineHeight)
            var dark = [Bool](repeating: false, count: width * height)
            for row in 0..<fineHeight {
                // A bitmap context stores its first row at the top, while page
                // coordinates count upward from the bottom.
                let y = height - 1 - row / fold
                let start = row * fineWidth
                for x in 0..<fineWidth where pixels[start + x] < 235 {
                    dark[y * width + x / fold] = true
                }
            }

            self.area = area
            self.width = width
            self.height = height
            self.scale = scale
            self.dark = dark
            self.mass = InkMap.mass(of: dark, width: width, height: height)
            label(reach: max(1, Int((9 * scale).rounded())))
        }

        /// A group of blobs is no picture when it is all rules, give or take a
        /// few corners and specks.
        static func isRuled(count: Int, mass: Int) -> Bool {
            mass <= max(6, count / 12)
        }

        private static func mass(of dark: [Bool], width: Int, height: Int) -> [Bool] {
            // The length of the run of ink through each pixel, across and down.
            var across = [Int32](repeating: 0, count: width * height)
            var down = [Int32](repeating: 0, count: width * height)
            for y in 0..<height {
                var x = 0
                while x < width {
                    guard dark[y * width + x] else { x += 1; continue }
                    var end = x
                    while end + 1 < width && dark[y * width + end + 1] { end += 1 }
                    for k in x...end { across[y * width + k] = Int32(end - x + 1) }
                    x = end + 1
                }
            }
            for x in 0..<width {
                var y = 0
                while y < height {
                    guard dark[y * width + x] else { y += 1; continue }
                    var end = y
                    while end + 1 < height && dark[(end + 1) * width + x] { end += 1 }
                    for k in y...end { down[k * width + x] = Int32(end - y + 1) }
                    y = end + 1
                }
            }
            var mass = [Bool](repeating: false, count: width * height)
            for y in 0..<height {
                for x in 0..<width where dark[y * width + x] {
                    let i = y * width + x
                    if across[i] <= 5 && down[i] <= 5 {
                        mass[i] = true
                        continue
                    }
                    guard x > 0, y > 0, x < width - 1, y < height - 1 else { continue }
                    var solid = true
                    for dy in -1...1 where solid {
                        for dx in -1...1 where !dark[(y + dy) * width + x + dx] { solid = false }
                    }
                    mass[i] = solid
                }
            }
            return mass
        }

        func rect(of blob: Blob) -> CGRect {
            rect(blob.minX, blob.minY, blob.maxX, blob.maxY)
        }

        private func rect(_ minX: Int, _ minY: Int, _ maxX: Int, _ maxY: Int) -> CGRect {
            CGRect(x: area.minX + CGFloat(minX) / scale,
                   y: area.minY + CGFloat(minY) / scale,
                   width: CGFloat(maxX - minX + 1) / scale,
                   height: CGFloat(maxY - minY + 1) / scale)
        }

        /// Gathers the ink into blobs.
        ///
        /// Solid ink reaches across a gap of about nine points to other solid
        /// ink, which keeps the bars of a chart together, and a photograph with
        /// the strip of shadow beside it. A rule joins only what it touches.
        /// Otherwise the frame around an infobox would gather up every picture
        /// inside it, captions and all, into one.
        private mutating func label(reach: Int) {
            var owner = [Int32](repeating: -1, count: width * height)
            var queue: [Int] = []
            for start in dark.indices where dark[start] && owner[start] < 0 {
                let id = Int32(blobs.count)
                var blob = Blob(minX: width, minY: height, maxX: -1, maxY: -1, count: 0, mass: 0)
                owner[start] = id
                queue.removeAll(keepingCapacity: true)
                queue.append(start)
                var head = 0
                while head < queue.count {
                    let p = queue[head]
                    head += 1
                    let x = p % width
                    let y = p / width
                    blob.minX = min(blob.minX, x)
                    blob.maxX = max(blob.maxX, x)
                    blob.minY = min(blob.minY, y)
                    blob.maxY = max(blob.maxY, y)
                    blob.count += 1
                    let solid = mass[p]
                    if solid { blob.mass += 1 }
                    let r = solid ? reach : 1
                    for ny in max(0, y - r)...min(height - 1, y + r) {
                        let rowStart = ny * width
                        for nx in max(0, x - r)...min(width - 1, x + r) {
                            let q = rowStart + nx
                            guard dark[q], owner[q] < 0 else { continue }
                            // Beyond touching distance, only solid to solid.
                            if abs(nx - x) > 1 || abs(ny - y) > 1, !mass[q] { continue }
                            owner[q] = id
                            queue.append(q)
                        }
                    }
                }
                blobs.append(blob)
            }
            self.owner = owner

            for b in blobs.indices {
                let blob = blobs[b]
                guard blob.maxX - blob.minX >= 4, blob.maxY - blob.minY >= 4 else { continue }
                let id = Int32(b)
                func own(_ x: Int, _ y: Int) -> Bool { owner[y * width + x] == id }
                // Each edge, give or take a pixel, inked along at least half its
                // length.
                func edge(_ points: [(Int, Int)], _ step: (Int, Int)) -> Bool {
                    let hits = points.filter { own($0.0, $0.1) || own($0.0 + step.0, $0.1 + step.1) }
                    return hits.count * 2 >= points.count
                }
                let xs = Array(blob.minX...blob.maxX)
                let ys = Array(blob.minY...blob.maxY)
                let edges = [edge(xs.map { ($0, blob.minY) }, (0, 1)),
                             edge(xs.map { ($0, blob.maxY) }, (0, -1)),
                             edge(ys.map { (blob.minX, $0) }, (1, 0)),
                             edge(ys.map { (blob.maxX, $0) }, (-1, 0))]
                blobs[b].closed = edges.filter { $0 }.count >= 3
            }
        }

        func stats(of members: [Int]) -> Stats {
            var minX = width, minY = height, maxX = -1, maxY = -1
            var count = 0
            var solid = 0
            var isMember = [Bool](repeating: false, count: blobs.count)
            for b in members {
                let blob = blobs[b]
                minX = min(minX, blob.minX)
                minY = min(minY, blob.minY)
                maxX = max(maxX, blob.maxX)
                maxY = max(maxY, blob.maxY)
                count += blob.count
                solid += blob.mass
                isMember[b] = true
            }
            guard maxX >= minX, maxY >= minY else {
                return Stats(rect: .null, count: 0, rows: 0, columns: 0, hollow: true, interiorInk: 0)
            }

            var rowHit = [Bool](repeating: false, count: maxY - minY + 1)
            var columnHit = [Bool](repeating: false, count: maxX - minX + 1)
            for y in minY...maxY {
                for x in minX...maxX {
                    let o = owner[y * width + x]
                    if o >= 0 && isMember[Int(o)] {
                        rowHit[y - minY] = true
                        columnHit[x - minX] = true
                    }
                }
            }
            // The middle three fifths of the box, each way.
            var interiorInk = 0
            let dx = (maxX - minX + 1) / 5
            let dy = (maxY - minY + 1) / 5
            if dx > 0, dy > 0 {
                for y in (minY + dy)...(maxY - dy) {
                    for x in (minX + dx)...(maxX - dx) where dark[y * width + x] { interiorInk += 1 }
                }
            }
            return Stats(rect: rect(minX, minY, maxX, maxY),
                         count: count,
                         rows: Double(rowHit.filter { $0 }.count) / Double(rowHit.count),
                         columns: Double(columnHit.filter { $0 }.count) / Double(columnHit.count),
                         hollow: InkMap.isRuled(count: count, mass: solid),
                         interiorInk: interiorInk)
        }
    }

    private static func startsNewParagraph(previous: Line,
                                           current: Line,
                                           blockLeft: CGFloat,
                                           metrics: Metrics) -> Bool {
        // A word broken across a line by a hyphen cannot be the end of a
        // paragraph, whatever the spacing says. Without this, a wide gap or a
        // short final line can split "ma-" from "chine" onto separate cards.
        if let last = previous.text.last, "-\u{2010}\u{00AD}".contains(last),
           let next = current.text.first, next.isLowercase {
            return false
        }

        // 1. Extra vertical space above this line.
        let gap = abs(previous.rect.midY - current.rect.midY)
        if gap > metrics.lineGap * 1.35 { return true }

        // Both remaining rules only make sense between two different lines. If
        // these two boxes are still side by side, neither applies.
        guard gap > metrics.lineGap * 0.55 else { return false }

        let shortfall = metrics.bodyRight - previous.rect.maxX
        let previousLineWasFull = shortfall < metrics.bodyWidth * 0.03

        // 2. First-line indent, relative to the block we’re already inside.
        //
        //    Suppressed when the line above ran the full measure without
        //    finishing its sentence. That combination means the paragraph is
        //    still going, and the indent we’re looking at is a hanging indent —
        //    the second line of a bullet, sitting further right than the marker
        //    above it. Reading that as a new paragraph cuts a sentence in half,
        //    which is the single worst thing this extractor can do.
        if !previousLineWasFull || endsSentence(previous.text) {
            let indentThreshold = max(4, metrics.bodyWidth * 0.015)
            if blockLeft.isFinite, current.rect.minX > blockLeft + indentThreshold { return true }
        }

        // 3. The line above stopped well short of the right margin and finished a
        //    sentence — the classic last line of a paragraph.
        if shortfall > metrics.bodyWidth * 0.14 && endsSentence(previous.text) { return true }

        return false
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        if Chunker.sentenceEnders.contains(last) { return true }
        return "\u{201D}\u{2019}\"".contains(last)
    }

    /// Joins a line onto the paragraph, healing words broken by a line-end hyphen.
    private static func append(_ line: String, to paragraph: inout String) {
        guard !paragraph.isEmpty else { paragraph = line; return }

        let hyphens: Set<Character> = ["-", "\u{2010}", "\u{00AD}"]
        if let last = paragraph.last, hyphens.contains(last),
           let next = line.first, next.isLowercase {
            paragraph.removeLast()
            paragraph += line
        } else if joinsWithoutSpace(paragraph.last, line.first) {
            paragraph += line
        } else {
            paragraph += " " + line
        }
    }

    /// Whether two lines should be joined with nothing between them.
    ///
    /// Japanese and Chinese put no spaces between words, so a line break in the
    /// middle of a sentence is just a line break. Joining those lines with a
    /// space inserts a gap that was never in the book, in the middle of a word.
    private static func joinsWithoutSpace(_ left: Character?, _ right: Character?) -> Bool {
        guard let left, let right else { return false }
        func ideographic(_ character: Character) -> Bool {
            guard let scalar = character.unicodeScalars.first,
                  character.unicodeScalars.count == 1 else { return false }
            // Hangul is written with spaces between words, so it is excluded
            // here even though it counts as a character for sizing.
            return Chunker.isIdeographic(scalar) && !(0xAC00...0xD7AF).contains(scalar.value)
        }
        func cjkPunctuation(_ character: Character) -> Bool {
            guard let scalar = character.unicodeScalars.first else { return false }
            return (0x3000...0x303F).contains(scalar.value)
                || (0xFF01...0xFF60).contains(scalar.value)
        }
        return (ideographic(left) || cjkPunctuation(left))
            && (ideographic(right) || cjkPunctuation(right))
    }

    /// Removes superscript footnote markers that extraction leaves welded to the
    /// end of a sentence, turning "called Scheme.2" back into "called Scheme."
    ///
    /// A raised digit carries no meaning once it is flattened into the line, and
    /// leaving it there both reads as a typo and stops the sentence splitter
    /// seeing a sentence boundary, so two thoughts end up on one card.
    ///
    /// Deliberately narrow. The digits must directly follow terminating
    /// punctuation, that punctuation must follow a word of at least three
    /// letters, and the digits must be followed by a space or the end of the
    /// paragraph. That leaves "3.14", "version 2.1", "2019.5" and "No.5" alone.
    static func strippingFootnoteMarkers(_ text: String) -> String {
        guard text.contains(where: \.isNumber) else { return text }

        let terminators: Set<Character> = [".", "!", "?", ")", "\u{201D}"]
        var result = ""
        result.reserveCapacity(text.count)

        let characters = Array(text)
        var i = 0
        while i < characters.count {
            let character = characters[i]
            result.append(character)
            i += 1

            guard terminators.contains(character) else { continue }

            // The word this punctuation ends, so "No." is not treated as prose.
            var letters = 0
            var back = result.index(before: result.endIndex)
            while back > result.startIndex {
                back = result.index(before: back)
                if result[back].isLetter { letters += 1 } else { break }
            }
            guard letters >= 3 else { continue }

            // One or two digits, then a break.
            var digits = 0
            var lookahead = i
            while lookahead < characters.count, characters[lookahead].isNumber, digits < 2 {
                digits += 1
                lookahead += 1
            }
            guard digits > 0 else { continue }
            let followed = lookahead >= characters.count || characters[lookahead] == " "
            if followed { i = lookahead }
        }
        return result
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
