import Foundation
import CoreGraphics

/// A PDF the reader has imported. Lightweight: the heavy chunked text lives in a
/// sidecar cache file, keyed by `id`.
struct Book: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var author: String?
    var fileName: String
    var pageCount: Int
    var addedAt: Date
    var lastOpenedAt: Date?

    /// Total chunks, cached here so the library can show progress without
    /// re-parsing a 200-page PDF on every launch.
    var totalChunks: Int
    var position: Position

    /// Cumulative reading time, used for the "you’ve put in X" framing.
    var secondsRead: Double

    /// The bundled walkthrough. It sits on the shelf like any other book, but
    /// it does not use up the free slot: charging someone their one free book
    /// to read the instructions would be a strange way to say hello.
    var isGuide: Bool = false

    struct Position: Codable, Hashable {
        var chunkIndex: Int = 0
        /// First few words of where you stopped, so the library card can remind
        /// you what you were in the middle of without reopening the file.
        var snippet: String = ""
        var sectionIndex: Int = 0
        /// The PDF page the card came from. A chunk index is only meaningful for
        /// one version of the chunker; the page number outlives any change to it.
        var page: Int = 0

        init(chunkIndex: Int = 0, snippet: String = "", sectionIndex: Int = 0, page: Int = 0) {
            self.chunkIndex = chunkIndex
            self.snippet = snippet
            self.sectionIndex = sectionIndex
            self.page = page
        }

        enum CodingKeys: String, CodingKey {
            case chunkIndex, snippet, sectionIndex, page
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chunkIndex = try c.decodeIfPresent(Int.self, forKey: .chunkIndex) ?? 0
            snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
            sectionIndex = try c.decodeIfPresent(Int.self, forKey: .sectionIndex) ?? 0
            page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
        }
    }



    init(id: UUID = UUID(), title: String, author: String? = nil, fileName: String,
         pageCount: Int, addedAt: Date = Date(), lastOpenedAt: Date? = nil,
         totalChunks: Int = 0, position: Position = .init(), secondsRead: Double = 0,
         isGuide: Bool = false) {
        self.id = id
        self.title = title
        self.author = author
        self.fileName = fileName
        self.pageCount = pageCount
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.totalChunks = totalChunks
        self.position = position
        self.secondsRead = secondsRead
        self.isGuide = isGuide
    }

    // MARK: - Decoding
    //
    // Hand-written so that a library file saved by an older version still loads
    // when a field is added. Swift’s synthesised decoder treats every
    // non-optional key as required and throws when one is missing — which, for
    // a file that holds every book and every saved place, means one new field
    // silently empties the shelf. Everything below therefore has a fallback.

    enum CodingKeys: String, CodingKey {
        case id, title, author, fileName, pageCount, addedAt, lastOpenedAt
        case totalChunks, position, secondsRead, isGuide
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        author = try c.decodeIfPresent(String.self, forKey: .author)
        fileName = try c.decode(String.self, forKey: .fileName)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        totalChunks = try c.decodeIfPresent(Int.self, forKey: .totalChunks) ?? 0
        position = try c.decodeIfPresent(Position.self, forKey: .position) ?? Position()
        secondsRead = try c.decodeIfPresent(Double.self, forKey: .secondsRead) ?? 0
        isGuide = try c.decodeIfPresent(Bool.self, forKey: .isGuide) ?? false
    }

    var progress: Double {
        guard totalChunks > 1 else { return 0 }
        return min(1, Double(position.chunkIndex) / Double(totalChunks - 1))
    }

    var isStarted: Bool { position.chunkIndex > 0 }
    /// A one-card document is never "finished": its only card is index 0, which
    /// is also where you start, so it would arrive on the shelf already done.
    var isFinished: Bool { totalChunks > 1 && position.chunkIndex >= totalChunks - 1 }
}

