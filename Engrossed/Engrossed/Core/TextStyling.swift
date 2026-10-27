import Foundation
import SwiftUI

enum TextStyling {

    /// Bolds the leading fraction of each word ("bionic"-style).
    ///
    /// Included as an option, not a feature we lean on: eye-tracking work found
    /// fixations spread across the whole word regardless, a 2,000-person test
    /// found no speed gain, and comprehension on easy text got slightly *worse*.
    /// Some readers still prefer how it looks, so it’s a toggle, off by default.
    static func fixationBolded(_ text: String, font: Font) -> AttributedString {
        var result = AttributedString()
        var index = text.startIndex

        while index < text.endIndex {
            // Copy any run of non-letters verbatim.
            if !text[index].isLetter {
                var run = ""
                while index < text.endIndex, !text[index].isLetter {
                    run.append(text[index])
                    index = text.index(after: index)
                }
                var piece = AttributedString(run)
                piece.font = font
                result.append(piece)
                continue
            }

            var word = ""
            while index < text.endIndex, text[index].isLetter || text[index] == "'" || text[index] == "\u{2019}" {
                word.append(text[index])
                index = text.index(after: index)
            }

            let boldCount = boldPrefixLength(for: word.count)
            var head = AttributedString(String(word.prefix(boldCount)))
            head.font = font.weight(.bold)
            result.append(head)

            if word.count > boldCount {
                var tail = AttributedString(String(word.dropFirst(boldCount)))
                tail.font = font
                result.append(tail)
            }
        }
        return result
    }

    private static func boldPrefixLength(for length: Int) -> Int {
        switch length {
        case 0: return 0
        case 1: return 1
        case 2...3: return 1
        case 4...6: return 2
        case 7...9: return 3
        default: return max(3, Int(Double(length) * 0.4))
        }
    }

    /// The "optimal recognition point" — slightly left of centre — used to align
    /// successive words in Pace mode so the eye doesn’t have to re-aim.
    static func pivotIndex(of word: String) -> Int {
        let letters = word.count
        switch letters {
        case 0, 1: return 0
        case 2...5: return 1
        case 6...9: return 2
        case 10...13: return 3
        default: return 4
        }
    }

    /// Splits into display words, keeping punctuation attached.
    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Longer words and sentence-final words get held on screen a beat longer.
    /// Uniform timing is part of why fast RSVP hurts comprehension; this softens it.
    static func dwellMultiplier(for word: String) -> Double {
        var multiplier = 1.0
        if word.count >= 9 { multiplier += 0.45 }
        else if word.count >= 6 { multiplier += 0.2 }
        if let last = word.last {
            if Chunker.sentenceEnders.contains(last) { multiplier += 0.9 }
            else if ",;:\u{3001}\u{FF0C}".contains(last) { multiplier += 0.4 }
        }
        return multiplier
    }
}

extension View {
    /// Applies a tap/click handler plus a keyboard shortcut in one place.
    @ViewBuilder
    func plainButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { self }
            .buttonStyle(.plain)
    }
}
