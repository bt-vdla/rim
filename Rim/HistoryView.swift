import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        let minutes = Int(store.records.filter { $0.date >= weekStart }.reduce(0) { $0 + $1.seconds } / 60)
        let days = Set(store.records.map { calendar.startOfDay(for: $0.date) })
        let today = calendar.startOfDay(for: .now)
        let grid = (0..<28).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }

        Form {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(minutes) min")
                            .scaledFont(44, .medium).monospacedDigit()
                        Text("This week").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 7), spacing: 10) {
                        ForEach(grid, id: \.self) { day in
                            Circle()
                                .fill(days.contains(day) ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                                .frame(width: 12, height: 12)
                                .accessibilityLabel(day.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            if !store.urges.isEmpty {
                Section("Urges") {
                    let week = store.urges.filter { $0.date >= weekStart }
                    LabeledContent("Ridden out this week", value: "\(week.filter(\.passed).count) of \(week.count)")
                    LabeledContent("All time", value: "\(store.urges.filter(\.passed).count)")
                }
            }

            if store.holds.count > 1 {
                Section("Breath hold") {
                    Chart(store.holds.suffix(30)) {
                        LineMark(x: .value("Date", $0.date), y: .value("Seconds", $0.seconds))
                            .interpolationMethod(.catmullRom)
                        PointMark(x: .value("Date", $0.date), y: .value("Seconds", $0.seconds))
                            .symbolSize(20)
                    }
                    .chartYAxisLabel("s")
                    .frame(height: 140)
                }
            }

            Section("Sessions") {
                if store.records.isEmpty {
                    Text("No sessions yet. They appear here when you finish one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.records.reversed().prefix(50)) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.pattern.title)
                            Text(record.date.formatted(.relative(presentation: .named)))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Duration.seconds(record.seconds).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("History")
    }
}
