import AVFoundation
import HealthKit

/// Live heart rate from AirPods Pro during a session.
/// AirPods only measure while a workout session runs, so one runs quietly and is discarded at the end.
/// Readings count only when HealthKit says they came from AirPods; other headphones simply show nothing.
@MainActor @Observable final class Heart {
    private(set) var bpm: Double?
    private var readings: [Double] = []
    private var workout: HKWorkoutSession?
    private var query: HKAnchoredObjectQuery?

    private static let store = HKHealthStore()
    private static let rate = HKQuantityType(.heartRate)

    static var airPodsProConnected: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portName.localizedCaseInsensitiveContains("AirPods Pro")
        }
    }

    static func authorize() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [rate])
    }

    func start() {
        guard Self.airPodsProConnected, HKHealthStore.isHealthDataAvailable() else { return }
        bpm = nil
        readings = []
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor
        guard let workout = try? HKWorkoutSession(healthStore: Self.store, configuration: config) else { return }
        let builder = workout.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: Self.store, workoutConfiguration: config)
        let start = Date.now
        workout.startActivity(with: start)
        builder.beginCollection(withStart: start) { _, _ in }
        self.workout = workout

        let receive: @Sendable ([HKSample]?) -> Void = { [weak self] samples in
            let values = (samples as? [HKQuantitySample] ?? [])
                .filter(Heart.fromAirPods)
                .map { $0.quantity.doubleValue(for: .count().unitDivided(by: .minute())) }
            guard !values.isEmpty else { return }
            Task { @MainActor in
                self?.readings += values
                self?.bpm = values.last
            }
        }
        let query = HKAnchoredObjectQuery(
            type: Self.rate, predicate: HKQuery.predicateForSamples(withStart: start, end: nil),
            anchor: nil, limit: HKObjectQueryNoLimit
        ) { _, samples, _, _, _ in receive(samples) }
        query.updateHandler = { _, samples, _, _, _ in receive(samples) }
        Self.store.execute(query)
        self.query = query
    }

    nonisolated static func fromAirPods(_ sample: HKQuantitySample) -> Bool {
        [sample.device?.name, sample.device?.model, sample.sourceRevision.productType, sample.sourceRevision.source.name]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains("AirPods") }
    }

    /// Stops measuring. Returns the average of the first and last few readings, when there were any.
    func stop() -> (start: Double, end: Double)? {
        if let query { Self.store.stop(query) }
        if let workout {
            workout.associatedWorkoutBuilder().discardWorkout()
            workout.end()
        }
        query = nil
        workout = nil
        bpm = nil
        guard readings.count >= 2 else { return nil }
        let k = min(3, readings.count / 2)
        let first = readings.prefix(k).reduce(0, +) / Double(k)
        let last = readings.suffix(k).reduce(0, +) / Double(k)
        return (first, last)
    }
}
