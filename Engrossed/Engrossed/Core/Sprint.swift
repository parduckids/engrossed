import Foundation
import Observation

/// A reading sprint: a bounded stretch of time with a visible end.
///
/// The bound is the point. An open-ended "read 200 pages" has no edge to aim at;
/// twenty minutes does, and it also forces the break that stops a session from
/// quietly decaying into staring at the same card.
@Observable
final class Sprint {
    private(set) var elapsed: TimeInterval = 0
    private(set) var isRunning = false
    private(set) var didFinish = false
    private(set) var chunksThisSprint = 0
    private(set) var wordsThisSprint = 0

    var targetMinutes: Double = 20

    private var timer: Timer?
    private var lastTick: Date?

    var remaining: TimeInterval { max(0, targetMinutes * 60 - elapsed) }

    var fractionComplete: Double {
        guard targetMinutes > 0 else { return 0 }
        return min(1, elapsed / (targetMinutes * 60))
    }

    var remainingText: String {
        let total = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        didFinish = false
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func pause() {
        // Bank the time since the last tick first: tick() checks isRunning, so
        // clearing the flag before calling it threw away every partial second.
        tick()
        isRunning = false
        timer?.invalidate()
        timer = nil
        lastTick = nil
    }

    func restart() {
        elapsed = 0
        didFinish = false
        chunksThisSprint = 0
        wordsThisSprint = 0
        start()
    }

    /// Time consumed since the last drain, for crediting the book’s total.
    private var undrained: TimeInterval = 0
    func drainReadingTime() -> TimeInterval {
        defer { undrained = 0 }
        return undrained
    }

    func recordChunk(words: Int) {
        chunksThisSprint += 1
        wordsThisSprint += words
    }

    private func tick() {
        guard isRunning, let last = lastTick else { return }
        let now = Date()
        let delta = now.timeIntervalSince(last)
        lastTick = now
        // Ignore huge deltas from sleep/backgrounding — you weren’t reading.
        guard delta < 90 else { return }
        elapsed += delta
        undrained += delta
        if !didFinish && remaining <= 0 {
            didFinish = true
            isRunning = false
            timer?.invalidate()
            timer = nil
        }
    }

    deinit { timer?.invalidate() }
}
