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

        var result: [PageText] = []
        result.reserveCapacity(count)
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
            let body = lines.filter { !isFurniture($0) }
            let furnitureOnPage = lines.filter(isFurniture)
            // Margins are measured per page. Books are printed with mirrored
            // margins — the inner edge swaps sides on facing pages — so a single
            // document-wide right margin is wrong for half the book, and every
            // full line on those pages looks short enough to end a paragraph.
            let metrics = pageMetrics(for: body, fallback: documentWide)
            let area = page.map { bodyArea(of: $0, furniture: furnitureOnPage) } ?? .null
            result.append(PageText(pageIndex: i,
                                   blocks: blocks(from: body, metrics: metrics,
                                                  page: page, contentArea: area)))
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

            mutating func absorb(_ other: Row) {
                rect = rect.union(other.rect)
                heights.append(contentsOf: other.heights)
            }
        }

        var rows: [Row] = []
        rows.reserveCapacity(64)

        for i in 0..<charCount {
            let bounds = page.characterBounds(at: i)
            guard bounds.height > 0.5, bounds.width.isFinite, bounds.origin.y.isFinite else { continue }
            let glyph = Row(rect: bounds, heights: [bounds.height])
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
            let rect = row.rect
            // A slight outset stops the selection from clipping ascenders and
            // the first glyph of the line. The right edge is given a whole
            // character of room: a mark that ends a line, an ideographic full
            // stop in particular, sits right on the boundary and is otherwise
            // left out, so the sentence loses the thing that ends it.
            var probe = rect.insetBy(dx: -1.5, dy: -1.5)
            probe.size.width += rect.height
            guard let raw = page.selection(for: probe)?.string else { return nil }
            let text = collapseWhitespace(raw)
            guard !text.isEmpty else { return nil }
            return Line(rect: rect, text: text,
                        glyphHeight: modalHeight(row.heights), heights: row.heights)
        }

        return result.isEmpty ? fallbackLines(of: page) : result
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

    private static func blocks(from lines: [Line], metrics: Metrics,
                               page: PDFPage?, contentArea: CGRect) -> [Block] {
        guard !lines.isEmpty else { return [] }

        var blocks: [Block] = []
        var current = ""
        var currentIsHeading = false
        // The left edge of the paragraph being built. Indents are judged against
        // this rather than the page margin, so an abstract or a block quote —
        // indented on every line — isn’t read as one paragraph per line.
        var blockLeft = CGFloat.greatestFiniteMagnitude

        func flush() {
            let trimmed = strippingFootnoteMarkers(current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 1 {
                blocks.append(currentIsHeading ? .heading(trimmed) : .paragraph(trimmed))
            }
            current = ""
            currentIsHeading = false
            blockLeft = .greatestFiniteMagnitude
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

        for (i, line) in lines.enumerated() {
            let heading = isHeadingLine(at: i)
            if i > 0 {
                // A tall empty band between two lines is where a figure lives.
                if let figure = figureRegion(above: line, below: lines[i - 1],
                                             metrics: metrics, page: page,
                                             contentArea: contentArea) {
                    flush()
                    blocks.append(.figure(figure))
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
            if current.isEmpty { currentIsHeading = heading }
            append(line.text, to: &current)
            blockLeft = min(blockLeft, line.rect.minX)
        }
        flush()

        // A figure can also sit above the first line or below the last one.
        if let page, let first = lines.first, let last = lines.last, !contentArea.isNull {
            if let top = inkedRegion(CGRect(x: metrics.bodyLeft, y: first.rect.maxY,
                                            width: metrics.bodyWidth,
                                            height: contentArea.maxY - first.rect.maxY),
                                     metrics: metrics, page: page, contentArea: contentArea) {
                blocks.insert(.figure(top), at: 0)
            }
            if let bottom = inkedRegion(CGRect(x: metrics.bodyLeft, y: contentArea.minY,
                                               width: metrics.bodyWidth,
                                               height: last.rect.minY - contentArea.minY),
                                        metrics: metrics, page: page, contentArea: contentArea) {
                blocks.append(.figure(bottom))
            }
        }
        return mergingOverlappingFigures(blocks)
    }

    /// A figure with labels inside it produces several candidate bands — one for
    /// each gap between its own text — which then overlap almost entirely. Fold
    /// those back into a single picture.
    private static func mergingOverlappingFigures(_ blocks: [Block]) -> [Block] {
        var result: [Block] = []

        for block in blocks {
            guard case .figure(let rect) = block else {
                result.append(block)
                continue
            }

            let existing = result.lastIndex { item in
                if case .figure(let other) = item { return overlapFraction(rect, other) > 0.3 }
                return false
            }

            if let existing, case .figure(let other) = result[existing] {
                result[existing] = .figure(rect.union(other))
            } else {
                result.append(block)
            }
        }
        return result
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

    private static func figureRegion(above current: Line, below previous: Line,
                                     metrics: Metrics, page: PDFPage?,
                                     contentArea: CGRect) -> CGRect? {
        guard let page else { return nil }
        // PDF y grows upward and lines arrive top-to-bottom, so the previous
        // line’s bottom edge is the top of the gap.
        let gapTop = previous.rect.minY
        let gapBottom = current.rect.maxY
        guard gapTop > gapBottom else { return nil }
        let gap = CGRect(x: metrics.bodyLeft, y: gapBottom,
                         width: metrics.bodyWidth, height: gapTop - gapBottom)
        return inkedRegion(gap, metrics: metrics, page: page, contentArea: contentArea)
    }

    /// Accepts a band only if it is big enough to be worth showing and actually
    /// has something drawn in it. Plenty of tall gaps are just white space, and a
    /// card containing a picture of nothing is worse than no card at all.
    private static func inkedRegion(_ rect: CGRect, metrics: Metrics,
                                    page: PDFPage, contentArea: CGRect) -> CGRect? {
        // Bounded as well as finite. Nothing rejects an absurd media box — a
        // page can declare itself 1e20 points tall and PDFKit reports it back
        // verbatim — and a figure region taken from one traps every later
        // attempt to scale it.
        guard rect.height.isFinite, rect.width.isFinite,
              rect.width < 20_000, rect.height < 20_000 else { return nil }

        // Clip to the body area *first*, for two reasons: a running head sitting
        // just above a figure would otherwise be baked into the picture, and
        // probing the raw band then clipping afterwards passes the ink test on
        // text that is then cropped away — leaving one-point slivers where a
        // figure was meant to be.
        let clip = contentArea.isNull ? page.bounds(for: .mediaBox) : contentArea
        let bounded = rect.intersection(clip)
        let minimumHeight = max(metrics.lineGap * 3.2, 58)
        guard !bounded.isNull, bounded.height >= minimumHeight, bounded.width > 40
        else { return nil }

        // Look for ink strictly *between* the lines. Character bounds don’t
        // always cover a glyph’s full extent, so a band measured right up to the
        // text edge catches the tops of letters, and every paragraph gap in the
        // book gets reported as a picture.
        let probe = bounded.insetBy(dx: 2, dy: 7)
        guard probe.height > 24, let ink = inkBounds(in: probe, of: page) else { return nil }

        // Trim to what was actually drawn, with a little air around it.
        let trimmed = ink.insetBy(dx: -6, dy: -6).intersection(bounded)
        guard !trimmed.isNull, trimmed.height >= minimumHeight * 0.55 else { return nil }
        return trimmed
    }

    /// Renders the band small and returns the bounding box of whatever was
    /// drawn in it, in page coordinates — or nil if there was essentially
    /// nothing there.
    ///
    /// The bounding box matters as much as the yes/no: the gap between two
    /// paragraphs is usually much taller than the picture sitting in it, and a
    /// card padded out with half a page of white space looks broken.
    private static func inkBounds(in rect: CGRect, of page: PDFPage) -> CGRect? {
        let width = 96
        // Clamp in floating point, before the conversion. Int(_: Double) traps
        // on anything past Int.max rather than saturating, so clamping the Int
        // afterwards never runs — and the number that gets there is only a
        // number in a file someone downloaded.
        let rows = Double(width) * rect.height / max(rect.width, 1)
        guard rows.isFinite, rows > 0 else { return nil }
        let height = max(8, Int(min(rows, 2000)))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        var dark = 0
        var minCol = width, maxCol = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            for column in 0..<width where pixels[row * width + column] < 235 {
                dark += 1
                if column < minCol { minCol = column }
                if column > maxCol { maxCol = column }
                if row < minRow { minRow = row }
                if row > maxRow { maxRow = row }
            }
        }

        // A few stray pixels are compression noise; a real figure covers ground.
        guard maxCol >= minCol, maxRow >= minRow,
              Double(dark) / Double(width * height) > 0.02 else { return nil }

        let pixelWidth = rect.width / CGFloat(width)
        let pixelHeight = rect.height / CGFloat(height)
        // A bitmap context stores its first row at the top, while page
        // coordinates count upward from the bottom.
        return CGRect(x: rect.minX + CGFloat(minCol) * pixelWidth,
                      y: rect.maxY - CGFloat(maxRow + 1) * pixelHeight,
                      width: CGFloat(maxCol - minCol + 1) * pixelWidth,
                      height: CGFloat(maxRow - minRow + 1) * pixelHeight)
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
