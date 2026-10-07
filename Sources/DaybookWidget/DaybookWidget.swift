import AppIntents
import DaybookCore
@preconcurrency import EventKit
import SwiftUI
import WidgetKit

// Daybook's home screen and lock screen widget: the next event, with a countdown,
// and today's tasks, which can be checked off right from the widget. It reads
// EventKit itself, using the access the app was given.

@main
struct DaybookWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        DeadlinesWidget()
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DaybookToday", intent: TodayWidgetIntent.self, provider: Provider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Your next event and today\u{2019}s tasks.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

/// The next big dates, counted down: Gradtrack and Job Tracker deadlines, and
/// anything marked high or urgent.
struct DeadlinesWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DaybookDeadlines", intent: TodayWidgetIntent.self, provider: Provider()) { entry in
            DeadlinesWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Deadlines")
        .description("Days left until your next deadlines.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

/// No options (yet); AppIntentConfiguration just gives the widget an async timeline.
struct TodayWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Today"
}

// MARK: Data

struct DayEntry: TimelineEntry {
    let date: Date
    /// Today's events not over yet (and not marked done), all-day ones first.
    let events: [AgendaItem]
    /// Open tasks due today or earlier, soonest first.
    let tasks: [TaskItem]
    let hasAccess: Bool
    /// The next big dates (see Countdown).
    var countdowns: [AgendaItem] = []

    var timed: [AgendaItem] { events.filter { !$0.isAllDay && $0.end > date } }
    var allDay: [AgendaItem] { events.filter(\.isAllDay) }
    var next: AgendaItem? { timed.first }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DayEntry { .sample }

    func snapshot(for configuration: TodayWidgetIntent, in context: Context) async -> DayEntry {
        context.isPreview ? .sample : await Self.load(at: .now)
    }

    func timeline(for configuration: TodayWidgetIntent, in context: Context) async -> Timeline<DayEntry> {
        let now = Date.now
        let entry = await Self.load(at: now)
        // A new entry at each start and end today, so "next" moves along on its own.
        let changes = Set(entry.timed.flatMap { [$0.start, $0.end] }.filter { $0 > now }).sorted().prefix(20)
        let entries = [entry] + changes.map {
            DayEntry(date: $0, events: entry.events, tasks: entry.tasks, hasAccess: entry.hasAccess, countdowns: entry.countdowns)
        }
        // Look again in 15 minutes for anything added elsewhere, or at midnight at the latest.
        let refresh = min(now.addingTimeInterval(15 * 60), Calendar.current.startOfDay(for: now).addingTimeInterval(86_400))
        return Timeline(entries: entries, policy: .after(refresh))
    }

    static func load(at now: Date) async -> DayEntry {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return DayEntry(date: now, events: [], tasks: [], hasAccess: false)
        }
        let store = EKEventStore()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!

