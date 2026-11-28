import AVFoundation
import HealthKit

/// Live heart rate from AirPods Pro during a session.
/// AirPods only measure while a workout session runs, so one runs quietly and is discarded at the end.
/// Readings count only when HealthKit says they came from AirPods; other headphones simply show nothing.
@MainActor @Observable final class Heart: NSObject, HKLiveWorkoutBuilderDelegate {
    /// True while measuring, before the first reading arrives.
    private(set) var waiting = false
    private(set) var bpm: Double? {
        didSet { if oldValue == nil, bpm != nil { firstReading = .now } }
    }
    private var readings: [Double] = []
    /// AirPods report a rate every few seconds, not each beat, so beats are timed from the rate.
    /// The phase carries over when the rate changes, so the pulse never skips.
    @ObservationIgnored private var anchor = (date: Date.now, phase: 0.0)
    @ObservationIgnored private var firstReading: Date?
    @ObservationIgnored private var fake: Task<Void, Never>?
    private var workout: HKWorkoutSession?
    private var query: HKAnchoredObjectQuery?

    private static let store = HKHealthStore()
    private static let rate = HKQuantityType(.heartRate)

    /// Any AirPods, or any Bluetooth headphones, since people rename their AirPods.
    static var airPodsProConnected: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portName.localizedCaseInsensitiveContains("AirPods")
                || [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType)
        }
    }

    static func authorize() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [rate])
    }

    /// The heartbeat at a moment: `beat` is a soft double thump each cycle, `weight` eases in over
    /// the first two seconds of readings so the gradient hands over from the breath smoothly.
    func pulse(at date: Date) -> (beat: Double, weight: Double) {
        guard let bpm, let firstReading else { return (0, 0) }
        let f = phase(at: date, bpm: bpm).truncatingRemainder(dividingBy: 1)
        let beat = exp(-pow((f - 0.06) / 0.07, 2)) + 0.45 * exp(-pow((f - 0.3) / 0.08, 2))
        let w = min(1, max(0, date.timeIntervalSince(firstReading) / 2))
        return (min(1, beat), w * w * (3 - 2 * w))
    }

    private func phase(at date: Date, bpm: Double) -> Double {
        anchor.phase + date.timeIntervalSince(anchor.date) * bpm / 60
    }

    private func receive(_ values: [Double]) {
        guard let value = values.last else { return }
        log("reading \(values)")
        waiting = false
        if let bpm { anchor = (.now, phase(at: .now, bpm: bpm)) } else { anchor = (.now, 0) }
        readings += values
        bpm = value
    }

    func start() {
        if Self.faking { return startFake() }
        log("route \(AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portName) \($0.portType.rawValue)" })")
        guard Self.airPodsProConnected, HKHealthStore.isHealthDataAvailable() else { return log("no headphones") }
        log("auth \(Self.store.authorizationStatus(for: HKObjectType.workoutType()).rawValue)")
        bpm = nil
        readings = []
        waiting = true
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor
        let workout: HKWorkoutSession
        do { workout = try HKWorkoutSession(healthStore: Self.store, configuration: config) } catch {
            waiting = false
            return log("session failed \(error)")
        }
        let builder = workout.associatedWorkoutBuilder()
        let source = HKLiveWorkoutDataSource(healthStore: Self.store, workoutConfiguration: config)
        source.enableCollection(for: Self.rate, predicate: nil)
        builder.dataSource = source
        builder.delegate = self
        let start = Date.now
        workout.startActivity(with: start)
        builder.beginCollection(withStart: start) { ok, error in
            Task { @MainActor in self.log("collecting \(ok) \(String(describing: error))") }
        }
        self.workout = workout

        let receive: @Sendable ([HKSample]?) -> Void = { [weak self] samples in
            let values = (samples as? [HKQuantitySample] ?? [])
                .filter(Heart.fromAirPods)
                .map { $0.quantity.doubleValue(for: .count().unitDivided(by: .minute())) }
            guard !values.isEmpty else { return }
            Task { @MainActor in self?.receive(values) }
        }
        let query = HKAnchoredObjectQuery(
            type: Self.rate, predicate: HKQuery.predicateForSamples(withStart: start, end: nil),
            anchor: nil, limit: HKObjectQueryNoLimit
        ) { _, samples, _, _, _ in receive(samples) }
        query.updateHandler = { _, samples, _, _, _ in receive(samples) }
        Self.store.execute(query)
        self.query = query
    }

    /// The live workout hands over each new heart rate as it is measured.
    nonisolated func workoutBuilder(_ builder: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        guard types.contains(Self.rate),
              let value = builder.statistics(for: Self.rate)?.mostRecentQuantity()?
                .doubleValue(for: .count().unitDivided(by: .minute()))
        else { return }
        Task { @MainActor in self.receive([value]) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ builder: HKLiveWorkoutBuilder) {}

    private func log(_ message: String) {
        #if DEBUG
        print("[heart] \(message)")
        #endif
    }

    nonisolated static func fromAirPods(_ sample: HKQuantitySample) -> Bool {
        [sample.device?.name, sample.device?.model, sample.sourceRevision.productType, sample.sourceRevision.source.name]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains("AirPods") }
    }

    /// Stops measuring. Returns the average of the first and last few readings, when there were any.
    func stop() -> (start: Double, end: Double)? {
        fake?.cancel()
        fake = nil
        firstReading = nil
        waiting = false
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

    #if DEBUG
    static let faking = ProcessInfo.processInfo.arguments.contains("-RimFakeHeart")
    #else
    static let faking = false
    #endif

    /// Simulator stand-in for AirPods: a rate that drifts down from 78, a reading every three seconds.
    private func startFake() {
        bpm = nil
        readings = []
        fake = Task { [weak self] in
            var rate = 78.0
            while !Task.isCancelled {
                self?.receive([rate.rounded()])
                rate = max(58, rate - Double.random(in: 0...1.6))
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
