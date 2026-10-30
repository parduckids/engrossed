import Foundation
import ImageIO

/// Reads an EPUB into the same shape the chunker already understands.
///
/// EPUB is much kinder than PDF: it is a ZIP of XHTML, so the paragraphs are
/// marked up rather than inferred from ink on a page. There is no geometry to
/// reverse-engineer, no hyphens to heal and no running heads to strip. The work
/// is finding the reading order and turning markup into paragraphs, headings
/// and pictures.
///
/// A "page" here is one document in the spine, which for most books is one
/// chapter. That keeps everything downstream, including the contents list and
/// the saved position, working unchanged.
enum EPUBExtractor {

    struct Book {
        var pages: [Chunker.Page]
        var title: String?
        var author: String?
        /// Title and spine index, for the contents list.
        var contents: [(title: String, page: Int, depth: Int)]
    }

    enum Failure: LocalizedError {
        case notAnArchive, noPackage, noReadableText, copyProtected

        var errorDescription: String? {
            switch self {
            case .notAnArchive:
                return "This EPUB couldn’t be opened. The file may be damaged."
            case .noPackage:
                return "This EPUB is missing its package file, so there is no way to tell what order to read it in."
            case .noReadableText:
                return "No readable text was found in this EPUB."
            case .copyProtected:
                return "This EPUB is copy-protected (DRM), so its text can’t be read."
            }
        }
    }

    /// Below this many pixels on either side, a picture is decoration rather
    /// than illustration: a spacer, a rule, a bullet. Books are full of them,
    /// and each one would otherwise be a card of its own.
    static let smallestPicture = 24

    /// A picture used this many times is an ornament: the flourish at every
    /// scene break, the device at the head of every chapter. An illustration
    /// appears once.
    static let ornamentUses = 3

    static func read(_ url: URL) throws -> Book {
        guard let archive = ZipArchive(url: url) else { throw Failure.notAnArchive }
        guard let packagePath = packagePath(in: archive) else { throw Failure.noPackage }
        guard let packageData = archive.contents(of: packagePath) else { throw Failure.noPackage }

        let root = EPUBPath.directory(of: packagePath)
        let package = PackageParser.parse(packageData)
        let spine = package.spine.compactMap { id in
            package.manifest[id].flatMap { locate($0, from: root, in: archive) }
        }

        // A book sold with DRM is a perfectly valid ZIP whose chapters are
        // ciphertext. Read anyway, it imported "successfully" and showed a
        // card of random symbols, which looks like a bug in this app rather
        // than a property of the file. Saying so up front is the honest answer,
        // and the only one that tells the reader what to do instead.
        let locked = encryptedPaths(in: archive)
        if spine.contains(where: { locked.contains($0) }) { throw Failure.copyProtected }

        var documents: [(path: String, blocks: [HTMLText.Block])] = []

        // A real book is a few megabytes of prose. The spine, though, is only a
        // list of idrefs: nothing stops one file being named a thousand times,
        // and nothing stops a thousand different files each being enormous. The
        // per-entry ceiling in ZipArchive bounds one chapter and never the sum,
        // so a 6 KB file could expand until the device ran out of memory, on the
        // main thread, while the reader watched an import spinner.
        let byteBudget = 32 * 1024 * 1024
        var used = 0
        var alreadyRead = Set<String>()
        var unreadable = 0

        for path in spine {
            guard used < byteBudget else { break }
            // The same file listed twice in the spine is read once.
            guard alreadyRead.insert(path).inserted else { continue }
            // The declared size is what the inflater writes into, so checking it
            // first stops one chapter overshooting the budget by the whole of
            // ZipArchive's own per-entry ceiling.
            //
            // The first entry is exempt on purpose: a legitimate book that
            // inlines its images as data URIs inside a single XHTML file has
            // huge markup and ordinary prose, and refusing it here would throw
            // noReadableText and reject the book outright.
            let declared = archive.entries[path]?.uncompressedSize ?? 0
            if !documents.isEmpty, used + declared > byteBudget { continue }
            guard let contents = archive.contents(of: path) else { continue }
            guard let html = markup(from: contents) else {
                unreadable += 1
                continue
            }
            let blocks = HTMLText.blocks(in: html, directory: EPUBPath.directory(of: path))
            guard !blocks.isEmpty else { continue }
            used += contents.count
            documents.append((path, blocks))
        }

        // The encryption manifest is the proper signal, but it can be missing
        // or written in a way the parser above does not recognise. A chapter
        // that is not text at all, in a book that carries rights-management
        // files, is the same lock seen from the other side.
        if unreadable > 0, !locked.isEmpty || hasRightsManagement(archive) { throw Failure.copyProtected }

        let pictures = PictureFilter(archive: archive, documents: documents, locked: locked)

        // A document with no text of its own (a cover, a frontispiece, a plate
        // between chapters) joins the next document that has some, rather than
        // becoming a page of its own. Its pictures are kept either way; what
        // this protects is the numbering. Pages are what a saved place falls
        // back on when cards are re-cut, and an update that suddenly counted
        // the cover and every plate as pages would move each reader's place
        // back by however many of them came before it.
        var pages: [Chunker.Page] = []
        var pageOfFile: [String: Int] = [:]
        var waiting: [Chunker.Block] = []
        var waitingFiles: [String] = []

        for document in documents {
            let blocks = document.blocks.compactMap(pictures.block(for:))
            guard hasText(document.blocks) else {
                waiting += blocks
                waitingFiles.append(document.path)
                continue
            }
            let index = pages.count
            pages.append(Chunker.Page(pageIndex: index, blocks: waiting + blocks))
            for file in waitingFiles + [document.path] { pageOfFile[file] = index }
            waiting = []
            waitingFiles = []
        }

        // A back cover or a closing plate has no later text to join, so it
        // goes at the end of the last page that has some.
        if let last = pages.indices.last, !waitingFiles.isEmpty {
            pages[last] = Chunker.Page(pageIndex: last, blocks: pages[last].blocks + waiting)
            for file in waitingFiles { pageOfFile[file] = last }
        }

        guard !pages.isEmpty else { throw Failure.noReadableText }

        return Book(pages: pages,
                    title: package.title,
                    author: package.author,
                    contents: contents(in: archive, package: package, root: root, pageOfFile: pageOfFile))
    }

