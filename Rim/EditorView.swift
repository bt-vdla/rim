import SwiftUI

/// Shapes a pattern on the screen edge itself: drag the joins between phases, tap a phase to change it.
struct EditorView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pattern: Pattern
    @State private var kinds: [Kind]
    @State private var seconds: [Double]
    @State private var dragging: Int?
    @State private var confirmReset = false
    @Namespace private var glass

    enum Kind {
        case inhale, hold, exhale

        var word: String {
            switch self {
            case .inhale: "Inhale"
            case .hold: "Hold"
            case .exhale: "Exhale"
            }
        }

        var next: Kind {
            switch self {
            case .inhale: .hold
            case .hold: .exhale
            case .exhale: .inhale
            }
        }
    }

    init(pattern: Pattern) {
        self.pattern = pattern
        _kinds = State(initialValue: pattern.beats.map {
            switch $0.phase {
            case .inhale: .inhale
            case .exhale: .exhale
            case .holdIn, .holdOut: .hold
            }
        })
        _seconds = State(initialValue: pattern.beats.map(\.seconds))
    }

    private var total: Double { seconds.reduce(0, +) }

    private var joins: [Double] {
        var sum = 0.0
        return [0] + seconds.map { sum += $0; return sum / total }
    }

    var body: some View {
        let colors = store.colors(pattern.id)
        ZStack {
            GeometryReader { proxy in
                let ring = RingPath(
                    rect: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 26, dy: 26),
                    radius: RingPath.screenRadius(proxy) - 26
                )
                ZStack {
                    Backdrop(colors: colors, full: 0.5, date: .now, still: true)
                    segments(ring: ring, colors: colors)
                    labels(ring: ring)
                    handles(ring: ring)
                }
                .contentShape(Rectangle())
                .gesture(edit(ring: ring))
            }
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Text(pattern.name).scaledFont(40, .medium)
                Text("\(total.clean) s a breath").font(.subheadline.weight(.medium).monospacedDigit()).opacity(0.65)
                VStack(spacing: 2) {
                    ForEach(kinds.indices, id: \.self) { i in
                        Stepper(value: phaseSeconds(i), in: 0.5...30, step: 0.5) {
                            Text("\(kinds[i].word)  \(seconds[i].clean) s")
                                .font(.body.weight(.medium))
                                .monospacedDigit()
                        }
                        .accessibilityAction(named: "Change to \(kinds[i].next.word)") { kinds[i] = kinds[i].next }
                    }
                }
                .frame(width: 250)
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        circle("minus", label: "Remove phase", disabled: kinds.count <= 2) {
                            kinds.removeLast()
                            seconds.removeLast()
                        }
                        circle("plus", label: "Add phase", disabled: kinds.count >= 4) {
                            kinds.append(.hold)
                            seconds.append(2)
                        }
                    }
                }
            }
            .foregroundStyle(.primary)

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    circle("xmark", label: "Cancel") { dismiss() }
                    Button(action: save) {
                        Text("Save")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 34)
                            .frame(height: 54)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    if store.prefs.beats[pattern.id.rawValue] != nil, pattern.id != .custom {
                        circle("arrow.counterclockwise", label: "Reset to original") { confirmReset = true }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 70)
        }
        .statusBarHidden()
        .animation(.smooth(duration: 0.35), value: kinds)
        .confirmationDialog("Reset \(pattern.name)?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset \(pattern.name)", role: .destructive) {
                store.prefs.beats[pattern.id.rawValue] = nil
                dismiss()
            }
        } message: {
            Text("Your changes to \(store.pattern(pattern.id).detail) are lost.")
        }
        .sensoryFeedback(.selection, trigger: seconds)
    }

    private func segments(ring: RingPath, colors: [Color]) -> some View {
        let joins = joins
        return Canvas { ctx, _ in
            ctx.stroke(ring.outline, with: .color(.white.opacity(0.08)), lineWidth: 1)
            for (i, kind) in kinds.enumerated() {
                let path = ring.span(from: joins[i], by: joins[i + 1] - joins[i])
                let color = switch kind {
                case .inhale: colors[0]
                case .hold: colors[1]
                case .exhale: colors[2]
                }
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 12))
                    layer.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 12)
                }
                ctx.stroke(path, with: .color(color), lineWidth: 3)
            }
        }
        .allowsHitTesting(false)
    }

    private func labels(ring: RingPath) -> some View {
        let joins = joins
        return ForEach(kinds.indices, id: \.self) { i in
            let mid = (joins[i] + joins[i + 1]) / 2
            let p = ring.point(mid), n = ring.normal(mid)
            VStack(spacing: 1) {
                Text(seconds[i].clean).font(.title3.weight(.semibold).monospacedDigit())
                Text(kinds[i].word).font(.caption)
            }
            .foregroundStyle(.primary)
            .contentTransition(.numericText())
            .position(x: p.x + n.dx * 42, y: p.y + n.dy * 42)
        }
        .allowsHitTesting(false)
    }

    private func handles(ring: RingPath) -> some View {
        let joins = joins
        return ForEach(1..<kinds.count, id: \.self) { k in
            Circle()
                .fill(.white.opacity(dragging == k ? 0.35 : 0.12))
                .frame(width: 30, height: 30)
                .glassEffect(.regular, in: .circle)
                .scaleEffect(dragging == k ? 1.25 : 1)
                .position(ring.point(joins[k]))
                .animation(.spring(duration: 0.3, bounce: 0), value: dragging)
        }
        .allowsHitTesting(false)
    }

    private func edit(ring: RingPath) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragging == nil {
                    let joins = joins
                    let hit = (1..<kinds.count).min {
                        distance(ring.point(joins[$0]), value.startLocation) < distance(ring.point(joins[$1]), value.startLocation)
                    }
                    if let hit, distance(ring.point(joins[hit]), value.startLocation) < 44 { dragging = hit } else { dragging = -1 }
                }
                guard let k = dragging, k > 0 else { return }
                move(join: k, to: ring.nearest(to: value.location).u)
            }
            .onEnded { value in
                defer { dragging = nil }
                guard dragging == -1, hypot(value.translation.width, value.translation.height) < 10 else { return }
                let (u, d) = ring.nearest(to: value.location)
                guard d < 70, let i = joins.indices.dropLast().last(where: { joins[$0] <= u }) else { return }
                kinds[i] = kinds[i].next
            }
    }

    private func move(join k: Int, to u: Double) {
        var cumulative = [0.0]
        for s in seconds { cumulative.append(cumulative.last! + s) }
        let low = cumulative[k - 1] + 0.5, high = cumulative[k + 1] - 0.5
        let snapped = min(max((u * total * 2).rounded() / 2, low), high)
        let left = snapped - cumulative[k - 1], right = cumulative[k + 1] - snapped
        guard left != seconds[k - 1] else { return }
        seconds[k - 1] = left
        seconds[k] = right
    }

    private func phaseSeconds(_ i: Int) -> Binding<Double> {
        Binding(
            get: { seconds.indices.contains(i) ? seconds[i] : 0.5 },
            set: { if seconds.indices.contains(i) { seconds[i] = $0 } }
        )
    }

    private func save() {
        var last = kinds.last(where: { $0 != .hold }) ?? .exhale
        let beats = zip(kinds, seconds).map { kind, s -> Beat in
            defer { if kind != .hold { last = kind } }
            switch kind {
            case .inhale: return Beat(phase: .inhale, seconds: s)
            case .exhale: return Beat(phase: .exhale, seconds: s)
            case .hold: return Beat(phase: last == .inhale ? .holdIn : .holdOut, seconds: s)
            }
        }
        store.prefs.beats[pattern.id.rawValue] = beats
        dismiss()
    }

    private func circle(_ symbol: String, label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(disabled ? 0.3 : 1))
                .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
