import Foundation
import AVFoundation
import Observation

/// Optional read-aloud. Hearing a line while reading it gives attention a second
/// channel to hold onto, which is why audiobook-plus-text is a common ADHD
/// strategy. Off by default; some people find it doubles the noise instead.
///
/// Two voices sit behind the one `speak`. The built-in system voice is the
/// default, costs nothing and never leaves the device. If the reader has pasted
/// in their own ElevenLabs key, the same card is fetched as audio and played
/// instead. Either way `speak`, `stop`, `isSpeaking` and `onFinish` mean exactly
/// what they always did, so the reader views never need to know which is
/// talking.
///
/// The paid voice is spending someone's money, so it is careful: one request
/// per card, never a retry, at most one card fetched ahead, and the last few
/// cards kept so going back doesn't pay twice. Whatever goes wrong, the card is
/// read with the built-in voice instead and the reader is told once, quietly.
@Observable
final class Narrator {
    private(set) var isSpeaking = false

    /// Why the ElevenLabs voice stepped aside, in one sentence. Set once when a
    /// request fails and kept for the rest of the book, so the reader can see
    /// why the voice changed without being interrupted by it.
    private(set) var notice: String?

    private let synthesizer = AVSpeechSynthesizer()
    private let delegateBox = DelegateBox()
    private let playerBox = PlayerBox()

    /// One card's worth of paid speech, with what's needed to fall back to the
    /// built-in voice for that same card if it doesn't work out.
    private struct Card {
        let line: ElevenLabs.Line
        let text: String
        let rate: Double
        let attempt: Attempt
    }

    /// The key and voice a request was made with. After a failure the narrator
    /// stays on the built-in voice until one of these changes, so a broken key
    /// can't fire a failing request on every card. The key is identified by
    /// its revision, never by the key itself.
    private struct Attempt: Equatable {
        let keyRevision: Int
        let voice: ElevenLabs.Voice
    }

    private struct Pending {
        let id: Int
        let task: Task<Data, Error>
    }

    // Bookkeeping for the paid voice. No view reads any of it, so none of it
    // needs observing.

    /// Bumped by every `speak` and `stop`. A response checks it on arrival and
    /// is dropped if the reader has moved on: late audio must never start over
    /// a card it doesn't belong to.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    /// The card whose audio is playing now.
    @ObservationIgnored private var playing: Card?
    /// The card that has been asked for and is still on its way.
    @ObservationIgnored private var awaiting: Card?
    /// The next card, handed over by `prepare`, waiting for this one to start.
    @ObservationIgnored private var upNext: (text: String, rate: Double)?
    /// The next card once its request has actually gone out.
    @ObservationIgnored private var prefetching: ElevenLabs.Line?
    @ObservationIgnored private var requests: [ElevenLabs.Line: Pending] = [:]
    @ObservationIgnored private var requestCount = 0
    @ObservationIgnored private var cache = ElevenLabs.AudioCache(limit: 20)
    @ObservationIgnored private var failedAttempt: Attempt?

