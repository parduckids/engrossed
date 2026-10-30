import Foundation

/// Reads an EPUB package document: what files exist, and what order to read
/// them in.
enum PackageParser {

    struct Package {
        var title: String?
        var author: String?
        /// Manifest id to href.
        var manifest: [String: String] = [:]
        /// Spine, in reading order, as manifest ids.
        var spine: [String] = []
        var navigationHref: String?
        var ncxHref: String?
    }

    static func parse(_ data: Data) -> Package {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()

        var package = delegate.package
        // The NCX is referenced by the spine's `toc` attribute rather than by
        // a property, which is why it is resolved here rather than inline.
        if let tocID = delegate.spineTOCID, let href = package.manifest[tocID] {
            package.ncxHref = href
        }
        return package
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var package = Package()
        var spineTOCID: String?
        private var collecting: String?
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            switch element.lowercased() {
            case "item":
                if let id = attributes["id"], let href = attributes["href"] {
                    package.manifest[id] = href
                    let properties = attributes["properties"] ?? ""
                    if properties.split(separator: " ").contains("nav") {
                        package.navigationHref = href
                    }
                    if attributes["media-type"] == "application/x-dtbncx+xml" {
                        package.ncxHref = href
                    }
                }
            case "itemref":
                // linear="no" marks front matter that is not part of the read.
                if let idref = attributes["idref"], attributes["linear"]?.lowercased() != "no" {
                    package.spine.append(idref)
                }
            case "spine":
                spineTOCID = attributes["toc"]
            case "title", "creator":
                collecting = element.lowercased()
                buffer = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting != nil { buffer += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (collecting, element.lowercased()) {
            case ("title", "title"):
                if package.title == nil, !text.isEmpty { package.title = text }
            case ("creator", "creator"):
                if package.author == nil, !text.isEmpty { package.author = text }
            default:
                break
            }
            if collecting == element.lowercased() { collecting = nil; buffer = "" }
        }
    }
}

/// Reads a table of contents, from either of the two formats EPUB has used.
enum NavigationParser {

    struct Entry {
        let title: String
        let href: String
        let depth: Int
    }

    /// EPUB 3: an XHTML `nav` document, where nesting is expressed by nested
    /// `ol` elements.
    static func parseNav(_ html: String) -> [Entry] {
        var entries: [Entry] = []
        var depth = 0
        var index = html.startIndex
        // The open anchor whose label is still being collected.
        //
        // Keeping it here means the label comes from text this loop already
        // walks past, instead of from a "</a" search run once per anchor. That
        // search scanned to the end of the document every time it failed, so a
        // nav whose anchors are never closed cost O(anchors x document) and hung
        // the import for minutes — and a malformed nav is exactly the case this
        // parser exists to survive.
        var pending: (href: String, start: String.Index, depth: Int)?

        func flush(upTo end: String.Index) {
            guard let anchor = pending else { return }
            pending = nil
            let label = HTMLText.plain(String(html[anchor.start..<end]))
            if !label.isEmpty {
                entries.append(Entry(title: label, href: anchor.href, depth: anchor.depth))
            }
        }

        while let open = html.range(of: "<", range: index..<html.endIndex) {
            guard let close = html.range(of: ">", range: open.upperBound..<html.endIndex) else { break }
            let tag = String(html[open.upperBound..<close.lowerBound])
            let isClosing = tag.hasPrefix("/")
            let name = tag.drop(while: { $0 == "/" })
                .prefix(while: { !$0.isWhitespace && $0 != "/" })
                .lowercased()

            if name == "ol" {
                flush(upTo: open.lowerBound)
                depth = max(0, depth + (isClosing ? -1 : 1))
            } else if name == "a" {
                if isClosing {
                    flush(upTo: open.lowerBound)
                } else if let href = attribute("href", in: tag) {
                    // An unclosed anchor's label ends where the next one starts.
                    flush(upTo: open.lowerBound)
                    pending = (href, close.upperBound, max(0, depth - 1))
                }
            } else if name == "li", isClosing {
                flush(upTo: open.lowerBound)
            }
            index = close.upperBound
        }
        flush(upTo: html.endIndex)
        return entries
    }

