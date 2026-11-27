import SwiftUI

enum Phase: String, Codable { case inhale, holdIn, exhale, holdOut }
enum Side: String, Codable { case both, left, right }

struct Beat: Codable, Hashable {
    var phase: Phase
    var seconds: Double
    var side: Side = .both
    var topUp = false
}

struct Pattern: Identifiable, Equatable {
    let id: PatternID
    var beats: [Beat]

    var name: String { id.title }
    var editable: Bool { ![.reset, .alternate, .rounds, .urge].contains(id) }
    var intense: Bool { id == .energize || id == .rounds }
    var cycle: Double { beats.reduce(0) { $0 + $1.seconds } }

    var detail: String {
        switch id {
        case .reset: "Two breaths in, one long out"
        case .alternate: "Left side, then right"
        case .rounds: "Fast breaths, then a long hold"
        case .urge: "Three sighs, then long exhales"
        default: beats.map(\.seconds.clean).joined(separator: " · ")
        }
    }

    static func beat(_ phase: Phase, _ seconds: Double, _ side: Side = .both, topUp: Bool = false) -> Beat {
        Beat(phase: phase, seconds: seconds, side: side, topUp: topUp)
    }

    static let defaults: [PatternID: [Beat]] = [
        .steady: [beat(.inhale, 4), beat(.holdIn, 4), beat(.exhale, 4), beat(.holdOut, 4)],
        .sleep: [beat(.inhale, 4), beat(.holdIn, 7), beat(.exhale, 8)],
        .balance: [beat(.inhale, 5.5), beat(.exhale, 5.5)],
        .reset: [beat(.inhale, 2.5), beat(.inhale, 1, topUp: true), beat(.exhale, 6)],
        .unwind: [beat(.inhale, 4), beat(.exhale, 8)],
        .triangle: [beat(.inhale, 4), beat(.holdIn, 4), beat(.exhale, 4)],
        .alternate: [
            beat(.inhale, 4, .left), beat(.holdIn, 4), beat(.exhale, 4, .right),
            beat(.inhale, 4, .right), beat(.holdIn, 4), beat(.exhale, 4, .left),
        ],
        .energize: [beat(.inhale, 1.5), beat(.exhale, 1)],
        .rounds: [beat(.inhale, 1.6), beat(.exhale, 1.4)],
        .custom: [beat(.inhale, 4), beat(.holdIn, 2), beat(.exhale, 6)],
        .urge: [beat(.inhale, 4), beat(.exhale, 8)],
    ]
}

extension Double {
    var clean: String { self == rounded() ? String(Int(self)) : String(format: "%.1f", self) }
}

/// One stretch of a session. `from`/`to` are positions on the screen edge: 0 is the top-left corner,
/// each quarter is one side, clockwise. Values past 1 wrap.
struct Step {
    var phase: Phase
    var seconds: Double?
    var side: Side = .both
    var from = 0.0, to = 0.0
    var fullFrom = 0.0, fullTo = 0.0
    var word: String
    var endsBreath = false
    var pulse = false
    var topUp = false
    var count: Int?
    var retention = false

    func moment(_ elapsed: Double) -> Moment {
        if retention { return Moment(u: from + elapsed / 60, full: 0, pulse: false, side: side) }
        let p = seconds.map { min(1, elapsed / $0) } ?? 0
        let eased = (1 - cos(.pi * p)) / 2
        return Moment(
            u: from + (to - from) * p, full: fullFrom + (fullTo - fullFrom) * eased, pulse: pulse, side: side
        )
    }
}

struct Moment {
    var u: Double
    var full: Double
    var pulse: Bool
    var side: Side
}

/// Produces the steps of a session one at a time. Rounds are generated, everything else repeats its beats.
struct Feed {
    let pattern: Pattern
    let pace: Double
    var powerBreaths = 30
    var rounds = 3
    var easeIn = false
    private var index = 0
    private var round = 1
    private var stage = 0
    private var fullness = 0.0

    init(pattern: Pattern, pace: Double, powerBreaths: Int = 30, rounds: Int = 3) {
        self.pattern = pattern
        self.pace = pace
        self.powerBreaths = powerBreaths
        self.rounds = rounds
    }

