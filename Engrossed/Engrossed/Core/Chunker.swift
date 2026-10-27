import Foundation
import NaturalLanguage

/// Turns paragraphs into reading cards.
///
/// The rule that matters: a chunk never ends mid-sentence. Splitting text at
/// sentence boundaries is what makes chunking reduce load rather than add it —
/// an arbitrary cut forces you to hold a fragment in working memory, which is
/// exactly the thing we are trying to avoid.
enum Chunker {

    /// Characters that end a sentence, in every script this app is likely to
    /// meet. The CJK forms matter more than they look: Japanese and Chinese end
    /// sentences with an ideographic full stop, and a check for ASCII "." alone
    /// classified every page of those languages as "not prose" and buried it in
    /// skippable aside cards.
    static let sentenceEnders: Set<Character> = [
        ".", "!", "?",
        "\u{3002}",   // 。 ideographic full stop
        "\u{FF01}",   // ！ fullwidth exclamation
        "\u{FF1F}",   // ？ fullwidth question
        "\u{2049}",   // ⁉
        "\u{0964}",   // । Devanagari danda, for Hindi and its neighbours
        "\u{0965}",   // ॥ double danda
        "\u{0589}",   // ։ Armenian full stop
        "\u{06D4}",   // ۔ Urdu full stop
        "\u{061F}"    // ؟ Arabic question mark
    ]
    // Note: 、 is deliberately absent. It is a comma, not a full stop, and
    // treating it as one would end paragraphs and cards in the middle of a
    // sentence. It belongs in the clause breakers used to split a run-on, and
    // it is already there.

    struct Options {
        /// Words we aim for per card. Small enough to take in at a glance.
        var targetWords: Int = 45
        /// Hard ceiling before we stop adding sentences.
        var maxWords: Int = 80
        /// A single sentence longer than this gets split at clause boundaries.
        var runOnSentenceWords: Int = 90
        /// Words per section, roughly three minutes at a calm pace.
        var sectionWords: Int = 650

        static let cozy = Options(targetWords: 28, maxWords: 50, runOnSentenceWords: 70, sectionWords: 450)
        static let standard = Options()
        static let roomy = Options(targetWords: 70, maxWords: 120, runOnSentenceWords: 130, sectionWords: 900)
    }

    static func chunk(pages: [TextExtractor.PageText], options: Options = .standard) -> BookText {
        var chunks: [Chunk] = []

        for page in stitchAcrossPages(pages) {
            // Runs of non-prose collapse into one card instead of thirty.
            var fragments: [String] = []

            func flushFragments() {
                guard !fragments.isEmpty else { return }
                for block in asideBlocks(fragments, options: options) {
                    chunks.append(Chunk(id: chunks.count,
                                        text: block.text,
                                        page: page.pageIndex,
                                        section: 0,
                                        startsParagraph: true,
                                        wordCount: wordCount(block.text),
                                        kind: block.kind))
                }
                fragments = []
            }

            for block in page.blocks {
                if case .heading(let title) = block {
                    // The extractor only calls something a heading when the
                    // typography says so, so it is one whatever its length or
                    // wording — no fragment test, which would throw away a
                    // one-word chapter title like "Evolution".
                    flushFragments()
                    chunks.append(Chunk(id: chunks.count,
                                        text: title,
                                        page: page.pageIndex,
                                        section: 0,
                                        startsParagraph: true,
                                        wordCount: wordCount(title),
                                        kind: .heading))
                    continue
                }
                guard case .paragraph(let paragraph) = block else {
                    if case .figure(let rect) = block {
                        flushFragments()
                        chunks.append(Chunk(id: chunks.count,
                                            text: "",
                                            page: page.pageIndex,
                                            section: 0,
                                            startsParagraph: true,
                                            wordCount: 0,
                                            kind: .figure,
                                            figure: FigureRegion(rect)))
                    }
                    continue
                }

                if isFragment(paragraph) {
                    fragments.append(paragraph)
                    continue
                }
                flushFragments()

                let sentences = splitSentences(paragraph, options: options)
                var buffer: [String] = []
                var bufferWords = 0
                var isFirstOfParagraph = true

                func flush() {
                    guard !buffer.isEmpty else { return }
                    let text = buffer.joined(separator: " ")
                    chunks.append(Chunk(id: chunks.count,
                                        text: text,
                                        page: page.pageIndex,
                                        section: 0,
                                        startsParagraph: isFirstOfParagraph,
                                        wordCount: bufferWords))
                    isFirstOfParagraph = false
                    buffer = []
                    bufferWords = 0
                }

                for sentence in sentences {
                    let words = wordCount(sentence)
                    if !buffer.isEmpty && bufferWords + words > options.maxWords {
                        flush()
                    }
                    buffer.append(sentence)
                    bufferWords += words
                    if bufferWords >= options.targetWords { flush() }
                }
                flush()
            }
            flushFragments()
        }

        let (sectioned, sections) = assignSections(to: chunks, options: options)
        return BookText(chunks: sectioned, sections: sections)
    }

