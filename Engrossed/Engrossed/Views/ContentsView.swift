import SwiftUI

/// The table of contents, and the only way to get somewhere specific.
///
/// A 240-entry outline dumped as a flat list is its own kind of wall of text, so
/// chapters are collapsed by default and only the one you are inside opens
/// automatically. What you get on opening it is a couple of dozen chapter names
/// and a clear mark showing where you are.
struct ContentsView: View {
    let text: BookText
    let currentChunk: Int
    let settings: ReadingSettings
    let onJump: (Int) -> Void

    var body: some View {
        ScrollView {
            ContentsList(text: text, currentChunk: currentChunk,
                         settings: settings, onJump: onJump)
        }
        .background(settings.theme.background.ignoresSafeArea())
    }
}

struct ContentsList: View {
    let text: BookText
    let currentChunk: Int
    let settings: ReadingSettings
    let onJump: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<Int> = []
    @State private var pageQuery = ""
    @State private var pageQueryFailed = false

    private var theme: PaperTheme { settings.theme }

    /// A top-level entry together with everything nested under it.
    private struct Chapter: Identifiable {
        let entry: ContentsEntry
        let children: [ContentsEntry]
        var id: Int { entry.id }
    }

    private var chapters: [Chapter] {
        var result: [Chapter] = []
        var current: ContentsEntry?
        var children: [ContentsEntry] = []

        for entry in text.contents {
            if entry.depth == 0 {
                if let current { result.append(Chapter(entry: current, children: children)) }
                current = entry
                children = []
            } else if current != nil {
                children.append(entry)
            } else {
                // An outline that starts nested: treat it as top level so
                // nothing is silently dropped.
                result.append(Chapter(entry: entry, children: []))
            }
        }
        if let current { result.append(Chapter(entry: current, children: children)) }
        return result
    }

    private var currentEntryID: Int? {
        text.contentsEntry(containing: currentChunk)?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            if text.contents.isEmpty {
                emptyNote
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(chapters) { chapter in
                        chapterRow(chapter)
                        if expanded.contains(chapter.id) {
                            ForEach(chapter.children) { child in
                                entryRow(child, isChild: true)
                            }
                        }
                    }
                }
            }

            goToPage
        }
        .padding(26)
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity)
        .onAppear(perform: expandCurrentChapter)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Contents")
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(theme.ink)
                if let entry = text.contentsEntry(containing: currentChunk) {
                    Text("You’re in \(entry.title)")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(SoftButtonStyle(theme: theme))
                .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private var emptyNote: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("This PDF doesn’t carry a contents list.")
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(theme.ink.opacity(0.75))
            Text("Nothing is wrong with it. Plenty of documents simply don’t include one. You can still jump by page below.")
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private func chapterRow(_ chapter: Chapter) -> some View {
        HStack(spacing: 0) {
            entryRow(chapter.entry, isChild: false)

            if !chapter.children.isEmpty {
                Button {
                    withAnimation(.smooth(duration: 0.22)) {
                        if expanded.contains(chapter.id) { expanded.remove(chapter.id) }
                        else { expanded.insert(chapter.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded.contains(chapter.id) ? 90 : 0))
                        .foregroundStyle(theme.whisper)
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded.contains(chapter.id) ? "Collapse" : "Show sections")
            }
        }
    }

    private func entryRow(_ entry: ContentsEntry, isChild: Bool) -> some View {
        let isCurrent = entry.id == currentEntryID
        let isPassed = entry.chunkIndex < currentChunk && !isCurrent

        return Button {
            onJump(entry.chunkIndex)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                // A small mark rather than a highlight bar: quieter, and it
                // still answers "where am I" at a glance.
                Circle()
                    .fill(isCurrent ? theme.accent : Color.clear)
                    .frame(width: 5, height: 5)
                    .padding(.leading, isChild ? 16 : 0)

                Text(entry.title)
                    .font(.system(size: isChild ? 13 : 15,
                                  weight: isCurrent ? .semibold : (isChild ? .regular : .medium),
                                  design: isChild ? .rounded : .serif))
                    .foregroundStyle(isCurrent ? theme.ink
                                     : theme.ink.opacity(isPassed ? 0.45 : 0.78))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Text(entry.pageLabel.isEmpty ? text.pageLabel(for: entry.page) : entry.pageLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.whisper)
            }
            .padding(.vertical, isChild ? 5 : 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var goToPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuietLabel(text: "GO TO PAGE", theme: theme)

            HStack(spacing: 9) {
                TextField(text.pageLabels.isEmpty ? "Page number" : "Printed page number",
                          text: $pageQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.ink.opacity(0.06)))
                    .frame(maxWidth: 190)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    #endif
                    .onSubmit(jumpToTypedPage)

                Button("Go", action: jumpToTypedPage)
                    .buttonStyle(SoftButtonStyle(theme: theme, prominent: true))
                    .disabled(pageQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text(pageQueryFailed
                 ? "No page with that number."
                 : "The number printed on the page, not its position in the file.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(pageQueryFailed ? theme.accent : theme.whisper)
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func jumpToTypedPage() {
        guard let target = text.chunkIndex(forPageQuery: pageQuery) else {
            pageQueryFailed = true
            return
        }
        pageQueryFailed = false
        onJump(target)
        dismiss()
    }

    /// Opens the chapter you are currently inside, and nothing else.
    private func expandCurrentChapter() {
        guard let currentEntryID else { return }
        for chapter in chapters {
            if chapter.id == currentEntryID || chapter.children.contains(where: { $0.id == currentEntryID }) {
                expanded.insert(chapter.id)
                return
            }
        }
    }
}
