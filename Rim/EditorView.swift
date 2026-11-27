import SwiftUI

/// Edit a pattern with one wheel per phase.
struct EditorView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pattern: Pattern
    @State private var seconds: [Double]
    @State private var confirmReset = false

    private static let choices = Array(stride(from: 1.0, through: 20.0, by: 0.5))

    init(pattern: Pattern) {
        self.pattern = pattern
        _seconds = State(initialValue: pattern.beats.map { min(20, max(1, ($0.seconds * 2).rounded() / 2)) })
    }

    private var edited: Bool { store.prefs.beats[pattern.id.rawValue] != nil && pattern.id != .custom }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                HStack(spacing: 0) {
                    ForEach(pattern.beats.indices, id: \.self) { i in
                        VStack(spacing: 4) {
                            Text(Feed.word(pattern.beats[i]))
                                .font(.subheadline.weight(.semibold))
                            Picker(Feed.word(pattern.beats[i]), selection: $seconds[i]) {
                                ForEach(Self.choices, id: \.self) { Text($0.clean).tag($0) }
                            }
                            .pickerStyle(.wheel)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Text("\(seconds.reduce(0, +).clean) s a breath")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .navigationTitle(pattern.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", action: save)
                }
                if edited {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Reset to original") { confirmReset = true }
                    }
                }
            }
            .confirmationDialog("Reset \(pattern.name)?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset \(pattern.name)", role: .destructive) {
                    store.prefs.beats[pattern.id.rawValue] = nil
                    dismiss()
                }
            } message: {
                Text("Your changes to \(pattern.detail) are lost.")
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        store.prefs.beats[pattern.id.rawValue] = zip(pattern.beats, seconds).map { beat, s in
            var beat = beat
            beat.seconds = s
            return beat
        }
        dismiss()
    }
}
