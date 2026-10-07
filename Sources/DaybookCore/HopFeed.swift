import Foundation

/// What hop (the keyboard launcher, github.com/MasonKimball05/hop) shows from
/// Daybook: the next event, the rest of today, tasks due, countdowns, and a
/// line on coding and email. Daybook writes it as hop.json on every refresh;
/// hop only reads it. Going the other way, hop sends daybook:// links (see
/// DaybookLink).
public struct HopFeed: Codable, Sendable, Equatable {
    public struct Event: Codable, Sendable, Equatable {
        public let title: String
        public let start: Date
        public let end: Date
        public let allDay: Bool
        public let calendar: String
        public let place: String?
    }

    public struct Task: Codable, Sendable, Equatable {
        public let id: String          // the reminder, for checking it off from hop
        public let title: String
        public let due: Date?
        public let hasTime: Bool
        public let overdue: Bool
        public let priority: String    // "none" ... "urgent"
    }

    public struct Countdown: Codable, Sendable, Equatable {
        public let title: String
        public let date: Date
        public let days: Int
    }

    public let updated: Date
    /// Events not over yet today, timed ones in order, all-day ones first.
    public let today: [Event]
    /// Open tasks overdue or due today, most pressing first.
    public let tasks: [Task]
    public let countdowns: [Countdown]
    public let waitingOnReplies: Int
    public let codingHoursToday: Double
    public let commitsToday: Int

    public static func build(now: Date, events: [AgendaItem], tasks: [TaskItem], countdowns: [AgendaItem],
                             waitingOnReplies: Int, sessions: [Work.Session], commitsToday: Int,
                             calendar: Calendar = .current) -> HopFeed {
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let today = events
            .filter { $0.start < endOfDay && $0.end > now }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
            .map { Event(title: $0.title, start: $0.start, end: $0.end, allDay: $0.isAllDay, calendar: $0.calendar, place: $0.place) }
        let due = tasks
            .filter { !$0.isCompleted && ($0.due.map { $0 < endOfDay } ?? false) }
            .sorted { (-$0.priority.rawValue, $0.due ?? .distantFuture) < (-$1.priority.rawValue, $1.due ?? .distantFuture) }
            .map { Task(id: $0.id, title: $0.title, due: $0.due, hasTime: $0.dueHasTime,
                        overdue: $0.isOverdue(now: now, calendar: calendar), priority: "\($0.priority)") }
        let counts = countdowns.map {
            Countdown(title: $0.title, date: $0.start, days: DaybookCore.Countdown.days(until: $0.start, now: now, calendar: calendar))
        }
        let coding = sessions
            .filter { calendar.isDate($0.start, inSameDayAs: now) || calendar.isDate($0.end, inSameDayAs: now) }
            .map(\.duration).reduce(0, +) / 3600
        return HopFeed(updated: now, today: today, tasks: due, countdowns: counts, waitingOnReplies: waitingOnReplies,
                       codingHoursToday: coding, commitsToday: commitsToday)
    }

    public func write(to folder: URL = DailySummary.folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: folder.appending(path: "hop.json"), options: .atomic)
    }
}

/// The daybook:// links Daybook on the Mac answers, for hop and anything else.
/// They only add things or check them off (and open Daybook to a view), never
/// read, change or delete, so a link from anywhere can't do harm.
public enum DaybookLink: Equatable, Sendable {
    case addTask(String)
    case addEvent(String)
    case log(title: String, start: Date, end: Date)
    case completeTask(id: String)
    case show(String)      // "today", "week", "month", "agenda", "tasks", "time"
    case brief

    public init?(_ url: URL) {
        guard url.scheme == "daybook", let host = url.host() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let iso = ISO8601DateFormatter()
        switch host {
        case "add-task": guard let text = value("text"), !text.isEmpty else { return nil }; self = .addTask(text)
        case "add-event": guard let text = value("text"), !text.isEmpty else { return nil }; self = .addEvent(text)
        case "log":
            guard let title = value("title"), !title.isEmpty, let start = value("start").flatMap(iso.date(from:)),
                  let end = value("end").flatMap(iso.date(from:)), end > start else { return nil }
            self = .log(title: title, start: start, end: end)
        case "complete-task": guard let id = value("id") else { return nil }; self = .completeTask(id: id)
        case "show": self = .show(value("view") ?? "today")
        case "brief": self = .brief
        default: return nil
        }
    }
}
