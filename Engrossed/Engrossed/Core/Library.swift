import Foundation
import Observation
import PDFKit

/// Owns the book list, the copied PDF files, the parsed-text cache, and — the
/// point of the whole app — where you were when you closed it.
@Observable
final class Library {
    static let shared = Library()

    private(set) var books: [Book] = []
    var importError: String?

    /// How many books the shelf holds at once without paying. One is free
    /// forever: read it, delete it, add another, as often as you like.
    static let freeShelfSize = 1

    /// Mirrored from the store by the app at launch and whenever it changes.
    var isShelfUnlocked = false

    /// Set when an import is turned away, so the shelf can offer the unlock.
    var needsUnlock = false

    /// Raised by the Mac's File > Open command, which has to work from inside a
    /// book as well as from the shelf.
    var wantsImport = false

    /// The file that was turned away, kept so that buying the unlock finishes
    /// the job. Dropping a book in, paying, and then having to find the file
    /// again would be a poor reward for having just paid.
    private var refusedImport: URL?

    /// Someone who already has several books keeps them all, even if they are
    /// not entitled (a refund, say). Taking books away from a reader who is
    /// halfway through one would be hostile, and they are already on the disk.
    /// Only *adding* another is gated.
    var canImportMore: Bool {
        isShelfUnlocked || books.filter { !$0.isGuide }.count < Library.freeShelfSize
    }

    var guideBook: Book? { books.first(where: \.isGuide) }

    private let fileManager = FileManager.default
    private var saveWorkItem: DispatchWorkItem?

    // MARK: - Locations