    /// EPUB 2: an NCX, where nesting is expressed by nested `navPoint`s.
    static func parseNCX(_ xml: String) -> [Entry] {
        let delegate = NCXDelegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.entries
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        let rest = tag[range.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        let value = rest.dropFirst()
        guard let end = value.firstIndex(of: quote) else { return nil }
        return String(value[..<end])
    }

    private final class NCXDelegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var depth = -1
        private var label = ""
        private var href: String?
        private var inLabel = false

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            switch element.lowercased() {
            case "navpoint":
                depth += 1
                label = ""
                href = nil
            case "text":
                inLabel = true
            case "content":
                if href == nil { href = attributes["src"] }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inLabel { label += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName: String?) {
            switch element.lowercased() {
            case "text":
                inLabel = false
            case "navpoint":
                let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if let href, !title.isEmpty {
                    entries.append(Entry(title: title, href: href, depth: max(0, depth)))
                }
                depth -= 1
            default:
                break
            }
        }
    }
}

/// Reads META-INF/encryption.xml: which files in the book are encrypted, and
/// with what.
enum EncryptionParser {

    struct Item {
        /// The EncryptionMethod's Algorithm URI, when it has one.
        var algorithm: String?
        /// The encrypted file, relative to the root of the container.
        var uri: String
    }

    static func parse(_ data: Data) -> [Item] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [Item] = []
        /// Local element names from the root down to the current element.
        private var path: [String] = []
        private var algorithm: String?
        private var references: [String] = []

        func parser(_ parser: XMLParser, didStartElement element: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            let name = element.lowercased()
            let parent = path.last
            let grandparent = path.count >= 2 ? path[path.count - 2] : nil
            switch name {
            case "encrypteddata":
                algorithm = nil
                references = []
            case "encryptionmethod" where parent == "encrypteddata":
                // Only the method that is a direct child counts. A key inside
                // KeyInfo carries its own EncryptionMethod, which describes how
                // the key was wrapped rather than how the file was.
                algorithm = attributes["Algorithm"] ?? attributes["algorithm"]
            case "cipherreference" where parent == "cipherdata" && grandparent == "encrypteddata":
                if let uri = attributes["URI"] ?? attributes["uri"] { references.append(uri) }
            default:
                break
            }
            path.append(name)
        }

        func parser(_ parser: XMLParser, didEndElement element: String,
                    namespaceURI: String?, qualifiedName: String?) {
            if !path.isEmpty { path.removeLast() }
            if element.lowercased() == "encrypteddata" {
                items += references.map { Item(algorithm: algorithm, uri: $0) }
                references = []
            }
        }
    }
}

/// Resolves the references inside an EPUB to entry names in its archive.
enum EPUBPath {

    /// The archive path a reference points at, or nil when it points outside
    /// the book.
    ///
    /// References in the markup are URLs relative to the file they appear in,
    /// so they arrive percent-encoded ("a%20figure.png") and climb out of their
    /// own folder ("../images/a.png"). NSString's standardizingPath looks as if
    /// it handles that, but it only resolves ".." in absolute paths, and every
    /// path inside a ZIP is relative: "Text/../images/a.png" came back
    /// unchanged and matched nothing.
    static func resolve(_ reference: String, against directory: String) -> String? {
        var href = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = href.firstIndex(of: "#") { href = String(href[..<hash]) }
        if let query = href.firstIndex(of: "?") { href = String(href[..<query]) }
        guard !href.isEmpty else { return nil }

        // A scheme means the target lives somewhere other than the archive: a
        // web address, or a data: URI holding the picture inline. Neither is a
        // file this reader can open.
        if let colon = href.firstIndex(of: ":") {
            let scheme = href[..<colon]
            if !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) {
                return nil
            }
        }

        let decoded = href.removingPercentEncoding ?? href
        var parts: [Substring] = decoded.hasPrefix("/") ? [] : directory.split(separator: "/")
        for component in decoded.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                // One level too many is a slip in the book, not a reason to
                // lose the file: the archive has no parent folder to climb to.
                if !parts.isEmpty { parts.removeLast() }
            default:
                parts.append(component)
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// The folder a path sits in, which is what its own references are
    /// relative to.
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

/// Turns markup into the blocks a chapter is made of: paragraphs, headings
/// and pictures.
///
/// Hand-rolled rather than XML-parsed on purpose: real EPUB content is often
/// only approximately well formed, and a strict parser would refuse whole
/// chapters over a stray attribute. This only needs to know where paragraphs
/// end, which elements are titles or pictures, and which to ignore.
enum HTMLText {

    /// A picture in a chapter, found by its path inside the archive.
    struct Picture: Equatable {
        var path: String
        var alt: String
        var caption: String
    }