    /// Alternate nostril, corner to corner: up the left edge, across the top, down the right;
    /// then back up the right, across, and down the left.
    private static let alternatePath: [(Double, Double)] = [
        (0.75, 1.0), (1.0, 1.25), (1.25, 1.5), (1.5, 1.25), (1.25, 1.0), (1.0, 0.75),
    ]

    /// How many sides of the screen each phase travels. Whole sides only, so every phase starts and
    /// ends on a corner: one side each, and spare sides go to the longest phases (later ones win ties).
    static func sides(for beats: [Beat]) -> [Int] {
        let n = beats.count
        guard n < 4 else { return Array(repeating: 1, count: n) }
        var spans = Array(repeating: 1, count: n)
        let order = beats.indices.sorted {
            beats[$0].seconds != beats[$1].seconds ? beats[$0].seconds > beats[$1].seconds : $0 > $1
        }
        for k in 0..<(4 - n) { spans[order[k % n]] += 1 }
        return spans
    }

    mutating func next() -> Step? {
        pattern.id == .rounds ? nextRound() : nextBeat()
    }

    private mutating func nextBeat() -> Step {
        // Urge opens with three physiological sighs before settling into its long exhales.
        let sighs = Pattern.defaults[.reset]!
        let opening = pattern.id == .urge && index < sighs.count * 3
        let beats = opening ? sighs : pattern.beats
        let local = pattern.id == .urge && !opening ? index - sighs.count * 3 : index
        let i = local % beats.count
        let beat = beats[i]
        let spans = Self.sides(for: beats)
        let before = Double(spans.prefix(i).reduce(0, +))
        // Ease in: the first breaths run up to 30% quicker, settling on the set pace by the sixth.
        let settle = easeIn ? 1 + 0.3 * max(0, 1 - Double(index / beats.count) / 6) : 1
        var step = Step(phase: beat.phase, seconds: beat.seconds / (pace * settle), side: beat.side, word: Self.word(beat), topUp: beat.topUp)
        if pattern.id == .alternate {
            (step.from, step.to) = Self.alternatePath[i % 6]
        } else {
            step.from = before / 4
            step.to = (before + Double(spans[i])) / 4
        }
        let nextIsTopUp = beats[(i + 1) % beats.count].topUp
        let target: Double = switch beat.phase {
        case .inhale: nextIsTopUp ? 0.75 : 1
        case .exhale: 0
        case .holdIn, .holdOut: fullness
        }
        step.fullFrom = fullness
        step.fullTo = target
        fullness = target
        step.endsBreath = i == beats.count - 1
        index += 1
        return step
    }

    private mutating func nextRound() -> Step? {
        let power = powerBreaths * 2
        if stage == power + 4 {
            round += 1
            guard round <= rounds else { return nil }
            stage = 0
        }
        let s = stage
        stage += 1
        if s < power {
            let inhale = s % 2 == 0
            return Step(
                phase: inhale ? .inhale : .exhale, seconds: (inhale ? 1.6 : 1.4) / pace,
                from: 0, to: 0, fullFrom: inhale ? 0 : 1, fullTo: inhale ? 1 : 0,
                word: inhale ? "Inhale" : "Exhale", endsBreath: !inhale, pulse: true, count: s / 2 + 1
            )
        }
        switch s - power {
        case 0:
            return Step(phase: .holdOut, seconds: nil, from: 0, to: 0, word: "Hold", retention: true)
        case 1:
            return Step(phase: .inhale, seconds: 2.5, from: 0, to: 0.25, fullFrom: 0, fullTo: 1, word: "Inhale fully")
        case 2:
            return Step(phase: .holdIn, seconds: 15, from: 0.25, to: 1.25, fullFrom: 1, fullTo: 1, word: "Hold")
        default:
            return Step(phase: .exhale, seconds: 3, from: 1.25, to: 1.5, fullFrom: 1, fullTo: 0, word: "Exhale", endsBreath: true)
        }
    }

    static func word(_ beat: Beat) -> String {
        if beat.topUp { return "Once more" }
        let side = beat.side == .both ? "" : " \(beat.side.rawValue)"
        return switch beat.phase {
        case .inhale: "Inhale" + side
        case .exhale: "Exhale" + side
        case .holdIn, .holdOut: "Hold"
        }
    }
}
