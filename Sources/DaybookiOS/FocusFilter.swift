import AppIntents
@preconcurrency import EventKit
import Foundation

/// Daybook's Focus filter (Settings ▸ Focus ▸ a Focus ▸ Add Filter ▸ Daybook):
/// only the calendars you pick show while that Focus is on, say just school
/// during Study. When the Focus ends, iOS runs this again with nothing picked,
/// and everything shows again.
struct DaybookFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Daybook Calendars"
    static let description = IntentDescription("Show only some calendars while this Focus is on.")

    @Parameter(title: "Calendars")
    var calendars: [CalendarEntity]?

    var displayRepresentation: DisplayRepresentation {
        let names = (calendars ?? []).map(\.title)
        return DisplayRepresentation(title: names.isEmpty ? "All calendars" : "\(names.joined(separator: ", "))")
    }

    func perform() async throws -> some IntentResult {
        let ids = (calendars ?? []).map(\.id)
        CalendarStore.focusCalendars = ids.isEmpty ? nil : Set(ids)
        await MainActor.run { NotificationCenter.default.post(name: .focusFilterChanged, object: nil) }
        return .result()
    }
}

extension Notification.Name {
    static let focusFilterChanged = Notification.Name("DaybookFocusFilterChanged")
}

/// A calendar, to pick in the Focus filter.
struct CalendarEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Calendar"
    static let defaultQuery = CalendarQuery()

    let id: String
    let title: String
    let account: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: account.isEmpty ? nil : "\(account)")
    }
}

struct CalendarQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CalendarEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [CalendarEntity] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return EKEventStore().calendars(for: .event)
            .map { CalendarEntity(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "") }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }
}
