import SwiftUI

struct ReaderView: View {
    @Environment(Library.self) private var library
    @Environment(ReadingSettings.self) private var settings

    let book: Book
    /// Opened from the guide card on the shelf, so run the walkthrough over it.
    var startsTour: Bool = false
    let onClose: () -> Void

    @State private var text: BookText?
    @State private var loadProgress: Double = 0
    @State private var loadError: String?

    @State private var index: Int = 0
    @State private var showCheckpoint = false
    /// Check-ins seen this read. Only the first one explains itself.
    @State private var checkInsShown = 0
    @State private var checkInIsFirst = true
    /// The part “Read it again” sent the reader back to, so its check-in can
    /// say so when they reach it a second time.
    @State private var rereadSection: Int?
    @State private var checkInKeyAt = Date()
    @State private var showBreak = false
    @State private var showSettings = false
    @State private var showContents = false
    @State private var resumedAt: Int?

    @State private var sprint = Sprint()
    @State private var narrator = Narrator()
    @State private var resumeSprintOnReturn = false
    @State private var tourStep: TourStep?

    @Environment(\.scenePhase) private var scenePhase

    private var theme: PaperTheme { settings.theme }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    private var documentURL: URL? { library.fileURL(for: book) }

    private var currentChunk: Chunk? {
        guard let text, text.chunks.indices.contains(index) else { return nil }
        return text.chunks[index]
    }

