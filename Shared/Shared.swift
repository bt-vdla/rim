import ActivityKit
import AppIntents
import SwiftUI

enum PatternID: String, Codable, CaseIterable, AppEnum {
    case steady, sleep, balance, reset, unwind, triangle, alternate, energize, rounds, custom, urge

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pattern"
    static let caseDisplayRepresentations: [PatternID: DisplayRepresentation] = [
        .steady: "Steady", .sleep: "Sleep", .balance: "Balance", .reset: "Reset", .unwind: "Unwind",
        .triangle: "Triangle", .alternate: "Alternate", .energize: "Energize", .rounds: "Wim Hof", .custom: "Custom", .urge: "Urge",
    ]

    var title: String { self == .rounds ? "Wim Hof" : rawValue.capitalized }

    /// The patterns you swipe between. Urge has its own button.
    static var carousel: [PatternID] { allCases.filter { $0 != .urge } }

    var colors: [Color] {
        switch self {
        case .steady: [Color(hex: 0x8BE9FF), Color(hex: 0x4C8DFF), Color(hex: 0x8F7BFF)]
        case .sleep: [Color(hex: 0xC9B8FF), Color(hex: 0x6A5BFF), Color(hex: 0xFF9E7A)]
        case .balance: [Color(hex: 0xA6FFD6), Color(hex: 0x2FD3AE), Color(hex: 0x4FA8FF)]
        case .reset: [Color(hex: 0xFFD9AE), Color(hex: 0xFF8FA3), Color(hex: 0xB57BFF)]
        case .unwind: [Color(hex: 0xB8D4FF), Color(hex: 0xA99BFF), Color(hex: 0xFFB8F0)]
        case .triangle: [Color(hex: 0xFFF1B0), Color(hex: 0xFFB547), Color(hex: 0xFF6B4A)]
        case .alternate: [Color(hex: 0xB0FFF1), Color(hex: 0xE8E4FF), Color(hex: 0xF5A8FF)]
        case .energize: [Color(hex: 0xFFE873), Color(hex: 0xFF7A45), Color(hex: 0xFF3D7F)]
        case .rounds: [Color(hex: 0xE6FBFF), Color(hex: 0x7DE3FF), Color(hex: 0x5B7CFF)]
        case .custom: [Color(hex: 0xF5D0FE), Color(hex: 0xA78BFA), Color(hex: 0x60A5FA)]
        case .urge: [Color(hex: 0xB8FFF0), Color(hex: 0x3FC7C9), Color(hex: 0x5B8CFF)]
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Hands a start request from Shortcuts, Controls or widgets to the app, even across a cold launch.
enum Launch {
    static let suite = UserDefaults(suiteName: "group.com.bt.rim") ?? .standard
    @MainActor static var handler: ((PatternID?) -> Void)?

    @MainActor static func request(_ id: PatternID?) {
        if let handler { return handler(id) }
        suite.set(id?.rawValue ?? "last", forKey: "pendingStart")
    }

    static func takePending() -> String? {
        defer { suite.removeObject(forKey: "pendingStart") }
        return suite.string(forKey: "pendingStart")
    }
}

struct StartBreathing: AppIntent {
    static let title: LocalizedStringResource = "Start Breathing"
    static let description = IntentDescription("Opens Rim and starts a session.")
    static let openAppWhenRun = true

    @Parameter(title: "Pattern") var pattern: PatternID?

    init() {}
    init(pattern: PatternID?) { self.pattern = pattern }

    @MainActor func perform() async throws -> some IntentResult {
        Launch.request(pattern)
        return .result()
    }
}

struct BreathActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var word: String
        var start: Date
        var end: Date
        var breaths: Int
    }

    var pattern: PatternID
}
