import Foundation

/// Reads an EPUB into the same shape the chunker already understands.
///
/// EPUB is much kinder than PDF: it is a ZIP of XHTML, so the paragraphs are
/// marked up rather than inferred from ink on a page. There is no geometry to
/// reverse-engineer, no hyphens to heal and no running heads to strip. The work
/// is finding the reading order and turning markup into plain paragraphs.
///
/// A "page" here is one document in the spine, which for most books is one
/// chapter. That keeps everything downstream, including the contents list and
/// the saved position, working unchanged.
enum EPUBExtractor {

    struct Book {
        var pages: [TextExtractor.PageText]
        var title: String?
        var author: String?
        /// Title and spine index, for the contents list.
        var contents: [(title: String, page: Int, depth: Int)]
    }

    enum Failure: LocalizedError {
        case notAnArchive, noPackage, noReadableText

        var errorDescription: String? {
            switch self {
            case .notAnArchive:
                return "This EPUB couldn’t be opened. The file may be damaged."
            case .noPackage:
                return "This EPUB is missing its package file, so there is no way to tell what order to read it in."
            case .noReadableText:
                return "No readable text was found in this EPUB."
            }
        }
    }

    static func read(_ url: URL) throws -> Book {
        guard let archive = ZipArchive(url: url) else { throw Failure.notAnArchive }
        guard let packagePath = packagePath(in: archive) else { throw Failure.noPackage }
        guard let packageData = archive.contents(of: packagePath) else { throw Failure.noPackage }

        let root = (packagePath as NSString).deletingLastPathComponent
        let package = PackageParser.parse(packageData)

        var pages: [TextExtractor.PageText] = []
        var spineFiles: [String] = []

        // A real book is a few megabytes of prose. The spine, though, is only a
        // list of idrefs: nothing stops one file being named a thousand times,
        // and nothing stops a thousand different files each being enormous. The
        // per-entry ceiling in ZipArchive bounds one chapter and never the sum,
        // so a 6 KB file could expand until the device ran out of memory, on the
        // main thread, while the reader watched an import spinner.
        let byteBudget = 32 * 1024 * 1024
        var used = 0
        var alreadyRead = Set<String>()

        for id in package.spine {
            guard used < byteBudget else { break }
            guard let href = package.manifest[id] else { continue }
            let path = resolve(href, relativeTo: root)
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
            if !pages.isEmpty, used + declared > byteBudget { continue }
            guard let contents = archive.contents(of: path) else { continue }
            let html = String(decoding: contents, as: UTF8.self)
            let paragraphs = HTMLText.paragraphs(in: html)
            guard !paragraphs.isEmpty else { continue }
            used += contents.count
            spineFiles.append(path)
            pages.append(TextExtractor.PageText(pageIndex: pages.count, paragraphs: paragraphs))
        }

        guard !pages.isEmpty else { throw Failure.noReadableText }

        return Book(pages: pages,
                    title: package.title,
                    author: package.author,
                    contents: contents(in: archive, package: package, root: root, spineFiles: spineFiles))
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

    private static func resolve(_ href: String, relativeTo root: String) -> String {
        let clean = href.components(separatedBy: "#")[0]
            .removingPercentEncoding ?? href.components(separatedBy: "#")[0]
        guard !root.isEmpty else { return clean }
        return ((root as NSString).appendingPathComponent(clean) as NSString).standardizingPath
    }

    // MARK: - Contents

    private static func contents(in archive: ZipArchive, package: PackageParser.Package,
                                 root: String, spineFiles: [String]) -> [(String, Int, Int)] {
        // EPUB 3 keeps the contents in a nav document; EPUB 2 in an NCX. Try
        // both, because plenty of files in the wild carry one or the other.
        var candidates: [String] = []
        if let nav = package.navigationHref { candidates.append(resolve(nav, relativeTo: root)) }
        if let ncx = package.ncxHref { candidates.append(resolve(ncx, relativeTo: root)) }

        for path in candidates {
            guard let data = archive.contents(of: path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let directory = (path as NSString).deletingLastPathComponent
            let entries = path.lowercased().hasSuffix(".ncx")
                ? NavigationParser.parseNCX(text)
                : NavigationParser.parseNav(text)

            var result: [(String, Int, Int)] = []
            for entry in entries {
                let target = resolve(entry.href, relativeTo: directory)
                guard let index = spineFiles.firstIndex(of: target) else { continue }
                result.append((entry.title, index, entry.depth))
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
