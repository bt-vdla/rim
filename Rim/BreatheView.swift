import SwiftUI

struct BreatheView: View {
    @Environment(Store.self) private var store
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragX: CGFloat = 0
    /// The pattern being blended away from, so colours and light cross over in one smooth pass.
    @State private var summaryClosed: Date?
    @State private var blendFrom: PatternID?
    @State private var blendStart = Date.distantPast
    @State private var blendEpoch = Date.now
    @State private var showSettings = false
    @State private var editing: Pattern?
    @State private var about: Pattern?
    @State private var holdTest = false
    @State private var safety: Pattern?
    @State private var epoch = Date.now
    @State private var shareImage: Image?
    @State private var calibrating = false
    @State private var pressStart: Date?
    @State private var welcomeStep = 0
    /// Light left over after a press: eases out quickly if you let go early, settles slowly into a session.
    @State private var afterglow: (date: Date, level: Double, length: Double)?
    @Namespace private var glass

    private enum Mode: Equatable { case welcome, safety, summary, idle, running, paused }

    private var mode: Mode {
        if !store.prefs.onboarded { return .welcome }
        if safety != nil { return .safety }
        switch session.state {
        case .running: return .running
        case .paused: return .paused
        case .idle: return session.summary != nil ? .summary : .idle
        }
    }

