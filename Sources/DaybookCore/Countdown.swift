import Foundation

/// The big dates ahead, counted down in days: all-day items from deadline-type
/// calendars (Gradtrack's deadlines, Job Tracker's follow-ups), Canvas
/// assignments, and anything marked high or urgent, over the next 60 days.
public enum Countdown {
    public static let horizonDays = 60

    public static func isDeadlineCalendar(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["deadline", "due", "follow", "renew"].contains { lower.contains($0) }
    }

    public static func upcoming(_ events: [AgendaItem], priorities: [String: Priority] = [:], now: Date,
                                limit: Int = 5, calendar: Calendar = .current) -> [AgendaItem] {
        let today = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: horizonDays, to: today)!
        return events
            .filter { event in
                let important = (priorities[event.id] ?? .none).isImportant
                let deadline = event.isAllDay && (isDeadlineCalendar(event.calendar) || Canvas.assignmentID(event.id) != nil)
                return (important || deadline) && event.start >= today && event.start < horizon
                    && (event.isAllDay || event.start > now)
            }
            .sorted { $0.start < $1.start }
            .prefix(limit)
            .map { $0 }
    }

    /// Whole days from today to the event's day.
    public static func days(until date: Date, now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// "Today", "Tomorrow", "12 days"
    public static func label(until date: Date, now: Date, calendar: Calendar = .current) -> String {
        switch days(until: date, now: now, calendar: calendar) {
        case ...0: "Today"
        case 1: "Tomorrow"
        case let n: "\(n) days"
        }
    }
}
