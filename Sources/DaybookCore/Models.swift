import Foundation

/// One calendar event, copied out of EventKit so the rest of the app (and the
/// tests) never touch EventKit types.
public struct AgendaItem: Hashable, Identifiable, Sendable, Codable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendar: String
    /// "#RRGGBB", the calendar's color.
    public let color: String
    public let location: String?
    public let url: URL?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool, calendar: String,
                color: String = "#888888", location: String? = nil, url: URL? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendar = calendar
        self.color = color
        self.location = location
        self.url = url
    }

    /// The location on one line. Addresses often come with a line per part
    /// ("Samford University\n800 Lakeshore Dr"), which breaks a one-line row.
    public var place: String? {
        let parts = (location ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// One task, backed by a reminder in Apple Reminders.
public struct TaskItem: Hashable, Identifiable, Sendable, Codable {
    public let id: String
    public let title: String
    public let due: Date?
    /// False when the due date is a day with no time ("friday", not "friday 3pm").
    public let dueHasTime: Bool
    public let list: String
    public let isCompleted: Bool
    public let priority: Priority
    public let repeats: Bool

    public init(id: String, title: String, due: Date?, dueHasTime: Bool = false, list: String = "Reminders",
                isCompleted: Bool = false, priority: Priority = .none, repeats: Bool = false) {
        self.id = id
        self.title = title
        self.due = due
        self.dueHasTime = dueHasTime
        self.list = list
        self.isCompleted = isCompleted
        self.priority = priority
        self.repeats = repeats
    }

    public func isOverdue(now: Date, calendar: Calendar) -> Bool {
        guard let due, !isCompleted else { return false }
        return dueHasTime ? due < now : calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }
}