    private var pattern: Pattern { session.pattern ?? safety ?? session.summary?.pattern ?? store.selected }
    private var style: RingStyle { store.prefs.ring }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let ring = RingPath(
                    rect: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 3, dy: 3),
                    radius: RingPath.screenRadius(proxy) - 3
                )
                let preview = Preview(pattern, pace: store.pace(pattern.id))
                TimelineView(.animation) { timeline in
                    scene(ring: ring, radius: RingPath.screenRadius(proxy), preview: preview, date: timeline.date)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
            .onLongPressGesture(minimumDuration: Self.holdDuration, perform: hold) { pressing in
                let holdable = mode == .idle || mode == .summary || (mode == .welcome && welcomeStep == 2)
                if pressing, holdable {
                    pressStart = .now
                    session.holdHaptic(strength: store.prefs.haptics, duration: Self.holdDuration)
                } else if pressStart != nil {
                    afterglow = (.now, fill(.now), 0.4)
                    pressStart = nil
                    session.cancelHaptics()
                }
            }
            .gesture(swipe)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(mode == .running ? .updatesFrequently : [])
            .accessibilityActions { voiceOverActions }

            controls
            corner
            urgeButton
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sensoryFeedback(.selection, trigger: store.prefs.selected)
        .sheet(isPresented: $showSettings) {
            SettingsView(
                openHoldTest: { present { holdTest = true } },
                openCalibrate: { present { calibrating = true } }
            )
        }
        .fullScreenCover(isPresented: $calibrating) { CalibrateView(pattern: store.selected) }
        .sheet(item: $editing) { EditorView(pattern: $0) }
        .sheet(item: $about) { AboutView(pattern: $0) }
        .fullScreenCover(isPresented: $holdTest) { HoldTestView() }
        .onChange(of: session.summary?.id) { old, new in
            if old != nil, new == nil { summaryClosed = .now }
            if new != nil { summaryClosed = nil }
        }
        .onChange(of: session.state) { old, new in
            // Every start gets the hold-to-begin flash, however it was started.
            let recent = afterglow.map { Date.now.timeIntervalSince($0.date) < 0.3 } ?? false
            if old == .idle, new == .running, !recent { afterglow = (.now, 0.8, 1.3) }
        }
        .onChange(of: pattern.id) { old, _ in
            blendFrom = old
            blendStart = .now
            blendEpoch = epoch
            epoch = .now
        }
        .onChange(of: store.prefs.onboarded) { _, done in
            if !done { welcomeStep = 0 }
        }
        .onChange(of: welcomeStep) { _, step in
            if step == 1 { session.demoHaptics(strength: store.prefs.haptics) }
        }
        .onChange(of: store.request) { _, id in
            guard let id else { return }
            store.request = nil
            guard session.state == .idle else { return }
            if id != .urge { store.prefs.selected = id }
            begin(store.pattern(id))
        }
        .task(id: session.summary?.id) {
            shareImage = nil
            guard let summary = session.summary else { return }
            let card = ShareCard(summary: summary, colors: summary.pattern.id.colors, best: bestHold)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 3
            if let image = renderer.uiImage { shareImage = Image(uiImage: image) }
        }
    }

    // MARK: Scene

    @ViewBuilder
    private func scene(ring: RingPath, radius: CGFloat, preview: Preview, date: Date) -> some View {
        let live = session.state != .idle
        let clock = live ? session.clock : date
        let closing = finaleAge(date) != nil
        let sample: (Date) -> Moment? = live
            ? { session.moment(at: $0) }
            : closing ? finaleSample : { preview.moment($0.timeIntervalSince(epoch)) }
        let now = sample(clock)
        let trail = closing ? 0.6 : style == .trace ? min(preview.total * 0.92, 20) : 1.15

        let rounds = live && pattern.id == .rounds
        let fade = sleepFade
        let k = blend(date)
        let from = k < 1 ? blendFrom : nil
        // The light goes dark at the crossover and comes back on the new pattern, so it never jumps.
        let dip = from == nil ? 1 : 1 - sin(.pi * k)
        let falling = collapse(at: date)
        // With AirPods measuring, the heartbeat leads the gradient and the breath steps back.
        let heart = live ? session.heart.pulse(at: date) : (beat: 0.0, weight: 0.0)
        ZStack {
            Backdrop(
                colors: mixed(from.map { backdropPalette($0, date) }, backdropPalette(pattern.id, date), k), full: (now?.full ?? 0) * (1 - 0.6 * heart.weight),
                date: date, still: reduceMotion,
                head: falling > 0 && session.summary != nil ? ring.point(session.endU) : now.map { ring.point($0.u) } ?? .zero,
                pull: now == nil || now?.pulse == true || reduceMotion ? 0
                    : (live || closing ? 0.2 + 0.3 * (now?.full ?? 0) : 0.15),
                collapse: falling,
                beat: heart.beat * heart.weight,
                contours: store.prefs.backdrop == .contours,
                radius: radius
            )
            RingCanvas(
                ring: ring, radius: radius, colors: mixed(from.map { ringPalette($0, date) }, ringPalette(pattern.id, date), k), style: style,
                date: clock, trail: trail,
                intensity: (mode == .running || closing ? 1 : mode == .paused ? 0.45 : mode == .welcome ? 0.85 : 0.55)
                    * fade * dip * (1 - 0.85 * falling),
                marks: rounds ? session.holds.map { 0.125 + $0 / 60 } : [],
                best: rounds ? bestHold.map { 0.125 + $0 / 60 } : nil,
                progress: live ? session.progress : nil,
                flash: flash(at: date),
                still: reduceMotion,
                sample: from != nil && k < 0.5 && !live && !closing ? oldSample : sample
            )
            center(date: date)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: editorial ? .bottomLeading : .center)
                .padding(.horizontal, editorial ? 32 : 40)
                .padding(.bottom, editorial ? 224 : 0)
                .animation(.smooth(duration: 0.5), value: editorial)
            if live, session.heart.bpm != nil || session.heart.waiting {
                heartRate(session.heart.bpm, beat: heart.beat * heart.weight)
            }
            Color.black.opacity((1 - fade) * 0.94).allowsHitTesting(false)
        }
    }

    // MARK: Theme

    /// Rest, sessions and the summary sit bottom-left, editorial style; onboarding stays centred.
    private var editorial: Bool {
        [.idle, .running, .paused, .summary].contains(mode)
    }

    /// The pattern's own hue, or with Heart rate on and a live reading, a hue that follows the heart.
    private func hue(_ id: PatternID) -> Color {
        guard store.prefs.palette == .heart, session.state != .idle, let bpm = session.heart.bpm else { return id.backdrop[1] }
        return Self.heartHue(bpm)
    }

    private func backdropPalette(_ id: PatternID, _ date: Date) -> [Color] {
        Self.oneHue(hue(id), ring: false)
    }

    private func ringPalette(_ id: PatternID, _ date: Date) -> [Color] {
        store.warmed(Self.oneHue(hue(id), ring: true), at: date)
    }

    /// One colour in light and dark steps: a deep base, the colour itself, a pale and a dim version.
    private static func oneHue(_ color: Color, ring: Bool) -> [Color] {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if ring {
            return [Color(hue: h, saturation: s * 0.25, brightness: 1), Color(hue: h, saturation: s * 0.6, brightness: 1),
                    Color(hue: h, saturation: s, brightness: 0.9)]
        }
        return [Color(hue: h, saturation: s, brightness: 0.16), Color(hue: h, saturation: s * 0.95, brightness: 0.62),
                Color(hue: h, saturation: s * 0.55, brightness: 0.85), Color(hue: h, saturation: s * 0.8, brightness: 0.42)]
    }

    /// Teal at 58 bpm or below, turning through blue and violet to red at 92 and above.
    /// The hue moves around the wheel rather than mixing, so it never passes through grey.
    private static func heartHue(_ bpm: Double) -> Color {
        let k = min(1, max(0, (bpm - 58) / 34))
        return Color(hue: 0.48 + 0.52 * k, saturation: 0.85, brightness: 0.95)
    }

    // MARK: Blending between patterns

    private static let blendLength = 0.6

    private func blend(_ date: Date) -> Double {
        Self.smooth(date.timeIntervalSince(blendStart) / Self.blendLength)
    }

    private func mixed(_ from: [Color]?, _ to: [Color], _ k: Double) -> [Color] {
        guard let from, k < 1 else { return to }
        return zip(from, to).map { $0.mix(with: $1, by: k) }
    }

    /// Until the crossover, the light keeps playing the pattern you swiped away from.
    private func oldSample(_ date: Date) -> Moment? {
        guard let blendFrom else { return nil }
        return Preview(store.pattern(blendFrom), pace: store.pace(blendFrom)).moment(date.timeIntervalSince(blendEpoch))
    }

    /// The best Power hold ever, from history and this session.
    private var bestHold: Double? { (store.records.flatMap(\.holds) + session.holds).max() }

    /// In Sleep, after six breaths the light fades to black over 30 seconds while the sound carries on.
    private var sleepFade: Double {
        guard store.prefs.sleepFade, mode == .running, pattern.id == .sleep else { return 1 }
        let start = 6 * pattern.cycle / store.pace(pattern.id)
        return min(1, max(0, 1 - (session.activeSeconds - start) / 30))
    }

    /// Light across the whole edge: gathering while you hold, settling after, and the bloom at the end.
    private func flash(at date: Date) -> Double {
        var level = fill(date)
        if let afterglow {
            let t = date.timeIntervalSince(afterglow.date) / afterglow.length
            if t < 1 { level = max(level, afterglow.level * (1 - Self.smooth(t))) }
        }
        if let age = finaleAge(date) { level = max(level, Self.bloom(age)) }
        return level
    }

    /// Smoothstep: no sudden starts or stops.
    private static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// While holding, the edge gathers light, easing in and out rather than ramping.
    private func fill(_ date: Date) -> Double {
        guard let pressStart else { return 0 }
        return 0.8 * Self.smooth(date.timeIntervalSince(pressStart) / Self.holdDuration)
    }

    /// The end bloom: a quick, soft swell that settles slowly. A single smooth curve with no corners:
    /// an exponential rise multiplied by a logistic fall. Peaks near 0.3s, gone by about 2s.
    private static func bloom(_ t: Double) -> Double {
        1.3 * (1 - exp(-t / 0.12)) / (1 + exp((t - 0.6) / 0.24))
    }

    // MARK: Closing

    /// After the end bloom the gradient falls into the light and the screen sinks to near-black;
    /// when the details are dismissed, it rises back.
    private func collapse(at date: Date) -> Double {
        if session.summary != nil, let finished = session.finishedAt {
            return Self.smooth((date.timeIntervalSince(finished) - 0.35) / 1.6)
        }
        if let closed = summaryClosed { return 1 - Self.smooth(date.timeIntervalSince(closed) / 1.0) }
        return 0
    }

    private static let finaleLength = 2.2

    /// Seconds since the session ended, while the closing animation is still playing.
    private func finaleAge(_ date: Date) -> Double? {
        guard session.state == .idle, let finished = session.finishedAt else { return nil }
        let age = date.timeIntervalSince(finished)
        return age >= 0 && age < Self.finaleLength ? age : nil
    }

    /// While the edge blooms, the light stays where it stopped and the gradient breathes with the bloom.
    private func finaleSample(_ date: Date) -> Moment? {
        guard let finished = session.finishedAt else { return nil }
        let full = min(1, Self.bloom(max(0, date.timeIntervalSince(finished))))
        return Moment(u: session.endU, full: full, pulse: false, side: .both)
    }

    @ViewBuilder
    private func center(date: Date) -> some View {
        VStack(alignment: editorial ? .leading : .center, spacing: 10) {
            switch mode {
            case .welcome:
                let page = Self.welcome[welcomeStep]
                VStack(spacing: 12) {
                    Text(page.title)
                        .scaledFont(34, .medium)
                        .tracking(-0.6)
                    Text(page.body)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                    if welcomeStep == 3 {
                        VStack(spacing: 4) {
                            Text(pattern.name).font(.title2.weight(.semibold))
                            Text(pattern.detail).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.top, 22)
                        .id(pattern.id)
                        .transition(.focus(reduceMotion: reduceMotion))
                        .modifier(DragSoften(x: dragX, reduceMotion: reduceMotion))
                    }
                }
                .multilineTextAlignment(.center)
                .id(welcomeStep)
                .transition(.letters(reduceMotion: reduceMotion))
            case .safety:
                VStack(spacing: 14) {
                    Text(pattern.name).scaledFont(44, .medium).tracking(-0.8)
                    Text("Sit or lie down. Never in water or while driving. Stop if you feel light-headed.")
                        .font(.body.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .transition(.letters(reduceMotion: reduceMotion))
            case .summary where (finaleAge(date) ?? .infinity) < 1.1:
                EmptyView()
            case .summary:
                if urgeSummary {
                    Text("Did it pass?").scaledFont(44, .medium).tracking(-0.8).transition(.letters(reduceMotion: reduceMotion))
                } else if let summary = session.summary {
                    SummaryText(summary: summary).transition(.swap(reduceMotion: reduceMotion))
                }
            case .idle:
                VStack(alignment: editorial ? .leading : .center, spacing: 8) {
                    Text(pattern.name)
                        .scaledFont(46, .medium)
                        .tracking(-1.2)
                    Text(pattern.detail)
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .id(pattern.id)
                .transition(.letters(reduceMotion: reduceMotion))
                .modifier(DragSoften(x: dragX, reduceMotion: reduceMotion))
            case .running, .paused:
                if let entry = session.current { running(entry, date: date) }
            }
        }
        .foregroundStyle(.primary)
        .animation(.smooth(duration: 0.45), value: session.current?.step.word)
        .animation(.smooth(duration: 0.5), value: mode)
        .animation(.smooth(duration: 0.5), value: welcomeStep)
    }

    @ViewBuilder
    private func running(_ entry: Session.Entry, date: Date) -> some View {
        let step = entry.step
        if mode == .paused {
            Text("Paused").scaledFont(44, .medium).tracking(-0.8).transition(.letters(reduceMotion: reduceMotion))
        } else if step.retention {
            Text(Duration.seconds(date.timeIntervalSince(entry.start)).formatted(.time(pattern: .minuteSecond)))
                .scaledFont(68, .light).monospacedDigit()
            Text("Tap to breathe").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        } else {
            let words = store.prefs.words == .always || (store.prefs.words == .first && session.activeSeconds < 60)
            if words {
                Text(step.word)
                    .scaledFont(44, .medium)
                    .tracking(-0.8)
                    .id(step.word)
                    .transition(.letters(reduceMotion: reduceMotion))
                if let cue = step.cue {
                    Text(cue)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .id(cue)
                        .transition(.swap(reduceMotion: reduceMotion))
                }
            }
            if pattern.id == .urge, let prompt = groundingPrompt {
                Text(prompt)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .id(prompt)
                    .transition(.swap(reduceMotion: reduceMotion))
            }
            if let count = step.count {
                Text("\(count)")
                    .scaledFont(22, .medium).monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else if store.prefs.count == .number, let seconds = step.seconds {
                // Counts the seconds of the phase: 1, 2, 3, 4.
                let n = min(Int(session.clock.timeIntervalSince(entry.start)) + 1, Int(seconds.rounded(.up)))
                Text("\(n)")
                    .scaledFont(22, .medium).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.3), value: n)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }

    /// Live heart rate at the foot of the screen; the heart beats with the gradient.
    private func heartRate(_ bpm: Double?, beat: Double) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "heart.fill")
                .font(.system(size: 13, weight: .semibold))
                .scaleEffect(reduceMotion ? 1 : 1 + 0.18 * beat)
            Text(bpm.map { "\(Int($0))" } ?? "--")
                .font(.system(size: 28, weight: .light).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.4), value: bpm.map(Int.init))
            Text("bpm")
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 56)
        .transition(.swap(reduceMotion: reduceMotion))
        .allowsHitTesting(false)
    }

    // MARK: VoiceOver

    /// What the screen says right now, since the light and words are drawn rather than read.
    private var spoken: String {
        switch mode {
        case .welcome: return "\(Self.welcome[welcomeStep].title) \(Self.welcome[welcomeStep].body)"
        case .safety: return "\(pattern.name). Sit or lie down. Never in water or while driving. Stop if you feel light-headed."
        case .summary:
            guard let s = session.summary else { return pattern.name }
            return "\(s.pattern.name) finished. \(Duration.seconds(s.seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))), \(String(AttributedString(localized: "^[\(s.breaths) breath](inflect: true)").characters))."
        case .idle: return "\(pattern.name), \(pattern.detail)"
        case .paused: return "Paused"
        case .running:
            guard let entry = session.current else { return pattern.name }
            if entry.step.retention {
                return "Hold, \(Int(session.clock.timeIntervalSince(entry.start))) seconds"
            }
            let heart = session.heart.bpm.map { ", heart rate \(Int($0))" } ?? ""
            return entry.step.word + (entry.step.cue.map { ", \($0)" } ?? "") + heart
        }
    }

    @ViewBuilder
    private var voiceOverActions: some View {
        switch mode {
        case .running:
            if session.current?.step.retention == true {
                Button("Breathe") { session.breathe() }
            } else {
                Button("Pause") { session.pause() }
            }
            Button("End session") { session.end() }
        case .paused:
            Button("Resume") { session.resume() }
            Button("End session") { session.end() }
        case .idle, .summary:
            Button("Begin") { begin(pattern) }
            Button("About this pattern") { about = pattern }
            Button("Next pattern") { shift(1) }
            Button("Previous pattern") { shift(-1) }
        case .welcome where welcomeStep == 2:
            Button("Begin") { advanceWelcome() }
        case .welcome where welcomeStep == 3:
            Button("Next pattern") { shift(1) }
            Button("Previous pattern") { shift(-1) }
        case .welcome, .safety:
            EmptyView()
        }
    }

    // MARK: Onboarding

    private static let welcome: [(title: String, body: String)] = [
        ("Follow the light.", "It travels the edge of your screen, one breath at a time."),
        ("Feel the phone.", "It swells as you breathe in and settles as you breathe out."),
        ("Hold to begin.", "Press and hold anywhere. Tap anytime to pause."),
        ("Choose a rhythm.", "Swipe to look around. Tap to learn more."),
        ("A nudge each evening?", "One reminder at 9 pm."),
    ]

    private func advanceWelcome() {
        pressStart = nil
        withAnimation(.smooth(duration: 0.5)) { welcomeStep = min(welcomeStep + 1, Self.welcome.count - 1) }
    }

    private func finishWelcome(remind: Bool) {
        if remind {
            store.prefs.reminder = true
            let minutes = store.prefs.reminderMinutes
            Task { await Reminder.set(true, minutes: minutes) }
        }
        withAnimation(.smooth(duration: 0.5)) { store.prefs.onboarded = true }
    }

    // MARK: Controls

    private var controls: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                switch mode {
                case .welcome where welcomeStep == 2:
                    EmptyView()
                case .welcome where welcomeStep == 4:
                    capsule("Not now", id: "left") { finishWelcome(remind: false) }
                    capsule("Remind me", id: "main") { finishWelcome(remind: true) }
                case .welcome:
                    capsule("Continue", id: "main") { advanceWelcome() }
                case .safety:
                    capsule("Not now", id: "left") { safety = nil }
                    capsule("Begin", id: "main") {
                        guard let safety else { return }
                        store.prefs.acknowledged.append(safety.id)
                        self.safety = nil
                        session.start(safety, store: store)
                    }
                case .summary where urgeSummary:
                    capsule("Still here", id: "left") { logUrge(passed: false, again: true) }
                    capsule("It passed", id: "main") { logUrge(passed: true, again: false) }
                case .idle, .summary:
                    EmptyView()
                case .paused:
                    capsule("End", id: "left") { session.end() }
                    capsule("Resume", id: "main") { session.resume() }
                case .running:
                    EmptyView()
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 22) {
            if mode == .idle || (mode == .summary && !urgeSummary) || (mode == .welcome && welcomeStep == 3) {
                VStack(spacing: 14) {
                    stepper
                    if mode == .idle {
                        Text("Hold anywhere to begin")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.swap(reduceMotion: reduceMotion))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 36)
        .animation(.smooth(duration: 0.45), value: mode)
        .animation(.smooth(duration: 0.45), value: welcomeStep)
        .animation(.smooth(duration: 0.45), value: pattern.editable)
    }

    private var stepper: some View {
        let all = PatternID.carousel
        let index = all.firstIndex(of: store.prefs.selected) ?? 0
        return PatternDial(selected: store.prefs.selected) { id in
            shift((all.firstIndex(of: id) ?? index) - index)
        }
        .accessibilityElement()
        .accessibilityLabel("Pattern")
        .accessibilityValue("\(index + 1) of \(all.count), \(store.prefs.selected.title)")
        .accessibilityAdjustableAction { direction in
            shift(direction == .increment ? 1 : -1)
        }
    }

    /// Urge mode is one tap from rest, top left.
    private var urgeButton: some View {
        Button { begin(store.pattern(.urge)) } label: {
            Label("Urge", systemImage: "leaf")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 18)
                .frame(height: 48)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Ride out an urge")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 20)
        .padding(.top, 6)
        .opacity(mode == .idle ? 1 : 0)
        .allowsHitTesting(mode == .idle)
        .animation(.smooth(duration: 0.45), value: mode)
    }

    private var urgeSummary: Bool { mode == .summary && session.summary?.pattern.id == .urge }

    private static let grounding = [
        "Name five things you can see.", "Four things you can feel.", "Three things you can hear.",
        "Two things you can smell.", "One slow sip of water.", "Let it rise, and let it pass.",
    ]

    /// After the opening sighs, a new grounding prompt every 30 seconds.
    private var groundingPrompt: String? {
        let t = session.activeSeconds - 30
        guard t > 0 else { return nil }
        return Self.grounding[min(Int(t / 30), Self.grounding.count - 1)]
    }

    private func logUrge(passed: Bool, again: Bool) {
        store.urges.append(UrgeLog(date: .now, passed: passed))
        withAnimation(.smooth(duration: 0.45)) { session.summary = nil }
        if again { begin(store.pattern(.urge)) }
    }

    /// Settings, and beside it Edit at rest or Share after a session, in the top right corner.
    private var corner: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if mode == .summary, !urgeSummary, let shareImage {
                    ShareLink(item: shareImage, preview: SharePreview("My Rim session", image: shareImage)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 48, height: 48)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("share", in: glass)
                    .accessibilityLabel("Share session")
                }
                if mode == .idle, pattern.editable {
                    circle("pencil", label: "Edit pattern", id: "edit", size: 48) { editing = pattern }
                }
                if mode == .idle || mode == .summary {
                    circle("slider.horizontal.3", label: "Settings", id: "settings", size: 48) { showSettings = true }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, 20)
        .padding(.top, 6)
        .animation(.smooth(duration: 0.45), value: mode)
        .animation(.smooth(duration: 0.45), value: pattern.editable)
    }

    private func capsule(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 30)
                .frame(height: 54)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID(id, in: glass)
    }

    private func circle(_ symbol: String, label: String, id: String, size: CGFloat = 54, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID(id, in: glass)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private static let holdDuration = 0.6

    /// Holding the screen begins from rest, and pauses a running session.
    private func hold() {
        afterglow = (.now, fill(.now), 1.3)
        pressStart = nil
        switch mode {
        case .idle, .summary: begin(pattern)
        case .running: session.pause()
        case .welcome where welcomeStep == 2:
            session.landHaptic()
            advanceWelcome()
        case .paused, .welcome, .safety: break
        }
    }

    private func tap() {
        switch mode {
        case .idle: about = pattern
        case .welcome where welcomeStep == 3: about = pattern
        case .summary: withAnimation(.smooth(duration: 0.5)) { session.summary = nil }
        case .running: session.current?.step.retention == true ? session.breathe() : session.pause()
        case .paused: session.resume()
        case .welcome, .safety: break
        }
    }

    private func begin(_ pattern: Pattern) {
        if pattern.intense, !store.prefs.acknowledged.contains(pattern.id) {
            safety = pattern
            return
        }
        session.start(pattern, store: store)
    }

    private func present(_ action: @escaping () -> Void) {
        showSettings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: action)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard mode == .idle || mode == .summary || (mode == .welcome && welcomeStep == 3) else { return }
                let x = value.translation.width
                guard abs(x) > abs(value.translation.height) else { return }
                let all = PatternID.carousel
                let i = all.firstIndex(of: store.prefs.selected) ?? 0
                let atEdge = (i == 0 && x > 0) || (i == all.count - 1 && x < 0)
                dragX = atEdge ? rubberband(x) : x
            }
            .onEnded { value in
                let t = value.translation, projected = value.predictedEndTranslation
                switch mode {
                case .welcome where welcomeStep == 3:
                    if projected.width < -90 { shift(1) } else if projected.width > 90 { shift(-1) }
                    withAnimation(.spring(duration: 0.4, bounce: 0)) { dragX = 0 }
                case .idle, .summary:
                    if abs(t.width) > abs(t.height) {
                        if projected.width < -90 { shift(1) } else if projected.width > 90 { shift(-1) }
                        withAnimation(.spring(duration: 0.4, bounce: 0)) { dragX = 0 }
                    } else if t.height < -60 {
                        showSettings = true
                    }
                case .running, .paused:
                    if t.height > 80 { session.end() }
                default:
                    break
                }
            }
    }

    private func shift(_ delta: Int) {
        let all = PatternID.carousel
        guard let i = all.firstIndex(of: store.prefs.selected), all.indices.contains(i + delta) else { return }
        withAnimation(.smooth(duration: 0.45)) {
            session.summary = nil
            store.prefs.selected = all[i + delta]
        }
    }

    private func rubberband(_ x: CGFloat) -> CGFloat {
        let dimension: CGFloat = 400, c: CGFloat = 0.55
        return (x * dimension * c) / (dimension + c * abs(x))
    }
}

