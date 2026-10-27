import Foundation

/// The one optional extra for read aloud: a reader's own ElevenLabs key, for a
/// voice that sounds like a person rather than a system voice.
///
/// Everything here is plain data in and plain data out, with no Keychain, no
/// settings and no audio, so it can be checked on its own. The key is passed
/// in for the single request that needs it and goes nowhere else: not into a
/// URL, not into a cache key, not into an error message. The server's own
/// error text is never shown either, because a reader should get one calm
/// sentence they can act on, and because it is not ours to vouch for.
///
/// What is deliberately not here: no call to `/v1/user`, `/v1/voices` or
/// `/v1/models`. A key can be made with Text to Speech access only, and a key
/// like that answers those with a refusal. Asking would turn a perfectly good
/// key into an error. Nor is the key "tested" on save: a test request costs
/// credits, and the first card read aloud is the test anyway.
enum ElevenLabs {

    // MARK: - Voices

    /// The two voices on offer. Named for what a reader is choosing between,
    /// not for the voices themselves, because nobody picks a narrator by the
    /// name of a stranger.
    enum Voice: String, CaseIterable, Identifiable {
        case woman, man
        var id: String { rawValue }

        var label: String {
            switch self {
            case .woman: return "Woman"
            case .man: return "Man"
            }
        }

        /// The only place either voice is named. Swapping one is this line and
        /// nothing else. Both are permanent library voices, which is why they
        /// need a paid plan: a free key gets a 402 and the reader is told so.
        var voiceID: String {
            switch self {
            case .woman: return "WQP7cQUF5aAS6Axh5yaa" // Elara, "Crisp Pro Narrator"
            case .man: return "gOupLcAkjEnguROwi4oS"   // Darian, "Warm Grounded Storyteller"
            }
        }
    }

    /// Flash rather than Multilingual v2: Flash speaks Hungarian, and v2 does
    /// not. It is also the cheaper and faster of the two, which suits a card
    /// that is read once and moved past.
    static let modelID = "eleven_flash_v2_5"

    /// 64 kbps is plenty for one voice, and half the bytes of the default.
    static let outputFormat = "mp3_44100_64"

    /// The only speeds the API accepts. Anything outside it is a 400, and a 400
    /// on every card would mean nothing ever plays, so speed is clamped here
    /// rather than trusted from anywhere.
    static let speedRange: ClosedRange<Double> = 0.7...1.2

    // MARK: - Key and speed

