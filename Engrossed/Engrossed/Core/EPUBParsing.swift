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

/// Turns markup into plain paragraphs.
///
/// Hand-rolled rather than XML-parsed on purpose: real EPUB content is often
/// only approximately well formed, and a strict parser would refuse whole
/// chapters over a stray attribute. This only needs to know where paragraphs
/// end and which elements to ignore.
enum HTMLText {

    /// Elements whose closing tag ends a paragraph.
    private static let blockElements: Set<String> = [
        "p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote",
        "section", "article", "tr", "td", "th", "figcaption", "pre", "dd", "dt",
    ]

    /// Elements whose contents are not prose and must not be read out.
    private static let skippedElements: Set<String> = ["script", "style", "head", "title"]

    static func paragraphs(in html: String) -> [String] {
        var paragraphs: [String] = []
        var current = ""
        var skipUntil: String?
        var index = html.startIndex

        func flush() {
            let text = collapse(decodeEntities(current))
            if text.count > 1 { paragraphs.append(text) }
            current = ""
        }

        while index < html.endIndex {
            guard let open = html.range(of: "<", range: index..<html.endIndex) else {
                if skipUntil == nil { current += html[index...] }
                break
            }

            if skipUntil == nil { current += html[index..<open.lowerBound] }

            guard let close = html.range(of: ">", range: open.upperBound..<html.endIndex) else { break }
            let tag = String(html[open.upperBound..<close.lowerBound])
            let isClosing = tag.hasPrefix("/")
            let name = tag.drop(while: { $0 == "/" })
                .prefix(while: { !$0.isWhitespace && $0 != "/" })
                .lowercased()

            if let skipped = skipUntil {
                if isClosing, name == skipped { skipUntil = nil }
            } else if skippedElements.contains(name), !isClosing {
                skipUntil = name
            } else if name == "br" {
                // A line break inside a paragraph, not a new paragraph. Older
                // Gutenberg files wrap every printed line in one, and flushing
                // here cut a sentence at every line of the original book.
                current += " "
            } else if blockElements.contains(name) {
                // Both ends: an unclosed <p> is extremely common in the wild.
                flush()
            }

            index = close.upperBound
        }
        flush()
        return paragraphs
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
