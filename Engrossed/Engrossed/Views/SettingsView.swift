import SwiftUI

struct SettingsView: View {
    @Environment(ReadingSettings.self) private var settings

    var body: some View {
        ScrollView {
            SettingsForm()
        }
        .background(settings.theme.background.ignoresSafeArea())
        // macOS only. A minimum width is how you stop a Mac window collapsing,
        // but on a 393pt phone a 460pt minimum is wider than the screen — the
        // sheet's contents are forced off the right edge and the whole thing
        // scrolls sideways.
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }
}

/// The controls themselves, separate from the scroll container so they can be
/// laid out and inspected on their own.
struct SettingsForm: View {
    @Environment(ReadingSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    private var theme: PaperTheme { settings.theme }

    @State private var store = Store.shared
    @State private var showPaywall = false
    /// What has been pasted into the key field and not saved yet. Emptied the
    /// moment it is saved, so the key isn't left sitting in view state.
    @State private var keyDraft = ""

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    var body: some View {
        @Bindable var settings = settings

        return VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("Reading")
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(SoftButtonStyle(theme: theme))
                        .keyboardShortcut(.escape, modifiers: [])
                }

                sample

                group("How much at a time") {
                    Picker("", selection: $settings.chunkSize) {
                        ForEach(ChunkSize.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    caption(settings.chunkSize.detail + " \u{00B7} cards always end on a whole sentence")
                }

                group("Look") {
                    Picker("", selection: $settings.theme) {
                        ForEach(PaperTheme.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Picker("", selection: $settings.font) {
                        ForEach(ReaderFont.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    slider("Text size", value: $settings.fontSize, range: 15...44, step: 1,
                           display: "\(Int(settings.fontSize))pt")
                    slider("Line spacing", value: $settings.lineSpacing, range: 1.1...2.2, step: 0.05,
                           display: String(format: "%.2f\u{00D7}", settings.lineSpacing))
                    slider("Line width", value: $settings.lineWidth, range: 34...86, step: 1,
                           display: "\(Int(settings.lineWidth)) chars")
                    caption(isCompact
                            ? "Accessibility guidance points at 50\u{2013}70 characters per line and 1.4\u{2013}1.6\u{00D7} spacing. On a phone the screen is narrower than that, so line width only bites at the low end."
                            : "Accessibility guidance points at 50\u{2013}70 characters per line and 1.4\u{2013}1.6\u{00D7} spacing. Both sliders start there.")

                    Button("Reset to those defaults") { settings.resetTypography() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.accent)
                }

                group("Focus") {
                    toggle("Ask me what I just read", $settings.checkpointsEnabled,
                           note: "A one-line recall prompt at the end of each stretch. The best-supported thing in this app. It closed the comprehension gap for ADHD readers in a controlled study.")

                    Text("A better recap is coming.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.ink.opacity(0.3))

                    toggle("Open straight into my book", $settings.openLastBookOnLaunch,
                           note: "Skips the shelf on launch and puts you back on the card you left. The shelf is one tap away.")

                    toggle("Step back a card when I return", $settings.rewindOnResume,
                           note: "Reopening drops you one card earlier, so you land inside the thought instead of at a cold edge.")

                    toggle("Hide overall progress", $settings.hideTotalProgress,
                           note: "Shows only where you are in the current stretch. \u{201C}4 of 11\u{201D} is finishable; \u{201C}3% of 200 pages\u{201D} is not.")
                }

                group("Sprints") {
                    toggle("Time-boxed sprints", $settings.sprintEnabled, note: nil)
                    if settings.sprintEnabled {
                        slider("Sprint length", value: $settings.sprintMinutes, range: 5...45, step: 5,
                               display: "\(Int(settings.sprintMinutes)) min")
                        caption("A bounded session has an edge to aim at. Around 20 minutes is the usual advice for reading with ADHD.")
                    }
                }

                group("Read aloud") {
                    toggle("Speak each card", $settings.speechEnabled,
                           note: "Cards advance when the voice finishes. Two channels for the same sentence gives attention more to hold, though for some people it’s just more noise. Try it and see.")
                    if settings.speechEnabled {
                        slider("Voice speed", value: $settings.speechRate, range: 0.32...0.60, step: 0.01,
                               display: String(format: "%.2f", settings.speechRate))
                    }
                    elevenLabsVoices(voice: $settings.elevenLabsVoice)
                }

                group("Extras") {
                    toggle("Bold the start of each word", $settings.fixationBolding,
                           note: "Some apps bold the first letters of every word. Worth knowing: a 2,074-person test found no speed gain, eye-tracking found no change in where people actually look, and comprehension on easy text dropped slightly. It’s here because some people like how it looks, not because it works.")
                    #if os(iOS)
                    toggle("Haptics", $settings.hapticsEnabled, note: nil)
                    #endif
                }

                group("Shelf") {
                    if store.isUnlocked {
                        caption("The shelf is unlocked. Thank you, genuinely.")
                    } else {
                        caption("One book at a time is free, forever. Delete it and add another as often as you like. Keeping several at once is a single payment.")
                        HStack(spacing: 10) {
                            Button("See the unlock") { showPaywall = true }
                                .buttonStyle(SoftButtonStyle(theme: theme))
                            Button("Restore purchase") { Task { await store.restore() } }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(theme.faint)
                                .disabled(store.isRestoring)
                        }
                    }
                }

                group("Guide") {
                    if library.guideBook == nil {
                        caption("The short walkthrough that came with the app. It does not use up your free book.")
                        Button("Put the guide back on my shelf") {
                            library.addGuide()
                            dismiss()
                        }
                        .buttonStyle(SoftButtonStyle(theme: theme))
                    } else {
                        caption("The guide is on your shelf. Remove it from there whenever you are done with it, and this button brings it back.")
                    }
                }

                group("Storage") {
                    Button("Clear parsed-text cache") {
                        library.clearCaches()
                    }
                    .buttonStyle(SoftButtonStyle(theme: theme))
                    caption("Your books and your places are kept. Only the extracted text is dropped, and it’s rebuilt the next time you open a book.")
                }
            }
        .padding(isCompact ? 20 : 30)
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showPaywall) {
            PaywallView().environment(settings)
        }
    }

    // MARK: - Sample

    private var sample: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if settings.fixationBolding {
                    Text(TextStyling.fixationBolded(sampleText, font: settings.bodyFont))
                } else {
                    Text(sampleText).font(settings.bodyFont)
                }
            }
            .lineSpacing(settings.resolvedLineSpacing)
            .foregroundStyle(theme.ink)
            .frame(maxWidth: settings.maxTextWidth, alignment: .leading)
        }
        .padding(18)
        // Bounded on purpose. The preview sits above the sliders in the same
        // scrolling column, so an unbounded one grows as the text size rises
        // and pushes the very slider being dragged down out from under the
        // reader's finger, and then off the bottom of the sheet.
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 210, alignment: .topLeading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(theme.ink.opacity(0.045)))
    }

    private let sampleText = "This is roughly what a card will look like. Change anything below and it updates here, so you can tune it without opening a book."

    // MARK: - ElevenLabs

    /// The one optional extra: a reader's own ElevenLabs key, for nicer voices.
    /// Leaving it empty changes nothing. With a key saved, the field gives way
    /// to the voice choice, because a saved key is never shown again, not even
    /// masked: there is nothing a reader can do with it on screen but leak it.
    private func elevenLabsVoices(voice: Binding<ElevenLabs.Voice>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("ElevenLabs voices (optional)")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(theme.ink.opacity(0.85))

            if settings.hasElevenLabsKey {
                Picker("", selection: voice) {
                    ForEach(ElevenLabs.Voice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button("Remove key") { settings.removeElevenLabsKey() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.accent)
            } else {
                HStack(spacing: 9) {
                    SecureField("Paste an ElevenLabs API key", text: $keyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.ink.opacity(0.06)))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .onSubmit(saveKey)

                    Button("Save", action: saveKey)
                        .buttonStyle(SoftButtonStyle(theme: theme))
                        .disabled(ElevenLabs.cleanedKey(keyDraft) == nil)
                        .opacity(ElevenLabs.cleanedKey(keyDraft) == nil ? 0.45 : 1)
                }
            }

            caption("Needs a paid ElevenLabs plan. While an ElevenLabs voice is reading, the text of each card is sent to ElevenLabs with your key. Nothing else is sent.")
        }
    }

    /// Stores the key and nothing more. It isn't tried against ElevenLabs
    /// here; the first card read aloud does that, and says what's wrong if
    /// anything is.
    private func saveKey() {
        guard settings.saveElevenLabsKey(keyDraft) else { return }
        keyDraft = ""
    }

    // MARK: - Builders

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            QuietLabel(text: title.uppercased(), theme: theme)
            content()
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11.5, design: .rounded))
            .foregroundStyle(theme.ink.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A labelled slider.
    ///
    /// Side by side, the fixed 104pt label and 62pt readout leave the slider
    /// about 140pt on a phone — a control too short to set a value with any
    /// precision. On a narrow screen the label moves above the track instead, so
    /// the slider gets the full width.
    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double, display: String) -> some View {
        Group {
            if isCompact {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(label)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(theme.ink.opacity(0.75))
                        Spacer()
                        Text(display)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.faint)
                    }
                    Slider(value: value, in: range, step: step)
                }
            } else {
                HStack(spacing: 12) {
                    Text(label)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(theme.ink.opacity(0.75))
                        .frame(width: 104, alignment: .leading)
                    Slider(value: value, in: range, step: step)
                    Text(display)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.faint)
                        .frame(width: 62, alignment: .trailing)
                }
            }
        }
    }

    private func toggle(_ label: String, _ value: Binding<Bool>, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: value) {
                Text(label)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(theme.ink.opacity(0.85))
            }
            .toggleStyle(.switch)
            if let note { caption(note) }
        }
    }
}