    /// A pasted key, cleaned up. Pasting often brings a stray space or newline
    /// with it, which would otherwise be sent and rejected. The prefix is not
    /// checked: newer keys start with "sk_", older ones are plain hex, and both
    /// work.
    static func cleanedKey(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// The built-in voice's speed slider, carried over to ElevenLabs.
    ///
    /// The slider is an `AVSpeechUtterance` rate from 0.32 to 0.60, and
    /// ElevenLabs takes a multiplier from 0.7 to 1.2. Mapping one range onto the
    /// other keeps the reader's choice meaning the same thing in both voices:
    /// the default 0.48 lands at about 0.99, a natural pace.
    static func speed(forSpeechRate rate: Double) -> Double {
        guard rate.isFinite else { return 1 }
        return clampedSpeed(0.7 + (rate - 0.32) / 0.28 * 0.5)
    }

    /// Clamped into the accepted range and rounded to two places. The rounding
    /// matters for the cache: a slider nudged by a hair would otherwise make a
    /// "different" speed and pay again for the same card.
    static func clampedSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1 }
        let clamped = min(max(speed, speedRange.lowerBound), speedRange.upperBound)
        return (clamped * 100).rounded() / 100
    }

    // MARK: - One card's speech

    /// Everything that decides what one card sounds like: the words, the voice
    /// and the speed. Two equal lines are the same audio, so this is also what
    /// the cache is keyed by. There is no key in it on purpose. Audio does not
    /// depend on whose key paid for it, and a secret has no business sitting
    /// in a dictionary key.
    struct Line: Hashable {
        let text: String
        let voice: Voice
        let speed: Double

        /// Nil for a card with nothing to say. ElevenLabs answers blank text
        /// with a 200 and charges for it, so it is never sent.
        init?(text: String, voice: Voice, speechRate: Double) {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return nil }
            self.text = words
            self.voice = voice
            self.speed = ElevenLabs.speed(forSpeechRate: speechRate)
        }
    }

    private struct Body: Encodable {
        let text: String
        let modelID: String
        let voiceSettings: VoiceSettings

        struct VoiceSettings: Encodable {
            let stability: Double
            let similarityBoost: Double
            let speed: Double

            enum CodingKeys: String, CodingKey {
                case stability
                case similarityBoost = "similarity_boost"
                case speed
            }
        }

        enum CodingKeys: String, CodingKey {
            case text
            case modelID = "model_id"
            case voiceSettings = "voice_settings"
        }
    }

    /// The request for one card. Nil rather than a half-built request if the
    /// key is blank or the body can't be made, so nothing is ever sent that
    /// could not succeed.
    ///
    /// The key travels in a header and only there. A query string ends up in
    /// server logs and proxies; a header does not.
    static func request(for line: Line, apiKey: String) -> URLRequest? {
        guard let key = cleanedKey(apiKey) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.elevenlabs.io"
        components.path = "/v1/text-to-speech/\(line.voice.voiceID)"
        components.queryItems = [URLQueryItem(name: "output_format", value: outputFormat)]
        guard let url = components.url else { return nil }

        let body = Body(text: line.text,
                        modelID: modelID,
                        voiceSettings: .init(stability: 0.5,
                                             similarityBoost: 0.75,
                                             speed: clampedSpeed(line.speed)))
        guard let json = try? JSONEncoder().encode(body) else { return nil }

        // Fifteen seconds, not the default sixty. Flash answers in about a
        // second; past fifteen it is not coming, and the reader should hear the
        // built-in voice rather than sit in silence for a minute.
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = json
        return request
    }

    /// Ephemeral, with no cache and no cookies: the text of a book is not
    /// something to leave lying around on disk because a response happened to
    /// pass through `URLCache`.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    /// One card's audio, as MP3 bytes.
    ///
    /// One request and no retries, ever. A retry is a second charge for the
    /// same card, and a loop of them against a broken key is how a reader's
    /// credits vanish overnight. Anything that goes wrong is thrown as a
    /// `Failure` (or as the cancellation it was) and the caller falls back.
    static func audio(for line: Line, apiKey: String,
                      session: URLSession = ElevenLabs.session) async throws -> Data {
        guard let request = request(for: line, apiKey: apiKey) else {
            throw Failure.unreachable
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        guard http.statusCode == 200, !data.isEmpty else {
            throw failure(httpStatus: http.statusCode, body: data)
        }
        return data
    }

    // MARK: - Failures

    /// What went wrong, in the few kinds a reader can do something about.
    enum Failure: Error, Equatable {
        case keyRejected
        case keyCannotSpeak
        case needsPaidPlan
        case voiceUnavailable
        case busy
        case unreachable

        /// One calm sentence, shown once. Fixed text only: nothing from the
        /// server and nothing from the request, so the key can never end up on
        /// screen or in a screenshot of it.
        var message: String {
            switch self {
            case .keyRejected:
                return "ElevenLabs didn't accept that key."
            case .keyCannotSpeak:
                return "That key isn't allowed to make speech. Give it Text to Speech access in ElevenLabs."
            case .needsPaidPlan:
                return "These voices need a paid ElevenLabs plan."
            case .voiceUnavailable:
                return "That voice isn't available on your ElevenLabs account."
            case .busy:
                return "ElevenLabs is out of credits or busy right now."
            case .unreachable:
                return "Couldn't reach ElevenLabs."
            }
        }
    }

    /// ElevenLabs puts the useful part of an error in `detail.status`. Some
    /// errors carry a plain string or a list there instead, which simply fails
    /// to decode and falls through to the general message.
    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let status: String? }
        let detail: Detail?
    }

    /// Reads an error response. Matches on both the HTTP code and the status
    /// together, because the same code covers more than one problem: a 401 is
    /// either a bad key or a key without permission, and the fix differs.
    static func failure(httpStatus: Int, body: Data) -> Failure {
        let status = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.detail?.status
        switch (httpStatus, status) {
        case (401, "invalid_api_key"): return .keyRejected
        case (401, "missing_permissions"): return .keyCannotSpeak
        case (402, "payment_required"): return .needsPaidPlan
        case (404, "voice_not_found"): return .voiceUnavailable
        case (429, _): return .busy
        // Older accounts have been told about an empty balance this way rather
        // than with a 429. Same problem for the reader, same sentence.
        case (_, "quota_exceeded"): return .busy
        default: return .unreachable
        }
    }

    /// Any error from `audio(for:)`, as the reader should hear about it. Nil
    /// for a cancellation: that only ever happens to a request nobody wants any
    /// more, which says nothing about the key or the account.
    static func failure(for error: Error) -> Failure? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
        return error as? Failure ?? .unreachable
    }

    // MARK: - Cache

    /// The last few cards' audio, in memory only.
    ///
    /// Going back a card, or tapping the speaker to hear one again, is the most
    /// natural thing in this app, and without this each one would be paid for
    /// twice. Twenty cards is a good few minutes of reading, a few megabytes at
    /// most, and gone when the book is closed. Never on disk.
    struct AudioCache {
        let limit: Int
        private var entries: [Line: Data] = [:]
        /// Oldest first. Reading an entry moves it to the end, so the card the
        /// reader keeps returning to is the last to go.
        private var order: [Line] = []

        init(limit: Int) { self.limit = max(1, limit) }

        var count: Int { entries.count }

        mutating func audio(for line: Line) -> Data? {
            guard let audio = entries[line] else { return nil }
            touch(line)
            return audio
        }

        mutating func store(_ audio: Data, for line: Line) {
            entries[line] = audio
            touch(line)
            while order.count > limit {
                entries[order.removeFirst()] = nil
            }
        }

        mutating func remove(_ line: Line) {
            entries[line] = nil
            order.removeAll { $0 == line }
        }

        private mutating func touch(_ line: Line) {
            order.removeAll { $0 == line }
            order.append(line)
        }
    }
}
