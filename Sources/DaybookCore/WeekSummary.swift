import Foundation

/// The file the Sunday evening preview reads: each of the next seven days (its
/// events, tasks due, hours booked and longest open stretch), deadlines in the
/// week after, and tasks that are overdue or have no date.
public struct WeekSummary: Sendable {
    public struct Day: Sendable {
        public let date: Date
        public let allDay: [AgendaItem]
        public let timed: [AgendaItem]
        public let tasks: [TaskItem]
        /// Time in timed events, counting overlaps once.
        public let booked: TimeInterval
        public let longestFree: DateInterval?
    }

    public let generatedAt: Date
    public let days: [Day]
    public let followingWeek: [AgendaItem] // all-day items (deadlines) in the 7 days after
    public let overdue: [TaskItem]
    public let undated: [TaskItem]

    /// The seven days starting tomorrow (Monday through Sunday, run on a Sunday).
    public init(now: Date, events: [AgendaItem], tasks: [TaskItem], calendar: Calendar = .current) {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let open = tasks.filter { !$0.isCompleted }
        generatedAt = now
        days = (0..<7).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: tomorrow)!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let onDay = events.filter { $0.start < next && $0.end > day }.sorted(by: DailySummary.order)
            let timed = onDay.filter { !$0.isAllDay }
            return Day(date: day, allDay: onDay.filter(\.isAllDay), timed: timed,
                       tasks: open.filter { $0.due.map { calendar.isDate($0, inSameDayAs: day) } ?? false },
                       booked: Self.booked(timed, from: day, to: next),
                       longestFree: FreeTime.blocks(on: day, events: timed, now: now, calendar: calendar).max { $0.duration < $1.duration })
        }
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: tomorrow)!
        let twoWeeks = calendar.date(byAdding: .day, value: 14, to: tomorrow)!
        followingWeek = events.filter { $0.isAllDay && $0.start >= weekEnd && $0.start < twoWeeks }.sorted(by: DailySummary.order)
        overdue = open.filter { $0.isOverdue(now: now, calendar: calendar) }
        undated = open.filter { $0.due == nil }
    }

    static func booked(_ events: [AgendaItem], from start: Date, to end: Date) -> TimeInterval {
        var total: TimeInterval = 0
        var cursor = start
        for event in events.sorted(by: { $0.start < $1.start }) {
            let from = max(event.start, cursor, start), to = min(event.end, end)
            if to > from { total += to.timeIntervalSince(from) }
            cursor = max(cursor, to)
        }
        return total
    }

    public func markdown(calendar: Calendar = .current, timeZone: TimeZone = .current) -> String {
        let day = Self.formatter("EEEE, MMMM d", timeZone)
        let time = Self.formatter("h:mm a", timeZone)
        let short = Self.formatter("EEE MMM d", timeZone)
        let busiest = days.max { $0.booked < $1.booked }
        var out = ["# Daybook: the week of \(day.string(from: days[0].date))", ""]
        for d in days {
            var heading = "## \(day.string(from: d.date))"
            heading += d.booked > 0 ? " (\(FreeTime.length(d.booked)) booked)" : " (nothing booked)"
            if let busiest, busiest.booked > 0, d.date == busiest.date { heading += ", the busiest day" }
            out.append(heading)
            out += d.allDay.map { "- All day: \($0.title) [\($0.calendar)]" }
            out += d.timed.map { "- \(time.string(from: $0.start))\u{2013}\(time.string(from: $0.end)): \($0.title) [\($0.calendar)]" }
            out += d.tasks.map { "- Task due: \($0.title) [\($0.list)]" }
            if d.allDay.isEmpty && d.timed.isEmpty && d.tasks.isEmpty { out.append("- Nothing scheduled") }
            if let free = d.longestFree {
                out.append("- Longest open stretch: \(time.string(from: free.start))\u{2013}\(time.string(from: free.end)) (\(FreeTime.length(free.duration)))")
            }
            out.append("")
        }
        if !followingWeek.isEmpty {
            out += ["## The week after (deadlines and all-day items)"] + followingWeek.map { "- \(short.string(from: $0.start)): \($0.title) [\($0.calendar)]" } + [""]
        }
        if !overdue.isEmpty { out += ["## Overdue tasks"] + overdue.map { "- \($0.title) [\($0.list)]" } + [""] }
        if !undated.isEmpty { out += ["## Tasks with no date"] + undated.map { "- \($0.title) [\($0.list)]" } + [""] }
        out.append("_Generated \(Self.formatter("MMM d, h:mm a", timeZone).string(from: generatedAt))_")
        return out.joined(separator: "\n") + "\n"
    }

    public func write(to folder: URL = DailySummary.folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(markdown().utf8).write(to: folder.appending(path: "week.md"), options: .atomic)
    }

    static func formatter(_ pattern: String, _ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = zone
        f.dateFormat = pattern
        return f
    }
}
