import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum ReadingMode: String, CaseIterable, Identifiable, Codable {
    case chunk, flow, pace
    var id: String { rawValue }

    var label: String {
        switch self {
        case .chunk: return "Cards"
        case .flow: return "Flow"
        case .pace: return "Pace"
        }
    }

    var symbol: String {
        switch self {
        case .chunk: return "rectangle.portrait.on.rectangle.portrait"
        case .flow: return "text.alignleft"
        case .pace: return "metronome"
        }
    }

    var blurb: String {
        switch self {
        case .chunk: return "One small card at a time. Nothing else on screen."
        case .flow: return "Scrolling text with everything but the current spot dimmed."
        case .pace: return "Words appear one at a time at a steady speed you set."
        }
    }
}

enum ChunkSize: String, CaseIterable, Identifiable, Codable {
    case cozy, standard, roomy
    var id: String { rawValue }

    var label: String {
        switch self {
        case .cozy: return "Small"
        case .standard: return "Medium"
        case .roomy: return "Large"
        }
    }

    var detail: String {
        switch self {
        case .cozy: return "~25 words · a sentence or two"
        case .standard: return "~45 words · a few sentences"
        case .roomy: return "~70 words · a short paragraph"
        }
    }

    var options: Chunker.Options {
        switch self {
        case .cozy: return .cozy
        case .standard: return .standard
        case .roomy: return .roomy
        }
    }
}

enum PaperTheme: String, CaseIterable, Identifiable, Codable {
    case paper, warm, grey, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .paper: return "Paper"
        case .warm: return "Sepia"
        case .grey: return "Slate"
        case .dark: return "Night"
        }
    }

    var isDark: Bool { self == .dark || self == .grey }

    var background: Color {
        switch self {
        case .paper: return Color(red: 0.98, green: 0.976, blue: 0.965)
        case .warm:  return Color(red: 0.965, green: 0.933, blue: 0.867)
        case .grey:  return Color(red: 0.17, green: 0.18, blue: 0.20)
        case .dark:  return Color(red: 0.07, green: 0.07, blue: 0.08)
        }
    }

    var ink: Color {
        switch self {
        case .paper: return Color(red: 0.13, green: 0.13, blue: 0.14)
        case .warm:  return Color(red: 0.24, green: 0.18, blue: 0.11)
        case .grey:  return Color(red: 0.90, green: 0.91, blue: 0.93)
        case .dark:  return Color(red: 0.87, green: 0.86, blue: 0.84)
        }
    }

    var faint: Color { ink.opacity(0.45) }
    var whisper: Color { ink.opacity(0.18) }

    var accent: Color {
        switch self {
        case .paper: return Color(red: 0.72, green: 0.34, blue: 0.42)
        case .warm:  return Color(red: 0.70, green: 0.38, blue: 0.20)
        case .grey:  return Color(red: 0.56, green: 0.74, blue: 0.86)
        case .dark:  return Color(red: 0.87, green: 0.60, blue: 0.52)
        }
    }

    /// The solid fill behind a prominent button.
    ///
    /// Deliberately separate from `accent`: a fill has to carry legible text on
    /// top of it, so it is constrained by contrast in a way a decorative accent
    /// is not. The two light themes are darkened slightly here to clear WCAG AA
    /// against white; the dark themes keep their accent and change the label
    /// instead. Everything else that uses `accent` carries no text and is
    /// unaffected.
    var accentFill: Color {
        switch self {
        case .paper: return Color(red: 0.66, green: 0.29, blue: 0.37)
        case .warm:  return Color(red: 0.63, green: 0.33, blue: 0.16)
        case .grey:  return Color(red: 0.56, green: 0.74, blue: 0.86)
        case .dark:  return Color(red: 0.87, green: 0.60, blue: 0.52)
        }
    }

    /// Text that sits on top of `accentFill`. Always change this together with
    /// `accentFill`: they are a contrast pair, and white on the light accents
    /// the dark themes use is unreadable.
    var onAccent: Color {
        switch self {
        case .paper, .warm: return .white
        case .grey, .dark:  return Color(red: 0.10, green: 0.10, blue: 0.11)
        }
    }

    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

