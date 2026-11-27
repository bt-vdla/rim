import AppIntents
import SwiftUI

@main
struct RimApp: App {
    @State private var store = Store()
    @State private var session = Session()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            BreatheView()
                .environment(store)
                .environment(session)
                .preferredColorScheme(.dark)
                .tint(Color(hex: 0x8BE9FF))
                .onAppear(perform: wire)
                .onOpenURL { url in
                    guard url.host == "start" else { return }
                    store.request = PatternID(rawValue: url.lastPathComponent) ?? store.prefs.selected
                }
                .onChange(of: phase) { _, phase in
                    guard phase == .active, let pending = Launch.takePending() else { return }
                    store.request = PatternID(rawValue: pending) ?? store.prefs.selected
                }
        }
    }

    private func wire() {
        Launch.handler = { id in store.request = id ?? store.prefs.selected }
        session.onFinish = { summary, start, end in
            store.records.append(Record(
                pattern: summary.pattern.id, date: start, seconds: summary.seconds,
                breaths: summary.breaths, holds: summary.holds
            ))
            if store.prefs.health { Task { await Health.save(start: start, end: end) } }
        }
    }
}

struct RimShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartBreathing(),
            phrases: [
                "Breathe with \(.applicationName)",
                "Start \(\.$pattern) in \(.applicationName)",
            ],
            shortTitle: "Breathe",
            systemImageName: "wind"
        )
        AppShortcut(
            intent: StartBreathing(pattern: .urge),
            phrases: ["Ride out an urge with \(.applicationName)", "I have an urge in \(.applicationName)"],
            shortTitle: "Ride out an urge",
            systemImageName: "leaf"
        )
    }
}
