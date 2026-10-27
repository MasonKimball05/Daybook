import ActivityKit
import AppIntents
import Foundation
import Observation

// Built into both the iPhone app and the widget extension: the app starts the
// Live Activity and answers the control, the extension draws them.

/// The next event, on the lock screen and in the Dynamic Island.
struct NextEventAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var start: Date
        var end: Date
        var place: String?
        /// When to set off, from Apple Maps travel time, for an event with a place.
        var leaveBy: Date?
        /// "18 min drive"
        var travel: String?
        /// The calendar's color, as hex.
        var color: String
    }

    /// The EventKit event this is for, so a refresh updates it rather than starting another.
    var eventID: String
}

/// Things asked of the app from outside it (the control), for it to act on once it's open.
@MainActor @Observable
final class AppRequests {
    static let shared = AppRequests()
    /// Goes up each time the Add Task control is pressed.
    var quickAdd = 0
}

/// The Add Task control in Control Center, on the lock screen or on the Action button:
/// opens Daybook on Today with the quick-add field ready to type in.
struct OpenQuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task in Daybook"
    static let description = IntentDescription("Opens Daybook ready to type a task.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRequests.shared.quickAdd += 1
        return .result()
    }
}
