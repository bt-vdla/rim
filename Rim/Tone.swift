import AVFoundation

/// A tiny sine synth: plucks and bowls mark phase changes, the drone swells with the breath.
/// It plays alongside other audio and keeps a session running with the screen locked.
final class Tone {
    private struct Voice {
        var freq = 0.0, phase = 0.0, amp = 0.0, decay = 1.0, attack = 0.005, age = 0.0
        var h2 = 0.0, h3 = 0.0
        var pan = 0.0
    }

    private struct Drone {
        var freq = 130.81, phase = 0.0, level = 0.0, current = 0.0
        var from = 0.0, to = 0.0, samples = 1.0, counter = 1.0
    }

    // ponytail: the render thread reads these without locks; a write can tear for one sample, which is inaudible.
    private let voices = UnsafeMutablePointer<Voice>.allocate(capacity: 8)
    private let drone = UnsafeMutablePointer<Drone>.allocate(capacity: 1)
    private let gain = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    /// Master fade: [current, target]. Stopping eases to silence instead of cutting the sound off.
    private let fade = UnsafeMutablePointer<Double>.allocate(capacity: 2)
    /// Bumped on every start, so a stop scheduled by the last session can't silence the next one.
    private var generation = 0
    private let engine = AVAudioEngine()
    private let rate = 48_000.0
    private var nextVoice = 0
    private var attached = false

    var style: SoundStyle = .pluck
    var volume: Double {
        get { gain.pointee }
        set { gain.pointee = newValue }
    }

    init() {
        voices.initialize(repeating: Voice(), count: 8)
        drone.initialize(to: Drone())
        gain.initialize(to: 0.6)
        fade.initialize(repeating: 1, count: 2)
    }

    private func attach() {
        guard !attached else { return }
        attached = true
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let voices = voices, drone = drone, gain = gain, fade = fade, rate = rate
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for frame in 0..<Int(frameCount) {
                var s = 0.0, left = 0.0, right = 0.0
                for i in 0..<8 {
                    var v = voices[i]
                    guard v.amp > 0.0001 else { continue }
                    let env = v.amp * min(1, v.age / v.attack)
                    let sample = env * (sin(v.phase) + v.h2 * sin(2 * v.phase) + v.h3 * sin(2.76 * v.phase))
                    let angle = (v.pan + 1) * .pi / 4
                    left += sample * cos(angle) * 1.414
                    right += sample * sin(angle) * 1.414
                    v.phase += 2 * .pi * v.freq / rate
                    v.age += 1 / rate
                    v.amp *= v.decay
                    voices[i] = v
                }
                var d = drone.pointee
                if d.counter < d.samples {
                    d.counter += 1
                    let p = d.counter / d.samples
                    d.level = d.from + (d.to - d.from) * (1 - cos(.pi * p)) / 2
                }
                d.current += (d.level - d.current) * 0.0008
                if d.current > 0.0005 {
                    s += d.current * (sin(d.phase) + 0.35 * sin(2 * d.phase) + 0.12 * sin(3 * d.phase))
                }
                d.phase += 2 * .pi * d.freq / rate
                drone.pointee = d
                fade[0] += (fade[1] - fade[0]) / (0.35 * rate)
                let g = gain.pointee * 0.32 * fade[0]
                let l = Float(tanh((left + s) * g)), r = Float(tanh((right + s) * g))
                for (i, buffer) in buffers.enumerated() {
                    buffer.mData!.assumingMemoryBound(to: Float.self)[frame] = i == 0 ? l : r
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    func start() {
        guard style != .off else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        generation += 1
        fade[0] = 1
        fade[1] = 1
        attach()
        try? engine.start()
    }

    /// Lets what's ringing decay, eases the master level to silence, then stops the engine.
    func stop(after delay: Double = 0) {
        let gen = generation
        rampDrone(to: 0, over: min(delay, 1.5))
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay - 1.8)) { [self] in
            if gen == generation { fade[1] = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard gen == generation else { return }
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func cue(_ step: Step, from progress: Double) {
        guard style != .off else { return }
        if style == .drone {
            let level = 0.06 + 0.3 * step.fullTo
            rampDrone(to: level, over: (step.seconds ?? 2) * (1 - progress))
            return
        }
        guard progress == 0 else { return }
        if step.retention { return pluck(130.81, 0.7, bowl: true) }
        let pan = step.side == .left ? -0.85 : step.side == .right ? 0.85 : 0
        switch step.phase {
        case .inhale where step.pulse: pluck(329.63, 0.25)
        case .inhale: pluck(step.topUp ? 523.25 : 392.0, 0.6, pan: pan)
        case .exhale where step.pulse: break
        case .exhale: pluck(293.66, 0.55, pan: pan)
        case .holdIn, .holdOut: break
        }
    }

    func pause() { rampDrone(to: 0, over: 0.8) }

    func finish() {
        guard style != .off else { return }
        // A soft, short two-note close rather than a gong: quiet, nearly pure, gone in a couple of seconds.
        pluck(392.0, 0.16, bowl: true, tau: 1.6, shimmer: 0.05)
        pluck(587.33, 0.09, bowl: true, tau: 1.3, shimmer: 0.05)
    }

    private func pluck(_ freq: Double, _ amp: Double, bowl: Bool? = nil, pan: Double = 0, tau: Double? = nil, shimmer: Double? = nil) {
        let bowl = bowl ?? (style == .bowl)
        let tau = tau ?? (bowl ? 3.5 : 0.9)
        voices[nextVoice] = Voice(
            freq: freq, amp: amp, decay: exp(-1 / (tau * rate)), attack: bowl ? 0.03 : 0.004,
            h2: bowl ? 0 : 0.18, h3: shimmer ?? (bowl ? 0.22 : 0), pan: pan
        )
        nextVoice = (nextVoice + 1) % 8
    }

    private func rampDrone(to level: Double, over seconds: Double) {
        var d = drone.pointee
        d.from = d.level
        d.to = level
        d.samples = max(1, seconds * rate)
        d.counter = 0
        drone.pointee = d
    }
}
