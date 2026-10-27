import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(ReadingSettings.self) private var settings

    let onOpen: (Book, Bool) -> Void

    @State private var isImporting = false
    @State private var showSettings = false
    @State private var pendingDelete: Book?

    private var theme: PaperTheme { settings.theme }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if library.books.isEmpty {
                    emptyState
                } else {
                    if let resume = library.books.first(where: {
                        $0.isStarted && !$0.isFinished && !$0.isGuide
                    }) {
                        resumeCard(resume)
                    }
                    shelf
                }
            }
            .background {
                // Resume without reaching for the mouse. Hidden so it can’t
                // disturb the header layout.
                Button("Resume") { resumeMostRecent() }
                    .keyboardShortcut("r", modifiers: .command)
                    .hidden()
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 60)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(theme.background.ignoresSafeArea())
        .onChange(of: library.wantsImport) { _, wants in
            if wants { consumeImportRequest() }
        }
        // Also on appear: choosing File > Open from inside a book sets the flag
        // and then swaps this view in, so the change happened before there was
        // anything here to observe it.
        .onAppear { if library.wantsImport { consumeImportRequest() } }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: [.pdf, .epub],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls { library.importPDF(from: url) }
            case .failure(let error):
                library.importError = error.localizedDescription
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ["pdf", "epub"].contains(url.pathExtension.lowercased()) else { return }
                    Task { @MainActor in library.importPDF(from: url) }
                }
            }
            return true
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(settings).environment(library)
        }
        .alert("Couldn’t add that file",
               isPresented: Binding(get: { library.importError != nil },
                                    set: { if !$0 { library.importError = nil } })) {
            Button("OK", role: .cancel) { library.importError = nil }
        } message: {
            Text(library.importError ?? "")
        }
        .confirmationDialog("Remove this book?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let book = pendingDelete { library.delete(book) }
                pendingDelete = nil
            }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This deletes Engrossed’s copy of \(pendingDelete?.title ?? "this book") and your place in it. The original file on your disk is untouched.")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Engrossed")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(greeting)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .layoutPriority(1)

            Spacer()
            HStack(spacing: 10) {
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(SoftButtonStyle(theme: theme))
                .help("Reading preferences")

                Button { addBook() } label: {
                    // On a phone the label alone squeezes the title into two lines.
                    if isCompact {
                        Image(systemName: "plus")
                    } else {
                        Label("Add a book", systemImage: "plus").fixedSize()
                    }
                }
                .buttonStyle(SoftButtonStyle(theme: theme, prominent: true))
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    /// Asking for a second book IS the moment to mention the unlock. Letting
    /// them pick a file first and then refusing it would be worse.
    private func consumeImportRequest() {
        library.wantsImport = false
        addBook()
    }

    private func addBook() {
        if library.canImportMore {
            isImporting = true
        } else {
            library.needsUnlock = true
        }
    }

    private func resumeMostRecent() {
        let target = library.books.first { $0.isStarted && !$0.isFinished } ?? library.books.first
        if let target { onOpen(target, false) }
    }

    private var greeting: String {
        let real = library.books.filter { !$0.isGuide }
        let unfinished = real.filter { $0.isStarted && !$0.isFinished }.count
        if library.books.isEmpty { return "Nothing here yet." }
        if real.isEmpty { return "Start with the guide, then add a book." }
        if unfinished == 0 { return "Pick something up." }
        return unfinished == 1 ? "One book in progress." : "\(unfinished) books in progress."
    }

    private func resumeCard(_ book: Book) -> some View {
        Button { onOpen(book, false) } label: {
            VStack(alignment: .leading, spacing: 14) {
                QuietLabel(text: "PICK UP WHERE YOU LEFT OFF", theme: theme)

                Text(book.title)
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !book.position.snippet.isEmpty {
                    // The last words you saw. Reinstating context beats a cold
                    // start — it’s far easier to resume a thought than restart one.
                    Text("\u{201C}\(book.position.snippet)\u{2026}\u{201D}")
                        .font(.system(size: 15, design: .serif))
                        .italic()
                        .foregroundStyle(theme.ink.opacity(0.62))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 10) {
                    StretchProgress(fraction: book.progress, theme: theme)
                        .frame(maxWidth: 220)
                    Text("\(Int(book.progress * 100))%")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.faint)
                    Spacer()
                    Text("Continue")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.ink.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(theme.accent.opacity(0.22), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var shelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuietLabel(text: "YOUR SHELF", theme: theme)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)],
                      alignment: .leading, spacing: 14) {
                ForEach(library.books) { book in
                    BookTile(book: book, theme: theme)
                        .onTapGesture { onOpen(book, book.isGuide) }
                        .contextMenu {
                            Button(book.isGuide ? "Start the tour" : "Open") { onOpen(book, book.isGuide) }
                            Button("Start over") { library.resetProgress(bookID: book.id) }
                            Divider()
                            Button("Remove\u{2026}", role: .destructive) { pendingDelete = book }
                        }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Dropping a file into a window is a desktop idea. On a tablet or a
            // phone the gesture people actually have is the button below.
            Text(dropHint)
                .font(.system(size: 22, weight: .medium, design: .serif))
                .foregroundStyle(theme.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 9) {
                bullet("It gets cut into small cards of whole sentences, never a wall of text.")
                bullet("Your place is saved constantly. Close it mid-sentence; it reopens there.")
                bullet("A stretch takes a few minutes and has a visible end.")
            }

            Button { addBook() } label: {
                Label("Choose a file", systemImage: "doc.badge.plus")
            }
            .buttonStyle(SoftButtonStyle(theme: theme, prominent: true))
            .padding(.top, 6)
        }
        .padding(.vertical, 30)
    }

    private var dropHint: String {
        #if os(macOS)
        "Drop a PDF or EPUB anywhere in this window."
        #else
        "Add a PDF or EPUB and start reading."
        #endif
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(theme.accent.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 7)
            Text(s)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(theme.ink.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BookTile: View {
    let book: Book
    let theme: PaperTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(book.title)
                .font(.system(size: 16, weight: .medium, design: .serif))
                .foregroundStyle(theme.ink)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if book.isGuide {
                QuietLabel(text: "A SHORT TOUR", theme: theme)
            } else if let author = book.author {
                Text(author)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            StretchProgress(fraction: book.progress, theme: theme, height: 2.5)

            HStack {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.faint)
                Spacer()
                if book.secondsRead > 60 {
                    Text("\(Int(book.secondsRead / 60)) min")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.whisper)
                }
            }
        }
        .padding(15)
        .frame(height: 148, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.ink.opacity(0.04))
        )
        .contentShape(Rectangle())
    }

    private var statusText: String {
        if book.isGuide { return "Tap to see how it works" }
        if book.isFinished { return "Finished" }
        if !book.isStarted { return "\(book.pageCount) pages \u{00B7} not started" }
        return "\(Int(book.progress * 100))% in"
    }
}