    enum Block: Equatable {
        case paragraph(String)
        /// h1 is level 1 and h6 is level 6.
        case heading(String, level: Int)
        case picture(Picture)
    }

    /// Elements whose closing tag ends a paragraph.
    private static let blockElements: Set<String> = [
        "p", "div", "li", "blockquote",
        "section", "article", "tr", "td", "th", "figcaption", "pre", "dd", "dt",
        "header", "footer", "aside", "nav", "table", "ul", "ol", "dl", "hr",
    ]

    private static let headingElements: [String: Int] = [
        "h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6,
    ]

    /// Elements whose contents are not prose and must not be read out.
    private static let skippedElements: Set<String> = ["script", "style", "head", "title"]

    /// Marks where one line of a heading ends and the next begins, until the
    /// lines are joined. A control character, so it can never come from text.
    private static let headingLineBreak = "\u{1F}"

    /// A title this long is markup being used for its looks: some books set
    /// an epigraph or a chapter summary in an h3. Read as a heading it would
    /// become one enormous title card, so it is read as prose instead.
    private static let longestHeadingWords = 24

    /// The blocks of one XHTML document, in reading order.
    ///
    /// - Parameter directory: the archive folder the document sits in. Picture
    ///   references are relative to it, which is how "../images/a.png" becomes
    ///   a path that can be opened.
    static func blocks(in html: String, directory: String) -> [Block] {
        var blocks: [Block] = []
        var current = ""
        var skipUntil: String?
        var index = html.startIndex

        // Inside a heading, text gathers in `current` like a paragraph's but
        // is flushed as a title.
        var headingLevel: Int?
        // A paragraph whose class says it is a caption, which is how books
        // without HTML5's figcaption label the line under a picture.
        var currentIsCaption = false
        // Pictures met while a paragraph was open. They are emitted once it
        // ends, so a picture in the middle of a sentence never cuts it in two.
        var pending: [Picture] = []
        // Inline SVG is drawing, not prose. Its only useful content is an
        // <image> pointing at a bitmap, which is how most tools wrap a cover.
        var svgDepth = 0
        // <figure>, which binds its pictures to its caption.
        var figureDepth = 0
        var figurePictures: [Picture] = []
        var figureCaption = ""
        var figureFirstBlock = 0
        var inFigcaption = false

        func appendText<S: StringProtocol>(_ text: S) {
            guard skipUntil == nil, svgDepth == 0 else { return }
            if inFigcaption { figureCaption += text } else { current += text }
        }

        func emitPending() {
            blocks.append(contentsOf: pending.map(Block.picture))
            pending = []
        }

        func flushHeading() {
            let level = headingLevel ?? 1
            headingLevel = nil
            let lines = current.components(separatedBy: headingLineBreak)
                .map { collapse(decodeEntities($0)) }
                .filter { !$0.isEmpty }
            current = ""
            currentIsCaption = false
            if let title = joinTitleLines(lines) {
                if Chunker.wordCount(title) > longestHeadingWords {
                    blocks.append(.paragraph(title))
                } else {
                    blocks.append(.heading(title, level: level))
                }
            }
            emitPending()
        }

        func flush() {
            if headingLevel != nil { flushHeading(); return }
            let text = collapse(decodeEntities(current))
            if text.count > 1 {
                if case .picture(var picture)? = blocks.last, picture.caption.isEmpty,
                   currentIsCaption || looksLikeCaption(text) {
                    picture.caption = text
                    blocks[blocks.count - 1] = .picture(picture)
                } else {
                    blocks.append(.paragraph(text))
                }
            }
            current = ""
            currentIsCaption = false
            emitPending()
        }

        func closeFigure() {
            flush()
            let caption = collapse(decodeEntities(figureCaption))
            if !figurePictures.isEmpty {
                // One caption under several pictures describes them as a
                // group, so it goes under the last, where it is read after
                // seeing them all.
                if caption.count > 1 { figurePictures[figurePictures.count - 1].caption = caption }
                blocks.append(contentsOf: figurePictures.map(Block.picture))
            } else if caption.count > 1 {
                // A figure with no picture is usually a quotation with its
                // source as the caption. Standing alone, the source became a
                // one-word "new section" card; it belongs with the quotation.
                if blocks.count > figureFirstBlock, case .paragraph(let text)? = blocks.last {
                    blocks[blocks.count - 1] = .paragraph(text + " " + caption)
                } else {
                    blocks.append(.paragraph(caption))
                }
            }
            figurePictures = []
            figureCaption = ""
            inFigcaption = false
        }

        while index < html.endIndex {
            guard let open = html.range(of: "<", range: index..<html.endIndex) else {
                appendText(html[index...])
                break
            }
            appendText(html[index..<open.lowerBound])

            // A comment is skipped whole. Taking it only as far as the first
            // ">" read the rest of a comment holding markup as text, and its
            // closing "-->" turned up as a card of its own.
            if html[open.lowerBound...].hasPrefix("<!--") {
                guard let end = html.range(of: "-->", range: open.upperBound..<html.endIndex) else { break }
                index = end.upperBound
                continue
            }

            guard let close = html.range(of: ">", range: open.upperBound..<html.endIndex) else { break }
            let tag = String(html[open.upperBound..<close.lowerBound])
            let isClosing = tag.hasPrefix("/")
            let isEmptyElement = tag.hasSuffix("/")
            let name = tag.drop(while: { $0 == "/" })
                .prefix(while: { !$0.isWhitespace && $0 != "/" })
                .lowercased()
            index = close.upperBound

            if let skipped = skipUntil {
                if isClosing, name == skipped { skipUntil = nil }
                continue
            }
            if skippedElements.contains(name) {
                // An empty <title/> has nothing to skip, and waiting for its
                // closing tag would swallow the rest of the chapter.
                if !isClosing, !isEmptyElement { skipUntil = name }
                continue
            }

            if name == "svg" {
                if isClosing { svgDepth = max(0, svgDepth - 1) } else if !isEmptyElement { svgDepth += 1 }
                continue
            }

            if name == "img" || name == "image" {
                guard !isClosing else { continue }
                let attributes = attributes(in: tag)
                let reference = attributes["src"] ?? attributes["xlink:href"] ?? attributes["href"] ?? ""
                let alt = collapse(decodeEntities(attributes["alt"] ?? ""))

                // A picture glued to the letters after it is part of a word:
                // a decorated initial drawn as an image, whose alt text is
                // the letter it stands for. Shown as a figure, the paragraph
                // would open "his book was written" with a picture of a T
                // somewhere after it.
                let next = character(after: close.upperBound, in: html)
                if svgDepth == 0, next?.isLetter == true, (1...3).contains(alt.count), alt.allSatisfy(\.isLetter) {
                    appendText(alt)
                    continue
                }

                guard let path = EPUBPath.resolve(decodeEntities(reference), against: directory) else { continue }
                let picture = Picture(path: path, alt: alt, caption: "")
                if figureDepth > 0 {
                    figurePictures.append(picture)
                } else {
                    pending.append(picture)
                }
                continue
            }

            // Everything inside an SVG apart from its pictures is drawing.
            if svgDepth > 0 { continue }

            if name == "br" {
                // A line break inside a paragraph, not a new paragraph. Older
                // Gutenberg files wrap every printed line in one, and flushing
                // here cut a sentence at every line of the original book.
                // Inside a heading it does separate two lines of the title.
                if headingLevel != nil { current += headingLineBreak } else { appendText(" ") }
                continue
            }

            if let level = headingElements[name] {
                if isClosing {
                    if headingLevel != nil { flushHeading() }
                } else {
                    flush()
                    headingLevel = level
                }
                continue
            }

            if name == "figure" {
                if isClosing {
                    guard figureDepth > 0 else { continue }
                    figureDepth -= 1
                    if figureDepth == 0 { closeFigure() }
                } else if !isEmptyElement {
                    if figureDepth == 0 {
                        flush()
                        figureFirstBlock = blocks.count
                    }
                    figureDepth += 1
                }
                continue
            }

            if name == "figcaption", figureDepth > 0 {
                if isClosing {
                    inFigcaption = false
                } else {
                    flush()
                    if !figureCaption.isEmpty { figureCaption += " " }
                    inFigcaption = true
                }
                continue
            }

            guard blockElements.contains(name) else { continue }

            if headingLevel != nil {
                // A paragraph cannot sit inside a heading, so one starting
                // means the heading was never closed. Any other block is a
                // line of the title, laid out with block markup.
                if name == "p", !isClosing {
                    flushHeading()
                } else {
                    current += headingLineBreak
                    continue
                }
            }
            if inFigcaption {
                figureCaption += " "
                continue
            }

            // A caption's class is often on a wrapper around the paragraph
            // that holds its words, so it carries into a block that opens
            // before the wrapper has any text of its own.
            let carriesCaption = currentIsCaption && !isClosing && current.allSatisfy(\.isWhitespace)
            // Both ends: an unclosed <p> is extremely common in the wild.
            flush()
            if !isClosing, !isEmptyElement {
                currentIsCaption = carriesCaption
                    || (attributes(in: tag)["class"] ?? "").lowercased().contains("caption")
            }
        }
        if figureDepth > 0 { closeFigure() }
        flush()
        return joinChapterHeadings(blocks)
    }

