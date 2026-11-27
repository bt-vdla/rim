import SwiftUI

/// The image a finished session shares as: story-sized, the pattern's colours, the edge light, the numbers.
struct ShareCard: View {
    let summary: Session.Summary
    let colors: [Color]
    let best: Double?

    var body: some View {
        let edge = LinearGradient(colors: [.white, colors[0], .white], startPoint: .topLeading, endPoint: .bottomTrailing)
        ZStack {
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.55, 0], [1, 0], [0, 0.45], [0.5, 0.55], [1, 0.4], [0, 1], [0.45, 1], [1, 1]],
                colors: [
                    colors[1], colors[0], colors[2],
                    colors[2].mix(with: .black, by: 0.35), colors[1].mix(with: .black, by: 0.5), colors[0].mix(with: .black, by: 0.35),
                    colors[0], colors[2], colors[1],
                ],
                smoothsColors: true
            )
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .inset(by: 12)
                .stroke(edge, lineWidth: 6)
                .blur(radius: 10)
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .inset(by: 12)
                .stroke(edge, lineWidth: 2.5)
            VStack(spacing: 8) {
                Spacer()
                Text(summary.pattern.name)
                    .font(.system(size: 22, weight: .semibold))
                    .opacity(0.85)
                Text(Duration.seconds(summary.seconds).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: 88, weight: .medium).monospacedDigit())
                    .tracking(-2)
                Text("^[\(summary.breaths) breath](inflect: true)")
                    .font(.system(size: 20, weight: .medium))
                    .opacity(0.85)
                if let longest = summary.holds.max() {
                    Text(longest >= (best ?? 0) ? "Personal best hold \(clock(longest))" : "Longest hold \(clock(longest))")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.top, 6)
                }
                if let heart = summary.heart {
                    Text("Heart \(Int(heart.start)) → \(Int(heart.end)) bpm")
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                }
                Spacer()
                Text(Date.now.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 14, weight: .medium))
                    .opacity(0.75)
                Text("Rim")
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 12)
            .padding(.vertical, 56)
        }
        .frame(width: 360, height: 640)
    }

    private func clock(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

/// Tap at the start of each inhale; five taps give your natural breath, and the pattern's pace follows it.
struct CalibrateView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pattern: Pattern
    @State private var taps: [Date] = []

    private var interval: Double? {
        guard taps.count >= 5, let first = taps.first, let last = taps.last else { return nil }
        return last.timeIntervalSince(first) / Double(taps.count - 1)
    }

    var body: some View {
        ZStack {
            Backdrop(colors: store.colors(pattern.id), full: taps.isEmpty ? 0.2 : 0.7, date: .now, still: true)
                .animation(.easeOut(duration: 0.3), value: taps.count)
            VStack(spacing: 12) {
                if let interval {
                    Text("\(String(format: "%.1f", interval)) s a breath")
                        .scaledFont(44, .medium)
                        .monospacedDigit()
                    Text("\(pattern.name) will run at this pace.")
                        .font(.body.weight(.medium))
                        .opacity(0.75)
                } else {
                    Text("Tap each time you start to breathe in.")
                        .scaledFont(26, .medium)
                        .multilineTextAlignment(.center)
                    Text("\(taps.count) of 5")
                        .font(.body.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .opacity(0.7)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 44)

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    button(interval == nil ? "Cancel" : "Not now") { dismiss() }
                    if interval != nil { button("Use this pace", action: use) }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 36)
        }
        .contentShape(Rectangle())
        .onTapGesture { if interval == nil { withAnimation { taps.append(.now) } } }
        .accessibilityAction(named: "Breathing in now") { if interval == nil { taps.append(.now) } }
        .sensoryFeedback(.impact(weight: .light), trigger: taps.count)
        .statusBarHidden()
    }

    private func use() {
        guard let interval else { return }
        store.prefs.pace[pattern.id.rawValue] = min(1.6, max(0.6, pattern.cycle / interval))
        dismiss()
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 30)
                .frame(height: 54)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}