    // MARK: - Non-prose

    /// A paragraph that isn’t meant to be read as sentences: a heading, a table
    /// row, an author line, a bare equation. Short and unterminated is the tell.
    static func isFragment(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return true }
        let words = wordCount(trimmed)

        // Contents-page dot leaders.
        if hasDotLeader(trimmed) { return true }

        // No sentence-ending punctuation anywhere in it. Index entries, table
        // rows and contents lines all look like this; prose essentially never
        // does, because extraction keeps the full stops.
        if !trimmed.contains(where: { sentenceEnders.contains($0) }) { return true }

        // Mostly symbols and digits: a stripped equation, a table row, a data
        // line. PDF extraction turns display maths into rubble, and rubble
        // presented as a sentence is worse than rubble labelled as an aside.
        if words < 60 && letterDensity(trimmed) < 0.62 { return true }

        if words >= 14 { return false }
        // A properly finished sentence is prose even when it is short. "Try one
        // now." is a sentence; six words was too high a bar, and the short ones
        // were being glued onto the heading that followed them.
        if sentenceEnders.contains(last), words >= 3 { return false }
        return true
    }

    private static func hasDotLeader(_ text: String) -> Bool {
        var run = 0
        for ch in text {
            if ch == "." { run += 1; if run >= 4 { return true } }
            else if ch == " " { continue }
            else { run = 0 }
        }
        return false
    }

    /// Share of characters that are letters or spaces. Ordinary prose sits well
    /// above 0.9; a line of maths sits far below it.
    static func letterDensity(_ text: String) -> Double {
        var good = 0
        var total = 0
        for ch in text where !ch.isWhitespace {
            total += 1
            if ch.isLetter || ch == "," || ch == "." || ch == "'" || ch == "\u{2019}" { good += 1 }
        }
        guard total > 0 else { return 0 }
        return Double(good) / Double(total)
    }

    private struct AsideBlock {
        var text: String
        var kind: ChunkKind
    }

    /// Groups a run of fragments into cards. A single short fragment standing on
    /// its own is a heading and gets its own card, which doubles as a useful
    /// signpost. Everything else is stacked, line per fragment, so a table still
    /// looks like a table.
    private static func asideBlocks(_ fragments: [String], options: Options) -> [AsideBlock] {
        if fragments.count == 1, wordCount(fragments[0]) <= 10 {
            return [AsideBlock(text: fragments[0], kind: .heading)]
        }

        var blocks: [AsideBlock] = []
        var lines: [String] = []
        var words = 0
        let lineLimit = 12

        func flush() {
            guard !lines.isEmpty else { return }
            blocks.append(AsideBlock(text: lines.joined(separator: "\n"), kind: .aside))
            lines = []
            words = 0
        }

        for fragment in fragments {
            let count = wordCount(fragment)
            if !lines.isEmpty && (lines.count >= lineLimit || words + count > options.maxWords * 2) {
                flush()
            }
            lines.append(fragment)
            words += count
        }
        flush()
        return blocks
    }

    // MARK: - Page boundaries

    /// A paragraph that runs off the bottom of one page and onto the next arrives
    /// here as two paragraphs. Left alone, that produces a card ending mid-clause
    /// at every page break — roughly once a page, which is exactly the kind of
    /// snag this app exists to remove. Rejoin them.
    static func stitchAcrossPages(_ pages: [TextExtractor.PageText]) -> [TextExtractor.PageText] {
        var result: [TextExtractor.PageText] = []

        for page in pages {
            var blocks = page.blocks
            guard !blocks.isEmpty else { result.append(page); continue }

            if let previous = result.last,
               case .paragraph(let tail)? = previous.blocks.last,
               case .paragraph(let head)? = blocks.first,
               continues(from: tail, into: head) {
                var merged = previous.blocks
                merged[merged.count - 1] = .paragraph(tail + " " + head)
                blocks.removeFirst()
                result[result.count - 1] = TextExtractor.PageText(pageIndex: previous.pageIndex,
                                                                  blocks: merged)
            }
            result.append(TextExtractor.PageText(pageIndex: page.pageIndex, blocks: blocks))
        }
        return result
    }

    private static func continues(from tail: String, into head: String) -> Bool {
        guard let lastChar = tail.last, let firstChar = head.first else { return false }
        // An unfinished sentence followed by something that isn’t a new sentence.
        let tailIsOpen = !".!?\u{201D}\"\u{2019}".contains(lastChar)
        let headIsContinuation = firstChar.isLowercase
            || firstChar == "\u{2014}" || firstChar == "," || firstChar == ";"
        return tailIsOpen && headIsContinuation
    }

    // MARK: - Sections

    private static func assignSections(to chunks: [Chunk], options: Options) -> ([Chunk], [Section]) {
        var chunks = chunks
        var sections: [Section] = []
        guard !chunks.isEmpty else { return (chunks, sections) }

        var sectionIndex = 0
        var first = 0
        var words = 0

        for i in chunks.indices {
            chunks[i].section = sectionIndex
            words += chunks[i].wordCount

            let isLast = i == chunks.count - 1
            // Prefer to break where a new paragraph starts, so a section is a
            // whole thought rather than a word count.
            let atNaturalBreak = isLast || (i + 1 < chunks.count && chunks[i + 1].startsParagraph)
            let longEnough = words >= options.sectionWords
            let wayTooLong = words >= options.sectionWords * 2

            if isLast || (longEnough && atNaturalBreak) || wayTooLong {
                sections.append(Section(id: sectionIndex,
                                        firstChunk: first,
                                        lastChunk: i,
                                        wordCount: words,
                                        startPage: chunks[first].page))
                sectionIndex += 1
                first = i + 1
                words = 0
            }
        }
        return (chunks, sections)
    }

    // MARK: - Sentences

    static func splitSentences(_ text: String, options: Options = .standard) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        if sentences.isEmpty {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { sentences = [t] }
        }
        return sentences.flatMap { splitRunOn($0, limit: options.runOnSentenceWords) }
    }

    /// Academic prose has sentences that run for half a page. Rather than let one
    /// card become a wall of text, break at clause boundaries — still a coherent
    /// unit, just a smaller one.
    private static func splitRunOn(_ sentence: String, limit: Int) -> [String] {
        guard wordCount(sentence) > limit else { return [sentence] }

        let breakers: [Character] = [";", ":", "\u{2014}",
                                     "\u{FF1B}",   // ；
                                     "\u{FF1A}",   // ：
                                     "\u{3001}"]   // 、 ideographic comma
        var parts: [String] = []
        var current = ""
        var currentWords = 0

        // Split on spaces where there are spaces, and on characters where there
        // are not, so a long CJK sentence can still be broken at a clause.
        let hasSpaces = sentence.contains(" ")
        let pieces: [String] = hasSpaces
            ? sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            : sentence.map(String.init)

        for word in pieces {
            current += (current.isEmpty || !hasSpaces ? "" : " ") + word
            currentWords += 1
            let last = word.last
            let isBreaker = last.map { breakers.contains($0) } ?? false
            let isComma = last == ","
            if currentWords >= limit / 2 && (isBreaker || (isComma && currentWords >= limit)) {
                parts.append(current)
                current = ""
                currentWords = 0
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.isEmpty ? [sentence] : parts
    }

    /// How much text a card is carrying.
    ///
    /// Counting runs between spaces is only right for languages that use them.
    /// Japanese and Chinese do not, so a 164-character paragraph counted as
    /// seven "words", the chunker kept pouring text in to reach its target, and
    /// readers of those languages got cards several times too long with
    /// unrelated paragraphs run together. Each ideograph or kana therefore
    /// counts as one, which is what word processors do and what keeps a card in
    /// those scripts about the size of a card in this one.
    static func wordCount(_ s: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in s.unicodeScalars {
            if isIdeographic(scalar) {
                count += 1
                inWord = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// Scripts written without spaces between words. Punctuation in the CJK
    /// block is left out: it separates, it is not a word in its own right.
    static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // hiragana and katakana
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xF900...0xFAFF,   // CJK compatibility
             0xAC00...0xD7AF:   // hangul syllables
            return true
        default:
            return false
        }
    }
}
