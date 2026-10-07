import Foundation

/// "Plan my day": puts open tasks into today's free stretches, most pressing
/// first. Only a proposal; nothing is saved until it's approved.
public enum DayPlanner {
    public struct Slot: Equatable, Sendable, Identifiable {
        public let task: TaskItem
        public var start: Date
        public var minutes: Int
        public var id: String { task.id }
        public var end: Date { start.addingTimeInterval(Double(minutes) * 60) }
    }

    /// Which tasks are worth planning today, in order: urgent, then high, then
    /// overdue, then due today (timed ones by time), then medium-or-higher with
    /// no date. Low and undated plain tasks wait.
    public static func candidates(_ tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> [TaskItem] {
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let soon = calendar.date(byAdding: .day, value: 3, to: endOfToday)!
        func rank(_ task: TaskItem) -> Int? {
            if task.priority == .urgent { return 0 }
            if task.priority == .high, (task.due ?? .distantPast) < soon { return 1 }
            if task.isOverdue(now: now, calendar: calendar) { return 2 }
            if let due = task.due, due < endOfToday { return 3 }
            if task.due == nil, task.priority >= .medium { return 4 }
            return nil
        }
        return tasks.filter { !$0.isCompleted }
            .compactMap { task in rank(task).map { (task, $0) } }
            .sorted { ($0.1, $0.0.due ?? .distantFuture) < ($1.1, $1.0.due ?? .distantFuture) }
            .map(\.0)
    }

    /// Fills the free stretches in order. Each task gets `minutes` (an hour for
    /// urgent and high), with a few minutes' breather between, and doesn't start
    /// in a stretch too short for it.
    public static func plan(_ tasks: [TaskItem], into blocks: [DateInterval], minutes: Int = 30, gap: Int = 5,
                            lengths: [String: Int] = [:]) -> [Slot] {
        var slots: [Slot] = []
        var remaining = blocks
        for task in tasks {
            let length = lengths[task.id] ?? (task.priority.isImportant ? max(minutes, 60) : minutes)
            guard let index = remaining.firstIndex(where: { $0.duration >= Double(length) * 60 }) else { continue }
            let block = remaining[index]
            let slot = Slot(task: task, start: block.start, minutes: length)
            slots.append(slot)
            let next = slot.end.addingTimeInterval(Double(gap) * 60)
            if next < block.end {
                remaining[index] = DateInterval(start: next, end: block.end)
            } else {
                remaining.remove(at: index)
            }
        }
        return slots
    }
}