/// What a card actually contains. Real documents are not all prose: a paper is
/// a third tables, captions, equations and references. Those are worth marking
/// rather than pretending — a card you are told you may skip is much easier to
/// skip than one that just refuses to make sense.
enum ChunkKind: String, Codable, Hashable {
    case prose
    /// A heading. Short, no sentence ending, sitting alone.
    case heading
    /// A table, equation block, author list, caption — anything not meant to be
    /// read left-to-right as sentences.
    case aside
    /// A picture: a diagram, chart, photograph or anything else drawn rather
    /// than typeset. Rendered from the PDF itself.
    case figure
}

/// Where a figure sits on its page, in the page’s own coordinate space.
struct FigureRegion: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var aspectRatio: Double { height > 0 ? width / height : 1 }
}

/// One readable card: a small group of whole sentences.
struct Chunk: Codable, Identifiable, Hashable {
    var id: Int
    var text: String
    var page: Int
    var section: Int
    var startsParagraph: Bool
    var wordCount: Int
    var kind: ChunkKind = .prose
    /// Set only for `.figure` cards.
    var figure: FigureRegion?

    var isProse: Bool { kind == .prose }

    enum CodingKeys: String, CodingKey {
        case id, text, page, section, startsParagraph, wordCount, kind, figure
    }

    init(id: Int, text: String, page: Int, section: Int, startsParagraph: Bool,
         wordCount: Int, kind: ChunkKind = .prose, figure: FigureRegion? = nil) {
        self.id = id
        self.text = text
        self.page = page
        self.section = section
        self.startsParagraph = startsParagraph
        self.wordCount = wordCount
        self.kind = kind
        self.figure = figure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
        section = try c.decodeIfPresent(Int.self, forKey: .section) ?? 0
        startsParagraph = try c.decodeIfPresent(Bool.self, forKey: .startsParagraph) ?? true
        wordCount = try c.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        kind = try c.decodeIfPresent(ChunkKind.self, forKey: .kind) ?? .prose
        // A region saved by an older build could hold a size no page could have,
        // which later traps when it is scaled for rendering. Drop the region
        // rather than failing the decode: a figure card with no region already
        // shows "This figure couldn't be drawn", whereas throwing here would
        // condemn the whole book to being re-parsed on every open.
        let savedFigure = try? c.decodeIfPresent(FigureRegion.self, forKey: .figure)
        figure = savedFigure.flatMap { region in
            let values = [region.x, region.y, region.width, region.height]
            guard values.allSatisfy(\.isFinite),
                  region.width > 0, region.height > 0,
                  region.width < 20_000, region.height < 20_000 else { return nil }
            return region
        }
    }
}

/// A stretch of chunks worth roughly a few minutes. Sections give the reader a
/// small denominator ("4 of 11") instead of an intimidating one ("chunk 812").
struct Section: Codable, Identifiable, Hashable {
    var id: Int
    var firstChunk: Int
    var lastChunk: Int
    var wordCount: Int
    var startPage: Int

    var chunkCount: Int { lastChunk - firstChunk + 1 }
    func contains(_ chunkIndex: Int) -> Bool {
        chunkIndex >= firstChunk && chunkIndex <= lastChunk
    }
}

/// One line of the table of contents.
struct ContentsEntry: Codable, Hashable, Identifiable {
    var id: Int
    var title: String
    /// Nesting level: 0 is a chapter, 1 a section, and so on.
    var depth: Int
    var page: Int
    /// The card this entry lands on.
    var chunkIndex: Int
    /// The printed page number, when it differs from the position in the file.
    var pageLabel: String = ""

    enum CodingKeys: String, CodingKey { case id, title, depth, page, chunkIndex, pageLabel }

    init(id: Int, title: String, depth: Int, page: Int, chunkIndex: Int, pageLabel: String = "") {
        self.id = id
        self.title = title
        self.depth = depth
        self.page = page
        self.chunkIndex = chunkIndex
        self.pageLabel = pageLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
        chunkIndex = try c.decodeIfPresent(Int.self, forKey: .chunkIndex) ?? 0
        pageLabel = try c.decodeIfPresent(String.self, forKey: .pageLabel) ?? ""
    }
}