        let daybookLists = store.calendars(for: .reminder).filter { $0.title == "Daybook" }
        let (done, priorities) = await marks(store, daybookLists)
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .map(EKConvert.item)
            .filter { !done.contains($0.id) && $0.end > now }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }

        var tasks: [TaskItem] = []
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            let hidden = Set(daybookLists.map(\.calendarIdentifier))
            let lists = store.calendars(for: .reminder).filter { !hidden.contains($0.calendarIdentifier) }
            if !lists.isEmpty {
                let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: lists)
                tasks = await withCheckedContinuation { continuation in
                    store.fetchReminders(matching: predicate) { continuation.resume(returning: ($0 ?? []).map(EKConvert.task)) }
                }
                .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            }
        }
        let horizon = calendar.date(byAdding: .day, value: Countdown.horizonDays, to: start)!
        let finished = await finishedCanvas(store, daybookLists, since: calendar.date(byAdding: .day, value: -180, to: start)!)
        let ahead = store.events(matching: store.predicateForEvents(withStart: start, end: horizon, calendars: nil))
            .map(EKConvert.item)
            .filter { !done.contains($0.id) && Canvas.assignmentID($0.id).map(finished.contains) != true }
        let countdowns = Countdown.upcoming(ahead, priorities: priorities, now: now)
        return DayEntry(date: now, events: events, tasks: tasks, hasAccess: true, countdowns: countdowns)
    }

    /// Canvas assignments whose task has been checked off (by assignment number),
    /// so a finished assignment stops counting down.
    private static func finishedCanvas(_ store: EKEventStore, _ daybookLists: [EKCalendar], since: Date) async -> Set<String> {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        let hidden = Set(daybookLists.map(\.calendarIdentifier))
        let lists = store.calendars(for: .reminder).filter { !hidden.contains($0.calendarIdentifier) }
        guard !lists.isEmpty else { return [] }
        let predicate = store.predicateForCompletedReminders(withCompletionDateStarting: since, ending: nil, calendars: lists)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let ids = (reminders ?? []).compactMap { reminder -> String? in
                    if case .canvas(let id) = DaybookMarker(url: nil, notes: reminder.notes) { id } else { nil }
                }
                continuation.resume(returning: Set(ids))
            }
        }
    }

    /// Events marked done, and event priorities, from the Daybook list (see DaybookMarker).
    private static func marks(_ store: EKEventStore, _ lists: [EKCalendar]) async -> (Set<String>, [String: Priority]) {
        guard !lists.isEmpty else { return ([], [:]) }
        let predicate = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: lists)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                var done: Set<String> = []
                var priorities: [String: Priority] = [:]
                for reminder in reminders ?? [] {
                    switch DaybookMarker(url: reminder.url, notes: reminder.notes) {
                    case .done(let id): done.insert(id)
                    case .priority(let id, let level): priorities[id] = Priority(rawValue: level)
                    default: break
                    }
                }
                continuation.resume(returning: (done, priorities))
            }
        }
    }
}

extension DayEntry {
    static var sample: DayEntry {
        let now = Date.now
        return DayEntry(
            date: now,
            events: [
                AgendaItem(id: "1", title: "Algorithms", start: now.addingTimeInterval(25 * 60), end: now.addingTimeInterval(85 * 60),
                           isAllDay: false, calendar: "Samford", color: "#2A5BD7", location: "Brooks Hall 210"),
                AgendaItem(id: "2", title: "Coffee with Sam", start: now.addingTimeInterval(3 * 3600), end: now.addingTimeInterval(4 * 3600),
                           isAllDay: false, calendar: "Home", color: "#F2994A"),
            ],
            tasks: [
                TaskItem(id: "a", title: "Submit the report", due: now, dueHasTime: false, list: "Reminders", isCompleted: false),
                TaskItem(id: "b", title: "PQ LinkedIn post", due: now, dueHasTime: false, list: "Reminders", isCompleted: false),
            ],
            hasAccess: true,
            countdowns: [
                AgendaItem(id: "d", title: "Project deadline", start: Calendar.current.date(byAdding: .day, value: 12, to: now)!,
                           end: now, isAllDay: true, calendar: "Deadlines", color: "#D7263D"),
            ])
    }
}

// MARK: Checking a task off

struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Task"
    static let isDiscoverable = false

    @Parameter(title: "Task") var taskID: String

    init() {}
    init(taskID: String) { self.taskID = taskID }

    func perform() async throws -> some IntentResult {
        let store = EKEventStore()
        if let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder {
            reminder.isCompleted = true
            try store.save(reminder, commit: true)
        }
        return .result()
    }
}

// MARK: Views