enum ReaderFont: String, CaseIterable, Identifiable, Codable {
    case serif, sans, rounded, mono
    var id: String { rawValue }

    var label: String {
        switch self {
        case .serif: return "Serif"
        case .sans: return "Sans"
        case .rounded: return "Rounded"
        case .mono: return "Mono"
        }
    }

    var design: Font.Design {
        switch self {
        case .serif: return .serif
        case .sans: return .default
        case .rounded: return .rounded
        case .mono: return .monospaced
        }
    }
}

/// Every reading preference, persisted in UserDefaults so the app looks the same
/// the next time you open it.
@Observable
final class ReadingSettings {
    static let shared = ReadingSettings()

    var mode: ReadingMode { didSet { store(mode.rawValue, "mode") } }
    var chunkSize: ChunkSize { didSet { store(chunkSize.rawValue, "chunkSize") } }
    var theme: PaperTheme { didSet { store(theme.rawValue, "theme") } }
    var font: ReaderFont { didSet { store(font.rawValue, "font") } }

    /// Point size of body text.
    var fontSize: Double { didSet { store(fontSize, "fontSize") } }
    /// Multiple of font size. 1.4–1.6 is the readable range in the accessibility
    /// guidance, so that’s where the slider sits by default.
    var lineSpacing: Double { didSet { store(lineSpacing, "lineSpacing") } }
    /// Measured in characters. 50–70 is the recommended band.
    var lineWidth: Double { didSet { store(lineWidth, "lineWidth") } }

    /// Words per minute for Pace mode. Capped at 350 on purpose: comprehension
    /// holds up to ~350 wpm and falls off measurably above it.
    var wordsPerMinute: Double { didSet { store(wordsPerMinute, "wpm") } }

    /// Bold the first letters of each word. Off by default — controlled studies
    /// find no benefit, so it’s here only because some people report liking it.
    var fixationBolding: Bool { didSet { store(fixationBolding, "fixationBolding") } }

    /// Ask a one-line recall question at the end of each stretch.
    var checkpointsEnabled: Bool { didSet { store(checkpointsEnabled, "checkpoints") } }

    /// On reopening, step back a card so you land in context rather than cold.
    var rewindOnResume: Bool { didSet { store(rewindOnResume, "rewindOnResume") } }

    /// Launch straight into the book you were reading, skipping the shelf.
    /// The gap between opening the app and reading the first word is where a
    /// session is most often lost, so the default is to remove it.
    var openLastBookOnLaunch: Bool { didSet { store(openLastBookOnLaunch, "openLast") } }

    /// Length of a reading sprint, in minutes.
    var sprintMinutes: Double { didSet { store(sprintMinutes, "sprintMinutes") } }
    var sprintEnabled: Bool { didSet { store(sprintEnabled, "sprintEnabled") } }

    /// Hide the overall percentage; show only position within the current stretch.
    var hideTotalProgress: Bool { didSet { store(hideTotalProgress, "hideTotalProgress") } }

    var speechEnabled: Bool { didSet { store(speechEnabled, "speechEnabled") } }
    var speechRate: Double { didSet { store(speechRate, "speechRate") } }

    /// Which ElevenLabs voice reads, once a reader has pasted in a key. Only
    /// the choice lives here. The key itself is in the Keychain, never in
    /// UserDefaults.
    var elevenLabsVoice: ElevenLabs.Voice { didSet { store(elevenLabsVoice.rawValue, "elevenLabsVoice") } }

    /// Whether a key is saved. A mirror of the Keychain, never stored, kept here
    /// for two reasons: Settings can switch between the field and the voice
    /// choice without reading the secret out, and the narrator can skip the
    /// Keychain entirely for everyone who never added a key.
    private(set) var hasElevenLabsKey: Bool

