import CoreHaptics

/// One haptic pattern per step: inhale swells, exhale fades, holds tap.
final class Haptics {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    /// Accents play on their own player so the breath pattern's volume curve can't soften them.
    private var accent: CHHapticPatternPlayer?
    var strength: Float = 0.8

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.playsHapticsOnly = true
        engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
    }

    /// While you hold to begin: a swell that gathers with the light on the edge.
    func holdSwell(duration: Double) {
        stop()
        guard let engine, strength > 0 else { return }
        let points = (0...6).map { i -> CHHapticParameterCurve.ControlPoint in
            let f = Double(i) / 6
            let eased = Float(f * f * (3 - 2 * f))
            return .init(relativeTime: duration * f, value: (0.06 + 0.5 * eased) * strength)
        }
        let swell = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
        ], relativeTime: 0, duration: duration)
        do {
            try engine.start()
            let pattern = try CHHapticPattern(events: [swell], parameterCurves: [
                CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: points, relativeTime: 0),
            ])
            player = try engine.makeAdvancedPlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    /// One firm tap: the moment a hold lands and a session begins.
    func tap() {
        guard let engine, strength > 0 else { return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9 * strength),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.55),
        ], relativeTime: 0)
        try? engine.start()
        accent = try? engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
        try? accent?.start(atTime: CHHapticTimeImmediate)
    }

    /// `startTap` adds one firm tap at the very top of a session, so you feel it begin.
    func play(_ step: Step, from progress: Double, startTap: Bool = false) {
        stop()
        guard let engine, strength > 0 else { return }
        let total = step.seconds ?? 0
        let d = max(0.05, total * (1 - progress))
        var events: [CHHapticEvent] = []
        var curves: [CHHapticParameterCurve] = []
        if startTap { self.tap() }

        func swell(_ from: Double, _ to: Double, sharpness: Float) {
            events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0, duration: d))
            let points = (0...7).map { i -> CHHapticParameterCurve.ControlPoint in
                let f = Double(i) / 7
                let p = progress + (1 - progress) * f
                let eased = (1 - cos(.pi * p)) / 2
                return .init(relativeTime: d * f, value: Float(from + (to - from) * eased) * strength)
            }
            curves.append(CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: points, relativeTime: 0))
        }

        func tap(_ intensity: Float, _ sharpness: Float, at time: Double) {
            events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity * strength),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: time))
        }

        switch step.phase {
        case .inhale:
            if step.pulse { swell(0.2, 0.6, sharpness: 0.4) }
            else if step.topUp { swell(0.55, 0.9, sharpness: 0.45) }
            else { swell(0.12, 0.8, sharpness: 0.35) }
        case .exhale:
            swell(step.pulse ? 0.45 : 0.65, 0, sharpness: 0.08)
        case .holdIn:
            if progress == 0 { tap(0.75, 0.55, at: 0) }
            var t = 1 - (total * progress).truncatingRemainder(dividingBy: 1)
            while t < d - 0.3 { tap(0.18, 0.2, at: t); t += 1 }
        case .holdOut:
            if progress == 0 { tap(step.retention ? 0.5 : 0.35, 0.1, at: 0) }
        }

        guard !events.isEmpty else { return }
        do {
            try engine.start()
            player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: events, parameterCurves: curves))
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    /// The close of a session: one soft tap as the edge blooms, then a long fade that settles with it.
    func finale() {
        stop()
        guard let engine, strength > 0 else { return }
        let fade = (0...8).map { i -> CHHapticParameterCurve.ControlPoint in
            let f = Double(i) / 8
            let eased = Float((1 + cos(.pi * f)) / 2)
            return .init(relativeTime: 1.6 * f, value: 0.42 * eased * strength)
        }
        let events = [
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6 * strength),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
            ], relativeTime: 0),
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.08),
            ], relativeTime: 0.04, duration: 1.6),
        ]
        do {
            try engine.start()
            let pattern = try CHHapticPattern(events: events, parameterCurves: [
                CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: fade, relativeTime: 0.04),
            ])
            player = try engine.makeAdvancedPlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }
}
