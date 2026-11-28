import SwiftUI

enum LengthMode: String, Codable, CaseIterable { case minutes, breaths, open }
enum SoundStyle: String, Codable, CaseIterable { case pluck, bowl, drone, off }
enum RingStyle: String, Codable, CaseIterable { case comet, trace }
enum WordsMode: String, Codable, CaseIterable { case always, first, off }
enum CountMode: String, Codable, CaseIterable { case number, off }
enum Palette: String, Codable, CaseIterable { case hue, heart }
enum BackdropStyle: String, Codable, CaseIterable { case gradient, contours }

struct Prefs: Codable {
    var selected: PatternID = .steady
    var length: LengthMode = .minutes
    var minutes = 5
    var breaths = 20
    var pace: [String: Double] = [:]
    var rounds = 3
    var powerBreaths = 30
    var sound: SoundStyle = .pluck
    var volume = 0.6
    var haptics = 0.8
    var ring: RingStyle = .comet
    var words: WordsMode = .always
    var count: CountMode = .number
    var reminder = false
    var reminderMinutes = 21 * 60
    var health = true
    var onboarded = false
    var acknowledged: [PatternID] = []
    var beats: [String: [Beat]] = [:]
    var easeIn = true
    var sleepFade = true
    var heartRate = false
    var palette: Palette = .hue
    var backdrop: BackdropStyle = .gradient
}

/// Reads whatever was saved and keeps defaults for anything missing, so adding a setting never wipes the rest.
extension Prefs {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var p = Prefs()
        func read<T: Decodable>(_ key: CodingKeys, _ path: WritableKeyPath<Prefs, T>) {
            if let value = try? c.decodeIfPresent(T.self, forKey: key) { p[keyPath: path] = value }
        }
        read(.selected, \.selected); read(.length, \.length); read(.minutes, \.minutes); read(.breaths, \.breaths)
        read(.pace, \.pace); read(.rounds, \.rounds); read(.powerBreaths, \.powerBreaths); read(.sound, \.sound)
        read(.volume, \.volume); read(.haptics, \.haptics); read(.ring, \.ring); read(.words, \.words)
        read(.count, \.count); read(.reminder, \.reminder)
        read(.reminderMinutes, \.reminderMinutes); read(.health, \.health); read(.onboarded, \.onboarded)
        read(.acknowledged, \.acknowledged); read(.beats, \.beats); read(.easeIn, \.easeIn)
        read(.sleepFade, \.sleepFade); read(.heartRate, \.heartRate); read(.palette, \.palette); read(.backdrop, \.backdrop)
        self = p
    }
}

struct Record: Codable, Identifiable {
    var id = UUID()
    var pattern: PatternID
    var date: Date
    var seconds: Double
    var breaths: Int
    var holds: [Double] = []
}

struct UrgeLog: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var passed: Bool
}

struct HoldResult: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var seconds: Double
}

@MainActor @Observable final class Store {
    var prefs: Prefs { didSet { Self.save(prefs, "prefs") } }
    var records: [Record] { didSet { Self.save(records, "records") } }
    var holds: [HoldResult] { didSet { Self.save(holds, "holds") } }
    var urges: [UrgeLog] { didSet { Self.save(urges, "urges") } }
    var request: PatternID?

    init() {
        var loaded: Prefs = Self.load("prefs") ?? Prefs()
        #if DEBUG
        if CommandLine.arguments.contains("-RimResetOnboarding") { loaded.onboarded = false }
        #endif
        prefs = loaded
        records = Self.load("records") ?? []
        holds = Self.load("holds") ?? []
        urges = Self.load("urges") ?? []
    }

    func pattern(_ id: PatternID) -> Pattern {
        Pattern(id: id, beats: prefs.beats[id.rawValue] ?? Pattern.defaults[id]!)
    }

    var selected: Pattern { pattern(prefs.selected) }

    func pace(_ id: PatternID) -> Double { prefs.pace[id.rawValue] ?? 1 }

    /// Colours warmed late in the evening by the clock.
    func warmed(_ colors: [Color], at date: Date = .now) -> [Color] {
        let hour = Calendar.current.component(.hour, from: date)
        let (tint, amount): (UInt32, Double) = switch hour {
        case 23, 0..<5: (0xFF5A4A, 0.45)
        case 21, 22: (0xFFB36B, 0.25)
        default: (0, 0)
        }
        guard amount > 0 else { return colors }
        return colors.map { $0.mix(with: Color(hex: tint), by: amount) }
    }

    /// Palette for a pattern, warmed late in the evening by the clock.
    func colors(_ id: PatternID, at date: Date = .now) -> [Color] {
        let hour = Calendar.current.component(.hour, from: date)
        let (tint, amount): (UInt32, Double) = switch hour {
        case 23, 0..<5: (0xFF5A4A, 0.45)
        case 21, 22: (0xFFB36B, 0.25)
        default: (0, 0)
        }
        guard amount > 0 else { return id.colors }
        return id.colors.map { $0.mix(with: Color(hex: tint), by: amount) }
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

extension LengthMode { var title: String { rawValue.capitalized } }
extension SoundStyle { var title: String { rawValue.capitalized } }
extension RingStyle { var title: String { rawValue.capitalized } }
extension Palette { var title: String { self == .hue ? "One hue" : "Heart rate" } }
extension BackdropStyle { var title: String { self == .gradient ? "Gradient" : "Contour lines" } }

extension WordsMode {
    var title: String {
        switch self {
        case .always: "Always"
        case .first: "First minute"
        case .off: "Off"
        }
    }
}
