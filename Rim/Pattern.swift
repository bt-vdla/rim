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
        case .rounds: "Cyclic hyperventilation and retention"
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
    /// Nose or mouth, shown under the word.
    var cue: String?
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
        step.cue = Self.cue(opening ? .reset : pattern.id, beat)
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
                word: inhale ? "Inhale" : "Exhale", cue: inhale ? "Deep, nose or mouth" : "Let it go",
                endsBreath: !inhale, pulse: true, count: s / 2 + 1
            )
        }
        switch s - power {
        case 0:
            return Step(phase: .holdOut, seconds: nil, from: 0, to: 0, word: "Hold", retention: true)
        case 1:
            return Step(phase: .inhale, seconds: 2.5, from: 0, to: 0.25, fullFrom: 0, fullTo: 1, word: "Inhale fully", cue: "Through the nose")
        case 2:
            return Step(phase: .holdIn, seconds: 15, from: 0.25, to: 1.25, fullFrom: 1, fullTo: 1, word: "Hold")
        default:
            return Step(phase: .exhale, seconds: 3, from: 1.25, to: 1.5, fullFrom: 1, fullTo: 0, word: "Exhale", cue: "Let it go", endsBreath: true)
        }
    }

    static func cue(_ id: PatternID, _ beat: Beat) -> String? {
        if id == .alternate {
            switch (beat.phase, beat.side) {
            case (.holdIn, _), (.holdOut, _): return "Close both"
            case (_, .left): return "Close the right nostril"
            default: return "Close the left nostril"
            }
        }
        if beat.topUp { return "A short sniff" }
        switch (id, beat.phase) {
        case (_, .holdIn), (_, .holdOut): return nil
        case (.energize, _): return "Sharp, through the nose"
        case (.reset, .exhale), (.urge, .exhale): return "Slowly, through the mouth"
        case (.sleep, .exhale): return "Through the mouth"
        default: return "Through the nose"
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

extension PatternID {
    /// What the pattern is for, and how to do it. Shown when you tap a pattern at rest.
    var about: (what: String, how: String) {
        switch self {
        case .steady: (
            "Box breathing: four equal sides. Even counts give a busy mind something steady to follow.",
            "In through the nose, hold, out through the nose, hold. Keep every side the same length."
        )
        case .sleep: (
            "4-7-8 breathing. A long hold and a longer exhale slow everything down before sleep.",
            "In through the nose for 4, hold for 7, out through the mouth for 8. If the hold feels long, shorten it with Edit."
        )
        case .balance: (
            "Resonance breathing: about five and a half breaths a minute, even in and out.",
            "Through the nose, both ways. Soft rather than deep."
        )
        case .reset: (
            "The physiological sigh: two breaths in, one long breath out. One to three can take the edge off quickly.",
            "Breathe in through the nose, top up with a short second sniff, then let it all go slowly through the mouth."
        )
        case .unwind: (
            "Exhales twice as long as inhales. Long exhales help the body settle.",
            "In through the nose for 4, out through the nose for 8."
        )
        case .triangle: (
            "Inhale, hold, exhale in equal parts. Box breathing without the empty hold, and easier to start with.",
            "Through the nose. Keep the hold relaxed, with the throat open."
        )
        case .alternate: (
            "Alternate nostril breathing: in on one side, out on the other. A slow, focusing practice from yoga.",
            "Close the right nostril with your thumb and breathe in on the left. Close both to hold, then breathe out on the right. Then reverse."
        )
        case .energize: (
            "Quick, even breaths through the nose to wake you up.",
            "Breathe sharply in and out through the nose, from the belly."
        )
        case .rounds: (
            "Cyclic hyperventilation and retention: rounds of deep, fast breaths, a hold on empty lungs, then a recovery breath.",
            "Breathe deeply 30 times. Let the last breath go and hold until you need to breathe, then tap. Breathe in fully and hold for 15 seconds."
        )
        case .custom: (
            "Your own rhythm. The light keeps to the counts you set with Edit.",
            "Through the nose, unless your pattern needs otherwise."
        )
        case .urge: (
            "For riding out a craving. Three sighs settle you fast, then long exhales carry you while it passes.",
            "In through the nose, slowly out through the mouth. Most cravings rise and fade within a few minutes."
        )
        }
    }
}

extension PatternID {
    /// How the pattern works on the body, and what the research says. Shown under "How it works".
    var science: String {
        switch self {
        case .steady:
            "A full box takes 16 seconds, so you breathe under four times a minute, well below the usual 12 to 20. Breathing this slowly lengthens the gaps between breaths and gives the vagus nerve, the main brake on heart rate, more time to act. The holds let carbon dioxide rise a little, which trains you to sit with the urge to breathe instead of reacting to it. In a 2023 Stanford study by Balban and colleagues, five minutes a day of box breathing improved mood over a month, though cyclic sighing, Reset here, did slightly better."
        case .sleep:
            "Popularised by Dr Andrew Weil from yogic pranayama. Each breath takes 19 seconds, about three a minute, and nearly half of it is exhale. Your heart naturally slows as you breathe out, so a long exhale keeps you on the slowing side of every breath. The hold before it lets carbon dioxide build slightly, which deepens the relaxation that follows. Small studies link 4-7-8 breathing to higher heart rate variability and lower blood pressure in the short term; the evidence for sleep itself is mostly people's own reports."
        case .balance:
            "Your heart rate rises a little with every inhale and falls with every exhale. This is respiratory sinus arrhythmia. Separately, the blood pressure reflex that steadies your heart cycles about once every ten seconds. Breathe at around five and a half breaths a minute and the two fall into step, so each wave of heart rate becomes as large as it can. Researchers such as Paul Lehrer and Evgeny Vaschillo built heart rate variability biofeedback on this, and trials link regular practice to less anxiety and better blood pressure control."
        case .reset:
            "You sigh on your own every few minutes. The second, short inhale reopens tiny air sacs in the lungs, the alveoli, that slowly collapse, so more of the lung takes part. The long exhale then clears more carbon dioxide than an ordinary breath. Jack Feldman's lab traced the sigh to a small group of brainstem neurons. In Balban and colleagues' 2023 Stanford study, five minutes of cyclic sighing a day lifted mood and lowered resting breathing rate more than mindfulness meditation did."
        case .unwind:
            "Breathing in briefly eases the vagal brake on your heart and breathing out applies it again, so the heart speeds up slightly on the inhale and slows on the exhale. Making the exhale twice as long keeps you on the calming side for most of each breath. At 12 seconds a breath you are also at five breaths a minute, close to the resonance pace that Balance uses, so the two effects add up."
        case .triangle:
            "With three equal parts of four seconds you breathe five times a minute, right at the pace that tends to make heart rate swing most with the breath. Holding at the top keeps the lungs' stretch receptors firing, which signals the brainstem to slow down. It leaves out box breathing's empty-lungs hold, the part most people find hardest, so it's a gentler place to start."
        case .alternate:
            "Nadi shodhana, from yoga. Your nostrils already take turns doing most of the work over a cycle of a few hours, the nasal cycle. Closing one side at a time makes each breath slower and longer, and gives your attention a physical task to hold. Small trials report lower heart rate and blood pressure after a few weeks of practice. Claims that it balances the two halves of the brain are not well supported; the slowing is what the evidence backs."
        case .energize:
            "Fast, even breaths through the nose, like kapalabhati or bhastrika in yoga, push stress hormones up and lift alertness. Breathing faster than your body needs also lowers carbon dioxide in the blood, which narrows blood vessels a little. That's where the tingling and light-headedness some people feel come from. Use it for a lift, not to relax, and slow down at the first sign of dizziness."
        case .rounds:
            "The deep, fast breaths blow off carbon dioxide. Oxygen hardly rises, since your blood is already almost full of it. Carbon dioxide, not low oxygen, is what makes you want to breathe, so you can then hold far longer than usual while oxygen quietly falls, sometimes a long way. That's why it must never be done in or near water: you can pass out before you feel the need to breathe. In a 2014 study by Kox and colleagues in PNAS, people trained in this style of breathing released more adrenaline and had a weaker inflammatory response to a bacterial toxin. Balban's 2023 study found it lifted mood too, though cyclic sighing did more for anxiety."
        case .custom:
            "Two rules of thumb hold for most rhythms. Fewer than about ten breaths a minute shifts the body toward rest, and the slowest effect tends to come near five or six a minute. A longer exhale than inhale adds calm, a longer inhale adds alertness. The light shows how many seconds each breath takes, so you can aim for either."
        case .urge:
            "Cravings come in waves. They build, peak and fade, usually within a few minutes, whether or not you act on them. Opening with sighs quickly lowers the body's arousal. The long exhales then keep your heart rate on its slowing phase, so the wave feels smaller while it passes. Naming what you can see, feel and hear pulls attention outward, away from the craving. Small trials have found that slow, deep breathing reduces cigarette cravings."
        }
    }
}
