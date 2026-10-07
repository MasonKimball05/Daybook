import Foundation

/// The file the morning-brief agent reads: today, tomorrow, overdue and undated
/// tasks, and the next two weeks of all-day items (deadlines, follow-ups).
/// Written as Markdown for reading and JSON for anything that wants structure.
public struct DailySummary: Codable, Sendable {
    public let generatedAt: Date
    public let today: [AgendaItem]
    public let tomorrow: [AgendaItem]
    public let tasksDueToday: [TaskItem]
    public let tasksOverdue: [TaskItem]
    public let tasksUndated: [TaskItem]
    public let upcoming: [AgendaItem]
    /// Open stretches left today (8 AM to 10 PM, half an hour or more).
    public let freeToday: [DateInterval]

    public init(now: Date, events: [AgendaItem], tasks: [TaskItem], calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: today)!
        let twoWeeks = calendar.date(byAdding: .day, value: 15, to: today)!
        let open = tasks.filter { !$0.isCompleted }

        generatedAt = now
        self.today = events.filter { $0.start < tomorrow && $0.end > today }.sorted(by: Self.order)
        self.tomorrow = events.filter { $0.start < dayAfter && $0.end > tomorrow }.sorted(by: Self.order)
        tasksDueToday = open.filter { task in (task.due.map { calendar.isDate($0, inSameDayAs: today) } ?? false) && !task.isOverdue(now: now, calendar: calendar) }
        tasksOverdue = open.filter { $0.isOverdue(now: now, calendar: calendar) }
        tasksUndated = open.filter { $0.due == nil }
        upcoming = events.filter { $0.isAllDay && $0.start >= dayAfter && $0.start < twoWeeks }.sorted(by: Self.order)
        freeToday = FreeTime.blocks(on: today, events: events, now: now, calendar: calendar)
    }

    static func order(_ a: AgendaItem, _ b: AgendaItem) -> Bool {
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        return a.start != b.start ? a.start < b.start : a.title < b.title
    }

    public func markdown(calendar: Calendar = .current, timeZone: TimeZone = .current) -> String {
        let day = formatter("EEEE, MMMM d", timeZone)
        let time = formatter("h:mm a", timeZone)
        let short = formatter("EEE MMM d", timeZone)
        func line(_ item: AgendaItem) -> String {
            let when = item.isAllDay ? "All day" : "\(time.string(from: item.start))\u{2013}\(time.string(from: item.end))"
            var text = "- \(when): \(item.title) [\(item.calendar)]"
            if let place = item.place { text += " @ \(place)" }
            return text
        }
        func taskLine(_ task: TaskItem) -> String {
            var text = "- \(task.title)"
            if let due = task.due { text += " (due \(task.dueHasTime ? short.string(from: due) + " " + time.string(from: due) : short.string(from: due)))" }
            return text + " [\(task.list)]"
        }
        var out = ["# Daybook: \(day.string(from: generatedAt))", ""]
        out += ["## Today"] + (today.isEmpty ? ["- Nothing on the calendar"] : today.map(line)) + [""]
        if !tasksOverdue.isEmpty { out += ["## Overdue tasks"] + tasksOverdue.map(taskLine) + [""] }
        if !freeToday.isEmpty {
            let longest = freeToday.max { $0.duration < $1.duration }!
            out += ["## Open time today"] + freeToday.map { block in
                var text = "- \(time.string(from: block.start))\u{2013}\(time.string(from: block.end)) (\(FreeTime.length(block.duration)))"
                if block == longest && freeToday.count > 1 { text += ", the longest" }
                return text
            } + [""]
        }
        out += ["## Tasks due today"] + (tasksDueToday.isEmpty ? ["- None"] : tasksDueToday.map(taskLine)) + [""]
        out += ["## Tomorrow"] + (tomorrow.isEmpty ? ["- Nothing on the calendar"] : tomorrow.map(line)) + [""]
        if !upcoming.isEmpty {
            out += ["## Coming up (next two weeks)"] + upcoming.map { "- \(short.string(from: $0.start)): \($0.title) [\($0.calendar)]" } + [""]
        }
        if !tasksUndated.isEmpty { out += ["## Tasks with no date"] + tasksUndated.map(taskLine) + [""] }
        out.append("_Generated \(formatter("MMM d, h:mm a", timeZone).string(from: generatedAt))_")
        return out.joined(separator: "\n") + "\n"
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Where the summary is written: ~/Library/Application Support/Daybook/today.md and today.json.
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Daybook")
    }

    public func write(to folder: URL = folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(markdown().utf8).write(to: folder.appending(path: "today.md"), options: .atomic)
        try json().write(to: folder.appending(path: "today.json"), options: .atomic)
    }

    private func formatter(_ pattern: String, _ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = zone
        f.dateFormat = pattern
        return f
    }
}
