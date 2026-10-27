import Foundation
import PDFKit

/// Builds the table of contents for a book, and works out which card each entry
/// lands on.
///
/// Without this there is no way to go anywhere: you can only step forward from
/// wherever you stopped, which makes "start at chapter five" impossible. Most
/// real PDFs carry a proper outline, so the job is mostly to map its page
/// destinations onto card indices — and to invent something usable for the
/// documents that have no outline at all.
enum ContentsBuilder {

    static func build(document: PDFDocument, text: BookText) -> [ContentsEntry] {
        let fromOutline = fromOutline(document: document, text: text)
        return fromOutline.isEmpty ? fromHeadings(text: text) : fromOutline
    }

    /// Contents for an EPUB, whose navigation already names its own sections, so
    /// there is nothing to infer: only the spine index to map onto a card.
    static func build(epubContents: [(title: String, page: Int, depth: Int)],
                      text: BookText) -> [ContentsEntry] {
        var entries: [ContentsEntry] = []
        var floor = 0

        for item in epubContents {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            guard var chunk = text.chunks.first(where: { $0.page == item.page })?.id
                    ?? text.chunks.first(where: { $0.page >= item.page })?.id
            else { continue }
            chunk = max(chunk, floor)
            floor = chunk
            entries.append(ContentsEntry(id: entries.count, title: title,
                                         depth: min(item.depth, 2), page: item.page,
                                         chunkIndex: chunk))
        }
        return entries
    }

    /// The printed page numbers, collected once so the reader can ask for the
    /// number shown on the page rather than its position in the file.
    static func pageLabels(of document: PDFDocument) -> [String] {
        var labels: [String] = []
        labels.reserveCapacity(document.pageCount)
        var sawRealLabel = false
        for i in 0..<document.pageCount {
            let label = document.page(at: i)?.label ?? ""
            if !label.isEmpty, label != String(i + 1) { sawRealLabel = true }
            labels.append(label)
        }
        // If every label just repeats the index, storing them buys nothing.
        return sawRealLabel ? labels : []
    }

    // MARK: - The document's own outline

    private static func fromOutline(document: PDFDocument, text: BookText) -> [ContentsEntry] {
        guard let root = document.outlineRoot else { return [] }

        var raw: [(title: String, page: Int, depth: Int)] = []
        flatten(root, depth: 0, document: document, into: &raw)

        var entries: [ContentsEntry] = []
        // Carried forward so the list can only ever move onward through the
        // book. A chapter and its first section usually start on the same page,
        // and matching each title against the cards there can resolve the child
        // to an earlier card than its parent. The list then runs backwards, and
        // "you are here" starts jumping about. Nesting means "inside", so a
        // child can never legitimately begin before the thing that contains it.
        var floor = 0

        for item in raw {
            guard !item.title.isEmpty,
                  let chunk = chunkIndex(forTitle: item.title, page: item.page, in: text)
            else { continue }
            let resolved = max(chunk, floor)
            floor = resolved
            entries.append(ContentsEntry(id: entries.count, title: item.title,
                                         depth: item.depth, page: item.page,
                                         chunkIndex: resolved,
                                         pageLabel: document.page(at: item.page)?.label ?? ""))
        }
        return entries
    }

    /// Deep enough for any real book. A document can nest its outline as far as
    /// it likes, and walking it forces PDFKit to materialise an object per node
    /// whose own dealloc is recursive — so a hostile file overflows the parse
    /// thread's stack on the way in or on the way out. Nothing genuine nests
    /// past about five, and ContentsView collapses everything below the top
    /// level to a single indent anyway.
    private static let maximumOutlineDepth = 12

