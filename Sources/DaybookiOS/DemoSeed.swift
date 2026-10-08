#if DEBUG && targetEnvironment(simulator)
import EventKit
import Foundation

/// `-seedDemo` (a debug launch argument, Simulator only): fills the Simulator's
/// empty calendar and reminders with a believable week, once, so every screen
/// can be checked with something on it. Never built into the app on a phone.
enum DemoSeed {
    static func runIfAsked() async {
        guard ProcessInfo.processInfo.arguments.contains("-seedDemo") else { return }
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true,
              (try? await store.requestFullAccessToReminders()) == true else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func at(_ day: Int, _ hour: Double) -> Date { calendar.date(byAdding: .day, value: day, to: today)!.addingTimeInterval(hour * 3600) }

        // Only once: a seeded week is marked by its first event.
        let existing = store.events(matching: store.predicateForEvents(withStart: at(-7, 0), end: at(30, 0), calendars: nil))
        guard !existing.contains(where: { $0.title == "COSC 490 Lecture" }) else { return }
        guard let events = store.defaultCalendarForNewEvents, let reminders = store.defaultCalendarForNewReminders() else { return }

        func event(_ title: String, _ day: Int, _ start: Double, _ end: Double, place: String? = nil, allDay: Bool = false, notes: String? = nil) {
            let item = EKEvent(eventStore: store)
            item.calendar = events
            item.title = title
            item.startDate = at(day, start)
            item.endDate = allDay ? at(day + 1, 0) : at(day, end)
            item.isAllDay = allDay
            item.location = place
            item.notes = notes
            try? store.save(item, span: .thisEvent, commit: false)
        }
        for day in -3...10 where calendar.component(.weekday, from: at(day, 0)) != 1 && calendar.component(.weekday, from: at(day, 0)) != 7 {
            event("COSC 490 Lecture", day, 9, 10.25, place: "Brooks Hall 214\n800 Lakeshore Drive\nBirmingham, AL 35229")
            event("Shift at the Library", day, 13, 16, place: "Davis Library")
        }
        event("Team standup with a fairly long title that should wrap or truncate", 0, 11, 11.5, notes: "Agenda:\n- demo\n- blockers")
        event("Dinner with Sam", 0, 18.5, 20, place: "Saw's Soul Kitchen\n1008 Oxmoor Rd\nHomewood, AL")
        event("Career Fair", 2, 0, 0, allDay: true)
        event("Midterm: Algorithms", 4, 10, 12, place: "Room 101")
        event("Project due", 6, 0, 0, allDay: true)
        try? store.commit()

        func task(_ title: String, _ day: Int?, _ hour: Double? = nil, priority: Int = 0, notes: String? = nil) {
            let item = EKReminder(eventStore: store)
            item.calendar = reminders
            item.title = title
            item.priority = priority
            item.notes = notes
            if let day {
                let date = hour.map { at(day, $0) } ?? at(day, 0)
                var parts = calendar.dateComponents([.year, .month, .day], from: date)
                if hour != nil { parts.hour = calendar.component(.hour, from: date); parts.minute = calendar.component(.minute, from: date) }
                item.dueDateComponents = parts
            }
            try? store.save(item, commit: false)
        }
        task("Submit lab report", 0, 17, priority: 1)
        task("Email advisor about spring schedule", -1)
        task("Read chapter 7", 1)
        task("Renew parking pass", 3, priority: 5)
        task("Buy groceries", nil)
        task("Call the bank about the weird charge from last week that never got sorted", 2, 10)
        try? store.commit()
    }
}
#endif
