import Foundation

/// How much a task or event matters. High and urgent ones get several alerts;
/// the rest get one (see AlertPlanner).
public enum Priority: Int, Codable, CaseIterable, Comparable, Sendable {
    case none = 0, low, medium, high, urgent

    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }

    public var isImportant: Bool { self >= .high }

    public var name: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .urgent: "Urgent"
        }
    }

    /// Reminders keeps a task's priority as a number: 1 is high, 5 medium, 9 low,
    /// 0 none. Reminders has no "urgent", so Daybook uses 2, which Reminders
    /// still shows as high.
    public init(reminderPriority: Int) {
        switch reminderPriority {
        case 2: self = .urgent
        case 1, 3, 4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }

    public var reminderPriority: Int {
        switch self {
        case .none: 0
        case .low: 9
        case .medium: 5
        case .high: 1
        case .urgent: 2
        }
    }

    /// From quick-add text: "!urgent", "!high", "!medium" ("!med"), "!low", or
    /// Reminders' own "!!!" (high), plus "!!!!" for urgent.
    static func token(_ word: Substring) -> Priority? {
        switch word.lowercased() {
        case "!urgent", "!!!!": .urgent
        case "!high", "!!!": .high
        case "!medium", "!med", "!!": .medium
        case "!low": .low
        default: nil
        }
    }
}
