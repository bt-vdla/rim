import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let openHoldTest: () -> Void
    let openCalibrate: () -> Void

    var body: some View {
        @Bindable var store = store
        let pattern = store.selected
        let id = pattern.id

        NavigationStack {
            Form {
                Section(pattern.name) {
                    if id == .rounds {
                        Stepper("^[\(store.prefs.rounds) round](inflect: true)", value: $store.prefs.rounds, in: 1...8)
                        Stepper("^[\(store.prefs.powerBreaths) breath](inflect: true) a round", value: $store.prefs.powerBreaths, in: 10...60, step: 5)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Pace", value: "\((pattern.cycle / store.pace(id)).clean) s a breath")
                        Slider(value: paceBinding(id), in: 0.6...1.6) {
                            Text("Pace")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise")
                        } maximumValueLabel: {
                            Image(systemName: "hare")
                        }
                    }
                    if id != .rounds {
                        Button("Match my breathing") { openCalibrate() }
                    }
                    if id == .sleep {
                        Toggle("Fade the light after six breaths", isOn: $store.prefs.sleepFade)
                    }
                }

                Section("Session") {
                    Picker("Length", selection: $store.prefs.length) {
                        ForEach(LengthMode.allCases, id: \.self) { Text($0.title) }
                    }
                    switch store.prefs.length {
                    case .minutes:
                        Stepper("\(store.prefs.minutes) min", value: $store.prefs.minutes, in: 1...60)
                    case .breaths:
                        Stepper("^[\(store.prefs.breaths) breath](inflect: true)", value: $store.prefs.breaths, in: 3...200)
                    case .open:
                        EmptyView()
                    }
                    Toggle("Ease into pace", isOn: $store.prefs.easeIn)
                    Picker("Sound", selection: $store.prefs.sound) {
                        ForEach(SoundStyle.allCases, id: \.self) { Text($0.title) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Haptics")
                        Slider(value: $store.prefs.haptics, in: 0...1) {
                            Text("Haptics")
                        } minimumValueLabel: {
                            Image(systemName: "iphone.slash")
                        } maximumValueLabel: {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                        }
                    }
                    Picker("Light", selection: $store.prefs.ring) {
                        ForEach(RingStyle.allCases, id: \.self) { Text($0.title) }
                    }
                    Picker("Colour", selection: $store.prefs.palette) {
                        ForEach(Palette.allCases, id: \.self) { Text($0.title) }
                    }
                    Picker("Background", selection: $store.prefs.backdrop) {
                        ForEach(BackdropStyle.allCases, id: \.self) { Text($0.title) }
                    }
                    Picker("Words", selection: $store.prefs.words) {
                        ForEach(WordsMode.allCases, id: \.self) { Text($0.title) }
                    }
                    Toggle("Count the seconds", isOn: countBinding)
                }

                Section {
                    NavigationLink("History") { HistoryView() }
                    Button("Breath-hold test") { openHoldTest() }
                    Toggle("Daily reminder", isOn: $store.prefs.reminder)
                    if store.prefs.reminder {
                        DatePicker("Time", selection: reminderTime, displayedComponents: .hourAndMinute)
                    }
                    Toggle("Save to Apple Health", isOn: $store.prefs.health)
                    Toggle("Heart rate from AirPods Pro", isOn: $store.prefs.heartRate)
                    Button("Replay onboarding") {
                        store.prefs.onboarded = false
                        dismiss()
                    }
                } header: {
                    Text("You")
                } footer: {
                    Text("Heart rate needs AirPods Pro 3.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: store.prefs.reminder) { updateReminder() }
        .onChange(of: store.prefs.heartRate) { _, on in
            if on { Task { await Heart.authorize() } }
        }
        .onChange(of: store.prefs.reminderMinutes) { updateReminder() }
    }

    private func paceBinding(_ id: PatternID) -> Binding<Double> {
        Binding(get: { store.pace(id) }, set: { store.prefs.pace[id.rawValue] = $0 })
    }

    private var countBinding: Binding<Bool> {
        Binding(get: { store.prefs.count == .number }, set: { store.prefs.count = $0 ? .number : .off })
    }

    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: store.prefs.reminderMinutes / 60, minute: store.prefs.reminderMinutes % 60, second: 0, of: .now) ?? .now
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                store.prefs.reminderMinutes = (c.hour ?? 21) * 60 + (c.minute ?? 0)
            }
        )
    }

    private func updateReminder() {
        let prefs = store.prefs
        Task { await Reminder.set(prefs.reminder, minutes: prefs.reminderMinutes) }
    }
}