    init() {
        delegateBox.onFinish = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
                self?.onFinish?()
            }
        }
        synthesizer.delegate = delegateBox
        playerBox.onFinish = { [weak self] player, succeeded in
            Task { @MainActor in
                self?.playerFinished(player, succeeded: succeeded)
            }
        }
    }

    /// Called when an utterance completes, so Cards mode can auto-advance.
    var onFinish: (() -> Void)?

    func speak(_ text: String, rate: Double) {
        halt()
        configureAudioSession()
        isSpeaking = true
        if let paid = elevenLabs(),
           let line = ElevenLabs.Line(text: text, voice: paid.attempt.voice, speechRate: rate) {
            speakWithElevenLabs(Card(line: line, text: text, rate: rate, attempt: paid.attempt),
                                key: paid.key)
        } else {
            speakBuiltIn(text, rate: rate)
        }
        // Whatever was fetched ahead is now either the card just started, held
        // as `awaiting`, or one the reader skipped past. Either way it is no
        // longer "next", and anything still on its way for a skipped card is
        // let go.
        prefetching = nil
        cancelUnwantedRequests()
    }

    /// Readies the card after this one, so the paid voice can start the moment
    /// this one ends instead of after a pause for the network.
    ///
    /// Nothing is fetched until this card's own audio is actually playing. If
    /// this card fails, or the reader stops before it starts, the next one is
    /// never paid for. Does nothing at all for the built-in voice.
    func prepare(_ text: String, rate: Double) {
        upNext = (text, rate)
        prefetchIfPlaying()
    }

    func stop() {
        halt()
        prefetching = nil
        cancelUnwantedRequests()
    }

    /// The reader moved to a card that isn't read aloud, such as a table or a
    /// figure. Whatever is already playing carries on, exactly as the built-in
    /// voice always has. But paid audio still on its way for the card before is
    /// dropped, because it would otherwise start over a card it doesn't belong
    /// to.
    func dropPendingAudio() {
        guard awaiting != nil else { return }
        generation += 1
        awaiting = nil
        upNext = nil
        prefetching = nil
        isSpeaking = false
        cancelUnwantedRequests()
    }

    // MARK: - Built-in voice

    private func speakBuiltIn(_ text: String, rate: Double) {
        let utterance = AVSpeechUtterance(string: text)
        // AVSpeechUtteranceDefaultSpeechRate is 0.5; the slider maps around it.
        utterance.rate = Float(max(0.3, min(0.62, rate)))
        utterance.postUtteranceDelay = 0.15
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    /// Silences everything and makes any response still on its way stale.
    /// Requests themselves are left alone here: the one for the card about to
    /// be spoken may be among them, and cancelling it would mean paying twice.
    private func halt() {
        generation += 1
        player?.stop()
        player = nil
        playing = nil
        awaiting = nil
        upNext = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    // MARK: - ElevenLabs voice

    private struct Paid {
        let key: String
        let attempt: Attempt
    }

    /// The key to read this card with, or nil for the built-in voice.
    ///
    /// Someone who never added a key never touches the Keychain here: the
    /// settings mirror answers first. The key is read fresh for each card
    /// rather than kept, so removing it in Settings takes effect on the very
    /// next card.
    private func elevenLabs() -> Paid? {
        guard ReadingSettings.shared.hasElevenLabsKey else { return nil }
        let attempt = currentAttempt()
        if let failed = failedAttempt {
            guard failed != attempt else { return nil }
            // A new key, or the other voice, since it failed. That deserves a
            // fresh try, and the old sentence no longer applies.
            failedAttempt = nil
            notice = nil
        }
        guard let saved = Keychain.read(.elevenLabsKey),
              let key = ElevenLabs.cleanedKey(saved) else { return nil }
        return Paid(key: key, attempt: attempt)
    }

    private func currentAttempt() -> Attempt {
        let settings = ReadingSettings.shared
        return Attempt(keyRevision: settings.elevenLabsKeyRevision, voice: settings.elevenLabsVoice)
    }

    private func speakWithElevenLabs(_ card: Card, key: String) {
        if let audio = cache.audio(for: card.line) {
            play(audio, card)
            return
        }
        let pending = request(card.line, key: key, attempt: card.attempt)
        awaiting = card
        let ticket = generation
        Task { @MainActor [weak self] in
            let result = await pending.result
            // The reader stopped, moved or changed card while this was on its
            // way, so it must not play now. If it did arrive, it is already in
            // the cache for Back or for hearing the card again.
            guard let self, ticket == self.generation else { return }
            self.awaiting = nil
            switch result {
            case .success(let audio):
                self.play(audio, card)
            case .failure:
                // Already explained by the request itself, if there was
                // anything to explain. All that's left is not leaving the
                // reader in silence.
                self.speakBuiltIn(card.text, rate: card.rate)
            }
        }
    }

    /// The request for one card, or the one already on its way for it. Asking
    /// twice for the same card, which is what happens when a prefetched card
    /// comes up before its audio has arrived, shares the first request instead
    /// of paying for a second.
    private func request(_ line: ElevenLabs.Line, key: String, attempt: Attempt) -> Task<Data, Error> {
        if let pending = requests[line] { return pending.task }
        requestCount += 1
        let id = requestCount
        let task = Task { @MainActor [weak self] () async throws -> Data in
            let result: Result<Data, Error>
            do {
                result = .success(try await ElevenLabs.audio(for: line, apiKey: key))
            } catch {
                result = .failure(error)
            }
            self?.requestEnded(id, line, result, attempt)
            return try result.get()
        }
        requests[line] = Pending(id: id, task: task)
        return task
    }

    private func requestEnded(_ id: Int, _ line: ElevenLabs.Line,
                              _ result: Result<Data, Error>, _ attempt: Attempt) {
        // Only forget the entry if it is still this request's. A cancelled one
        // can finish after a fresh request for the same card has taken its
        // place.
        if requests[line]?.id == id { requests[line] = nil }
        switch result {
        case .success(let audio):
            cache.store(audio, for: line)
        case .failure(let error):
            if let failure = ElevenLabs.failure(for: error) {
                stepAside(failure, attempt)
            }
        }
    }

    private func play(_ audio: Data, _ card: Card) {
        guard let player = try? AVAudioPlayer(data: audio, fileTypeHint: AVFileType.mp3.rawValue) else {
            unplayable(card)
            return
        }
        player.delegate = playerBox
        self.player = player
        playing = card
        guard player.play() else {
            self.player = nil
            playing = nil
            unplayable(card)
            return
        }
        prefetchIfPlaying()
    }

    /// Audio that came back but won't play. It is not kept, so it can't fail
    /// again from the cache, and the card is read with the built-in voice.
    private func unplayable(_ card: Card) {
        cache.remove(card.line)
        stepAside(.unreachable, card.attempt)
        speakBuiltIn(card.text, rate: card.rate)
    }

    private func playerFinished(_ finished: AVAudioPlayer, succeeded: Bool) {
        // A player that was stopped or replaced has nothing more to say.
        guard finished === player, let card = playing else { return }
        player = nil
        playing = nil
        if succeeded {
            isSpeaking = false
            onFinish?()
        } else {
            unplayable(card)
        }
    }

    /// Fetches the card handed over by `prepare`, once this card is playing.
    private func prefetchIfPlaying() {
        guard player != nil, let next = upNext else { return }
        upNext = nil
        guard let paid = elevenLabs(),
              let line = ElevenLabs.Line(text: next.text, voice: paid.attempt.voice,
                                         speechRate: next.rate) else { return }
        prefetching = line
        if cache.audio(for: line) == nil {
            _ = request(line, key: paid.key, attempt: paid.attempt)
        }
        cancelUnwantedRequests()
    }

    /// Lets go of every request no card wants any more: anything other than the
    /// card being waited for and the one fetched ahead. That keeps at most two
    /// open at once, which matters because ElevenLabs limits how many requests
    /// one account can have in flight, and tripping that limit by ourselves
    /// would look to the reader like their account had failed.
    private func cancelUnwantedRequests() {
        let wanted = [awaiting?.line, prefetching].compactMap { $0 }
        for (line, pending) in requests where !wanted.contains(line) {
            pending.task.cancel()
            requests[line] = nil
        }
    }

    /// Stops using ElevenLabs for the rest of this book, and says why, once.
    ///
    /// Reopening the book, pasting a different key or choosing the other voice
    /// all give it another try. Until then, every card is read with the
    /// built-in voice, and nothing else is sent.
    private func stepAside(_ failure: ElevenLabs.Failure, _ attempt: Attempt) {
        // A late failure from a key or voice the reader has already changed
        // says nothing about the current one.
        guard failedAttempt != attempt, attempt == currentAttempt() else { return }
        failedAttempt = attempt
        notice = failure.message
        upNext = nil
        prefetching = nil
        cancelUnwantedRequests()
    }

    // MARK: - Delegates

    private final class DelegateBox: NSObject, AVSpeechSynthesizerDelegate {
        var onFinish: (() -> Void)?
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            onFinish?()
        }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}
    }

    /// The player's delegate, kept on its own object for the same reason as
    /// `DelegateBox`: the delegate has to be an NSObject, and the narrator is
    /// an observable Swift class that is better left as one.
    private final class PlayerBox: NSObject, AVAudioPlayerDelegate {
        var onFinish: ((AVAudioPlayer, Bool) -> Void)?
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            onFinish?(player, flag)
        }
        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            onFinish?(player, false)
        }
    }
}