    /// Whether a document has anything to read. A caption counts, because it
    /// was read as a paragraph before pictures were, and a document that had
    /// a page then must keep it now.
    private static func hasText(_ blocks: [HTMLText.Block]) -> Bool {
        blocks.contains {
            switch $0 {
            case .paragraph, .heading: return true
            case .picture(let picture): return !picture.caption.isEmpty
            }
        }
    }

    // MARK: - Pictures

    /// Decides which pictures in a book are worth a card, and measures them.
    private struct PictureFilter {
        let archive: ZipArchive
        let locked: Set<String>
        private var uses: [String: Int] = [:]
        private var sizes: [String: (width: Int, height: Int)] = [:]

        init(archive: ZipArchive, documents: [(path: String, blocks: [HTMLText.Block])], locked: Set<String>) {
            self.archive = archive
            self.locked = locked
            var measured = Set<String>()
            for document in documents {
                for case .picture(let picture) in document.blocks {
                    let name = archive.name(matching: picture.path) ?? picture.path
                    uses[name, default: 0] += 1
                    // Measured once, however often it is used, and never if
                    // it is locked: its header is ciphertext too.
                    guard measured.insert(name).inserted, !locked.contains(name) else { continue }
                    sizes[name] = EPUBExtractor.pictureSize(of: name, in: archive)
                }
            }
        }

        /// The block a parsed block becomes. A picture that is not kept gives
        /// back its caption as a paragraph, so no words are lost with it.
        func block(for block: HTMLText.Block) -> Chunker.Block? {
            switch block {
            case .paragraph(let text):
                return .paragraph(text)
            case .heading(let title, _):
                return .heading(title)
            case .picture(let picture):
                if let image = keep(picture) { return .picture(image) }
                return picture.caption.isEmpty ? nil : .paragraph(picture.caption)
            }
        }

        private func keep(_ picture: HTMLText.Picture) -> EmbeddedImage? {
            let name = archive.name(matching: picture.path) ?? picture.path
            // Missing, encrypted, or in a format the system cannot decode
            // (an SVG file, most often): there is nothing to show.
            guard !locked.contains(name), let size = sizes[name] else { return nil }
            guard min(size.width, size.height) >= EPUBExtractor.smallestPicture else { return nil }
            if picture.caption.isEmpty, uses[name, default: 0] >= EPUBExtractor.ornamentUses { return nil }
            return EmbeddedImage(path: name, alt: picture.alt, caption: picture.caption,
                                 pixelWidth: size.width, pixelHeight: size.height)
        }
    }