/// The parsed document, cached to disk so re-opening is instant.
struct BookText: Codable {
    /// Bumped whenever the shape on disk changes, which drops every cached
    /// parse. Version 6 was written twice during development with two different
    /// payloads, so it is retired rather than reused: a stale v6 file is
    /// indistinguishable from a current one by the version check alone, and
    /// lenient decoding would quietly accept it with its newer fields empty.
    static let currentVersion = 7

    var version: Int = BookText.currentVersion
    var chunks: [Chunk]
    var sections: [Section]
    var contents: [ContentsEntry] = []
    /// The printed page number for each page, where the document declares one.
    /// Books number their front matter in roman numerals, so the label on the
    /// page in your hand is often nothing like its index in the file — and the
    /// label is the number a reader is actually looking for.
    var pageLabels: [String] = []

    enum CodingKeys: String, CodingKey { case version, chunks, sections, contents, pageLabels }

    init(chunks: [Chunk], sections: [Section],
         contents: [ContentsEntry] = [], pageLabels: [String] = []) {
        self.chunks = chunks
        self.sections = sections
        self.contents = contents
        self.pageLabels = pageLabels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        chunks = try c.decodeIfPresent([Chunk].self, forKey: .chunks) ?? []
        sections = try c.decodeIfPresent([Section].self, forKey: .sections) ?? []
        contents = try c.decodeIfPresent([ContentsEntry].self, forKey: .contents) ?? []
        pageLabels = try c.decodeIfPresent([String].self, forKey: .pageLabels) ?? []
    }

    /// The printed number for a page, falling back to its position in the file.
    func pageLabel(for page: Int) -> String {
        if pageLabels.indices.contains(page), !pageLabels[page].isEmpty {
            return pageLabels[page]
        }
        return String(page + 1)
    }

    /// Resolves what a reader typed into a card index.
    ///
    /// Tries the printed page number first, because that is the one on the page
    /// they are looking at, and only then the raw position in the file.
    func chunkIndex(forPageQuery query: String) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        if let page = pageLabels.firstIndex(where: { $0.lowercased() == trimmed }) {
            return firstChunk(onOrAfter: page)
        }
        if let number = Int(trimmed), number >= 1 {
            return firstChunk(onOrAfter: number - 1)
        }
        return nil
    }

    /// No silent fallback to the last card. A page number past the end of the
    /// book should fail and say so, not throw the reader to the final page and
    /// save that as their place.
    func firstChunk(onOrAfter page: Int) -> Int? {
        chunks.first { $0.page >= page }?.id
    }

    /// The entry covering a card: the last one that starts at or before it.
    func contentsEntry(containing chunkIndex: Int) -> ContentsEntry? {
        contents.last { $0.chunkIndex <= chunkIndex }
    }

    var wordCount: Int { chunks.reduce(0) { $0 + $1.wordCount } }

    func section(containing chunkIndex: Int) -> Section? {
        sections.first { $0.contains(chunkIndex) }
    }
}

/// Wraps a decode so that one unreadable entry can’t take the whole list down
/// with it. A single corrupt book should cost you that book, not your shelf.
struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// What kind of file a book is. Inferred from the extension, because that is
/// what the reader chose and what the copy on disk is named.
enum BookFormat {
    case pdf
    case epub

    init(url: URL) {
        // Trust the file, not its name. Downloads and renames get the extension
        // wrong often enough, and a PDF that someone saved as .epub should
        // still open rather than be refused as a damaged book.
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let magic = try? handle.read(upToCount: 4), magic.count >= 2 {
                let bytes = [UInt8](magic)
                if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { self = .pdf; return }  // %PDF
                if bytes.starts(with: [0x50, 0x4B]) { self = .epub; return }             // PK, a ZIP
            }
        }
        self = url.pathExtension.lowercased() == "epub" ? .epub : .pdf
    }

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .epub: return "epub"
        }
    }
}