    private static func flatten(_ node: PDFOutline, depth: Int, document: PDFDocument,
                                into list: inout [(title: String, page: Int, depth: Int)]) {
        guard depth <= maximumOutlineDepth else { return }
        for i in 0..<node.numberOfChildren {
            guard let child = node.child(at: i) else { continue }

            // Most outlines use a destination; some use a GoTo action instead.
            let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
            let page = destination.flatMap { pageIndex(of: $0, in: document) } ?? -1

            let title = (child.label ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if page >= 0 { list.append((title, page, depth)) }
            flatten(child, depth: depth + 1, document: document, into: &list)
        }
    }

    /// Resolves a destination to a page index, defensively.
    ///
    /// `PDFDestination.page` is declared nonnull, so Swift imports it as
    /// non-optional — but it is a *weak* reference, and a bookmark pointing at a
    /// page PDFKit has released hands back nil anyway. Binding it through an
    /// explicit `PDFPage?` forces the check that the type system has been told
    /// is unnecessary. `index(for:)` then returns NSNotFound for a page that is
    /// not in this document, which is a very large number rather than an error.
    private static func pageIndex(of destination: PDFDestination, in document: PDFDocument) -> Int? {
        let page: PDFPage? = destination.page
        guard let page else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound, index >= 0, index < document.pageCount else { return nil }
        return index
    }

    /// Finds the card an outline entry points at.
    ///
    /// The page alone isn't enough: a paper can open three sections on page one,
    /// and landing all three on the same card would make the contents useless.
    /// Matching the entry's own words against the cards on that page resolves it
    /// — measured at 262 of 262 entries across a 244-page book and a paper.
    private static func chunkIndex(forTitle title: String, page: Int, in text: BookText) -> Int? {
        var candidates = text.chunks.filter { $0.page == page }
        if candidates.isEmpty {
            // Destination lands on a page with no extractable text (a plate, a
            // chapter divider): take the next card that exists.
            guard let next = text.chunks.first(where: { $0.page >= page }) else { return nil }
            candidates = [next]
        }

        let needle = normalize(title)
        if !needle.isEmpty {
            if let hit = candidates.first(where: { normalize($0.text).hasPrefix(needle) })
                ?? candidates.first(where: { $0.kind == .heading && normalize($0.text).contains(needle) })
                ?? candidates.first(where: { normalize($0.text).contains(needle) }) {
                return hit.id
            }
        }
        return candidates.first?.id
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Fallback for documents with no outline

    /// Built from the headings the chunker found, in two passes.
    ///
    /// Textbooks, manuals and course readers are the documents most likely to
    /// ship without an outline, and they are also the ones that number their
    /// sections — "3: Introduction to Evolution", "2.1 Properties of Water".
    /// That numbering is worth far more than a bare heading, because it says
    /// which entries are real chapters and how they nest. So the first pass
    /// takes only numbered headings, and the loose scrape runs only when the
    /// document turns out not to number anything.
    ///
    /// Either way the book's own printed contents page is excluded. Every line
    /// on it looks exactly like a heading, so without that it wins: the list
    /// fills up with entries that all jump to the contents page, and the real
    /// chapters never appear at all.
    private static func fromHeadings(text: BookText) -> [ContentsEntry] {
        let skip = printedContentsPages(in: text)
        let headings = text.chunks.filter { $0.kind == .heading && !skip.contains($0.page) }

        let numbered = headings.compactMap { chunk -> ContentsEntry? in
            let title = tidy(chunk.text)
            guard let depth = numberedDepth(of: title) else { return nil }
            return ContentsEntry(id: 0, title: title, depth: depth,
                                 page: chunk.page, chunkIndex: chunk.id)
        }
        // One or two numbered headings in a document that doesn't number its
        // chapters is a coincidence, and a contents list of two entries is worse
        // than none. Four is enough to be a scheme — provided the numbers
        // actually run in order.
        let loose = looseHeadings(headings)
        let candidates: [ContentsEntry]
        if numbered.count >= 4 && numbersRunInOrder(numbered) {
            candidates = numbered
        } else {
            // Some books number in roman rather than arabic, and label the
            // number rather than standing it alone: "BOOK IV.", "PROP. XLVII."
            let labelled = labelledHeadings(headings, looseCount: loose.count)
            candidates = labelled.isEmpty ? loose : labelled
        }

        // Running heads repeat verbatim; a real heading appears once. Deeper
        // entries are only deduped within the division they sit in, because a
        // title like "PROP. I." legitimately recurs once per book — deduping
        // those globally throws away every repeat after the first.
        var seenTop = Set<String>()
        var seenInside = Set<String>()
        var entries: [ContentsEntry] = []
        for candidate in candidates {
            let key = normalize(candidate.title)
            guard !key.isEmpty else { continue }
            if candidate.depth == 0 {
                guard !seenTop.contains(key) else { continue }
                seenTop.insert(key)
                seenInside.removeAll()
            } else {
                guard !seenInside.contains(key) else { continue }
                seenInside.insert(key)
            }
            var entry = candidate
            entry.id = entries.count
            entries.append(entry)
        }

        return thinned(entries)
    }

    /// Beyond a certain length a contents list stops being navigation and
    /// becomes another wall of text. Trimming to fit takes the deepest entries
    /// first, so what survives is the spine: losing half the propositions in a
    /// book is a shame, losing two of its seven books is a broken contents list.
    private static func thinned(_ entries: [ContentsEntry], limit: Int = 150) -> [ContentsEntry] {
        guard entries.count > limit else { return renumbered(entries) }
        var kept = entries

        for depth in [2, 1] where kept.count > limit {
            let atDepth = kept.indices.filter { kept[$0].depth == depth }
            guard !atDepth.isEmpty else { continue }
            let keepCount = max(0, atDepth.count - (kept.count - limit))
            var keepable = Set<Int>()
            if keepCount > 0 {
                let step = Double(atDepth.count) / Double(keepCount)
                for i in 0..<keepCount {
                    keepable.insert(atDepth[min(atDepth.count - 1, Int(Double(i) * step))])
                }
            }
            kept = kept.indices
                .filter { kept[$0].depth != depth || keepable.contains($0) }
                .map { kept[$0] }
        }

        // A list that is still too long has nothing left to thin by depth — it
        // is flat. Fall back to sampling it evenly, so the cap always holds.
        if kept.count > limit {
            let step = Double(kept.count) / Double(limit)
            kept = (0..<limit).map { kept[min(kept.count - 1, Int(Double($0) * step))] }
        }
        return renumbered(kept)
    }

    private static func renumbered(_ entries: [ContentsEntry]) -> [ContentsEntry] {
        entries.enumerated().map { index, entry in
            var entry = entry
            entry.id = index
            return entry
        }
    }

    // MARK: - Headings numbered with a labelled roman numeral

    private struct Labelled {
        let label: String
        let number: Int
        let chunk: Chunk
    }

    /// Contents for a book that numbers itself "BOOK IV." and "PROP. XLVII.".
    ///
    /// Roman numbering is invisible to the arabic pass, so a book that uses it
    /// falls through to the loose scrape and its contents list fills with
    /// whatever else happened to be set like a heading. Euclid's Elements is the
    /// case in point: its 7 books and 197 propositions are all present and all
    /// unreadable, and the list it shipped instead was 77% fragments of algebra.
    private static func labelledHeadings(_ headings: [Chunk], looseCount: Int) -> [ContentsEntry] {
        let parsed = headings.compactMap(labelled)
        guard parsed.count >= 8 else { return [] }
        // A coverage gate, because this pass displaces the loose scrape and so
        // has to be carrying most of the document before it may. Four "Fig. I."
        // captions must never replace a report's twenty real section titles.
        guard Double(parsed.count) >= Double(looseCount) * 0.25 else { return [] }

        var counts: [String: Int] = [:]
        for item in parsed { counts[item.label, default: 0] += 1 }
        let labels = Set(counts.filter { $0.value >= 4 }.map(\.key))
        guard !labels.isEmpty else { return [] }

        var kept = parsed.filter { labels.contains($0.label) }
        guard kept.count >= 8 else { return [] }

        // Which label contains which, judged by whether the inner one's
        // numbering actually restarts under the outer one. Rarity is not enough:
        // a novel with four plates and sixteen chapters would nest every chapter
        // under a plate caption.
        let nesting = containment(in: kept, labels: labels)

        if let nesting {
            // A division with nothing inside it before the next division is a
            // line on the book's own printed contents page, not a division of
            // the book. Only safe to apply once containment is established,
            // which is why it waits until here.
            var childless = Set<Int>()
            for (offset, item) in kept.enumerated() where item.label == nesting.outer {
                let next = kept[(offset + 1)...].firstIndex { $0.label == nesting.outer }
                    ?? kept.endIndex
                if !kept[(offset + 1)..<next].contains(where: { $0.label == nesting.inner }) {
                    childless.insert(offset)
                }
            }
            kept = kept.enumerated().filter { !childless.contains($0.offset) }.map(\.element)
        }

        return kept.map { item in
            ContentsEntry(id: 0, title: tidy(item.chunk.text),
                          depth: nesting?.inner == item.label ? 1 : 0,
                          page: item.chunk.page, chunkIndex: item.chunk.id)
        }
    }

    /// Reads "BOOK IV." or "PROP. XLVII.—Theorem." into its label and number.
    private static func labelled(_ chunk: Chunk) -> Labelled? {
        var rest = Substring(tidy(chunk.text))
        let word = rest.prefix(while: \.isLetter)
        guard word.count >= 2, word.count <= 12 else { return nil }
        rest = rest.dropFirst(word.count)
        if rest.first == "." { rest = rest.dropFirst() }
        guard let separator = rest.first, separator.isWhitespace else { return nil }
        rest = rest.drop(while: \.isWhitespace)

        // Uppercase only. Lowercase roman numerals appear mid-sentence in
        // cross-references ("Prop. iii. is the particular case of Prop. i.").
        let numeral = rest.prefix { "IVXLCDM".contains($0) }
        guard !numeral.isEmpty, let value = TextExtractor.romanValue(String(numeral)) else {
            return nil
        }
        rest = rest.dropFirst(numeral.count)
        if let next = rest.first {
            guard ".,-\u{2013}\u{2014}".contains(next) || next.isWhitespace else { return nil }
        }
        return Labelled(label: word.uppercased(), number: value, chunk: chunk)
    }

    /// Whether one label nests inside another, judged by restarts.
    ///
    /// The inner numbering counts up within a division and starts again in the
    /// next one, and each restart should sit right after an outer heading. That
    /// is what containment means, and it is a fact about the document rather
    /// than a guess from how often each word appears.
    private static func containment(in items: [Labelled],
                                    labels: Set<String>) -> (outer: String, inner: String)? {
        for outer in labels.sorted() {
            for inner in labels.sorted() where inner != outer {
                let sequence = items.filter { $0.label == outer || $0.label == inner }
                var steps = 0, restarts = 0, explained = 0
                for i in 1..<max(1, sequence.count) where sequence[i].label == inner {
                    guard sequence[i - 1].label == inner else {
                        // An inner heading straight after an outer one: a
                        // restart only if it really starts over.
                        if sequence[i].number <= 1 || sequence[i - 1].label == outer {
                            if sequence[i].number <= 1 { restarts += 1; explained += 1 }
                        }
                        continue
                    }
                    steps += 1
                    if sequence[i].number < sequence[i - 1].number { restarts += 1 }
                }
                guard steps >= 4, restarts >= 2,
                      Double(explained) >= Double(restarts) * 0.7 else { continue }
                return (outer, inner)
            }
        }
        return nil
    }

    /// Whether a run of numbered headings is a chapter scheme or a coincidence.
    ///
    /// Chapters count upward through a book, so their leading numbers almost
    /// never go backwards. Numbered things that are not chapters restart
    /// constantly: a geometry text sets its exercises as "1.", "2.", "3." on
    /// page after page, and every one of them is typographically a heading.
    /// Reading those as a contents list produces a few dozen entries titled with
    /// fragments of algebra and no chapters at all, which is worse than having
    /// no contents list, so the whole numbered pass is abandoned when the
    /// sequence doesn't hold.
    private static func numbersRunInOrder(_ entries: [ContentsEntry]) -> Bool {
        var previous = -1
        var backwards = 0
        var counted = 0
        for entry in entries {
            guard let number = leadingNumber(of: entry.title) else { continue }
            if previous >= 0 {
                counted += 1
                // A number well below the last one is a restart, not a chapter.
                if number < previous { backwards += 1 }
            }
            previous = number
        }
        guard counted >= 3 else { return false }
        return Double(backwards) <= Double(counted) * 0.15
    }

    private static func leadingNumber(of title: String) -> Int? {
        var rest = Substring(title)
        for word in ["chapter ", "section ", "part ", "unit ", "lecture ", "appendix "]
        where rest.lowercased().hasPrefix(word) {
            rest = rest.dropFirst(word.count)
            break
        }
        let digits = rest.prefix(while: \.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    /// The generic scrape, for documents with no numbering to go on. Filtered
    /// harder than the numbered pass, because there is nothing vouching for
    /// these beyond their typography.
    private static func looseHeadings(_ headings: [Chunk]) -> [ContentsEntry] {
        headings.compactMap { chunk in
            let title = tidy(chunk.text)
            guard title.count >= 3, title.count <= 80 else { return nil }
            guard title.contains(where: { $0.isLetter }) else { return nil }
            // "Figure", "Summary", "Attribution", "Notes" — set like headings,
            // scattered through every chapter, and useless to navigate by.
            guard title.split(separator: " ").count >= 2 else { return nil }
            return ContentsEntry(id: 0, title: title, depth: 0,
                                 page: chunk.page, chunkIndex: chunk.id)
        }
    }

    /// How deeply a numbered heading nests, or nil if it isn't numbered.
    ///
    /// "4" and "Chapter 4" are top level, "4.2" sits under them, "4.2.1" under
    /// that. The number has to be followed by something — a bare page number
    /// that escaped the furniture filter is not a chapter.
    private static func numberedDepth(of title: String) -> Int? {
        var rest = Substring(title)
        for word in ["chapter ", "section ", "part ", "unit ", "lecture ", "appendix "]
        where rest.lowercased().hasPrefix(word) {
            rest = rest.dropFirst(word.count)
            break
        }

        var digits = 0, dots = 0
        var index = rest.startIndex
        while index < rest.endIndex {
            let character = rest[index]
            if character.isNumber {
                digits += 1
            } else if character == "." || character == "-" {
                // A trailing separator ("4.") is punctuation, not another level.
                guard rest.index(after: index) < rest.endIndex,
                      rest[rest.index(after: index)].isNumber else { break }
                dots += 1
            } else {
                break
            }
            index = rest.index(after: index)
        }
        guard digits > 0 else { return nil }

        // The number has to be punctuated like a number that labels something.
        // Without this, every "Page 1, sentence 1" in a document reads as a
        // contents entry, because there is a digit with words after it.
        var tail = rest[index...]
        let separators = ":.)-\u{2013}\u{2014}"
        guard let next = tail.first else { return nil }
        guard separators.contains(next) || next.isWhitespace else { return nil }
        while let first = tail.first, separators.contains(first) || first.isWhitespace {
            tail = tail.dropFirst()
        }

        // And what follows has to read as a title rather than as more of the
        // page: a run of words, not an equation or a line of coordinates.
        let letters = tail.filter(\.isLetter).count
        guard letters >= 3, !tail.contains("=") else { return nil }
        guard Double(letters) >= Double(tail.count) * 0.55 else { return nil }
        return min(dots, 2)
    }

    /// The pages holding the book's own printed contents list.
    ///
    /// Those pages are nothing but headings, so they have to be recognised and
    /// set aside — both so they stop filling the contents list with entries that
    /// point at themselves, and so the reader stops serving them up as cards to
    /// read, which is what a page of run-together chapter titles becomes.
    static func printedContentsPages(in text: BookText) -> Set<Int> {
        var byPage: [Int: (entries: Int, words: Int, announced: Bool)] = [:]
        for chunk in text.chunks where chunk.kind != .figure {
            var page = byPage[chunk.page] ?? (0, 0, false)
            page.entries += contentsEntryCount(in: chunk.text)
            page.words += chunk.text.split(whereSeparator: \.isWhitespace).count
            if announcesContents(chunk.text) { page.announced = true }
            byPage[chunk.page] = page
        }

        var pages = Set<Int>()
        for (page, counts) in byPage {
            // A page that says "Contents" at the top needs less corroboration
            // than one recognised by its shape alone.
            guard counts.entries >= (counts.announced ? 2 : 4) else { continue }
            // Entries have to be most of what is on the page. The measure is
            // words per entry, which is what separates a contents list from a
            // page of numbered exercises: a contents entry is a title, five or
            // six words long, while an exercise is a whole question. Without
            // this, a maths book loses its problem sets.
            guard counts.entries * 12 >= counts.words else { continue }
            pages.insert(page)
        }
        return pages
    }

    /// How many contents entries a piece of text contains.
    ///
    /// Counted inside the text rather than per card, because a contents page
    /// sets its entries tight enough that they arrive as one run of text rather
    /// than one card each.
    static func contentsEntryCount(in text: String) -> Int {
        var count = 0
        if text.contains("....") || text.contains(". . .") { count += 1 }

        // Every place a number starts a word and a title follows it.
        var index = text.startIndex
        var atWordStart = true
        while index < text.endIndex {
            let character = text[index]
            if atWordStart, character.isNumber,
               numberedDepth(of: String(text[index...].prefix(64))) != nil {
                count += 1
                // Skip past this entry's number so "1.2.3" counts once.
                while index < text.endIndex, text[index].isNumber || text[index] == "." {
                    index = text.index(after: index)
                }
                atWordStart = false
                continue
            }
            atWordStart = character.isWhitespace
            index = text.index(after: index)
        }
        return count
    }

    /// Marks the parts of a book nobody sits down to read as non-prose, so the
    /// reader offers them to skim rather than serving them a sentence at a time.
    ///
    /// Two kinds: the printed contents list at the front, and the apparatus at
    /// the back of a book or of each chapter — references, bibliography,
    /// further reading, attributions. A reference list is the worst possible
    /// thing to meter out one card at a time, because every entry is its own
    /// unrelated fragment and there are hundreds of them; landing in one feels
    /// like the book has stopped making sense. None of it is thrown away: the
    /// cards are still there to page through, and still reachable from the
    /// contents list. They are just no longer presented as something to read.
    static func demoteNonReading(in text: inout BookText) {
        let pages = printedContentsPages(in: text)
        var inApparatus = false

        for i in text.chunks.indices {
            let chunk = text.chunks[i]
            if chunk.kind == .heading {
                // A heading ends the previous run and may start a new one, so
                // an apparatus section reaches exactly to the next title.
                inApparatus = isApparatusHeading(chunk.text)
                continue
            }
            // On a contents page, only the cards that actually carry entries.
            // A short book can open chapter one below its own contents list,
            // and that prose is still there to be read.
            let isContentsList = pages.contains(chunk.page)
                && contentsEntryCount(in: chunk.text) > 0
            guard inApparatus || isContentsList else { continue }
            if text.chunks[i].kind == .prose { text.chunks[i].kind = .aside }
        }
    }

    /// Titles that introduce apparatus rather than reading.
    private static func isApparatusHeading(_ title: String) -> Bool {
        var key = normalize(title)
        // "References and Notes", "Works Cited", "Selected Bibliography" — the
        // shape varies, so match on the words that carry the meaning.
        for filler in ["selected", "further", "additional", "and", "the", "chapter"] {
            key = key.replacingOccurrences(of: filler, with: "")
        }
        let apparatus: Set<String> = [
            "references", "reference", "bibliography", "bibliographies",
            "workscited", "literaturecited", "citations", "sources",
            "reading", "readings", "notes", "endnotes", "footnotes",
            "attribution", "attributions", "credits", "licensing", "license",
            "acknowledgments", "acknowledgements", "index",
        ]
        return apparatus.contains(key)
    }

    private static func announcesContents(_ text: String) -> Bool {
        let key = normalize(text)
        return key == "contents" || key == "tableofcontents" || key == "coursecontents"
    }

    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