/// The session's details on the darkened screen: lines rise into focus one after another,
/// and the time and breath count roll up from zero.
struct SummaryText: View {
    let summary: Session.Summary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var seconds = 0.0
    @State private var breaths = 0

    var body: some View {
        VStack(spacing: 12) {
            reveal(0, Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
                .scaledFont(68, .light).monospacedDigit()
                .contentTransition(.numericText()))
            reveal(1, Text("^[\(breaths) breath](inflect: true)")
                .font(.title3.weight(.medium))
                .contentTransition(.numericText()))
            if !summary.holds.isEmpty {
                reveal(2, Text("Holds \(summary.holds.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }.formatted(.list(type: .and)))")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary))
            }
            if let heart = summary.heart {
                reveal(3, Text("Heart \(Int(heart.start)) → \(Int(heart.end)) bpm")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary))
            }
            reveal(4, Text(summary.pattern.name).font(.subheadline.weight(.medium)).foregroundStyle(.secondary))
        }
        .onAppear {
            shown = true
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 1.1).delay(0.15)) {
                seconds = summary.seconds
                breaths = summary.breaths
            }
        }
    }

    private func reveal(_ order: Int, _ line: some View) -> some View {
        line
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 6)
            .offset(y: shown || reduceMotion ? 0 : 16)
            .scaleEffect(shown || reduceMotion ? 1 : 0.97)
            .animation(.easeOut(duration: 0.6).delay(0.12 * Double(order)), value: shown)
    }
}

