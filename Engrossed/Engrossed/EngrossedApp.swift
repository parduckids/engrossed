import SwiftUI

@main
struct EngrossedApp: App {
    @State private var library = Library.shared
    @State private var settings = ReadingSettings.shared
    @State private var store = Store.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(settings)
                .tint(settings.theme.accent)
                .preferredColorScheme(settings.theme.colorScheme)
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 760)
        .commands {
            // A real Open command rather than an empty group: a Mac app with no
            // File > Open, whose only Cmd-O lives on a button that disappears
            // when you open a book, is a Mac app with no way to add a second one.
            CommandGroup(replacing: .newItem) {
                Button("Open\u{2026}") { library.wantsImport = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Picker("Reading mode", selection: Binding(
                    get: { settings.mode },
                    set: { settings.mode = $0 }
                )) {
                    ForEach(ReadingMode.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        #endif
    }
}

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(ReadingSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    @State private var openBook: Book?
    @State private var didAutoOpen = false
    @State private var launching = true
    @State private var startTour = false
    @State private var store = Store.shared
    #if DEBUG
    @State private var debugSheet = false
    #endif

    var body: some View {
        content
            .onOpenURL { handle($0) }
    }

    /// Handles both `engrossed://` links and PDFs opened from Finder or Files.
    ///
    /// `engrossed://resume` picks up the most recent unfinished book, which makes
    /// the app usable from Spotlight, the Dock, Shortcuts or a hotkey — worth
    /// having when the hardest part of reading is the bit before you start.
    private func handle(_ url: URL) {
        if url.isFileURL {
            if let book = library.importPDF(from: url) {
                withAnimation(.smooth(duration: 0.28)) { openBook = book }
            }
            return
        }

        guard url.scheme == "engrossed" else { return }
        switch url.host {
        case "resume":
            let target = library.books.first { $0.isStarted && !$0.isFinished }
                ?? library.books.first
            if let target { withAnimation(.smooth(duration: 0.28)) { openBook = target } }
        case "open":
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "id" }?.value
            if let id, let uuid = UUID(uuidString: id), let book = library.book(withID: uuid) {
                withAnimation(.smooth(duration: 0.28)) { openBook = book }
            }
        case "library":
            openBook = nil
        default:
            break
        }
    }

    private var content: some View {
        ZStack {
            shell
                .onAppear(perform: openLastBookIfWanted)

            if launching {
                LaunchView { withAnimation(.smooth(duration: 0.3)) { launching = false } }
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
    }

    /// The moment between opening the app and reading the first word is where a
    /// reading session most often dies. If there’s a book in progress, skip it.
    private func openLastBookIfWanted() {
        guard didAutoOpen == false else { return }
        didAutoOpen = true

        // The guide goes on the shelf, but is never forced open. Opening
        // straight into a walkthrough nobody asked for is the fastest way to
        // make someone close an app.
        library.installGuideIfNeeded()

        #if DEBUG
        // Lets a script reach the walkthrough, which otherwise needs a tap.
        if debugScreen == "tour", let guide = library.guideBook {
            startTour = true
            openBook = guide
            return
        }
        #endif

        guard settings.openLastBookOnLaunch, openBook == nil else { return }
        guard let book = library.books.first(where: {
            $0.isStarted && !$0.isFinished && !$0.isGuide
        }) else { return }
        openBook = book
    }

    #if DEBUG
    /// Opens a screen straight from a launch argument, e.g.
    /// `xcrun simctl launch <device> com.lowshelf.engrossed -debug.screen settings`.
    /// Sheets can only otherwise be reached by tapping, which makes it
    /// impossible to check their layout from a script. Debug builds only.
    private var debugScreen: String? {
        UserDefaults.standard.string(forKey: "debug.screen")
    }
    #endif

    private var shell: some View {
        ZStack {
            settings.theme.background.ignoresSafeArea()

            if let book = openBook {
                ReaderView(book: book, startsTour: startTour) {
                    startTour = false
                    openBook = nil
                }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.02)),
                        removal: .opacity))
            } else {
                LibraryView { book, wantsTour in
                    startTour = wantsTour
                    withAnimation(.smooth(duration: 0.28)) { openBook = book }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.28), value: openBook?.id)
        // Lives here rather than on the shelf: a PDF opened from Finder or
        // Files while the reader is inside a book is still a blocked import,
        // and on the shelf this sheet would have nothing to appear over.
        .sheet(isPresented: Binding(get: { library.needsUnlock },
                                    set: { library.needsUnlock = $0 })) {
            PaywallView().environment(settings)
                .onDisappear {
                    // Dismissed without buying: do not hold on to the file.
                    if !store.isUnlocked { library.forgetRefusedImport() }
                }
        }
        #if DEBUG
        // Presented as a real sheet, not an overlay: an overlay has nothing for
        // its Done button to dismiss, which makes the button look broken.
        .sheet(isPresented: $debugSheet) {
            switch debugScreen {
            case "settings":
                SettingsView().environment(settings).environment(library)
            case "paywall":
                PaywallView().environment(settings)
            default:
                EmptyView()
            }
        }
        // Only the screens that really are sheets. "tour" is not one, and
        // presenting an empty sheet for it covered the entire app in white.
        .onAppear { debugSheet = ["settings", "paywall"].contains(debugScreen ?? "") }
        #endif
        // The library owns the gate but not the entitlement, so the two are
        // kept in step here rather than having the data layer reach into
        // StoreKit itself.
        .onChange(of: library.wantsImport) { _, wants in
            // The file importer is presented by the shelf, so come back to it.
            if wants, openBook != nil {
                withAnimation(.smooth(duration: 0.28)) { openBook = nil }
            }
        }
        .onAppear { library.isShelfUnlocked = store.isUnlocked }
        .onChange(of: store.isUnlocked) { _, unlocked in
            library.isShelfUnlocked = unlocked
            // If a file was refused a moment ago, finish the job now rather
            // than making them go and find it again.
            if unlocked, let book = library.completeRefusedImport() {
                withAnimation(.smooth(duration: 0.28)) { openBook = book }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Closing the lid counts as closing the app: flush position now.
            if phase != .active { library.saveNow() }
        }
    }
}
