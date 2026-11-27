import ActivityKit
import HealthKit
import UserNotifications

enum Health {
    private static let store = HKHealthStore()
    private static let mindful = HKCategoryType(.mindfulSession)

    /// The first call shows the permission sheet, so it lands at the end of the first session.
    static func save(start: Date, end: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: [mindful], read: [])
        guard store.authorizationStatus(for: mindful) == .sharingAuthorized else { return }
        let sample = HKCategorySample(type: mindful, value: HKCategoryValue.notApplicable.rawValue, start: start, end: end)
        try? await store.save(sample)
    }
}

enum Reminder {
    static func set(_ on: Bool, minutes: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily"])
        guard on, (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.body = "Take a minute to breathe."
        var time = DateComponents()
        time.hour = minutes / 60
        time.minute = minutes % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: time, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: "daily", content: content, trigger: trigger))
    }
}

/// Lock Screen, Dynamic Island and StandBy presence during a session.
@MainActor final class Live {
    private var activity: Activity<BreathActivity>?

    func start(_ id: PatternID, state: BreathActivity.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: BreathActivity(pattern: id), content: .init(state: state, staleDate: nil))
    }

    func update(_ state: BreathActivity.ContentState) {
        guard let activity else { return }
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