/// While you drag between patterns, the name softens with your finger and drifts only slightly.
private struct DragSoften: ViewModifier {
    let x: CGFloat
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .offset(x: reduceMotion ? 0 : x * 0.18)
            .blur(radius: reduceMotion ? 0 : min(abs(x) / 30, 8))
            .opacity(1 - min(abs(x) / 260, 0.65))
    }
}

/// The pattern dial: one coloured bar per pattern. A small glass lens rests around the chosen bar; as you
/// drag it swells into a wider lens that magnifies and bends the bars beneath and names the pattern.
struct PatternDial: View {
    let selected: PatternID
    let select: (PatternID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragX: CGFloat?

    static let width: CGFloat = 330
    static let height: CGFloat = 64
    private static let open = CGSize(width: 104, height: 52)
    private static let resting = CGSize(width: 20, height: 40)
    private let all = PatternID.carousel
    private var pad: CGFloat { Self.open.width / 2 + 6 }
    private var slot: CGFloat { (Self.width - 2 * pad) / CGFloat(all.count - 1) }

    var body: some View {
        let index = all.firstIndex(of: selected) ?? 0
        let x = dragX.map { min(max($0, pad), Self.width - pad) } ?? pad + CGFloat(index) * slot
        let tint = selected.colors[1]
        let lifted = dragX != nil
        let lens = lifted ? Self.open : Self.resting
        ZStack {
            Capsule()
                .fill(.black.opacity(0.55))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            bars
                .modifier(Lens(x: x, y: Self.height / 2, width: lens.width, height: lens.height, lift: lifted ? 1 : 0, enabled: !reduceMotion))
            Capsule()
                .fill(.white.opacity(0.05))
                .overlay(alignment: .top) {
                    // A soft sheen along the top, where light would catch curved glass.
                    Capsule()
                        .fill(LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom))
                        .frame(height: lens.height * 0.45)
                        .padding(.horizontal, lens.width * 0.12)
                        .padding(.top, 2)
                }
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(colors: [tint, .white.opacity(0.1), tint.opacity(0.55)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.2
                    )
                )
                .overlay(alignment: .top) {
                    if lifted {
                        Text(selected.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(tint)
                            .fixedSize()
                            .contentTransition(.numericText())
                            .padding(.top, 6)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)).animation(.smooth(duration: 0.25)))
                    }
                }
                .overlay {
                    Capsule()
                        .fill(tint)
                        .frame(width: 5, height: 22)
                        .shadow(color: tint.opacity(0.8), radius: 6)
                        .offset(y: lifted ? 10 : 0)
                }
                .frame(width: lens.width, height: lens.height)
                .position(x: x, y: Self.height / 2)
        }
        .frame(width: Self.width, height: Self.height)
        .contentShape(.capsule)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.82)) { dragX = value.location.x }
                let clamped = min(max(value.location.x, pad), Self.width - pad)
                let i = Int(((clamped - pad) / slot).rounded())
                if all[i] != selected { select(all[i]) }
            }
            .onEnded { _ in
                withAnimation(.spring(duration: 0.55, bounce: 0.3)) { dragX = nil }
            })
        .animation(.smooth(duration: 0.3), value: selected)
    }

    private var bars: some View {
        Canvas { ctx, size in
            for (i, id) in all.enumerated() {
                let x = pad + CGFloat(i) * slot
                let rect = CGRect(x: x - 1.25, y: size.height / 2 - 7, width: 2.5, height: 14)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.25), with: .color(id.colors[1]))
            }
        }
    }
}

/// Feeds the lens shader its position and size every frame, so the refraction moves with the glass.
private struct Lens: ViewModifier, Animatable {
    var x: CGFloat
    let y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var lift: CGFloat
    let enabled: Bool

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(x, width), .init(height, lift)) }
        set {
            x = newValue.first.first
            width = newValue.first.second
            height = newValue.second.first
            lift = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        content.layerEffect(
            ShaderLibrary.lens(.float2(x, y), .float2(width, height), .float(lift)),
            maxSampleOffset: CGSize(width: 40, height: 40),
            isEnabled: enabled
        )
    }
}
