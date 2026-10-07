import CoreGraphics
import DaybookCore
@preconcurrency import EventKit
import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
import WidgetKit
#endif

/// Everything Daybook knows, read from EventKit: every calendar the device syncs
/// (iCloud, Samford's Exchange, subscribed feeds like Gradtrack, Job Tracker and
/// Parliament) and the reminders that back the task list. Shared by the Mac and
/// iPhone apps; iCloud keeps the two in step.
@MainActor
@Observable
final class CalendarStore {
    struct CalendarInfo: Identifiable, Hashable {
        let id: String
        let title: String
        let color: String
        let account: String
    }

    enum Access { case unknown, granted, denied }

    /// The hidden Reminders list Daybook keeps its own things in, as completed
    /// reminders that iCloud syncs: done marks for calendar events (which have no
    /// "done" of their own, and school or subscribed calendars can't be written to)
    /// and the morning brief for the iPhone. See DaybookMarker.
    static let doneListName = "Daybook"

    private(set) var eventAccess = Access.unknown
    private(set) var reminderAccess = Access.unknown
    private(set) var calendars: [CalendarInfo] = []
    private(set) var events: [AgendaItem] = []
    private(set) var tasks: [TaskItem] = []
    /// Tasks completed today, so they can be seen (crossed out) and undone.
    private(set) var completedToday: [TaskItem] = []
    /// AgendaItem ids marked done.
    private(set) var doneEventIDs: Set<String> = []
    /// Priorities set on events in Daybook, by AgendaItem id.
    private(set) var eventPriorities: [String: Priority] = [:]
    /// Morning briefs posted by the scheduled task (the last two weeks), newest first.
    private(set) var briefs: [PostedBrief] = []
    var brief: PostedBrief? { briefs.first }

    struct PostedBrief: Identifiable, Hashable {
        let date: String // "2026-10-07"
        let markdown: String
        /// This posting's reminder. A rerun on the same day posts a new one, so
        /// "seen" is tracked by this, not the date.
        let version: String
        var id: String { date }
    }
    private(set) var lastError: String?

