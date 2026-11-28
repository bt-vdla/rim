import SwiftUI

/// Runs a breathing session. Steps are scheduled against their planned start time so light, sound and
/// haptics never drift apart; the views only ask where things are at a given moment.
@MainActor @Observable final class Session {
    enum State { case idle, running, paused }
    enum Limit { case minutes(Int), breaths(Int), open }

    struct Entry {
        var step: Step
        var start: Date
    }

    struct Summary: Identifiable {
        let id = UUID()
        var pattern: Pattern
        var seconds: Double
        var breaths: Int
        var holds: [Double]
        var heart: (start: Double, end: Double)?
    }

    private(set) var state: State = .idle
    private(set) var entries: [Entry] = []
    private(set) var breaths = 0
    private(set) var pattern: Pattern?
    private(set) var began = Date.now
    private(set) var pausedAt: Date?
    var summary: Summary?
    private(set) var holds: [Double] = []
    private(set) var finishedAt: Date?
    /// Where the light was when the session ended, so the closing bloom happens there.
    private(set) var endU = 0.125
    var onFinish: ((Summary, Date, Date) -> Void)?

    private var wallStart = Date.now
    private var feed: Feed?
    private var limit = Limit.open
    private var rounds = 3
    private var task: Task<Void, Never>?
    private let haptics = Haptics()
    private let tone = Tone()
    private let live = Live()
    let heart = Heart()

    var current: Entry? { entries.last }

    /// Share of the session done, or nil when it runs open-ended.
    var progress: Double? {
        if pattern?.id == .rounds { return Double(holds.count) / Double(max(rounds, 1)) }
        return switch limit {
        case .minutes(let m): activeSeconds / (Double(m) * 60)
        case .breaths(let n): Double(breaths) / Double(max(n, 1))
        case .open: nil
        }
    }
    var clock: Date { pausedAt ?? .now }
    var activeSeconds: Double { clock.timeIntervalSince(began) }

    func start(_ pattern: Pattern, store: Store) {
        let prefs = store.prefs
        self.pattern = pattern
        feed = Feed(pattern: pattern, pace: store.pace(pattern.id), powerBreaths: prefs.powerBreaths, rounds: prefs.rounds)
        feed?.easeIn = prefs.easeIn && [.sleep, .balance, .unwind, .steady, .custom].contains(pattern.id)
        limit = switch prefs.length {
        case .minutes: .minutes(prefs.minutes)
        case .breaths: .breaths(prefs.breaths)
        case .open: .open
        }
        if pattern.id == .urge { limit = .minutes(3) }
        rounds = prefs.rounds
        haptics.strength = Float(prefs.haptics)
        tone.style = prefs.sound
        tone.volume = prefs.volume
        tone.start()
        if prefs.heartRate || Heart.faking { heart.start() }
        breaths = 0
        holds = []
        entries = []
        summary = nil
        began = .now
        wallStart = .now
        pausedAt = nil
        state = .running
        UIApplication.shared.isIdleTimerDisabled = true
        advance(at: .now)
        if let current { live.start(pattern.id, state: liveState(current)) }
    }

    func pause() {
        guard state == .running else { return }
        pausedAt = .now
        state = .paused
        task?.cancel()
        haptics.stop()
        tone.pause()
    }

    func resume() {
        guard state == .paused, let pausedAt else { return }
        let gap = Date.now.timeIntervalSince(pausedAt)
        for i in entries.indices { entries[i].start += gap }
        began += gap
        self.pausedAt = nil
        state = .running
        guard let current else { return }
        let progress = current.step.seconds.map { Date.now.timeIntervalSince(current.start) / $0 } ?? 0
        cue(current.step, from: min(progress, 0.99))
        schedule()
    }

    /// Ends the hold in Rounds; the next breath starts now.
    func breathe() {
        guard state == .running, current?.step.retention == true else { return }
        advance(at: .now)
    }

    func end() {
        guard state != .idle else { return }
        finish(at: clock)
    }

    /// The swell under a hold-to-begin, the tap when it lands, or quiet if you let go early.
    func holdHaptic(strength: Double, duration: Double) {
        haptics.strength = Float(strength)
        haptics.holdSwell(duration: duration)
    }

    func landHaptic() { haptics.tap() }

    func cancelHaptics() { haptics.stop() }

    /// A sample breath for onboarding: an inhale swell, then an exhale fade, in haptics alone.
    func demoHaptics(strength: Double) {
        haptics.strength = Float(strength)
        haptics.play(Step(phase: .inhale, seconds: 3, word: ""), from: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [haptics] in
            haptics.play(Step(phase: .exhale, seconds: 3.5, word: ""), from: 0)
        }
    }

    func moment(at date: Date) -> Moment? {
        guard let first = entries.first else { return nil }
        let entry = entries.last { $0.start <= date } ?? first
        return entry.step.moment(max(0, date.timeIntervalSince(entry.start)))
    }

    private func advance(at date: Date) {
        if let last = current {
            if last.step.retention { holds.append(date.timeIntervalSince(last.start)) }
            if last.step.endsBreath {
                breaths += 1
                if reachedLimit(at: date) { return finish(at: date) }
            }
        }
        guard let step = feed?.next() else { return finish(at: date) }
        entries.append(Entry(step: step, start: date))
        if entries.count > 12 { entries.removeFirst() }
        cue(step, from: 0)
        schedule()
    }

    private func reachedLimit(at date: Date) -> Bool {
        switch limit {
        case .minutes(let m): date.timeIntervalSince(began) >= Double(m) * 60 - 0.5
        case .breaths(let n): breaths >= n
        case .open: false
        }
    }

    private func schedule() {
        task?.cancel()
        guard let current, let seconds = current.step.seconds else { return }
        let end = current.start.addingTimeInterval(seconds)
        task = Task { [weak self] in
            let wait = end.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self, self.state == .running else { return }
            self.advance(at: end)
        }
    }

    private func cue(_ step: Step, from progress: Double) {
        haptics.play(step, from: progress, startTap: entries.count == 1 && progress == 0)
        tone.cue(step, from: progress)
        if let current, !step.pulse || step.count == 1 { live.update(liveState(current)) }
    }

    private func liveState(_ entry: Entry) -> BreathActivity.ContentState {
        let end = entry.start.addingTimeInterval(entry.step.seconds ?? 3600)
        return .init(word: entry.step.word, start: entry.start, end: end, breaths: breaths)
    }

    private func finish(at date: Date) {
        task?.cancel()
        endU = moment(at: date)?.u ?? 0.125
        haptics.finale()
        tone.finish()
        tone.stop(after: 5)
        live.end()
        let beats = heart.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        let seconds = date.timeIntervalSince(began)
        if let pattern, seconds > 10 {
            let summary = Summary(pattern: pattern, seconds: seconds, breaths: breaths, holds: holds, heart: beats)
            self.summary = summary
            onFinish?(summary, wallStart, .now)
        }
        finishedAt = .now
        state = .idle
        entries = []
        pausedAt = nil
        pattern = nil
    }
}