struct TodayWidgetView: View {
    let entry: DayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if !entry.hasAccess {
            Text("Open Daybook to allow calendar access.").font(.caption).foregroundStyle(.secondary)
        } else {
            switch family {
            case .accessoryInline: inline
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
    }

    // Lock screen

    private var inline: some View {
        if let next = entry.next {
            Text("\(next.start, format: .dateTime.hour().minute()) \(next.title)")
        } else {
            Text(entry.tasks.isEmpty ? "Nothing left today" : "\(entry.tasks.count) tasks left today")
        }
    }

    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: "checklist")
            Text("\(entry.tasks.count)").font(.title3.weight(.semibold))
        }
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let next = entry.next {
                Text(next.title).font(.headline).lineLimit(1).widgetAccentable()
                Text(timeRange(next)).font(.caption)
                countdown(next).font(.caption)
            } else {
                Text("Nothing else today").font(.headline).widgetAccentable()
                Text(entry.tasks.isEmpty ? "No tasks due" : "\(entry.tasks.count) tasks due").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let next = entry.next {
                eventBlock(next, titleLines: 3)
            } else {
                Text("Nothing else today").font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 0)
            if !entry.tasks.isEmpty {
                Label("\(entry.tasks.count) \(entry.tasks.count == 1 ? "task" : "tasks")", systemImage: "checklist")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header
                if let next = entry.next {
                    eventBlock(next, titleLines: 2)
                    ForEach(entry.timed.dropFirst().prefix(1)) { compactEvent($0) }
                } else {
                    Text("Nothing else today").font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            taskList(limit: 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let next = entry.next {
                eventBlock(next, titleLines: 2)
            }
            ForEach(entry.allDay.prefix(2)) { compactEvent($0) }
            ForEach(entry.timed.dropFirst().prefix(4)) { compactEvent($0) }
            if entry.events.isEmpty {
                Text("Nothing else today").font(.subheadline.weight(.semibold))
            }
            Divider()
            taskList(limit: 5)
            Spacer(minLength: 0)
            if let next = entry.countdowns.first {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass").foregroundStyle(.secondary)
                    Text(next.title).lineLimit(1)
                    Spacer()
                    Text(Countdown.label(until: next.start, now: entry.date)).fontWeight(.semibold)
                }
                .font(.caption)
            }
        }
    }

    // Pieces

    private var header: some View {
        Text(entry.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .textCase(.uppercase)
    }

    private func eventBlock(_ item: AgendaItem, titleLines: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: item.color)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(titleLines)
                Text(timeRange(item)).font(.caption).foregroundStyle(.secondary)
                countdown(item).font(.caption.weight(.medium)).foregroundStyle(.tint)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func compactEvent(_ item: AgendaItem) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: item.color)).frame(width: 6, height: 6)
            Text(item.isAllDay ? "All day" : item.start.formatted(date: .omitted, time: .shortened))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(item.title).font(.caption).lineLimit(1)
        }
    }

    private func taskList(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tasks").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            if entry.tasks.isEmpty {
                Text("All clear").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entry.tasks.prefix(limit)) { task in
                HStack(spacing: 6) {
                    Button(intent: CompleteTaskIntent(taskID: task.id)) {
                        Image(systemName: "circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Text(task.title).font(.caption).lineLimit(1)
                        .foregroundStyle(task.isOverdue(now: entry.date, calendar: .current) ? Color.red : Color.primary)
                }
            }
            if entry.tasks.count > limit {
                Text("+\(entry.tasks.count - limit) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func timeRange(_ item: AgendaItem) -> String {
        item.isAllDay ? "All day"
            : item.start.formatted(date: .omitted, time: .shortened) + " \u{2013} " + item.end.formatted(date: .omitted, time: .shortened)
    }

    /// "in 25 min", or "now" while it's on.
    @ViewBuilder private func countdown(_ item: AgendaItem) -> some View {
        if item.start <= entry.date {
            Text("Now")
        } else {
            Text("in \(Text(item.start, style: .relative))")
        }
    }
}

struct DeadlinesWidgetView: View {
    let entry: DayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if !entry.hasAccess {
            Text("Open Daybook to allow calendar access.").font(.caption).foregroundStyle(.secondary)
        } else if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 1) {
                if let next = entry.countdowns.first {
                    Text(Countdown.label(until: next.start, now: entry.date)).font(.headline).widgetAccentable()
                    Text(next.title).font(.caption).lineLimit(2)
                } else {
                    Text("No deadlines").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if family == .systemSmall, let next = entry.countdowns.first {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXT DEADLINE").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                Spacer(minLength: 0)
                Text("\(max(Countdown.days(until: next.start, now: entry.date), 0))")
                    .font(.system(size: 44, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                Text(Countdown.days(until: next.start, now: entry.date) == 1 ? "day left" : "days left")
                    .font(.caption).foregroundStyle(.secondary)
                Text(next.title).font(.caption.weight(.semibold)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("DEADLINES").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                if entry.countdowns.isEmpty {
                    Text("Nothing in the next two months.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(entry.countdowns.prefix(3)) { item in
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: item.color)).frame(width: 6, height: 6)
                        Text(item.title).font(.caption).lineLimit(1)
                        Spacer()
                        Text(Countdown.label(until: item.start, now: entry.date))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Countdown.days(until: item.start, now: entry.date) <= 3 ? Color.red : Color.primary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