    var hiddenCalendars: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenCalendars), forKey: "hiddenCalendars"); Task { await reload() } }
    }

    /// A range the month view needs, on top of the usual next four weeks.
    var extraRange: (start: Date, end: Date)? {
        didSet { Task { await reload() } }
    }

    /// The last change that can be taken back, shown as a banner for a few seconds.
    struct UndoAction: Identifiable {
        let id = UUID()
        let message: String
        let undo: @MainActor () -> Void
    }

    private(set) var undoAction: UndoAction?

    func offerUndo(_ message: String, _ undo: @escaping @MainActor () -> Void) {
        let action = UndoAction(message: message, undo: undo)
        undoAction = action
        Task {
            try? await Task.sleep(for: .seconds(6))
            if undoAction?.id == action.id { undoAction = nil }
        }
    }

    func performUndo() {
        let action = undoAction
        undoAction = nil
        action?.undo()
    }

    func dismissUndo() { undoAction = nil }

    @ObservationIgnored let store = EKEventStore()
    /// The event a save just wrote, so a later undo can find it.
    @ObservationIgnored private(set) var lastSavedEventID: String?
    /// The EventKit events behind `events`, by AgendaItem id, for the details view.
    @ObservationIgnored private var ekEvents: [String: EKEvent] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        hiddenCalendars = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? [])
        // Another app (or iCloud) changed a calendar or reminder: refresh.
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.reload() } }
        }
    }

    // MARK: Access

    /// Picks up access granted on an earlier launch, without asking again.
    func checkAccess() async {
        func status(_ type: EKEntityType) -> Access {
            switch EKEventStore.authorizationStatus(for: type) {
            case .fullAccess: .granted
            case .notDetermined: .unknown
            default: .denied
            }
        }
        eventAccess = status(.event)
        reminderAccess = status(.reminder)
        await reload()
    }

    func requestAccess() async {
        do {
            eventAccess = try await store.requestFullAccessToEvents() ? .granted : .denied
            reminderAccess = try await store.requestFullAccessToReminders() ? .granted : .denied
        } catch {
            lastError = error.localizedDescription
        }
        await reload()
    }

    static func openPrivacySettings() {
        #if os(macOS)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars")!)
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }

    // MARK: Loading

    /// Events from yesterday through four weeks out (plus the month on screen),
    /// open reminders, today's completed ones, and the done marks.
    func reload() async {
        let calendar = Calendar.current
        var start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!
        // Two months ahead, for the deadline countdowns.
        var end = calendar.date(byAdding: .day, value: Countdown.horizonDays + 1, to: start)!
        if let extra = extraRange {
            start = min(start, extra.start)
            end = max(end, extra.end)
        }

        if eventAccess == .granted {
            let all = store.calendars(for: .event)
            calendars = all.map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: EKConvert.hex($0.cgColor), account: $0.source?.title ?? "") }
                .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
            let visible = all.filter { !hiddenCalendars.contains($0.calendarIdentifier) }
            if visible.isEmpty {
                events = []
            } else {
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: visible)
                let found = store.events(matching: predicate)
                events = found.map(EKConvert.item)
                ekEvents = Dictionary(zip(events.map(\.id), found), uniquingKeysWith: { first, _ in first })
            }
        }
        if reminderAccess == .granted {
            let daybookLists = doneLists()
            let hidden = Set(daybookLists.map(\.calendarIdentifier))
            let lists = store.calendars(for: .reminder).filter { !hidden.contains($0.calendarIdentifier) }
            tasks = await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists))
            completedToday = await fetch(store.predicateForCompletedReminders(
                withCompletionDateStarting: calendar.startOfDay(for: .now), ending: nil, calendars: lists))
            let entries = await fetchEntries(in: daybookLists)
            doneEventIDs = Set(entries.compactMap { if case .done(let id) = $0.marker { id } else { nil } })
            eventPriorities = Dictionary(entries.compactMap { entry -> (String, Priority)? in
                guard case .priority(let id, let level) = entry.marker, let priority = Priority(rawValue: level) else { return nil }
                return (id, priority)
            }, uniquingKeysWith: { a, _ in a })
            briefs = entries.compactMap { entry in
                if case .brief(let date) = entry.marker { PostedBrief(date: date, markdown: entry.body, version: entry.reminderID) } else { nil }
            }.sorted { $0.date > $1.date }
        }
        exportSummary()
        await AlertScheduler.reschedule(self)
        #if os(iOS)
        // Keep the home screen widget in step with what the app shows.
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private func fetch(_ predicate: NSPredicate) async -> [TaskItem] {
        await withCheckedContinuation { continuation in
            // EventKit calls back on its own queue; convert to plain values there.
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(EKConvert.task))
            }
        }
    }

    /// One reminder from a Daybook list, reduced to what it stands for.
    struct Entry: Sendable {
        let reminderID: String
        let marker: DaybookMarker
        let body: String
    }

    /// Everything in the given Daybook lists that Daybook recognizes.
    private func fetchEntries(in lists: [EKCalendar]) async -> [Entry] {
        // An empty list of calendars would mean "every list", so check first.
        guard !lists.isEmpty else { return [] }
        // Open ones too: the "brief is ready" reminder stays open so its alert fires.
        let predicate = store.predicateForReminders(in: lists)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap(Self.entry))
            }
        }
    }

    nonisolated static func entry(_ reminder: EKReminder) -> Entry? {
        guard let marker = DaybookMarker(url: reminder.url, notes: reminder.notes) else { return nil }
        return Entry(reminderID: reminder.calendarItemIdentifier, marker: marker, body: BriefNote.body(reminder.notes))
    }

    // MARK: Tasks

    /// Adds a task from typed text ("submit report friday 3pm") to the default Reminders list.
    /// A date picked in the app (`due`) wins over one typed in the text.
    func addTask(_ text: String, due picked: Date? = nil, hasTime pickedHasTime: Bool = false) {
        let parsed = QuickAdd.parse(text)
        guard !parsed.title.isEmpty, let list = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = parsed.title
        reminder.calendar = list
        reminder.priority = (parsed.priority ?? .none).reminderPriority
        if let picked {
            Self.setDue(picked, hasTime: pickedHasTime, on: reminder)
        } else if let due = parsed.due {
            Self.setDue(due, hasTime: parsed.hasTime, on: reminder)
        }
        save(reminder)
    }

    /// Gives a task a new date (or none). It shows on that day in the calendar views.
    func setDue(_ task: TaskItem, _ due: Date?, hasTime: Bool) {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return }
        Self.setDue(due, hasTime: hasTime, on: reminder)
        save(reminder)
    }

    private static func setDue(_ due: Date?, hasTime: Bool, on reminder: EKReminder) {
        // Drop the alert Daybook added for the old time; leave any others alone.
        let oldDue = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        for alarm in reminder.alarms ?? [] where oldDue != nil && alarm.absoluteDate == oldDue {
            reminder.removeAlarm(alarm)
        }
        guard let due else {
            reminder.dueDateComponents = nil
            return
        }
        let fields: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: due)
        // A timed task also gets an alert at that time, like Reminders would add.
        if hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
    }

    func setPriority(_ task: TaskItem, _ priority: Priority) {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return }
        reminder.priority = priority.reminderPriority
        save(reminder)
    }

    // MARK: Task details

    enum Repeat: String, CaseIterable, Identifiable {
        case never = "Never", daily = "Every day", weekdays = "Every weekday", weekly = "Every week",
             monthly = "Every month", yearly = "Every year"
        var id: String { rawValue }
    }

    /// One of a task's own Reminders alerts.
    enum TaskAlarm: Hashable {
        case before(minutes: Int)  // before the due time (0 is "at the due time")
        case at(Date)

        var label: String {
            switch self {
            case .before(let minutes): minutes == 0 ? "At the due time" : AlertSettings.describe(minutes)
            case .at(let date): date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
            }
        }
    }

    struct TaskDraft: Equatable {
        var title = ""
        var notes = ""
        var link = ""
        var listID = ""
        var due: Date?
        var hasTime = false
        var priority = Priority.none
        var repeats = Repeat.never
        var alarms: [TaskAlarm] = []
    }

    /// Reminders lists a task can be in (not Daybook's hidden one).
    var reminderLists: [CalendarInfo] {
        let hidden = Set(doneLists().map(\.calendarIdentifier))
        return store.calendars(for: .reminder)
            .filter { $0.allowsContentModifications && !hidden.contains($0.calendarIdentifier) }
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: EKConvert.hex($0.cgColor), account: $0.source?.title ?? "") }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    func draft(for task: TaskItem) -> TaskDraft? {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return nil }
        return TaskDraft(title: reminder.title ?? "", notes: reminder.notes ?? "", link: reminder.url?.absoluteString ?? "",
                         listID: reminder.calendar?.calendarIdentifier ?? "", due: task.due, hasTime: task.dueHasTime,
                         priority: task.priority, repeats: Self.repeatKind(reminder.recurrenceRules?.first),
                         alarms: (reminder.alarms ?? []).map { alarm in
                             alarm.absoluteDate.map(TaskAlarm.at) ?? .before(minutes: Int((-alarm.relativeOffset / 60).rounded()))
                         })
    }

    @discardableResult
    func save(_ draft: TaskDraft, for task: TaskItem) -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return false }
        reminder.title = draft.title.trimmingCharacters(in: .whitespaces)
        reminder.notes = draft.notes.isEmpty ? nil : draft.notes
        reminder.url = URL(string: draft.link.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 }
        if let list = store.calendar(withIdentifier: draft.listID) { reminder.calendar = list }
        reminder.priority = draft.priority.reminderPriority
        // A repeating task needs a date to repeat from: today, if it had none.
        var due = draft.due
        if draft.repeats != .never && due == nil { due = Calendar.current.startOfDay(for: .now) }
        Self.setDue(due, hasTime: draft.hasTime, on: reminder)
        for rule in reminder.recurrenceRules ?? [] { reminder.removeRecurrenceRule(rule) }
        if let rule = Self.rule(draft.repeats) { reminder.addRecurrenceRule(rule) }
        Self.setAlarms(draft.alarms, due: due, hasTime: draft.hasTime, on: reminder)
        do {
            try store.save(reminder, commit: true)
            lastError = nil
            Task { await reload() }
            return true
        } catch {
            lastError = "Couldn\u{2019}t save the task: \(error.localizedDescription)"
            return false
        }
    }

    func delete(_ task: TaskItem) {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return }
        let copy = draft(for: task)
        do {
            try store.remove(reminder, commit: true)
            if let copy {
                offerUndo("Deleted \u{201C}\(task.title)\u{201D}") { [weak self] in self?.restore(copy) }
            }
        } catch {
            lastError = "Couldn\u{2019}t delete the task: \(error.localizedDescription)"
        }
        Task { await reload() }
    }

    /// Replaces a task's own alerts. "Before" alerts follow the due time; on a task
    /// with a day but no time they count back from 9 AM that day (not midnight), so
    /// those are saved as exact times.
    private static func setAlarms(_ alarms: [TaskAlarm], due: Date?, hasTime: Bool, on reminder: EKReminder) {
        for alarm in reminder.alarms ?? [] { reminder.removeAlarm(alarm) }
        let hour = AlertSettings(enabled: true).allDayHour
        for alarm in Set(alarms) {
            switch alarm {
            case .at(let date):
                reminder.addAlarm(EKAlarm(absoluteDate: date))
            case .before(let minutes):
                guard let due else { continue } // nothing to count back from
                if hasTime {
                    // Relative to the due time, so it moves with the task if the date changes.
                    reminder.addAlarm(EKAlarm(relativeOffset: -Double(minutes) * 60))
                } else if let morning = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: due) {
                    reminder.addAlarm(EKAlarm(absoluteDate: morning.addingTimeInterval(-Double(minutes) * 60)))
                }
            }
        }
    }

    /// A deleted task, back as a new reminder with the same details.
    private func restore(_ draft: TaskDraft) {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = store.calendar(withIdentifier: draft.listID) ?? store.defaultCalendarForNewReminders()
        reminder.title = draft.title
        reminder.notes = draft.notes.isEmpty ? nil : draft.notes
        reminder.url = URL(string: draft.link)
        reminder.priority = draft.priority.reminderPriority
        Self.setDue(draft.due, hasTime: draft.hasTime, on: reminder)
        if let rule = Self.rule(draft.repeats) { reminder.addRecurrenceRule(rule) }
        Self.setAlarms(draft.alarms, due: draft.due, hasTime: draft.hasTime, on: reminder)
        save(reminder)
    }

    /// Removes events Daybook just made (an undo of blocking time or a day plan).
    func removeEvents(_ identifiers: [String]) {
        for id in identifiers {
            if let event = store.event(withIdentifier: id) { try? store.remove(event, span: .thisEvent, commit: true) }
        }
        Task { await reload() }
    }

    /// Puts an event back how it was before a change (an undo of a move).
    func restoreEvent(_ identifier: String, to draft: EventDraft) {
        guard let event = store.event(withIdentifier: identifier) else { return }
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.title = draft.title
        try? store.save(event, span: .thisEvent, commit: true)
        Task { await reload() }
    }

    private static func rule(_ kind: Repeat) -> EKRecurrenceRule? {
        switch kind {
        case .never: nil
        case .daily: EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekdays: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1,
                                         daysOfTheWeek: [.monday, .tuesday, .wednesday, .thursday, .friday].map { EKRecurrenceDayOfWeek($0) },
                                         daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        case .weekly: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case .monthly: EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly: EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        }
    }

    private static func repeatKind(_ rule: EKRecurrenceRule?) -> Repeat {
        guard let rule else { return .never }
        switch rule.frequency {
        case .daily: return .daily
        case .weekly: return (rule.daysOfTheWeek?.count ?? 0) == 5 ? .weekdays : .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        @unknown default: return .never
        }
    }

    /// Checks a task off, or (for one completed today) un-checks it.
    func setDone(_ task: TaskItem, _ done: Bool, undoable: Bool = true) {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return }
        reminder.isCompleted = done
        save(reminder)
        if undoable {
            offerUndo(done ? "Checked off \u{201C}\(task.title)\u{201D}" : "Unchecked \u{201C}\(task.title)\u{201D}") { [weak self] in
                self?.setDone(task, !done, undoable: false)
            }
        }
    }

    // MARK: Events

    func isDone(_ item: AgendaItem) -> Bool { doneEventIDs.contains(item.id) }

    func priority(of item: AgendaItem) -> Priority { eventPriorities[item.id] ?? .none }

    /// The next big dates, for the countdowns.
    var countdowns: [AgendaItem] {
        Countdown.upcoming(events.filter { !isDone($0) }, priorities: eventPriorities, now: .now)
    }

    /// An event's priority lives in the Daybook list, like done marks, since
    /// events have no priority of their own and many calendars are read-only.
    func setPriority(_ item: AgendaItem, _ priority: Priority) {
        eventPriorities[item.id] = priority == .none ? nil : priority // show it right away
        Task {
            await remove { if case .priority(let id, _) = $0 { id == item.id } else { false } }
            if priority != .none, let list = doneMarksList(create: true) {
                let marker = DaybookMarker.priority(eventID: item.id, level: priority.rawValue)
                let mark = EKReminder(eventStore: store)
                mark.calendar = list
                mark.title = "\(priority.name) priority: \(item.title)"
                mark.url = marker.url
                mark.notes = marker.url.absoluteString
                mark.isCompleted = true
                try? store.save(mark, commit: true)
            }
            await reload()
        }
    }

    /// Marks a calendar event done (or not) with a completed reminder in the
    /// Daybook list. The event itself is never changed.
    func setDone(_ item: AgendaItem, _ done: Bool, undoable: Bool = true) {
        if undoable {
            offerUndo(done ? "Marked \u{201C}\(item.title)\u{201D} done" : "Marked \u{201C}\(item.title)\u{201D} not done") { [weak self] in
                self?.setDone(item, !done, undoable: false)
            }
        }
        if done {
            guard !isDone(item), let list = doneMarksList(create: true) else { return }
            let marker = DaybookMarker.done(eventID: item.id)
            let mark = EKReminder(eventStore: store)
            mark.calendar = list
            mark.title = "\u{2713} " + item.title
            mark.url = marker.url
            mark.notes = marker.url.absoluteString // survives accounts that drop the URL
            mark.isCompleted = true
            doneEventIDs.insert(item.id) // show it right away; the reload confirms
            save(mark)
        } else {
            doneEventIDs.remove(item.id)
            Task {
                await remove { $0 == .done(eventID: item.id) }
                await reload()
            }
        }
    }

    /// Removes the Daybook reminders whose marker matches, from every Daybook list.
    private func remove(where matches: (DaybookMarker) -> Bool) async {
        for entry in await fetchEntries(in: doneLists()) where matches(entry.marker) {
            if let reminder = store.calendarItem(withIdentifier: entry.reminderID) as? EKReminder {
                try? store.remove(reminder, commit: true)
            }
        }
    }

    // MARK: Morning brief

    /// Puts the morning brief (Markdown) in the Daybook list, where the iPhone app
    /// finds it and pops it up. Replaces today's, and clears out ones over two weeks old.
    func postBrief(_ markdown: String, date: Date = .now) async -> Bool {
        guard reminderAccess == .granted, let list = doneMarksList(create: true) else { return false }
        let key = BriefNote.dayKey(date)
        let cutoff = BriefNote.dayKey(Calendar.current.date(byAdding: .day, value: -14, to: date)!)
        await remove { marker in
            switch marker {
            case .brief(let day): day == key || day < cutoff
            case .ready: true // from an older version, which alerted through Reminders
            case .done, .priority: false
            }
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = "Morning brief \u{00B7} " + date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        reminder.url = DaybookMarker.brief(date: key).url
        reminder.notes = BriefNote.compose(date: key, markdown: markdown)
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            lastError = "Couldn\u{2019}t save the brief to Reminders: \(error.localizedDescription)"
            return false
        }
    }

    /// The brief has been seen: clear any "brief is ready" reminder an older version left.
    func briefSeen() {
        Task { await remove { if case .ready = $0 { true } else { false } } }
    }

    /// Every list named Daybook. There can be more than one: an older version made
    /// it in the default account, which on the Mac was Samford's Exchange.
    private func doneLists() -> [EKCalendar] {
        store.calendars(for: .reminder).filter { $0.title == Self.doneListName }
    }

    /// The Daybook list new things go in: the one in iCloud, made on first use.
    /// iCloud keeps everything on a reminder; Exchange drops its URL.
    private func doneMarksList(create: Bool) -> EKCalendar? {
        let lists = doneLists()
        if let iCloud = lists.first(where: { Self.isICloud($0.source) }) { return iCloud }
        guard create else { return lists.first }
        let iCloud = store.sources.first { Self.isICloud($0) && !$0.calendars(for: .reminder).isEmpty }
        guard let source = iCloud ?? store.defaultCalendarForNewReminders()?.source else { return lists.first }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Self.doneListName
        list.source = source
        do {
            try store.saveCalendar(list, commit: true)
            return list
        } catch {
            lastError = "Couldn\u{2019}t create the Daybook list in Reminders: \(error.localizedDescription)"
            return lists.first
        }
    }

    nonisolated static func isICloud(_ source: EKSource?) -> Bool {
        source?.sourceType == .calDAV && source?.title == "iCloud"
    }

    private func save(_ reminder: EKReminder) {
        do {
            try store.save(reminder, commit: true)
            lastError = nil
        } catch {
            lastError = "Couldn\u{2019}t save to Reminders: \(error.localizedDescription)"
        }
        Task { await reload() }
    }

    // MARK: Creating and editing events

    /// The fields of an event, for the editor.
    struct EventDraft: Equatable {
        var title = ""
        var start = Date.now
        var end = Date.now.addingTimeInterval(3600)
        var isAllDay = false
        var calendarID = ""
        var location = ""
        var notes = ""
    }

    /// Calendars Daybook can write to (not subscribed feeds), for the editor's picker.
    var writableCalendars: [CalendarInfo] {
        let writable = Set(store.calendars(for: .event).filter(\.allowsContentModifications).map(\.calendarIdentifier))
        return calendars.filter { writable.contains($0.id) }
    }

    /// New events go in the calendar used last, else iCloud's default, so they
    /// sync to the iPhone and don't land in Samford's by accident.
    var defaultEventCalendarID: String? {
        let writable = writableCalendars
        if let last = UserDefaults.standard.string(forKey: "lastEventCalendar"), writable.contains(where: { $0.id == last }) { return last }
        if let fallback = store.defaultCalendarForNewEvents, Self.isICloud(fallback.source) { return fallback.calendarIdentifier }
        let iCloud = store.calendars(for: .event).first { $0.allowsContentModifications && Self.isICloud($0.source) }
        return iCloud?.calendarIdentifier ?? store.defaultCalendarForNewEvents?.calendarIdentifier
    }

    func canEdit(_ item: AgendaItem) -> Bool { ekEvents[item.id]?.calendar?.allowsContentModifications ?? false }
    func repeats(_ item: AgendaItem) -> Bool { ekEvents[item.id]?.hasRecurrenceRules ?? false }

    /// A new event starting at `start`, an hour long (or as long as `end` allows).
    func newDraft(at start: Date, until end: Date? = nil) -> EventDraft {
        EventDraft(start: start, end: min(end ?? .distantFuture, start.addingTimeInterval(3600)), calendarID: defaultEventCalendarID ?? "")
    }

    /// Blocks out time for a task: an event with its name at the start of `block`,
    /// an hour long or the whole block if that's shorter. The task itself stays open.
    func blockTime(for task: TaskItem, in block: DateInterval) {
        var draft = newDraft(at: block.start, until: block.end)
        draft.title = task.title
        draft.notes = "Time for a task in Daybook."
        if save(draft), let id = lastSavedEventID {
            offerUndo("Blocked time for \u{201C}\(task.title)\u{201D}") { [weak self] in self?.removeEvents([id]) }
        }
    }

    /// Today's free stretches from now on, for planning the day.
    var freeToday: [DateInterval] {
        let today = Calendar.current.startOfDay(for: .now)
        return FreeTime.blocks(on: today, events: events.filter { Calendar.current.isDateInToday($0.start) || ($0.start < today && $0.end > today) })
    }

    /// Puts a day plan on the calendar: one event per task, named after it.
    @discardableResult
    func schedule(_ slots: [DayPlanner.Slot]) -> Int {
        var saved: [String] = []
        for slot in slots {
            var draft = newDraft(at: slot.start)
            draft.title = slot.task.title
            draft.end = slot.end
            draft.notes = "Planned in Daybook."
            if save(draft), let id = lastSavedEventID { saved.append(id) }
        }
        if !saved.isEmpty {
            offerUndo("Planned \(saved.count) \(saved.count == 1 ? "task" : "tasks")") { [weak self] in self?.removeEvents(saved) }
        }
        return saved.count
    }

    /// A new event starting at the next whole hour (or on `day`, at that hour).
    func newDraft(on day: Date? = nil) -> EventDraft {
        let calendar = Calendar.current
        let nextHour = calendar.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
        var start = nextHour
        if let day, !calendar.isDateInToday(day) {
            start = calendar.date(bySettingHour: calendar.component(.hour, from: nextHour), minute: 0, second: 0, of: day) ?? day
        }
        return EventDraft(start: start, end: start.addingTimeInterval(3600), calendarID: defaultEventCalendarID ?? "")
    }

    func draft(for item: AgendaItem) -> EventDraft? {
        guard let event = ekEvents[item.id] else { return nil }
        return EventDraft(title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                          calendarID: event.calendar?.calendarIdentifier ?? "", location: event.location ?? "", notes: event.notes ?? "")
    }

    /// Saves a new event, or changes to `item`. For a repeating event, `futureToo`
    /// changes this and every later one; otherwise just this one.
    @discardableResult
    func save(_ draft: EventDraft, editing item: AgendaItem? = nil, futureToo: Bool = false) -> Bool {
        let event: EKEvent
        if let item {
            guard let existing = ekEvents[item.id] else { return false }
            event = existing
        } else {
            event = EKEvent(eventStore: store)
        }
        guard let calendar = store.calendar(withIdentifier: draft.calendarID) ?? store.defaultCalendarForNewEvents else { return false }
        event.calendar = calendar
        event.title = draft.title.trimmingCharacters(in: .whitespaces)
        event.isAllDay = draft.isAllDay
        event.startDate = draft.start
        event.endDate = max(draft.end, draft.start)
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        do {
            try store.save(event, span: futureToo ? .futureEvents : .thisEvent, commit: true)
            lastSavedEventID = event.eventIdentifier
            UserDefaults.standard.set(calendar.calendarIdentifier, forKey: "lastEventCalendar")
            lastError = nil
            Task { await reload() }
            return true
        } catch {
            lastError = "Couldn\u{2019}t save the event: \(error.localizedDescription)"
            return false
        }
    }

    func delete(_ item: AgendaItem, futureToo: Bool = false) {
        guard let event = ekEvents[item.id] else { return }
        // A single event can come back as a copy; a run of repeats can't.
        let copy = event.hasRecurrenceRules ? nil : draft(for: item)
        do {
            try store.remove(event, span: futureToo ? .futureEvents : .thisEvent, commit: true)
            lastError = nil
            if let copy {
                offerUndo("Deleted \u{201C}\(item.title)\u{201D}") { [weak self] in self?.save(copy) }
            }
        } catch {
            lastError = "Couldn\u{2019}t delete the event: \(error.localizedDescription)"
        }
        Task { await reload() }
    }

    /// An event from typed text ("Coffee with Sam thu 2pm"): an hour long at that
    /// time, all day on a bare date, or at the next hour with no date at all.
    /// A picked date wins over a typed one; `day` is used when there's neither.
    func addEvent(_ text: String, picked: (due: Date, hasTime: Bool)? = nil, day: Date? = nil) {
        let parsed = QuickAdd.parse(text)
        guard !parsed.title.isEmpty else { return }
        var draft = newDraft(on: day)
        draft.title = parsed.title
        let when = picked ?? parsed.due.map { ($0, parsed.hasTime) }
        if let (due, hasTime) = when {
            if hasTime {
                draft.start = due
                draft.end = due.addingTimeInterval(3600)
            } else {
                draft.isAllDay = true
                draft.start = Calendar.current.startOfDay(for: due)
                draft.end = draft.start
            }
        }
        if save(draft), let priority = parsed.priority, priority != .none {
            // The new event's id is known once it's saved and reloaded.
            Task {
                await reload()
                if let item = events.first(where: { $0.title == draft.title && $0.start == draft.start }) { setPriority(item, priority) }
            }
        }
    }

    // MARK: Search

    struct SearchResults {
        var upcoming: [AgendaItem] = []
        var past: [AgendaItem] = []   // most recent first
        var tasks: [TaskItem] = []    // open first
        var isEmpty: Bool { upcoming.isEmpty && past.isEmpty && tasks.isEmpty }
    }

    /// Events from six months back to a year ahead, and every task (done or not),
    /// whose title, location or notes contain the text.
    func search(_ text: String) async -> SearchResults {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return SearchResults() }
        func matches(_ value: String?) -> Bool {
            value?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        var results = SearchResults()
        let calendar = Calendar.current
        if eventAccess == .granted {
            let start = calendar.date(byAdding: .month, value: -6, to: .now)!
            let end = calendar.date(byAdding: .year, value: 1, to: .now)!
            let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .filter { matches($0.title) || matches($0.location) || matches($0.notes) }
                .prefix(300)
            for event in found {
                let item = EKConvert.item(event)
                ekEvents[item.id] = event // so tapping a result shows its details
                if item.end > .now { results.upcoming.append(item) } else { results.past.append(item) }
            }
            results.upcoming.sort { $0.start < $1.start }
            results.past.sort { $0.start > $1.start }
        }
        if reminderAccess == .granted {
            let hidden = Set(doneLists().map(\.calendarIdentifier))
            let lists = store.calendars(for: .reminder).filter { !hidden.contains($0.calendarIdentifier) }
            if !lists.isEmpty {
                let all = await withCheckedContinuation { continuation in
                    store.fetchReminders(matching: store.predicateForReminders(in: lists)) { reminders in
                        continuation.resume(returning: (reminders ?? []).map(EKConvert.task))
                    }
                }
                results.tasks = all.filter { matches($0.title) }
                    .sorted { ($0.isCompleted ? 1 : 0, $0.due ?? .distantFuture) < ($1.isCompleted ? 1 : 0, $1.due ?? .distantFuture) }
            }
        }
        return results
    }

    // MARK: Event details

    /// Everything about an event that the agenda rows leave out.
    struct EventDetails {
        struct Person: Hashable {
            enum Response { case accepted, declined, tentative, waiting }
            let name: String
            let response: Response
            let isOrganizer: Bool
            let isMe: Bool
        }

        let account: String
        let notes: String?
        let people: [Person]
        let repeats: String?
        let alerts: [String]
        let meeting: URL?
        let eventIdentifier: String?
    }

    func details(for item: AgendaItem) -> EventDetails? {
        guard let event = ekEvents[item.id] else { return nil }
        let organizerURL = event.organizer?.url
        var people = (event.attendees ?? []).map { person in
            EventDetails.Person(name: Self.name(of: person), response: Self.response(person.participantStatus),
                                isOrganizer: person.url == organizerURL, isMe: person.isCurrentUser)
        }
        // The organizer isn't always among the attendees.
        if let organizer = event.organizer, !people.contains(where: \.isOrganizer) {
            people.insert(EventDetails.Person(name: Self.name(of: organizer), response: .accepted, isOrganizer: true,
                                              isMe: organizer.isCurrentUser), at: 0)
        }
        people.sort { ($0.isOrganizer ? 0 : 1, $0.name) < ($1.isOrganizer ? 0 : 1, $1.name) }
        let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EventDetails(
            account: event.calendar?.source?.title ?? "",
            notes: notes?.isEmpty == false ? notes : nil,
            people: people,
            repeats: event.recurrenceRules?.first.map(Self.describe),
            alerts: (event.alarms ?? []).map(Self.describe),
            meeting: MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes]),
            eventIdentifier: event.eventIdentifier)
    }

    private static func name(of person: EKParticipant) -> String {
        if let name = person.name, !name.isEmpty { return name }
        // No name: the address from "mailto:someone@samford.edu".
        return person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
    }

    private static func response(_ status: EKParticipantStatus) -> EventDetails.Person.Response {
        switch status {
        case .accepted, .completed, .delegated: .accepted
        case .declined: .declined
        case .tentative: .tentative
        default: .waiting
        }
    }

    /// "Every week on Tue, Thu, until Dec 12, 2026"
    private static func describe(_ rule: EKRecurrenceRule) -> String {
        let unit = switch rule.frequency {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        @unknown default: "time"
        }
        var text = rule.interval == 1 ? "Every \(unit)" : "Every \(rule.interval) \(unit)s"
        if rule.frequency == .weekly, let days = rule.daysOfTheWeek, !days.isEmpty {
            let symbols = Calendar.current.shortWeekdaySymbols
            text += " on " + days.map { symbols[$0.dayOfTheWeek.rawValue - 1] }.joined(separator: ", ")
        }
        if let end = rule.recurrenceEnd?.endDate {
            text += ", until " + end.formatted(date: .abbreviated, time: .omitted)
        } else if let count = rule.recurrenceEnd?.occurrenceCount, count > 0 {
            text += ", \(count) times"
        }
        return text
    }

    /// "15 minutes before", "1 day before", "At time of event"
    private static func describe(_ alarm: EKAlarm) -> String {
        if let date = alarm.absoluteDate { return date.formatted(date: .abbreviated, time: .shortened) }
        let seconds = -alarm.relativeOffset
        if seconds == 0 { return "At time of event" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        let amount = formatter.string(from: abs(seconds)) ?? ""
        return seconds > 0 ? "\(amount) before" : "\(amount) after"
    }

    // MARK: Summary for the morning brief

    func exportSummary() {
        // Only the Mac runs the morning brief; the iPhone has nothing to write.
        #if os(macOS)
        do {
            let open = events.filter { !isDone($0) }
            try DailySummary(now: .now, events: open, tasks: tasks, eventPriorities: eventPriorities).write()
            try WeekSummary(now: .now, events: open, tasks: tasks).write()
        } catch {
            lastError = "Couldn\u{2019}t write the daily summary: \(error.localizedDescription)"
        }
        #endif
    }

}
