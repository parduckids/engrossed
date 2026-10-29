import Foundation

/// What the check-in says at the end of a part.
///
/// The check-in works because you try to recall the part before you see any
/// of it again. So it asks first, and “Remind me” only gives the skeleton: how
/// each paragraph opened. Nothing here summarises, because a summary would let
/// you skip the thinking. The Chrome extension does the same, in recap.js, with
/// the same rules and the same questions, so the two feel like one product.
enum Recap {
    /// Asked in turn when the part has no heading to ask about, picked by the
    /// part’s number so the same part always gets the same question.
    static let questions = [
        "In one line, what was that about?",
        "What\u{2019}s the main point of that part?",
        "What would you tell a friend about that bit?",
        "What stuck with you from that part?",
    ]

    /// The explanation is only worth reading once. After that it is a wall of
    /// text between the reader and the buttons, so later check-ins say the
    /// short version.
    static let firstBody = "Don\u{2019}t write it down. Just say it to yourself. If nothing comes, that\u{2019}s the useful part. It means the last few minutes didn\u{2019}t land, and it\u{2019}s cheaper to re-read now than to find out in twenty pages."
    static let shortBody = "Just say it to yourself. If nothing comes, read it again."
    static let againBody = "Second time through. Is it clearer now?"

    /// How long the check-in is up before Return carries on. Return also turns
    /// the cards, so without this the press after the last card of a part
    /// closed the check-in before anyone had read it. Taps are never delayed:
    /// a tap is deliberate.
    static let armDelay: Duration = .seconds(1)

    /// The heading the part sits under: the one whose section makes up most of
    /// it. A part often starts at the end of one section and runs into the
    /// next, and the question should be about the one you spent most of the
    /// part in. When no heading covers most of it, there is nothing honest to
    /// name.
    ///
    /// The heading cards are the source, as in the extension. The book’s
    /// contents are only the fallback, because they are often coarser than the
    /// page: an EPUB’s entries land on the first card of their file, so several
    /// of them can share one card. A lone short line the chunker showed as a
    /// heading (“* * *”, “II”, a page number) is not a topic, so a heading needs
    /// a few letters to count.
    static func heading(for section: Section, in text: BookText) -> String? {
        var marks: [(index: Int, title: String)] = text.chunks.enumerated()
            .filter { $0.element.kind == .heading && $0.element.text.filter(\.isLetter).count >= 3 }
            .map { ($0.offset, $0.element.text) }
        if marks.isEmpty {
            var seen = Set<Int>()
            marks = text.contents.sorted { $0.chunkIndex < $1.chunkIndex }
                .filter { seen.insert($0.chunkIndex).inserted }
                .map { ($0.chunkIndex, $0.title) }
        }
        guard !marks.isEmpty, section.firstChunk <= section.lastChunk else { return nil }

        var mark = -1
        var words: [Int: Int] = [:]
        var total = 0
        for i in section.firstChunk...section.lastChunk where text.chunks.indices.contains(i) {
            while mark + 1 < marks.count && marks[mark + 1].index <= i { mark += 1 }
            let chunk = text.chunks[i]
            guard chunk.kind == .prose else { continue }
            total += chunk.wordCount
            if mark >= 0 { words[mark, default: 0] += chunk.wordCount }
        }
        guard let best = words.max(by: { $0.value < $1.value }),
              Double(best.value) >= Double(total) * 0.6 else { return nil }

        var title = marks[best.key].title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = title.last, ".:;,".contains(last) { title.removeLast() }
        // A long heading is a sentence in disguise, and reads badly in quotes.
        guard !title.isEmpty, !tooLong(title) else { return nil }
        return title
    }

    private static func tooLong(_ heading: String) -> Bool {
        isUnspaced(heading)
            ? heading.count > 24
            : heading.split(whereSeparator: \.isWhitespace).count > 10
    }

    /// Scripts written without spaces between words: Thai, Lao, Myanmar,
    /// Khmer, kana and CJK ideographs. Hangul is left out, because Korean does
    /// put spaces between words.
    private static func isUnspaced(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF,
                 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    static func question(for section: Section, heading: String?) -> String {
        if let heading {
            // A heading that is already a question is the best question there is.
            if heading.hasSuffix("?") || heading.hasSuffix("\u{FF1F}") { return heading }
            return "What was \u{201C}\(heading)\u{201D} about?"
        }
        return questions[section.id % questions.count]
    }

    /// The opening words of each paragraph in the part.
    static func openingLines(for section: Section, in text: BookText,
                             limit: Int = 6, words: Int = 9) -> [String] {
        guard section.firstChunk <= section.lastChunk else { return [] }
        var lines: [String] = []
        for i in section.firstChunk...section.lastChunk where text.chunks.indices.contains(i) {
            guard lines.count < limit else { break }
            let chunk = text.chunks[i]
            if chunk.kind == .prose && chunk.startsParagraph {
                lines.append(opening(chunk.text, words: words))
            }
        }
        return lines
    }

    private static func opening(_ text: String, words count: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: String
        let cut: Bool
        if isUnspaced(trimmed) {
            // Chinese, Japanese or Thai have no spaces, so nine “words” can be
            // the whole paragraph. Cut those by characters instead.
            out = String(trimmed.prefix(30))
            cut = trimmed.count > 30
        } else {
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            out = parts.prefix(count).joined(separator: " ")
            cut = parts.count > count
        }
        // Nine words that happen to end a sentence are a whole thought already.
        if !cut || endsSentence(out) { return out }
        while let last = out.last, ",;:".contains(last) { out.removeLast() }
        return out + "\u{2026}"
    }

    private static func endsSentence(_ text: String) -> Bool {
        var tail = Substring(text)
        if let last = tail.last, "\"\u{201D}\u{2019})".contains(last) { tail = tail.dropLast() }
        guard let last = tail.last else { return false }
        return ".!?\u{3002}\u{FF01}\u{FF1F}".contains(last)
    }

    static func tally(for section: Section) -> String {
        let words = section.wordCount
        let about = words >= 100 ? Int((Double(words) / 10).rounded()) * 10 : words
        let minutes = max(1, Int((Double(words) / 220).rounded()))
        return "That part was about \(about.formatted()) words, roughly \(minutes) minute\(minutes == 1 ? "" : "s") of reading."
    }
}