    private var root: URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: true))
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Engrossed", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var booksDirectory: URL {
        let dir = root.appendingPathComponent("Books", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var cacheDirectory: URL {
        var dir = root.appendingPathComponent("Cache", isDirectory: true)
        let isNew = !fileManager.fileExists(atPath: dir.path)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        if isNew {
            // Parsed text is rebuilt from the book in seconds. Backing it up
            // would double every book in the reader's iCloud storage for nothing.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    private var indexURL: URL { root.appendingPathComponent("library.json") }

    func fileURL(for book: Book) -> URL {
        booksDirectory.appendingPathComponent(book.fileName)
    }

    private func cacheURL(for book: Book, options: Chunker.Options) -> URL {
        cacheDirectory.appendingPathComponent("\(book.id.uuidString)-\(options.targetWords).json")
    }

    // MARK: - Lifecycle

    private init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Book].self, from: data) {
            books = decoded
        } else if let salvaged = try? decoder.decode([Lenient<Book>].self, from: data) {
            // One malformed entry shouldn’t cost you the rest of the shelf.
            books = salvaged.compactMap(\.value)
        } else {
            books = []
        }
        sort()
    }

    /// Debounced so that advancing a card every two seconds doesn’t hammer the disk.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(books) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func sort() {
        books.sort { a, b in
            let l = a.lastOpenedAt ?? a.addedAt
            let r = b.lastOpenedAt ?? b.addedAt
            return l > r
        }
    }

    // MARK: - Importing

    @discardableResult
    func importPDF(from source: URL) -> Book? {
        // The single choke point. Every route in reaches this: the file
        // importer, drag and drop, and Open With. Gating at the call sites
        // instead would let a multi-file selection past the limit.
        guard canImportMore else {
            refusedImport = source
            needsUnlock = true
            return nil
        }
        return add(from: source, isGuide: false)
    }

    /// Finishes an import that was refused before the unlock was bought.
    @discardableResult
    func completeRefusedImport() -> Book? {
        guard canImportMore, let source = refusedImport else { return nil }
        refusedImport = nil
        return add(from: source, isGuide: false)
    }

    func forgetRefusedImport() {
        refusedImport = nil
    }

    /// Removes the temporary copy iOS leaves in Documents/Inbox. Does nothing
    /// anywhere else, and never touches a file the reader chose themselves.
    private func discardInboxCopy(_ source: URL) {
        #if os(iOS)
        guard source.path.contains("/Documents/Inbox/") else { return }
        try? fileManager.removeItem(at: source)
        #endif
    }

    // MARK: - The guide

    private static let installedGuideKey = "library.hasInstalledGuide"

    /// Puts the walkthrough on the shelf the first time the app runs, and never
    /// again: someone who deletes it has finished with it, and re-adding it on
    /// the next launch would be nagging.
    @discardableResult
    func installGuideIfNeeded() -> Book? {
        guard !UserDefaults.standard.bool(forKey: Library.installedGuideKey) else { return nil }
        UserDefaults.standard.set(true, forKey: Library.installedGuideKey)
        return addGuide()
    }

    @discardableResult
    func addGuide() -> Book? {
        if let existing = guideBook { return existing }
        guard let source = Bundle.main.url(forResource: "Guide", withExtension: "pdf") else {
            return nil
        }
        return add(from: source, isGuide: true)
    }

    @discardableResult
    private func add(from source: URL, isGuide: Bool) -> Book? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let format = BookFormat(url: source)

        // Read the metadata before copying anything, so a file that turns out
        // to be unreadable never leaves a stray copy behind.
        var metaTitle: String?
        var author: String?
        var unitCount = 0

        switch format {
        case .pdf:
            guard let document = PDFDocument(url: source) else {
                importError = "\(source.lastPathComponent) couldn\u{2019}t be opened as a PDF."
                discardInboxCopy(source)
                return nil
            }
            if document.isLocked {
                importError = "\(source.lastPathComponent) is password-protected."
                discardInboxCopy(source)
                return nil
            }
            let attributes = document.documentAttributes ?? [:]
            metaTitle = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            unitCount = document.pageCount

        case .epub:
            do {
                let book = try EPUBExtractor.read(source)
                metaTitle = book.title
                author = book.author
                unitCount = book.pages.count
            } catch {
                importError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                discardInboxCopy(source)
                return nil
            }
        }

        let id = UUID()
        let fileName = "\(id.uuidString).\(format.fileExtension)"
        let destination = booksDirectory.appendingPathComponent(fileName)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            importError = "Couldn\u{2019}t copy \(source.lastPathComponent): \(error.localizedDescription)"
            discardInboxCopy(source)
            return nil
        }

        // iOS hands an app opened from Files or the share sheet its own copy in
        // Documents/Inbox and expects the app to delete it. Ours is now safely
        // in Books/, so leaving the Inbox copy would store every imported book
        // twice, for ever, out of the reader's sight.
        discardInboxCopy(source)

        let title: String
        if let metaTitle, metaTitle.count > 2,
           !metaTitle.lowercased().hasSuffix(".pdf"), !metaTitle.lowercased().hasSuffix(".epub") {
            title = metaTitle
        } else {
            title = source.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
        }

        let book = Book(id: id,
                        title: title,
                        author: (author?.isEmpty == false) ? author : nil,
                        fileName: fileName,
                        pageCount: unitCount,
                        isGuide: isGuide)
        books.insert(book, at: 0)
        saveNow()
        return book
    }

    func delete(_ book: Book) {
        books.removeAll { $0.id == book.id }
        try? fileManager.removeItem(at: fileURL(for: book))
        for option in [Chunker.Options.cozy, .standard, .roomy] {
            try? fileManager.removeItem(at: cacheURL(for: book, options: option))
        }
        saveNow()
    }

    // MARK: - Position

    func book(withID id: UUID) -> Book? { books.first { $0.id == id } }

    func updatePosition(bookID: UUID, chunkIndex: Int, sectionIndex: Int,
                        snippet: String, page: Int) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].position = Book.Position(chunkIndex: chunkIndex,
                                          snippet: snippet,
                                          sectionIndex: sectionIndex,
                                          page: page)
        books[i].lastOpenedAt = Date()
        scheduleSave()
    }

    func addReadingTime(bookID: UUID, seconds: Double) {
        guard seconds > 0, let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].secondsRead += seconds
        scheduleSave()
    }

    func markOpened(bookID: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].lastOpenedAt = Date()
        scheduleSave()
    }

    func resetProgress(bookID: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].position = Book.Position()
        saveNow()
    }

    private func setTotalChunks(_ total: Int, bookID: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }), books[i].totalChunks != total
        else { return }
        books[i].totalChunks = total
        scheduleSave()
    }

    // MARK: - Parsing

    /// Parses the PDF off the main thread, caching the result so the second open
    /// of a 200-page book is instant.
    func text(for book: Book,
              options: Chunker.Options,
              progress: @escaping (Double) -> Void) async throws -> BookText {
        let url = fileURL(for: book)
        let cache = cacheURL(for: book, options: options)

        if let data = try? Data(contentsOf: cache),
           let cached = try? JSONDecoder().decode(BookText.self, from: data),
           cached.version == BookText.currentVersion,
           !cached.chunks.isEmpty {
            await MainActor.run { setTotalChunks(cached.chunks.count, bookID: book.id) }
            return cached
        }

        let format = BookFormat(url: url)
        let parsed: BookText = try await Task.detached(priority: .userInitiated) {
            var text: BookText

            switch format {
            case .pdf:
                guard let document = PDFDocument(url: url) else {
                    throw LibraryError.unreadable
                }
                let pages = TextExtractor.extract(from: document) { value in
                    Task { @MainActor in progress(value * 0.85) }
                }
                text = Chunker.chunk(pages: pages, options: options)
                // Needs both the document (for its outline) and the finished
                // cards (to map each destination onto one), so it runs here
                // rather than inside the chunker.
                ContentsBuilder.demoteNonReading(in: &text)
                text.contents = ContentsBuilder.build(document: document, text: text)
                text.pageLabels = ContentsBuilder.pageLabels(of: document)

            case .epub:
                let book = try EPUBExtractor.read(url)
                await MainActor.run { progress(0.6) }
                text = Chunker.chunk(pages: book.pages, options: options)
                ContentsBuilder.demoteNonReading(in: &text)
                text.contents = ContentsBuilder.build(epubContents: book.contents, text: text)
            }

            await MainActor.run { progress(0.97) }
            return text
        }.value

        guard !parsed.chunks.isEmpty else { throw LibraryError.noText }

        if let data = try? JSONEncoder().encode(parsed) {
            try? data.write(to: cache, options: .atomic)
        }
        await MainActor.run { setTotalChunks(parsed.chunks.count, bookID: book.id) }
        return parsed
    }

    /// Dropped when the reader changes chunk size, since cards are re-cut.
    func clearCaches() {
        try? fileManager.removeItem(at: cacheDirectory)
    }

    enum LibraryError: LocalizedError {
        case unreadable, noText

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "This PDF couldn’t be opened."
            case .noText:
                return "No selectable text found. This looks like a scanned PDF, so it needs OCR before it can be read in cards."
            }
        }
    }
}