    /// Goes up each time the key is saved or removed. After a failure the
    /// narrator stops trying ElevenLabs for the rest of the book, and this is
    /// how it notices a new key deserves a fresh try without holding on to the
    /// old one to compare against.
    private(set) var elevenLabsKeyRevision = 0

    var hapticsEnabled: Bool { didSet { store(hapticsEnabled, "haptics") } }

    private let defaults = UserDefaults.standard
    private static let prefix = "reading."

    private init() {
        let d = UserDefaults.standard
        func key(_ k: String) -> String { ReadingSettings.prefix + k }
        func double(_ k: String, _ fallback: Double) -> Double {
            d.object(forKey: key(k)) as? Double ?? fallback
        }
        func bool(_ k: String, _ fallback: Bool) -> Bool {
            d.object(forKey: key(k)) as? Bool ?? fallback
        }

        mode = ReadingMode(rawValue: d.string(forKey: key("mode")) ?? "") ?? .chunk
        chunkSize = ChunkSize(rawValue: d.string(forKey: key("chunkSize")) ?? "") ?? .standard
        theme = PaperTheme(rawValue: d.string(forKey: key("theme")) ?? "") ?? .paper
        font = ReaderFont(rawValue: d.string(forKey: key("font")) ?? "") ?? .serif
        #if os(iOS)
        // An iPad is held further away and has room for a proper column.
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let defaultFontSize: Double = isPad ? 24 : 20
        #else
        let defaultFontSize: Double = 25
        #endif
        fontSize = double("fontSize", defaultFontSize)
        lineSpacing = double("lineSpacing", 1.5)
        lineWidth = double("lineWidth", 60)
        wordsPerMinute = min(double("wpm", 280), 350)
        fixationBolding = bool("fixationBolding", false)
        checkpointsEnabled = bool("checkpoints", true)
        rewindOnResume = bool("rewindOnResume", true)
        openLastBookOnLaunch = bool("openLast", true)
        sprintMinutes = double("sprintMinutes", 20)
        sprintEnabled = bool("sprintEnabled", true)
        hideTotalProgress = bool("hideTotalProgress", true)
        speechEnabled = bool("speechEnabled", false)
        speechRate = double("speechRate", 0.48)
        elevenLabsVoice = ElevenLabs.Voice(rawValue: d.string(forKey: key("elevenLabsVoice")) ?? "") ?? .woman
        hasElevenLabsKey = Keychain.contains(.elevenLabsKey)
        hapticsEnabled = bool("haptics", true)
    }

    private func store(_ value: Any, _ k: String) {
        defaults.set(value, forKey: ReadingSettings.prefix + k)
    }

    // MARK: - ElevenLabs key

    /// Keeps a pasted key. Nothing is sent to ElevenLabs to check it: a check
    /// would cost credits, and a key limited to Text to Speech can't answer the
    /// questions a check would ask. The first card read aloud is the test, and
    /// if it fails the reader is told why in one sentence.
    @discardableResult
    func saveElevenLabsKey(_ pasted: String) -> Bool {
        guard let key = ElevenLabs.cleanedKey(pasted),
              Keychain.save(key, for: .elevenLabsKey) else { return false }
        hasElevenLabsKey = true
        elevenLabsKeyRevision += 1
        return true
    }

    func removeElevenLabsKey() {
        Keychain.delete(.elevenLabsKey)
        hasElevenLabsKey = Keychain.contains(.elevenLabsKey)
        elevenLabsKeyRevision += 1
    }

    // MARK: - Derived

    var bodyFont: Font { .system(size: fontSize, design: font.design) }
    var resolvedLineSpacing: Double { fontSize * (lineSpacing - 1) }
    /// Rough em-width conversion from a character count to points.
    var maxTextWidth: Double { lineWidth * fontSize * 0.5 }

    func resetTypography() {
        fontSize = 25
        lineSpacing = 1.5
        lineWidth = 60
    }
}