    // MARK: - Headings

    /// "Chapter One" followed by "The Water Cycle" is one title set in two
    /// sizes. As two cards it reads as two sections, the first with nothing in
    /// it; joined, the label and the name make the single title the page shows.
    private static func joinChapterHeadings(_ blocks: [Block]) -> [Block] {
        var result: [Block] = []
        for block in blocks {
            if case .heading(let title, _) = block,
               case .heading(let label, let level)? = result.last,
               isChapterLabel(label), !isChapterLabel(title),
               let joined = joinTitleLines([label, title]),
               Chunker.wordCount(joined) <= longestHeadingWords {
                result[result.count - 1] = .heading(joined, level: level)
            } else {
                result.append(block)
            }
        }
        return result
    }

    /// The lines of one title as a single line: "Chapter One: The Water
    /// Cycle", "II. Rain and Rivers", or the lines simply run together when
    /// the first is not a chapter label.
    private static func joinTitleLines(_ lines: [String]) -> String? {
        guard var title = lines.first else { return nil }
        for line in lines.dropFirst() {
            if isChapterLabel(title), !isChapterLabel(line) {
                var label = title
                while let last = label.last, ".:".contains(last) { label.removeLast() }
                let bare = label.lowercased()
                let isNumeral = bare.allSatisfy(\.isNumber) || isRomanNumeral(bare)
                title = label + (isNumeral ? ". " : ": ") + line
            } else {
                title += " " + line
            }
        }
        return title
    }

