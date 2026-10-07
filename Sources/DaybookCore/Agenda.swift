import Foundation

/// Groups events and tasks into days for the agenda views.
public enum Agenda {
    public struct Day: Identifiable, Sendable {
        public let date: Date // start of the day
        public let allDay: [AgendaItem]
        public let timed: [AgendaItem]
        public let tasks: [TaskItem]
        public var id: Date { date }
        public var isEmpty: Bool { allDay.isEmpty && timed.isEmpty && tasks.isEmpty }
    }

    /// `days` consecutive days starting at `start`'s day. An event shows on every
    /// day it touches (a three-day conference appears on all three).
    public static func days(from start: Date, count days: Int, events: [AgendaItem], tasks: [TaskItem],
                            calendar: Calendar = .current) -> [Day] {
        let first = calendar.startOfDay(for: start)
        return (0..<days).compactMap { offset -> Day? in
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: first),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            let touching = events.filter { $0.start < dayEnd && $0.end > dayStart }
            let dayTasks = tasks.filter { task in
                guard let due = task.due, !task.isCompleted else { return false }
                return calendar.isDate(due, inSameDayAs: dayStart)
            }
            return Day(date: dayStart,
                       allDay: touching.filter(\.isAllDay).sorted { $0.title < $1.title },
                       timed: touching.filter { !$0.isAllDay }.sorted { $0.start < $1.start },
                       tasks: dayTasks.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) })
        }
    }
}
