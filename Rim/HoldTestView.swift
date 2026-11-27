import SwiftUI

/// After a normal exhale, press and hold until the first urge to breathe. The light laps once a minute.
struct HoldTestView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var result: Double?

    var body: some View {
        let colors = PatternID.rounds.colors
        ZStack {
            GeometryReader { proxy in
                let ring = RingPath(
                    rect: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 3, dy: 3),
                    radius: RingPath.screenRadius(proxy) - 3
                )
                TimelineView(.animation(paused: start == nil)) { timeline in
                    let elapsed = start.map { timeline.date.timeIntervalSince($0) } ?? 0
                    ZStack {
                        Backdrop(colors: colors, full: min(elapsed / 60, 1), date: timeline.date, still: reduceMotion)
                        RingCanvas(
                            ring: ring, radius: RingPath.screenRadius(proxy), colors: colors, style: .trace, date: timeline.date,
                            trail: min(elapsed, 59), intensity: start == nil ? 0.5 : 1, still: reduceMotion
                        ) { date in
                            guard let start else { return nil }
                            let e = max(0, date.timeIntervalSince(start))
                            return Moment(u: 0.125 + e / 60, full: min(e / 40, 1), pulse: false, side: .both)
                        }
                        center(elapsed: elapsed)
                    }
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(press)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(start != nil ? "Holding" : result.map { "\(Int($0)) seconds" } ?? "Breathe out normally, then start the hold until you first want to breathe.")
            .accessibilityActions {
                if start != nil {
                    Button("Stop hold") { stop() }
                } else if result == nil {
                    Button("Start hold") { start = .now }
                }
            }

            if start == nil {
                GlassEffectContainer(spacing: 14) {
                    HStack(spacing: 14) {
                        button("Done") { dismiss() }
                        if result != nil {
                            button("Again") { withAnimation(.smooth) { result = nil } }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 36)
                .transition(.swap(reduceMotion: reduceMotion))
            }
        }
        .foregroundStyle(.primary)
        .statusBarHidden()
        .animation(.smooth(duration: 0.4), value: start == nil)
        .sensoryFeedback(.impact(weight: .medium), trigger: start)
        .sensoryFeedback(.success, trigger: result)
    }

    @ViewBuilder
    private func center(elapsed: Double) -> some View {
        Group {
            if start != nil {
                Text("\(Int(elapsed)) s")
                    .scaledFont(64, .regular).monospacedDigit()
                    .contentTransition(.numericText())
            } else if let result {
                VStack(spacing: 8) {
                    Text("\(Int(result)) s").scaledFont(64, .regular).monospacedDigit()
                    if let previous = store.holds.dropLast().last {
                        Text("Last time \(Int(previous.seconds)) s").font(.subheadline).opacity(0.6)
                    }
                }
            } else {
                Text("Breathe out normally, then press and hold until you first want to breathe.")
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
            }
        }
        .transition(.swap(reduceMotion: reduceMotion))
        .animation(.smooth(duration: 0.4), value: result)
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard start == nil, result == nil else { return }
                start = .now
            }
            .onEnded { _ in stop() }
    }

    private func stop() {
        guard let start else { return }
        let seconds = Date.now.timeIntervalSince(start)
        self.start = nil
        guard seconds > 1 else { return }
        store.holds.append(HoldResult(date: .now, seconds: seconds))
        result = seconds
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .padding(.horizontal, 30)
                .frame(height: 54)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}