    private var currentSection: Section? {
        text?.section(containing: index)
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            if let text, !text.chunks.isEmpty {
                reader(text)
            } else if let loadError {
                errorState(loadError)
            } else {
                loadingState
            }
        }
        .task { await load() }
        .onDisappear { finishSession() }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(settings).environment(library)
        }
        .sheet(isPresented: $showContents) {
            if let text {
                ContentsView(text: text, currentChunk: index, settings: settings) { target in
                    jump(to: target)
                }
            }
        }
        .onChange(of: settings.chunkSize) { _, _ in
            Task { await reload() }
        }
        .onChange(of: sprint.didFinish) { _, finished in
            if finished { showBreak = true; narrator.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if resumeSprintOnReturn {
                    resumeSprintOnReturn = false
                    sprint.start()
                }
            } else {
                // iOS sends .inactive and then .background on the way out, so
                // this runs twice. Latch on the first pass, where the sprint is
                // still running, and let the second pass find the flag already
                // set rather than overwrite it with the paused state.
                if sprint.isRunning { resumeSprintOnReturn = true }
                narrator.stop()
                sprint.pause()
                // Credit the time now. onDisappear never runs if the system
                // kills the app while it is in the background, and the session
                // would be lost with it.
                library.addReadingTime(bookID: book.id, seconds: sprint.drainReadingTime())
                library.saveNow()
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 20) {
            Text(book.title)
                .font(.system(size: 20, weight: .medium, design: .serif))
                .foregroundStyle(theme.ink.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            StretchProgress(fraction: loadProgress, theme: theme)
                .frame(width: 180)

            Text(loadProgress < 0.9 ? "Cutting this into cards\u{2026}" : "Almost there\u{2026}")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(theme.faint)

            Button("Back to shelf") { onClose() }
                .buttonStyle(SoftButtonStyle(theme: theme))
                .padding(.top, 10)
        }
        .padding(40)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(theme.faint)
            Text(message)
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(theme.ink.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Back to shelf") { onClose() }
                .buttonStyle(SoftButtonStyle(theme: theme, prominent: true))
        }
        .padding(40)
    }

    // MARK: - Reader

    @ViewBuilder
    private func reader(_ text: BookText) -> some View {
        VStack(spacing: 0) {
            topBar(text)

            ZStack {
                switch settings.mode {
                case .chunk:
                    ChunkModeView(text: text,
                                  index: $index,
                                  settings: settings,
                                  narrator: narrator,
                                  resumedAt: resumedAt,
                                  documentURL: documentURL,
                                  onAdvance: advance,
                                  onBack: goBack)
                case .flow:
                    FlowModeView(text: text, index: index, settings: settings,
                                 documentURL: documentURL,
                                 onSelect: { step(to: $0) },
                                 onAdvance: advance,
                                 onBack: goBack,
                                 onScrolled: { drift(to: $0) })
                case .pace:
                    PaceModeView(text: text,
                                 index: $index,
                                 settings: settings,
                                 onAdvance: advance,
                                 onBack: goBack,
                                 documentURL: documentURL)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomBar(text)
        }
        .overlay {
            if showCheckpoint, let section = currentSection {
                CheckpointView(section: section,
                               text: text,
                               settings: settings,
                               sprint: sprint,
                               isFirst: checkInIsFirst,
                               isSecondTime: rereadSection == section.id,
                               lastKeyAt: checkInKeyAt,
                               onContinue: {
                                   showCheckpoint = false
                                   rereadSection = nil
                                   step(to: section.lastChunk + 1)
                               },
                               onReread: {
                                   showCheckpoint = false
                                   rereadSection = section.id
                                   step(to: section.firstChunk)
                               })
                    .transition(.opacity)
            }
            if showBreak {
                BreakView(sprint: sprint,
                          settings: settings,
                          onResume: { showBreak = false; sprint.restart() },
                          onStop: { showBreak = false; onClose() })
                    .transition(.opacity)
            }
        }
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let tourStep {
                    TourOverlay(step: tourStep,
                                spotlight: anchors[tourStep].map { proxy[$0] },
                                settings: settings,
                                onNext: advanceTour,
                                onSkip: { endTour() })
                }
            }
            // The reader draws inside the safe area, but the dimming has to
            // cover the status bar and the home indicator too. Extending the
            // geometry reader itself keeps the anchors and the drawing in one
            // coordinate space; ignoring it further in would put them in two.
            .ignoresSafeArea()
        }
        .animation(.smooth(duration: 0.25), value: showCheckpoint)
        .animation(.smooth(duration: 0.25), value: showBreak)
        .animation(.smooth(duration: 0.28), value: tourStep)
    }

    private func topBar(_ text: BookText) -> some View {
        HStack(spacing: 14) {
            Button { onClose() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.faint)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Back to shelf")

            if !isCompact {
                Text(book.title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if settings.sprintEnabled {
                sprintPill
            }

            Picker("", selection: Binding(get: { settings.mode },
                                          set: { settings.mode = $0; narrator.stop() })) {
                ForEach(ReadingMode.allCases) { mode in
                    Image(systemName: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            .tourAnchor(.modes)

            Button { showContents = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.faint)
            .keyboardShortcut("t", modifiers: .command)
            .help("Contents")
            .tourAnchor(.contents)

            Button { showSettings = true } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.faint)
            .keyboardShortcut(",", modifiers: .command)
            .tourAnchor(.settings)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var sprintPill: some View {
        Button {
            if sprint.isRunning { sprint.pause() } else { sprint.start() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: sprint.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 8))
                Text(sprint.remainingText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .fixedSize()
            }
            .foregroundStyle(sprint.isRunning ? theme.accent : theme.faint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(theme.ink.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(sprint.isRunning ? "Pause the sprint" : "Start a \(Int(settings.sprintMinutes))-minute sprint")
        .tourAnchor(.sprint)
    }

    private func bottomBar(_ text: BookText) -> some View {
        VStack(spacing: 10) {
            if let section = currentSection {
                HStack(spacing: 12) {
                    Text(positionText(section))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.faint)
                        .tourAnchor(.progress)

                    Spacer()

                    if !settings.hideTotalProgress {
                        Text("\(Int(Double(index) / Double(max(1, text.chunks.count - 1)) * 100))% of book")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.whisper)
                    }

                    StretchDots(total: section.chunkCount,
                                current: index - section.firstChunk,
                                theme: theme)
                }
            }

            if settings.sprintEnabled && sprint.isRunning {
                StretchProgress(fraction: sprint.fractionComplete, theme: theme, height: 2)
            }
        }
        .frame(maxWidth: settings.maxTextWidth + 16)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }

    /// Deliberately phrased small. "Card 4 of 11 in this part" is a finishable
    /// number; "chunk 812 of 4,930" is a reason to close the app.
    private func positionText(_ section: Section) -> String {
        let within = index - section.firstChunk + 1
        let left = section.chunkCount - within
        if left == 0 { return "Last card in this part" }
        if left <= 3 { return "\(left) more, then a breather" }
        return "\(within) of \(section.chunkCount) in this part"
    }

    // MARK: - Navigation

    private func advance() {
        guard let text else { return }
        guard index < text.chunks.count - 1 else {
            Haptics.milestone(enabled: settings.hapticsEnabled)
            step(to: index)
            return
        }
        if let section = currentSection,
           index == section.lastChunk,
           settings.checkpointsEnabled {
            narrator.stop()
            // Return and Space reach this again while the check-in is up.
            // Only a new check-in counts, but every press holds off arming it.
            if !showCheckpoint {
                checkInIsFirst = checkInsShown == 0
                checkInsShown += 1
            }
            checkInKeyAt = .now
            showCheckpoint = true
            return
        }
        step(to: index + 1)
    }

    // MARK: - Walkthrough

    private func advanceTour() {
        guard let tourStep else { return }
        let next = TourStep(rawValue: tourStep.rawValue + 1)
        if let next { self.tourStep = next } else { endTour() }
    }

    private func endTour() {
        tourStep = nil
    }

    /// Jumps somewhere else in the book, from the contents or a page number.
    ///
    /// Routed through the same step that ordinary reading uses, so the new place
    /// is saved exactly like any other — a jump you lose on quitting would be
    /// worse than no jump at all.
    private func jump(to target: Int) {
        narrator.stop()
        showCheckpoint = false
        step(to: target)
    }

    /// Going back is always available, in every mode. Being unable to re-read a
    /// sentence is a measurable comprehension cost, so nothing here is one-way.
    private func goBack() {
        // The keys still reach the reader under the check-in. Moving the card
        // behind it would make “Got it” land back on the same part.
        guard !showCheckpoint else { return }
        step(to: max(0, index - 1))
    }

    private func step(to newIndex: Int) {
        guard let text else { return }
        let clamped = min(max(0, newIndex), text.chunks.count - 1)
        if clamped != index {
            Haptics.tap(enabled: settings.hapticsEnabled)
            sprint.recordChunk(words: text.chunks[index].wordCount)
        }
        index = clamped
        resumedAt = nil
        persist()
    }

    /// Moving because the reader scrolled, rather than because they stepped.
    ///
    /// Scrolling through Flow is real reading and has to save the place, but it
    /// is not a step: no haptic for every paragraph that sweeps past under a
    /// thumb, and no sprint credit for words the eye flew over.
    private func drift(to newIndex: Int) {
        guard let text, text.chunks.indices.contains(newIndex), newIndex != index else { return }
        index = newIndex
        resumedAt = nil
        persist(at: newIndex, in: text)
    }

    private func persist() {
        guard let text else { return }
        persist(at: index, in: text)
    }

    private func persist(at chunkIndex: Int, in parsed: BookText) {
        guard parsed.chunks.indices.contains(chunkIndex) else { return }
        let chunk = parsed.chunks[chunkIndex]
        library.updatePosition(bookID: book.id,
                               chunkIndex: chunkIndex,
                               sectionIndex: chunk.section,
                               snippet: snippet(from: chunk.text),
                               page: chunk.page)
    }

    private func snippet(from text: String) -> String {
        let words = text.split(separator: " ").prefix(12)
        return words.joined(separator: " ")
    }

    // MARK: - Loading

    private func load() async {
        guard text == nil else { return }
        library.markOpened(bookID: book.id)
        sprint.targetMinutes = settings.sprintMinutes
        if settings.sprintEnabled { sprint.start() }

        do {
            let parsed = try await library.text(for: book, options: settings.chunkSize.options) { p in
                loadProgress = p
            }
            loadProgress = 1
            text = parsed

            // Resume, stepping back one card so you land inside the thought you
            // were in rather than at the edge of a new one.
            let saved = resolveSavedIndex(in: parsed)
            let rewound = settings.rewindOnResume ? max(0, saved - 1) : saved
            index = rewound
            resumedAt = (rewound != saved) ? rewound : nil

            if startsTour {
                // Cards mode has the card anchor the first step points at.
                settings.mode = .chunk
                withAnimation(.smooth(duration: 0.35).delay(0.35)) { tourStep = .card }
            }

            // If the index had to be recovered, write the corrected one back so
            // the next launch doesn’t have to search for it again. Note this
            // stores the resolved card, not the rewound one — otherwise every
            // recovery would quietly cost you a card.
            if saved != min(max(0, book.position.chunkIndex), parsed.chunks.count - 1) {
                persist(at: saved, in: parsed)
            }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Finds where the reader actually was.
    ///
    /// A chunk index only means anything for the chunking that produced it. If an
    /// app update changes how cards are cut, every stored index silently shifts,
    /// and the one promise this app makes — that it puts you back where you were —
    /// quietly breaks. So when the card count has changed, the saved text and page
    /// are used to find the spot again.
    private func resolveSavedIndex(in parsed: BookText) -> Int {
        let saved = book.position
        let clamped = min(max(0, saved.chunkIndex), parsed.chunks.count - 1)

        // Same chunking as last time: the index is trustworthy.
        guard book.totalChunks != parsed.chunks.count, book.totalChunks > 0 else {
            return clamped
        }

        // Re-anchor on the words that were on screen, but only near the page
        // they were on. A forty-character prefix is not unique in a real book:
        // the contents page at the front repeats chapter titles word for word,
        // so searching from index zero finds the contents entry rather than the
        // chapter, and the reader is thrown to page three of a book they were
        // two hundred pages into. The recovered index is then saved, so the
        // real place is gone for good.
        let snippet = saved.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.count > 12 {
            let head = String(snippet.prefix(40))
            let near = { (chunk: Chunk) in abs(chunk.page - saved.page) <= 1 }
            if let match = parsed.chunks.firstIndex(where: { near($0) && $0.text.hasPrefix(head) }) {
                return match
            }
            if let match = parsed.chunks.firstIndex(where: { near($0) && $0.text.contains(head) }) {
                return match
            }
        }

        // Failing that, the page is still right.
        if let match = parsed.chunks.firstIndex(where: { $0.page >= saved.page }) {
            return match
        }
        return clamped
    }

    private func reload() async {
        let anchorPage = currentChunk?.page ?? 0
        text = nil
        loadProgress = 0
        do {
            let parsed = try await library.text(for: book, options: settings.chunkSize.options) { p in
                loadProgress = p
            }
            text = parsed
            // Chunk indices changed under us; land on the same page instead.
            index = parsed.chunks.firstIndex { $0.page >= anchorPage } ?? 0
            persist()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func finishSession() {
        narrator.stop()
        sprint.pause()
        library.addReadingTime(bookID: book.id, seconds: sprint.drainReadingTime())
        library.saveNow()
    }
}