    private static let labelWords: Set<String> = [
        "chapter", "chap", "ch", "part", "book", "volume", "vol", "section",
        "act", "scene", "canto", "letter", "lecture", "lesson", "unit",
        "appendix", "stave", "episode",
    ]

    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh",
        "eighth", "ninth", "tenth",
    ]

    /// Whether a heading only says which chapter this is, without naming it:
    /// "1", "XII", "Chapter One", "CHAPTER 4.", "Part the Second", "Prologue".
    static func isChapterLabel(_ heading: String) -> Bool {
        var text = heading.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".:".contains(last) { text.removeLast() }
        guard !text.isEmpty, text.count <= 40 else { return false }
        if ["prologue", "epilogue", "interlude"].contains(text) { return true }

        var words = text.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".:")) }
            .filter { !$0.isEmpty }
        if let first = words.first, labelWords.contains(first) { words.removeFirst() }
        // "Part the Second": the article only ever appears before a number.
        if words.first == "the", words.count > 1 { words.removeFirst() }
        guard !words.isEmpty, words.count <= 3 else { return false }
        return words.allSatisfy { word in
            // Three digits at most: "1984" on its own is a title, not a chapter.
            if word.allSatisfy(\.isNumber) { return word.count <= 3 }
            return isRomanNumeral(word) || numberWords.contains(word)
        }
    }

    /// A well-formed roman numeral, so that a title like "Civil" or "Mild",
    /// spelled only with the letters numerals use, is not taken for one.
    private static func isRomanNumeral(_ word: String) -> Bool {
        guard !word.isEmpty, word.count <= 12 else { return false }
        return word.range(of: "^m{0,4}(cm|cd|d?c{0,3})(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$",
                          options: .regularExpression) != nil
    }

    // MARK: - Captions and attributes

    /// The first character of text after a position, looking past closing
    /// tags. A decorated initial is usually wrapped, as in
    /// `<span class="dropcap"><img alt="T"/></span>his`, and the letter it
    /// belongs to only comes after the wrapper closes.
    private static func character(after position: String.Index, in html: String) -> Character? {
        var index = position
        for _ in 0..<4 {
            guard index < html.endIndex else { return nil }
            guard html[index...].hasPrefix("</"),
                  let end = html[index...].firstIndex(of: ">") else { return html[index] }
            index = html.index(after: end)
        }
        return index < html.endIndex ? html[index] : nil
    }

    /// A line that labels the picture above it, written as running text
    /// rather than marked up: "Figure 3. ...", "Plate IV: ...", "Fig. 2.1 ...".
    ///
    /// The number has to be followed by punctuation. "Figure 3 shows the
    /// results" straight after a picture is the prose discussing it, and
    /// taking it for the caption would move it out of the reading.
    private static func looksLikeCaption(_ text: String) -> Bool {
        guard Chunker.wordCount(text) <= 60 else { return false }
        return text.range(of: "^(figure|fig\\.|plate|illustration|map|diagram)\\s+([0-9]+(\\.[0-9]+)*|[ivxlc]+)\\s*[.:\u{2013}\u{2014}-]",
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The attributes of a tag, by lowercased name. Values come in double
    /// quotes, single quotes or none, and all three turn up in real books.
    static func attributes(in tag: String) -> [String: String] {
        var result: [String: String] = [:]
        var i = tag.startIndex
        // Past the element's own name.
        while i < tag.endIndex, tag[i] == "/" { i = tag.index(after: i) }
        while i < tag.endIndex, !tag[i].isWhitespace, tag[i] != "/" { i = tag.index(after: i) }

        while i < tag.endIndex {
            while i < tag.endIndex, tag[i].isWhitespace || tag[i] == "/" { i = tag.index(after: i) }
            let nameStart = i
            while i < tag.endIndex, !tag[i].isWhitespace, tag[i] != "=", tag[i] != "/" {
                i = tag.index(after: i)
            }
            let name = tag[nameStart..<i].lowercased()
            while i < tag.endIndex, tag[i].isWhitespace { i = tag.index(after: i) }
            guard !name.isEmpty else {
                if i < tag.endIndex { i = tag.index(after: i) }
                continue
            }
            guard i < tag.endIndex, tag[i] == "=" else {
                if result[name] == nil { result[name] = "" }
                continue
            }
            i = tag.index(after: i)
            while i < tag.endIndex, tag[i].isWhitespace { i = tag.index(after: i) }
            guard i < tag.endIndex else { break }

            let value: Substring
            if tag[i] == "\"" || tag[i] == "'" {
                let quote = tag[i]
                let valueStart = tag.index(after: i)
                let valueEnd = tag[valueStart...].firstIndex(of: quote) ?? tag.endIndex
                value = tag[valueStart..<valueEnd]
                i = valueEnd < tag.endIndex ? tag.index(after: valueEnd) : valueEnd
            } else {
                let valueStart = i
                while i < tag.endIndex, !tag[i].isWhitespace { i = tag.index(after: i) }
                value = tag[valueStart..<i]
            }
            if result[name] == nil { result[name] = String(value) }
        }
        return result
    }

    /// Markup stripped down to its text, for a single label.
    static func plain(_ html: String) -> String {
        var result = ""
        var index = html.startIndex
        while index < html.endIndex {
            guard let open = html.range(of: "<", range: index..<html.endIndex) else {
                result += html[index...]
                break
            }
            result += html[index..<open.lowerBound]
            guard let close = html.range(of: ">", range: open.upperBound..<html.endIndex) else { break }
            index = close.upperBound
        }
        return collapse(decodeEntities(result))
    }

    private static func collapse(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}",
        "rdquo": "\u{201D}", "hellip": "\u{2026}", "eacute": "é",
        "egrave": "è", "agrave": "à", "ccedil": "ç", "uuml": "ü",
        "ouml": "ö", "auml": "ä", "szlig": "ß", "pound": "£", "euro": "€",
        "copy": "©", "deg": "°", "middot": "\u{00B7}", "shy": "",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard let ampersand = text.range(of: "&", range: index..<text.endIndex) else {
                result += text[index...]
                break
            }
            result += text[index..<ampersand.lowerBound]

            // An entity is short; anything longer is a stray ampersand.
            let limit = text.index(ampersand.upperBound, offsetBy: 10, limitedBy: text.endIndex) ?? text.endIndex
            guard let semicolon = text.range(of: ";", range: ampersand.upperBound..<limit) else {
                result += "&"
                index = ampersand.upperBound
                continue
            }

            let body = String(text[ampersand.upperBound..<semicolon.lowerBound])
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let value: UInt32?
                if digits.lowercased().hasPrefix("x") {
                    value = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    value = UInt32(digits)
                }
                if let value, let scalar = Unicode.Scalar(value) {
                    result.append(Character(scalar))
                } else {
                    result += "&\(body);"
                }
            } else if let replacement = namedEntities[body.lowercased()] {
                result += replacement
            } else {
                result += "&\(body);"
            }
            index = semicolon.upperBound
        }
        return result
    }
}
