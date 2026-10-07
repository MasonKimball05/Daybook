import AppIntents
import DaybookCore
import Foundation

// Siri, Shortcuts and the Action button: add a task or event by voice, and ask
// what's next or what's on today. Each runs Daybook's own store in the background.

struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription("Adds a task. Include a day, a time or a priority, like \u{201C}call the bank friday 3pm !high\u{201D}.")

    @Parameter(title: "Task", requestValueDialog: "What\u{2019}s the task?")
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) to Daybook") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = CalendarStore()
        await store.checkAccess()
        guard store.reminderAccess == .granted else {
            return .result(dialog: "Open Daybook first and allow access to Reminders.")
        }
        store.addTask(text)
        let parsed = QuickAdd.parse(text)
        var reply = "Added \u{201C}\(parsed.title)\u{201D}"
        if let due = parsed.due { reply += ", due " + QuickAddField.label(due, hasTime: parsed.hasTime) }
        return .result(dialog: "\(reply).")
    }
}

struct AddEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Event"
    static let description = IntentDescription("Adds a calendar event, like \u{201C}coffee with Sam thursday 2pm\u{201D}. An hour long unless you change it in Daybook.")

    @Parameter(title: "Event", requestValueDialog: "What\u{2019}s the event, and when?")
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) to my calendar") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = CalendarStore()
        await store.checkAccess()
        guard store.eventAccess == .granted else {
            return .result(dialog: "Open Daybook first and allow access to Calendars.")
        }
        let parsed = QuickAdd.parse(text)
        store.addEvent(text)
        let when = parsed.due.map { " on " + QuickAddField.label($0, hasTime: parsed.hasTime) } ?? " at the next hour"
        return .result(dialog: "Added \u{201C}\(parsed.title)\u{201D}\(when).")
    }
}

struct NextEventIntent: AppIntent {
    static let title: LocalizedStringResource = "What\u{2019}s Next"
    static let description = IntentDescription("Tells you your next event today and how long until it.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = CalendarStore()
        await store.checkAccess()
        let now = Date.now
        let next = store.events
            .filter { !$0.isAllDay && $0.end > now && Calendar.current.isDateInToday($0.start) && !store.isDone($0) }
            .min { $0.start < $1.start }
        guard let next else { return .result(dialog: "Nothing else on your calendar today.") }
        let time = next.start.formatted(date: .omitted, time: .shortened)
        if next.start <= now {
            return .result(dialog: "\(next.title) is on now, until \(next.end.formatted(date: .omitted, time: .shortened)).")
        }
        let minutes = Int(next.start.timeIntervalSince(now) / 60) + 1
        var reply = "\(next.title) at \(time), in \(Self.spoken(minutes))"
        if let place = next.place { reply += ", at \(place)" }
        return .result(dialog: "\(reply).")
    }
}

extension NextEventIntent {
    /// "25 minutes", "1 hour", "2 hours and 5 minutes"
    static func spoken(_ minutes: Int) -> String {
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return unit(rest, "minute") }
        return rest == 0 ? unit(hours, "hour") : unit(hours, "hour") + " and " + unit(rest, "minute")
    }
}

struct TodayIntent: AppIntent {
    static let title: LocalizedStringResource = "What\u{2019}s on Today"
    static let description = IntentDescription("Reads out what\u{2019}s left on your calendar today and the tasks due.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = CalendarStore()
        await store.checkAccess()
        let now = Date.now
        let calendar = Calendar.current
        let events = store.events
            .filter { !$0.isAllDay && $0.end > now && calendar.isDateInToday($0.start) && !store.isDone($0) }
            .sorted { $0.start < $1.start }
        let tasks = store.tasks.filter { task in task.due.map { calendar.isDateInToday($0) || $0 < now } ?? false }
        var parts: [String] = []
        if events.isEmpty {
            parts.append("Nothing else on your calendar today")
        } else {
            let list = events.prefix(4).map { "\($0.title) at \($0.start.formatted(date: .omitted, time: .shortened))" }
            parts.append("\(events.count) more \(events.count == 1 ? "event" : "events"): " + list.joined(separator: ", "))
        }
        if tasks.isEmpty {
            parts.append("no tasks due")
        } else {
            parts.append("\(tasks.count) \(tasks.count == 1 ? "task" : "tasks") due: " + tasks.prefix(4).map(\.title).joined(separator: ", "))
        }
        return .result(dialog: "\(parts.joined(separator: ". And ")).")
    }
}

struct DaybookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTaskIntent(), phrases: [
            "Add a task in \(.applicationName)",
            "Add a task to \(.applicationName)",
            "New \(.applicationName) task",
        ], shortTitle: "Add Task", systemImageName: "checklist")
        AppShortcut(intent: AddEventIntent(), phrases: [
            "Add an event in \(.applicationName)",
            "New \(.applicationName) event",
        ], shortTitle: "Add Event", systemImageName: "calendar.badge.plus")
        AppShortcut(intent: NextEventIntent(), phrases: [
            "What\u{2019}s next in \(.applicationName)",
            "What\u{2019}s my next event in \(.applicationName)",
        ], shortTitle: "What\u{2019}s Next", systemImageName: "clock")
        AppShortcut(intent: TodayIntent(), phrases: [
            "What\u{2019}s on today in \(.applicationName)",
            "What do I have today in \(.applicationName)",
        ], shortTitle: "Today", systemImageName: "sun.max")
    }
}