    /// A picture's displayed size in pixels, read from its header.
    ///
    /// Only the front of the file is inflated: the header is all ImageIO needs
    /// for the size, and decoding every illustration in full just to measure
    /// it would make importing a picture book as slow as drawing it.
    static func pictureSize(of name: String, in archive: ZipArchive) -> (width: Int, height: Int)? {
        guard let head = archive.prefix(of: name, maxBytes: 64 * 1024) else { return nil }
        if let size = pixelSize(of: head) { return size }
        // A JPEG can carry a thumbnail or colour profile ahead of the frame
        // header, past the part read above. Those are rare enough to read
        // whole, within reason.
        guard let entry = archive.entries[name], entry.uncompressedSize > head.count,
              entry.uncompressedSize <= 16 * 1024 * 1024,
              let whole = archive.contents(of: name) else { return nil }
        return pixelSize(of: whole)
    }

    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        // EXIF orientations 5 to 8 turn the picture on its side, and the card
        // shows it upright.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            return (height, width)
        }
        return (width, height)
    }

    // MARK: - Copy protection

    /// The two schemes that only scramble embedded fonts, so a font file
    /// cannot be lifted out of the book. The text is untouched, and books
    /// from perfectly ordinary publishers use them.
    private static let fontObfuscation: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]

    /// Archive paths listed in META-INF/encryption.xml under anything other
    /// than font obfuscation.
    static func encryptedPaths(in archive: ZipArchive) -> Set<String> {
        guard let name = archive.name(matching: "META-INF/encryption.xml"),
              let data = archive.contents(of: name) else { return [] }
        var paths = Set<String>()
        for item in EncryptionParser.parse(data) {
            // No algorithm at all is not something an honest file does, and
            // reading ciphertext as prose is the worse mistake.
            if let algorithm = item.algorithm, fontObfuscation.contains(algorithm) { continue }
            // References are relative to the root of the container.
            guard let path = EPUBPath.resolve(item.uri, against: "") else { continue }
            paths.insert(archive.name(matching: path) ?? path)
        }
        return paths
    }

    /// The licence files the main DRM schemes leave beside the book: Adobe's,
    /// Readium LCP's and Apple's. An encryption.xml alone is not evidence,
    /// since ordinary books carry one just for their obfuscated fonts.
    private static func hasRightsManagement(_ archive: ZipArchive) -> Bool {
        ["META-INF/rights.xml", "META-INF/license.lcpl", "META-INF/sinf.xml"]
            .contains { archive.name(matching: $0) != nil }
    }

    /// The markup of a content document, or nil when the bytes are not text.
    ///
    /// Ciphertext, or any other binary, is full of control bytes that text
    /// never contains, so a small sample is enough to tell them apart.
    static func markup(from data: Data) -> String? {
        let head = [UInt8](data.prefix(2))
        if head == [0xFF, 0xFE] || head == [0xFE, 0xFF] {
            return String(data: data, encoding: .utf16)
        }
        let sample = data.prefix(2048)
        let control = sample.reduce(0) { count, byte in
            count + ((byte < 0x09 || (byte > 0x0D && byte < 0x20)) ? 1 : 0)
        }
        guard control * 50 <= sample.count else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Finding the package

    private static func packagePath(in archive: ZipArchive) -> String? {
        if let container = archive.contents(of: "META-INF/container.xml"),
           let path = firstAttribute(named: "full-path", ofElement: "rootfile",
                                     in: String(decoding: container, as: UTF8.self)) {
            return path
        }
        // Some older files have a container that cannot be parsed. Fall back to
        // whatever .opf is in the archive rather than refusing the book.
        return archive.order.first { $0.lowercased().hasSuffix(".opf") }
    }

    /// The archive entry a reference names, as the archive spells it.
    private static func locate(_ href: String, from directory: String, in archive: ZipArchive) -> String? {
        guard let path = EPUBPath.resolve(href, against: directory) else { return nil }
        return archive.name(matching: path) ?? path
    }

    // MARK: - Contents

    private static func contents(in archive: ZipArchive, package: PackageParser.Package,
                                 root: String, pageOfFile: [String: Int]) -> [(String, Int, Int)] {
        // EPUB 3 keeps the contents in a nav document; EPUB 2 in an NCX. Try
        // both, because plenty of files in the wild carry one or the other.
        var candidates: [String] = []
        if let nav = package.navigationHref, let path = locate(nav, from: root, in: archive) {
            candidates.append(path)
        }
        if let ncx = package.ncxHref, let path = locate(ncx, from: root, in: archive) {
            candidates.append(path)
        }

        for path in candidates {
            guard let data = archive.contents(of: path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let directory = EPUBPath.directory(of: path)
            let entries = path.lowercased().hasSuffix(".ncx")
                ? NavigationParser.parseNCX(text)
                : NavigationParser.parseNav(text)

            var result: [(String, Int, Int)] = []
            for entry in entries {
                guard let target = locate(entry.href, from: directory, in: archive),
                      let page = pageOfFile[target] else { continue }
                result.append((entry.title, page, entry.depth))
            }
            if !result.isEmpty { return result }
        }
        return []
    }

    // MARK: - Small XML helper

    /// Pulls one attribute out of the first matching element. Enough for
    /// container.xml, and far less machinery than a full parse.
    private static func firstAttribute(named attribute: String, ofElement element: String,
                                       in xml: String) -> String? {
        guard let elementRange = xml.range(of: "<\(element)", options: .caseInsensitive) else { return nil }
        let rest = xml[elementRange.upperBound...]
        guard let close = rest.firstIndex(of: ">") else { return nil }
        let tag = String(rest[..<close])
        guard let attributeRange = tag.range(of: "\(attribute)=", options: .caseInsensitive) else { return nil }
        let afterEquals = tag[attributeRange.upperBound...]
        guard let quote = afterEquals.first, quote == "\"" || quote == "'" else { return nil }
        let value = afterEquals.dropFirst()
        guard let end = value.firstIndex(of: quote) else { return nil }
        return String(value[..<end])
    }
}
