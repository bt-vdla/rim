import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct RimWidgets: WidgetBundle {
    var body: some Widget {
        StartWidget()
        BreatheControl()
        UrgeControl()
        BreathLive()
    }
}

// MARK: Start widget

struct PickPattern: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Pattern"
    @Parameter(title: "Pattern", default: .steady) var pattern: PatternID
}

struct StartEntry: TimelineEntry {
    let date: Date
    let pattern: PatternID
}

struct StartProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> StartEntry { StartEntry(date: .now, pattern: .steady) }
    func snapshot(for configuration: PickPattern, in context: Context) async -> StartEntry {
        StartEntry(date: .now, pattern: configuration.pattern)
    }
    func timeline(for configuration: PickPattern, in context: Context) async -> Timeline<StartEntry> {
        Timeline(entries: [StartEntry(date: .now, pattern: configuration.pattern)], policy: .never)
    }
}

struct StartWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "start", intent: PickPattern.self, provider: StartProvider()) {
            StartWidgetView(entry: $0)
        }
        .configurationDisplayName("Breathe")
        .description("Starts a pattern.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct StartWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StartEntry

    var body: some View {
        let colors = entry.pattern.colors
        let gradient = LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Circle().inset(by: 5).stroke(lineWidth: 2)
                    Image(systemName: "wind")
                }
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Circle().stroke(lineWidth: 2).frame(width: 22, height: 22)
                    Text(entry.pattern.title).font(.headline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                ZStack {
                    ContainerRelativeShape().inset(by: 7)
                        .stroke(gradient, lineWidth: 8)
                        .blur(radius: 9)
                        .opacity(0.8)
                    ContainerRelativeShape().inset(by: 7)
                        .stroke(gradient, lineWidth: 2)
                    Text(entry.pattern.title)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color.black.mix(with: colors[1], by: 0.25), .black, Color.black.mix(with: colors[2], by: 0.2)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .widgetURL(URL(string: "rim://start/\(entry.pattern.rawValue)"))
    }
}

// MARK: Control Center

struct BreatheControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.bt.rim.breathe") {
            ControlWidgetButton(action: StartBreathing()) {
                Label("Breathe", systemImage: "wind")
            }
        }
        .displayName("Breathe")
    }
}

struct UrgeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.bt.rim.urge") {
            ControlWidgetButton(action: StartBreathing(pattern: .urge)) {
                Label("Ride out an urge", systemImage: "leaf")
            }
        }
        .displayName("Ride out an urge")
    }
}

// MARK: Live Activity

struct BreathLive: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BreathActivity.self) { context in
            let colors = context.attributes.pattern.colors
            HStack(spacing: 16) {
                timer(context.state, tint: colors[0]).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.word).font(.title3.weight(.medium))
                    Text(context.attributes.pattern.title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(context.state.breaths)")
                    .font(.title2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding(18)
            .activityBackgroundTint(Color.black.mix(with: colors[1], by: 0.2).opacity(0.8))
        } dynamicIsland: { context in
            let tint = context.attributes.pattern.colors[0]
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    timer(context.state, tint: tint).frame(width: 36, height: 36)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.word).font(.title3.weight(.medium))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.breaths)").font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                }
            } compactLeading: {
                timer(context.state, tint: tint)
            } compactTrailing: {
                Text(context.state.word).font(.caption.weight(.medium)).foregroundStyle(tint)
            } minimal: {
                timer(context.state, tint: tint)
            }
        }
    }

    private func timer(_ state: BreathActivity.ContentState, tint: Color) -> some View {
        ProgressView(timerInterval: state.start...max(state.start, state.end), countsDown: false) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .progressViewStyle(.circular)
        .tint(tint)
    }
}
