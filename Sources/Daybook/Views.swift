import DaybookCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: CalendarStore
    @State private var tab = Tab.today
    @State private var query = ""
    #if os(macOS)
    @State private var showingBrief = false
    @State private var addingEvent = false
    @State private var planning = false
    #endif

    enum Tab: String, CaseIterable, Identifiable {
        case today = "Today", week = "Week", month = "Month", agenda = "Agenda", tasks = "Tasks"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if (store.eventAccess == .granted || store.reminderAccess == .granted) && !query.isEmpty {
                SearchResultsView(store: store, query: query)
            } else if store.eventAccess == .granted || store.reminderAccess == .granted {
                switch tab {
                case .today: DayListView(store: store, start: .now, days: 1)
                #if os(macOS)
                case .week: WeekGridView(store: store)
                #else
                case .week: DayListView(store: store, start: .now, days: 7)
                #endif
                case .agenda: DayListView(store: store, start: .now, days: 7)
                case .month: MonthView(store: store)
                case .tasks: TasksView(store: store)
                }
            } else {
                PermissionView(store: store)
            }
        }
        .frame(minWidth: 560, minHeight: 600)
        #if os(macOS)
        .searchable(text: $query, placement: .toolbar, prompt: "Search events and tasks")
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 380)
            }
            #if os(macOS)
            ToolbarItem {
                Button { planning = true } label: { Label("Plan My Day", systemImage: "wand.and.stars") }
                    .help("Fit today\u{2019}s tasks into your free time")
            }
            ToolbarItem {
                Button { addingEvent = true } label: { Label("New Event", systemImage: "calendar.badge.plus") }
                    .keyboardShortcut("n")
                    .help("New event (\u{2318}N)")
            }
            ToolbarItem {
                Button { showingBrief = true } label: { Label("Morning Brief", systemImage: "sun.horizon") }
                    .help("Today\u{2019}s morning brief")
                    .disabled(!Brief.exists)
            }
            #endif
            ToolbarItem {
                CalendarFilter(store: store)
            }
            ToolbarItem {
                Button { Task { await store.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
            }
        }
        #if os(macOS)
        .sheet(isPresented: $showingBrief) { BriefSheet().onAppear { store.briefSeen() } }
        .sheet(isPresented: $addingEvent) { EventEditor(store: store) }
        .sheet(isPresented: $planning) { PlanDayView(store: store) }
        // A new brief pops up once: on launch, or the next time Daybook comes to the front.
        .onAppear(perform: showNewBrief)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in showNewBrief() }
        #endif
        .overlay(alignment: .bottom) { UndoBanner(store: store).animation(.snappy, value: store.undoAction?.id) }
        .overlay(alignment: .bottom) {
            if let error = store.lastError {
                Text(error)
                    .font(.callout)
                    .padding(8)
                    .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
    }

    #if os(macOS)
    private func showNewBrief() {
        if Brief.isUnseen && !showingBrief { showingBrief = true }
    }
    #endif
}

// MARK: Today and Week

struct DayListView: View {
    let store: CalendarStore
    let start: Date
    let days: Int
    var showsQuickAdd = true
    /// New tasks typed here land on this day unless they say otherwise (the month view's selected day).
    var quickAddDate: Date? = nil

    var body: some View {
        let agenda = Agenda.days(from: start, count: days, events: store.events, tasks: store.tasks)
        let isToday = days == 1 && Calendar.current.isDateInToday(start)
        let overdue = isToday || days > 1 ? store.tasks.filter { $0.isOverdue(now: .now, calendar: .current) } : []
        List {
            if days == 1 && showsQuickAdd {
                QuickAddField(store: store, defaultDate: quickAddDate)
            }
            if isToday && !store.countdowns.isEmpty {
                Section("Counting down") {
                    ForEach(store.countdowns.prefix(3)) { CountdownRow(item: $0) }
                }
            }
            if !overdue.isEmpty {
                Section("Overdue") {
                    ForEach(overdue) { TaskRow(store: store, task: $0, showDate: true) }
                }
            }
            ForEach(agenda) { day in
                Section {
                    if day.isEmpty {
                        Text("Nothing scheduled").foregroundStyle(.secondary)
                    }
                    ForEach(day.allDay) { EventRow(store: store, item: $0) }
                    ForEach(Self.slots(day)) { slot in
                        switch slot {
                        case .event(let item): EventRow(store: store, item: item)
                        case .free(let block): FreeRow(store: store, block: block)
                        }
                    }
                    ForEach(day.tasks) { TaskRow(store: store, task: $0, showDate: false) }
                } header: {
                    Text(Self.heading(day.date)).font(.headline)
                }
            }
            if isToday && !store.completedToday.isEmpty {
                Section("Done today") {
                    ForEach(store.completedToday) { TaskRow(store: store, task: $0, showDate: false) }
                }
            }
        }
        .listStyle(.inset)
        .scrollDismissesKeyboard(.immediately)
    }

    /// Timed events with the free stretches between them, in order. Past days get no free rows.
    enum Slot: Identifiable {
        case event(AgendaItem)
        case free(DateInterval)
        var id: String {
            switch self {
            case .event(let item): item.id
            case .free(let block): "free-\(block.start.timeIntervalSince1970)"
            }
        }
        var start: Date {
            switch self {
            case .event(let item): item.start
            case .free(let block): block.start
            }
        }
    }

    static func slots(_ day: Agenda.Day) -> [Slot] {
        let isPast = Calendar.current.startOfDay(for: day.date) < Calendar.current.startOfDay(for: .now)
        let free = isPast ? [] : FreeTime.blocks(on: day.date, events: day.timed)
        return (day.timed.map(Slot.event) + free.map(Slot.free)).sorted { $0.start < $1.start }
    }

    static func heading(_ date: Date) -> String {
        let text = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        if Calendar.current.isDateInToday(date) { return "Today \u{00B7} " + text }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow \u{00B7} " + text }
        return text
    }
}

/// The check button shared by events and tasks.
struct DoneButton: View {
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(done ? "Mark not done" : "Mark done")
    }
}

struct EventRow: View {
    let store: CalendarStore
    let item: AgendaItem
    @State private var showingDetails = false

    var body: some View {
        let done = store.isDone(item)
        HStack(alignment: .center, spacing: 10) {
            DoneButton(done: done) { store.setDone(item, !done) }
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: item.color))
                .frame(width: 4)
                .frame(minHeight: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    PriorityBadge(priority: store.priority(of: item))
                    Text(item.title).font(.body.weight(.medium)).strikethrough(done)
                }
                HStack(spacing: 6) {
                    Text(item.isAllDay ? "All day" : "\(item.start.formatted(date: .omitted, time: .shortened)) \u{2013} \(item.end.formatted(date: .omitted, time: .shortened))")
                    Text("\u{00B7} \(item.calendar)").lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // On its own line, so a long address can't push the time and calendar around.
                if let place = item.place {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            if let url = item.url {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    .help(url.absoluteString)
            }
        }
        .opacity(done || isPast ? 0.5 : 1)
        .padding(.vertical, 2)
        // Tapping anywhere but the check opens the details.
        .contentShape(Rectangle())
        .onTapGesture { showingDetails = true }
        #if os(macOS)
        .popover(isPresented: $showingDetails, arrowEdge: .trailing) {
            EventDetailView(store: store, item: item).frame(width: 380).frame(maxHeight: 620)
        }
        #else
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                EventDetailView(store: store, item: item)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDetails = false } }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        #endif
        .contextMenu {
            Button("Show Details") { showingDetails = true }
            Button(done ? "Mark Not Done" : "Mark Done") { store.setDone(item, !done) }
            PriorityMenu(current: store.priority(of: item)) { store.setPriority(item, $0) }
        }
    }

    private var isPast: Bool { !item.isAllDay && item.end < .now }
}

/// Everything about one event, from tapping it in a list.
struct EventDetailView: View {
    let store: CalendarStore
    let item: AgendaItem
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var changed = false
    @State private var travel: Int?

    var body: some View {
        let details = store.details(for: item)
        let done = store.isDone(item)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Title, calendar, and when.
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: item.color)).frame(width: 5)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.title2.weight(.semibold)).strikethrough(done)
                            .textSelection(.enabled)
                        Text([item.calendar, details?.account].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(when).font(.subheadline)
                        if let repeats = details?.repeats {
                            Label(repeats, systemImage: "repeat").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                // What can be done with it.
                HStack(spacing: 8) {
                    if let meeting = details?.meeting {
                        Button { openURL(meeting) } label: { Label("Join", systemImage: "video.fill") }
                            .buttonStyle(.borderedProminent)
                    }
                    Button { store.setDone(item, !done) } label: {
                        Label(done ? "Not Done" : "Mark Done", systemImage: done ? "arrow.uturn.backward" : "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    PriorityMenu(current: store.priority(of: item), compact: true) { store.setPriority(item, $0) }
                        .buttonStyle(.bordered)
                    if store.canEdit(item) {
                        Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                            .buttonStyle(.bordered)
                    } else if let url = calendarURL(details) {
                        Button { openURL(url) } label: { Label("Calendar", systemImage: "calendar") }
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.regular)

                if let location = item.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                    section("Location", systemImage: "mappin.and.ellipse") {
                        Text(location).textSelection(.enabled)
                        #if os(iOS)
                        if let travel, !item.isAllDay {
                            let walking = AlertScheduler.settings.walking
                            let leave = item.start.addingTimeInterval(-Double(travel) * 60)
                            Label("\(travel) min \(walking ? "walk" : "drive") \u{00B7} leave by \(leave.formatted(date: .omitted, time: .shortened))",
                                  systemImage: walking ? "figure.walk" : "car.fill")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        #endif
                        if let maps = mapsURL(location) {
                            Link("Open in Maps", destination: maps).font(.callout)
                        }
                    }
                }

                if let url = item.url {
                    section("Link", systemImage: "link") {
                        Link(url.absoluteString, destination: url).lineLimit(2).font(.callout)
                    }
                }

                if let people = details?.people, !people.isEmpty {
                    section("\(people.count) \(people.count == 1 ? "Person" : "People")", systemImage: "person.2") {
                        ForEach(people, id: \.self) { person in
                            HStack(spacing: 8) {
                                Image(systemName: icon(person.response)).foregroundStyle(color(person.response))
                                Text(person.name + (person.isMe ? " (you)" : "")).lineLimit(1)
                                if person.isOrganizer {
                                    Text("Organizer").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let alerts = details?.alerts, !alerts.isEmpty {
                    section("Alerts", systemImage: "bell") {
                        ForEach(alerts, id: \.self) { Text($0) }
                    }
                }

                if let notes = details?.notes {
                    section("Notes", systemImage: "note.text") {
                        Text(Self.linked(notes)).textSelection(.enabled)
                    }
                }

                if details == nil {
                    Text("The full details aren\u{2019}t loaded. Pull to refresh and try again.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        .task { if item.end > .now { travel = await LeaveBy.travelMinutes(to: item, walking: AlertScheduler.settings.walking) } }
        #endif
        // After an edit or delete these details are out of date, so close them too.
        .sheet(isPresented: $editing, onDismiss: { if changed { dismiss() } }) {
            EventEditor(store: store, editing: item) { changed = true }
        }
    }

    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Wednesday, October 7 · 2:00 – 3:00 PM", or the span for all-day and multi-day events.
    private var when: String {
        let calendar = Calendar.current
        let day = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        if item.isAllDay {
            let last = calendar.date(byAdding: .day, value: -1, to: item.end) ?? item.start
            if calendar.isDate(item.start, inSameDayAs: last) { return item.start.formatted(day) + " \u{00B7} All day" }
            return item.start.formatted(day) + " \u{2013} " + last.formatted(day)
        }
        if calendar.isDate(item.start, inSameDayAs: item.end) {
            return item.start.formatted(day) + " \u{00B7} " + item.start.formatted(date: .omitted, time: .shortened)
                + " \u{2013} " + item.end.formatted(date: .omitted, time: .shortened)
        }
        return item.start.formatted(day.hour().minute()) + " \u{2013} " + item.end.formatted(day.hour().minute())
    }

    private func mapsURL(_ location: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: location.replacingOccurrences(of: "\n", with: ", "))]
        return components?.url
    }

    /// Opens the event in Apple's Calendar app.
    private func calendarURL(_ details: CalendarStore.EventDetails?) -> URL? {
        #if os(macOS)
        guard let id = details?.eventIdentifier?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "ical://ekevent/\(id)?method=show&options=more")
        #else
        // iOS can only open Calendar to a moment, so open it to the event's start.
        return URL(string: "calshow:\(item.start.timeIntervalSinceReferenceDate)")
        #endif
    }

    private func icon(_ response: CalendarStore.EventDetails.Person.Response) -> String {
        switch response {
        case .accepted: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .waiting: "circle.dotted"
        }
    }

    private func color(_ response: CalendarStore.EventDetails.Person.Response) -> Color {
        switch response {
        case .accepted: .green
        case .declined: .red
        case .tentative: .orange
        case .waiting: .secondary
        }
    }

    /// Notes with their web addresses made tappable.
    static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}

/// Makes a new event, or changes or deletes one. Subscribed calendars (Gradtrack,
/// Job Tracker, Parliament) are read-only, so they never show up here.
struct EventEditor: View {
    let store: CalendarStore
    let item: AgendaItem?
    /// Called after a save or delete.
    var onFinish: () -> Void = {}
    @State private var draft: CalendarStore.EventDraft
    @State private var askingSpan = false
    @State private var askingDelete = false
    @Environment(\.dismiss) private var dismiss

    init(store: CalendarStore, editing item: AgendaItem? = nil, on day: Date? = nil, onFinish: @escaping () -> Void = {}) {
        self.store = store
        self.item = item
        self.onFinish = onFinish
        _draft = State(initialValue: item.flatMap(store.draft(for:)) ?? store.newDraft(on: day))
    }

    /// A new event in a free stretch.
    init(store: CalendarStore, at block: DateInterval) {
        self.store = store
        self.item = nil
        _draft = State(initialValue: store.newDraft(at: block.start, until: block.end))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    TextField("Location", text: $draft.location)
                }
                Section {
                    Toggle("All day", isOn: $draft.isAllDay)
                    DatePicker("Starts", selection: $draft.start, displayedComponents: draft.isAllDay ? .date : [.date, .hourAndMinute])
                    DatePicker("Ends", selection: $draft.end, in: draft.start..., displayedComponents: draft.isAllDay ? .date : [.date, .hourAndMinute])
                }
                Section {
                    Picker("Calendar", selection: $draft.calendarID) {
                        ForEach(store.writableCalendars) { info in
                            Label {
                                Text(info.account.isEmpty ? info.title : "\(info.title) (\(info.account))")
                            } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(Color(hex: info.color))
                            }
                            .tag(info.id)
                        }
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                }
                if item != nil {
                    Section {
                        Button("Delete Event", role: .destructive) { askingDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(item == nil ? "New Event" : "Edit Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(item == nil ? "Add" : "Save") {
                        if let item, store.repeats(item) { askingSpan = true } else { save(futureToo: false) }
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || draft.calendarID.isEmpty)
                }
            }
            // Moving the start keeps the length the same, like Calendar does.
            .onChange(of: draft.start) { old, new in draft.end = draft.end.addingTimeInterval(new.timeIntervalSince(old)) }
            .confirmationDialog("This is a repeating event.", isPresented: $askingSpan) {
                Button("Save for This Event Only") { save(futureToo: false) }
                Button("Save for Future Events") { save(futureToo: true) }
            }
            .confirmationDialog(item.map { "Delete \u{201C}\($0.title)\u{201D}?" } ?? "", isPresented: $askingDelete, titleVisibility: .visible) {
                if let item {
                    if store.repeats(item) {
                        Button("Delete This Event Only", role: .destructive) { store.delete(item); finish() }
                        Button("Delete All Future Events", role: .destructive) { store.delete(item, futureToo: true); finish() }
                    } else {
                        Button("Delete Event", role: .destructive) { store.delete(item); finish() }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 520)
        #endif
    }

    private func save(futureToo: Bool) {
        if store.save(draft, editing: item, futureToo: futureToo) { finish() }
    }

    private func finish() {
        onFinish()
        dismiss()
    }
}

/// An open stretch between events. Tap it to block time for a task or add an
/// event there; or drag a task onto it.
struct FreeRow: View {
    let store: CalendarStore
    let block: DateInterval
    @State private var targeted = false
    @State private var addingEvent = false

    var body: some View {
        let tasks = store.tasks.filter { task in
            // Tasks for that day or earlier, or with no date, soonest first.
            task.due.map { Calendar.current.startOfDay(for: $0) <= block.start } ?? true
        }
        .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }

        Menu {
            Section("Block this time for") {
                ForEach(tasks.prefix(12)) { task in
                    Button(task.title) { store.blockTime(for: task, in: block) }
                }
                if tasks.isEmpty { Text("No open tasks") }
            }
            Button("New Event Here\u{2026}", systemImage: "calendar.badge.plus") { addingEvent = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundStyle(.green)
                Text("Free \u{00B7} \(block.start.formatted(date: .omitted, time: .shortened)) \u{2013} \(block.end.formatted(date: .omitted, time: .shortened))")
                Text(FreeTime.length(block.duration)).foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(targeted ? Color.green : Color.secondary.opacity(0.4))
                    .background(targeted ? Color.green.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let task = store.tasks.first(where: { $0.id == id }) else { return false }
            store.blockTime(for: task, in: block)
            return true
        } isTargeted: { targeted = $0 }
        .sheet(isPresented: $addingEvent) { EventEditor(store: store, at: block) }
    }
}

/// "Project deadline · Deadlines        12 days"
struct CountdownRow: View {
    let item: AgendaItem

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: item.color)).frame(width: 7, height: 7)
            Text(item.title).lineLimit(1)
            Text(item.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(Countdown.label(until: item.start, now: .now))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(Countdown.days(until: item.start, now: .now) <= 3 ? Color.red : Color.primary)
        }
    }
}

// MARK: Undo

/// "Checked off “Pay rent”  Undo", for a few seconds after a change.
struct UndoBanner: View {
    let store: CalendarStore

    var body: some View {
        if let action = store.undoAction {
            HStack(spacing: 12) {
                Text(action.message).lineLimit(1)
                Button("Undo") { store.performUndo() }
                    .fontWeight(.semibold)
                    .keyboardShortcut("z", modifiers: .command)
                Button { store.dismissUndo() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(action.id)
        }
    }
}

// MARK: Plan my day

/// Proposes today's plan: open tasks in the free stretches, most pressing first.
/// Switch tasks off or change their length and the rest move to fit; nothing is
/// saved until Add to Calendar.
struct PlanDayView: View {
    let store: CalendarStore
    @State private var skipped: Set<String> = []
    @State private var lengths: [String: Int] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let candidates = DayPlanner.candidates(store.tasks, now: .now)
        let slots = DayPlanner.plan(candidates.filter { !skipped.contains($0.id) }, into: store.freeToday, lengths: lengths)
        let placed = Set(slots.map(\.id))
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("Nothing pressing today: no urgent, overdue or due-today tasks.").foregroundStyle(.secondary)
                } else if store.freeToday.isEmpty {
                    Text("No free time left today.").foregroundStyle(.secondary)
                }
                if !slots.isEmpty {
                    Section("The plan") {
                        ForEach(slots.sorted { $0.start < $1.start }) { slot in row(slot.task, slot: slot) }
                    }
                }
                let left = candidates.filter { !placed.contains($0.id) }
                if !left.isEmpty {
                    Section {
                        ForEach(left) { row($0, slot: nil) }
                    } header: {
                        Text("Not planned")
                    } footer: {
                        Text("Switched off, or no free stretch long enough.")
                    }
                }
            }
            .navigationTitle("Plan My Day")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Calendar") {
                        store.schedule(slots)
                        dismiss()
                    }
                    .disabled(slots.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 520)
        #endif
    }

    private func row(_ task: TaskItem, slot: DayPlanner.Slot?) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { !skipped.contains(task.id) },
                set: { on in if on { skipped.remove(task.id) } else { skipped.insert(task.id) } }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    PriorityBadge(priority: task.priority)
                    Text(task.title)
                }
                if let slot {
                    Text("\(slot.start.formatted(date: .omitted, time: .shortened)) \u{2013} \(slot.end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                    Button(FreeTime.length(Double(minutes) * 60)) { lengths[task.id] = minutes }
                }
            } label: {
                Text(FreeTime.length(Double(slot?.minutes ?? lengths[task.id] ?? 30) * 60)).font(.callout)
            }
            .fixedSize()
        }
        .opacity(slot == nil ? 0.6 : 1)
    }
}

// MARK: Priority

/// "!" in orange for high, "!!" in red for urgent; nothing below that.
struct PriorityBadge: View {
    let priority: Priority

    var body: some View {
        switch priority {
        case .urgent: Image(systemName: "exclamationmark.2").foregroundStyle(.red).fontWeight(.bold)
            .accessibilityLabel("Urgent")
        case .high: Image(systemName: "exclamationmark").foregroundStyle(.orange).fontWeight(.bold)
            .accessibilityLabel("High priority")
        default: EmptyView()
        }
    }
}

/// Picks a priority, from a context menu or a button.
struct PriorityMenu: View {
    let current: Priority
    var compact = false
    let set: (Priority) -> Void

    var body: some View {
        Menu {
            ForEach(Priority.allCases.reversed(), id: \.self) { priority in
                Button { set(priority) } label: {
                    if priority == current { Label(priority.name, systemImage: "checkmark") } else { Text(priority.name) }
                }
            }
        } label: {
            if compact {
                Label(current == .none ? "Priority" : current.name, systemImage: "flag")
            } else {
                Label("Priority", systemImage: "flag")
            }
        }
    }
}

/// When Daybook alerts, by priority. The same screen on the Mac (Settings) and
/// the iPhone (the gear on Tasks); each device keeps its own.
struct AlertSettingsView: View {
    let store: CalendarStore
    @State private var settings = AlertScheduler.settings

    var body: some View {
        Form {
            Section {
                Toggle("Alerts on this device", isOn: $settings.enabled)
            } footer: {
                #if os(macOS)
                Text("Off on the Mac by default, so you aren\u{2019}t alerted twice when the iPhone has them on.")
                #else
                Text("Turn this off on whichever device you don\u{2019}t want alerts on, so they don\u{2019}t come twice.")
                #endif
            }
            Section {
                ForEach(AlertSettings.offsetChoices, id: \.self) { minutes in
                    Toggle(AlertSettings.describe(minutes), isOn: Binding(
                        get: { settings.importantOffsets.contains(minutes) },
                        set: { on in
                            if on { settings.importantOffsets.append(minutes) } else { settings.importantOffsets.removeAll { $0 == minutes } }
                        }))
                }
            } header: {
                Text("High and urgent")
            } footer: {
                Text("One alert at each time checked: \(settings.importantOffsets.count) in all.")
            }
            Section("Urgent tasks") {
                Picker("After it\u{2019}s due, remind me", selection: $settings.urgentRepeatMinutes) {
                    Text("Never").tag(Int?.none)
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("Every \($0) minutes").tag(Int?.some($0)) }
                }
                if settings.urgentRepeatMinutes != nil {
                    Stepper("Up to \(settings.urgentRepeatCount) times", value: $settings.urgentRepeatCount, in: 1...10)
                }
            }
            Section {
                Picker("Tasks", selection: $settings.normalTaskOffset) { offsetChoices }
                Picker("Events", selection: $settings.normalEventOffset) { offsetChoices }
            } header: {
                Text("Everything else")
            } footer: {
                Text("One alert. Calendar may already alert you for events with alerts of their own.")
            }
            #if os(iOS)
            Section {
                Toggle("Leave-by alerts", isOn: $settings.leaveBy)
                if settings.leaveBy {
                    Picker("Getting there", selection: $settings.walking) {
                        Text("Driving").tag(false)
                        Text("Walking").tag(true)
                    }
                    Picker("Extra time", selection: $settings.leaveBuffer) {
                        ForEach([0, 5, 10, 15, 20], id: \.self) { Text($0 == 0 ? "None" : "\($0) minutes").tag($0) }
                    }
                }
            } header: {
                Text("Leaving for events")
            } footer: {
                Text("For events with a place in the next 12 hours, an alert when it\u{2019}s time to go, from Apple Maps travel time. Needs your location while Daybook is open.")
            }
            .onChange(of: settings.leaveBy, initial: true) { if settings.leaveBy { LeaveBy.authorize() } }
            #endif
            Section {
                Picker("Alert at", selection: $settings.allDayHour) {
                    ForEach(5...12, id: \.self) { hour in
                        Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
                            .formatted(date: .omitted, time: .shortened)).tag(hour)
                    }
                }
            } header: {
                Text("Days without a time")
            } footer: {
                Text("For all-day events, and tasks with a day but no time.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings) {
            AlertScheduler.settings = settings
            Task { await AlertScheduler.reschedule(store) }
        }
    }

    @ViewBuilder private var offsetChoices: some View {
        Text("None").tag(Int?.none)
        ForEach(AlertSettings.offsetChoices, id: \.self) { Text(AlertSettings.describe($0)).tag(Int?.some($0)) }
    }
}

// MARK: Search

/// Events (six months back to a year ahead) and tasks matching the search text.
struct SearchResultsView: View {
    let store: CalendarStore
    let query: String
    @State private var results = CalendarStore.SearchResults()
    @State private var searched = ""

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Search event titles, places and notes, and task names.").foregroundStyle(.secondary)
            } else if results.isEmpty && searched == query {
                Text("Nothing matches \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary)
            }
            if !results.upcoming.isEmpty {
                Section("Upcoming") { ForEach(results.upcoming) { dated($0) } }
            }
            if !results.tasks.isEmpty {
                Section("Tasks") { ForEach(results.tasks) { TaskRow(store: store, task: $0, showDate: true) } }
            }
            if !results.past.isEmpty {
                Section("Past") { ForEach(results.past) { dated($0) } }
            }
        }
        .listStyle(.inset)
        .scrollDismissesKeyboard(.immediately)
        // Wait for a pause in typing before searching.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = await store.search(query)
            searched = query
        }
    }

    private func dated(_ item: AgendaItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            EventRow(store: store, item: item)
        }
    }
}

// MARK: Month

struct MonthView: View {
    let store: CalendarStore
    @State private var month = Date.now
    @State private var selected = Calendar.current.startOfDay(for: .now)

    var body: some View {
        let grid = MonthGrid(containing: month)
        VStack(spacing: 0) {
            header(grid)
            weekdayLabels
            VStack(spacing: 1) {
                ForEach(grid.weeks, id: \.first) { week in
                    HStack(spacing: 1) {
                        ForEach(week, id: \.self) { day in
                            DayCell(store: store, day: day, inMonth: grid.contains(day), selected: Calendar.current.isDate(day, inSameDayAs: selected))
                                .onTapGesture {
                                    selected = day
                                    #if os(iOS)
                                    // Tapping the grid also puts the keyboard away.
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    #endif
                                }
                        }
                    }
                }
            }
            .background(Color.secondary.opacity(0.2))
            Divider()
            DayListView(store: store, start: selected, days: 1, quickAddDate: selected)
                .frame(minHeight: 180)
        }
        #if os(iOS)
        .gesture(DragGesture(minimumDistance: 30).onEnded { drag in
            // Swipe the grid sideways to change months, like Calendar on iPhone.
            if abs(drag.translation.width) > abs(drag.translation.height) { shift(drag.translation.width < 0 ? 1 : -1) }
        })
        #endif
        .onAppear { store.extraRange = grid.range }
        .onChange(of: month) { store.extraRange = MonthGrid(containing: month).range }
    }

    private func header(_ grid: MonthGrid) -> some View {
        HStack {
            Text(grid.month.formatted(.dateTime.month(.wide).year())).font(.title2.weight(.semibold))
            Spacer()
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Today") {
                month = .now
                selected = Calendar.current.startOfDay(for: .now)
            }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var weekdayLabels: some View {
        HStack(spacing: 1) {
            ForEach(Calendar.current.shortWeekdaySymbols, id: \.self) { name in
                Text(name.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 4)
    }

    private func shift(_ months: Int) {
        month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month
    }
}

struct DayCell: View {
    #if os(iOS)
    static let cellHeight: CGFloat = 46
    #else
    static let cellHeight: CGFloat = 84
    #endif

    let store: CalendarStore
    let day: Date
    let inMonth: Bool
    let selected: Bool

    var body: some View {
        let calendar = Calendar.current
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)!
        let items = store.events.filter { $0.start < dayEnd && $0.end > day }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
        let tasks = store.tasks.filter { $0.due.map { calendar.isDate($0, inSameDayAs: day) } == true }
        let isToday = calendar.isDateInToday(day)
        VStack(alignment: .leading, spacing: 2) {
            Text("\(calendar.component(.day, from: day))")
                .font(.callout.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary))
                .frame(width: 24, height: 24)
                .background(isToday ? Color.red : Color.clear, in: Circle())
            #if os(iOS)
            // A phone-width cell only fits dots: one per event (up to four), gray for tasks.
            HStack(spacing: 2) {
                ForEach(items.prefix(4)) { item in
                    Circle().fill(Color(hex: item.color)).frame(width: 5, height: 5).opacity(store.isDone(item) ? 0.35 : 1)
                }
                if !tasks.isEmpty { Circle().strokeBorder(Color.secondary, lineWidth: 1.2).frame(width: 6, height: 6) }
            }
            #else
            // Events first, then tasks (with an open circle, like a checkbox): three lines
            // in all, counting "+N more", which is all an 84-point cell has room for.
            let lines = items.count + tasks.count > 3 ? 2 : 3
            let shownEvents = Array(items.prefix(lines))
            let shownTasks = Array(tasks.prefix(lines - shownEvents.count))
            ForEach(shownEvents) { item in
                HStack(spacing: 3) {
                    Circle().fill(Color(hex: item.color)).frame(width: 6, height: 6)
                    Text(item.title).lineLimit(1).truncationMode(.tail).strikethrough(store.isDone(item))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption2)
                .opacity(store.isDone(item) ? 0.5 : 1)
            }
            ForEach(shownTasks) { task in
                HStack(spacing: 3) {
                    Image(systemName: "circle").font(.system(size: 6, weight: .bold))
                    Text(task.title).lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            let extra = items.count + tasks.count - shownEvents.count - shownTasks.count
            if extra > 0 {
                Text("+\(extra) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            #endif
            Spacer(minLength: 0)
        }
        .padding(4)
        // minWidth 0 lets every day take an equal share of the week, so a long title
        // gets cut off with "…" instead of widening its day into the next one.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: Self.cellHeight, alignment: .topLeading)
        .clipped()
        .background(selected ? Color.accentColor.opacity(0.15) : Color(white: 0.5, opacity: inMonth ? 0.04 : 0.0))
        .background(.background)
        .contentShape(Rectangle())
    }
}

// MARK: Tasks

struct TasksView: View {
    let store: CalendarStore

    var body: some View {
        let now = Date.now
        let calendar = Calendar.current
        let overdue = store.tasks.filter { $0.isOverdue(now: now, calendar: calendar) }
        let today = store.tasks.filter { task in task.due.map { calendar.isDateInToday($0) } == true && !task.isOverdue(now: now, calendar: calendar) }
        let later = store.tasks.filter { task in task.due.map { $0 >= calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))! } == true }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        let undated = store.tasks.filter { $0.due == nil }

        List {
            QuickAddField(store: store)
            if store.reminderAccess != .granted {
                Text("Allow Reminders access to see and add tasks.").foregroundStyle(.secondary)
            }
            section("Overdue", overdue)
            section("Today", today)
            section("Upcoming", later)
            section("No date", undated)
            section("Done today", store.completedToday)
        }
        .listStyle(.inset)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder private func section(_ title: String, _ tasks: [TaskItem]) -> some View {
        if !tasks.isEmpty {
            Section(title) {
                ForEach(tasks) { TaskRow(store: store, task: $0, showDate: title != "Today" && title != "Done today") }
            }
        }
    }
}

struct TaskRow: View {
    let store: CalendarStore
    let task: TaskItem
    let showDate: Bool
    @State private var editingDate = false
    @State private var showingDetails = false

    var body: some View {
        HStack(spacing: 10) {
            DoneButton(done: task.isCompleted) { store.setDone(task, !task.isCompleted) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    PriorityBadge(priority: task.priority)
                    Text(task.title).strikethrough(task.isCompleted)
                }
                HStack(spacing: 6) {
                    if let due = task.due {
                        if showDate { Text(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) }
                        if task.dueHasTime { Text(due.formatted(date: .omitted, time: .shortened)) }
                    }
                    if task.repeats { Image(systemName: "repeat").accessibilityLabel("Repeats") }
                    Text(task.list)
                }
                .font(.caption)
                .foregroundStyle(task.isOverdue(now: .now, calendar: .current) ? .red : .secondary)
            }
            Spacer()
            if !task.isCompleted {
                Button { editingDate = true } label: {
                    Image(systemName: task.due == nil ? "calendar.badge.plus" : "calendar")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(task.due == nil ? "Add a date" : "Change the date")
                .popover(isPresented: $editingDate) {
                    DueEditor(due: task.due, hasTime: task.dueHasTime) { due, hasTime in
                        store.setDue(task, due, hasTime: hasTime)
                    }
                }
            }
        }
        .opacity(task.isCompleted ? 0.5 : 1)
        .padding(.vertical, 2)
        // Tapping anywhere but the check and date buttons opens the details.
        .contentShape(Rectangle())
        .onTapGesture { showingDetails = true }
        .sheet(isPresented: $showingDetails) { TaskDetailView(store: store, task: task) }
        // Drag onto a free stretch to block out time for it.
        .draggable(task.id) { Label(task.title, systemImage: "checklist").padding(6) }
        .contextMenu {
            Button("Show Details") { showingDetails = true }
            Button(task.isCompleted ? "Mark Not Done" : "Mark Done") { store.setDone(task, !task.isCompleted) }
            if !task.isCompleted {
                Button(task.due == nil ? "Add Date\u{2026}" : "Change Date\u{2026}") { editingDate = true }
                PriorityMenu(current: task.priority) { store.setPriority(task, $0) }
            }
        }
    }
}

/// Everything about a task, editable: notes, link, list, date, repeat, priority.
struct TaskDetailView: View {
    let store: CalendarStore
    let task: TaskItem
    @State private var draft: CalendarStore.TaskDraft
    @State private var askingDelete = false
    @Environment(\.dismiss) private var dismiss

    init(store: CalendarStore, task: TaskItem) {
        self.store = store
        self.task = task
        _draft = State(initialValue: store.draft(for: task) ?? CalendarStore.TaskDraft(title: task.title))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...8)
                    TextField("Link", text: $draft.link)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
                Section {
                    Toggle("Date", isOn: Binding(
                        get: { draft.due != nil },
                        set: { draft.due = $0 ? (draft.due ?? Calendar.current.startOfDay(for: .now)) : nil }))
                    if let due = draft.due {
                        DatePicker("Day", selection: Binding(get: { due }, set: { draft.due = $0 }), displayedComponents: .date)
                        Toggle("Time", isOn: $draft.hasTime)
                        if draft.hasTime {
                            DatePicker("At", selection: Binding(get: { due }, set: { draft.due = $0 }), displayedComponents: .hourAndMinute)
                        }
                    }
                    Picker("Repeat", selection: $draft.repeats) {
                        ForEach(CalendarStore.Repeat.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section {
                    Picker("Priority", selection: $draft.priority) {
                        ForEach(Priority.allCases.reversed(), id: \.self) { Text($0.name).tag($0) }
                    }
                    Picker("List", selection: $draft.listID) {
                        ForEach(store.reminderLists) { list in
                            Text(list.account.isEmpty ? list.title : "\(list.title) (\(list.account))").tag(list.id)
                        }
                    }
                }
                Section {
                    Button("Delete Task", role: .destructive) { askingDelete = true }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if store.save(draft, for: task) { dismiss() } }
                        .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete \u{201C}\(task.title)\u{201D}?", isPresented: $askingDelete, titleVisibility: .visible) {
                Button("Delete Task", role: .destructive) {
                    store.delete(task)
                    dismiss()
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 560)
        #endif
    }
}

/// Picks a day, and optionally a time, for a task. "Remove Date" makes it undated.
struct DueEditor: View {
    let onSave: (Date?, Bool) -> Void
    @State private var date: Date
    @State private var hasTime: Bool
    private let hadDate: Bool
    @Environment(\.dismiss) private var dismiss

    init(due: Date?, hasTime: Bool, onSave: @escaping (Date?, Bool) -> Void) {
        self.onSave = onSave
        hadDate = due != nil
        // No date yet: start on today at the next hour, in case a time is wanted.
        let calendar = Calendar.current
        let nextHour = calendar.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
        _date = State(initialValue: due ?? nextHour)
        _hasTime = State(initialValue: hasTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("Day", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            Toggle("At a specific time", isOn: $hasTime.animation())
            if hasTime {
                DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
            }
            HStack {
                if hadDate {
                    Button("Remove Date", role: .destructive) { finish(nil) }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { finish(hasTime ? date : Calendar.current.startOfDay(for: date)) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 300)
        .presentationDetents([.large])
    }

    private func finish(_ due: Date?) {
        onSave(due, hasTime && due != nil)
        dismiss()
    }
}

struct QuickAddField: View {
    let store: CalendarStore
    /// Used when nothing is picked and the text names no date.
    var defaultDate: Date? = nil
    @State private var text = ""
    @State private var picked: (due: Date, hasTime: Bool)?
    @State private var picking = false
    @State private var makingEvent = false
    @FocusState private var typing: Bool

    var body: some View {
        let parsed = QuickAdd.parse(text)
        HStack {
            // Switches between adding a task and adding a calendar event.
            Button { makingEvent.toggle() } label: {
                Image(systemName: makingEvent ? "calendar.circle.fill" : "plus.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .help(makingEvent ? "Adding an event. Click to add a task instead." : "Adding a task. Click to add an event instead.")
            .accessibilityLabel(makingEvent ? "Adding an event" : "Adding a task")
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($typing)
                .onSubmit(add)
                #if os(iOS)
                .submitLabel(.done)
                #endif
            // What the task will be due: picked, else typed, else this view's day.
            if let picked {
                Text(Self.label(picked.due, hasTime: picked.hasTime)).font(.caption).foregroundStyle(.tint)
            } else if !text.isEmpty, let due = parsed.due {
                Text(Self.label(due, hasTime: parsed.hasTime)).font(.caption).foregroundStyle(.secondary)
            }
            Button { picking = true } label: {
                Image(systemName: picked == nil ? "calendar.badge.plus" : "calendar.badge.checkmark")
            }
            .buttonStyle(.borderless)
            .help("Pick a date")
            .popover(isPresented: $picking) {
                DueEditor(due: picked?.due ?? defaultDate, hasTime: picked?.hasTime ?? false) { due, hasTime in
                    picked = due.map { ($0, hasTime) }
                }
            }
            #if os(iOS)
            // While typing: a way out of the keyboard without adding the task.
            if typing {
                if !text.isEmpty {
                    Button { text = ""; picked = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear")
                }
                Button("Done") { typing = false }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            #endif
        }
        .animation(.snappy(duration: 0.2), value: typing)
        .padding(.vertical, 4)
    }

    private var placeholder: String {
        let kind = makingEvent ? "an event" : "a task"
        if let defaultDate {
            return "Add \(kind) for \(defaultDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
        }
        return makingEvent ? "Add an event: \u{201C}coffee with Sam thu 2pm\u{201D}" : "Add a task: \u{201C}submit report friday 3pm\u{201D}"
    }

    private func add() {
        if makingEvent {
            store.addEvent(text, picked: picked, day: defaultDate)
        } else if let picked {
            store.addTask(text, due: picked.due, hasTime: picked.hasTime)
        } else if QuickAdd.parse(text).due == nil, let defaultDate {
            store.addTask(text, due: defaultDate, hasTime: false)
        } else {
            store.addTask(text)
        }
        text = ""
        picked = nil
    }

    static func label(_ due: Date, hasTime: Bool) -> String {
        hasTime ? due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                : due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

// MARK: Calendars and permission

struct CalendarFilter: View {
    @Bindable var store: CalendarStore

    var body: some View {
        Menu {
            ForEach(Dictionary(grouping: store.calendars, by: \.account).sorted { $0.key < $1.key }, id: \.key) { account, calendars in
                Section(account.isEmpty ? "Other" : account) {
                    ForEach(calendars) { info in
                        Toggle(info.title, isOn: Binding(
                            get: { !store.hiddenCalendars.contains(info.id) },
                            set: { shown in
                                if shown { store.hiddenCalendars.remove(info.id) } else { store.hiddenCalendars.insert(info.id) }
                            }))
                    }
                }
            }
        } label: {
            Label("Calendars", systemImage: "calendar")
        }
        .help("Choose which calendars to show")
    }
}

struct PermissionView: View {
    let store: CalendarStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.checkmark").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Daybook needs access to Calendars and Reminders").font(.title3.weight(.semibold))
            Text("It shows every calendar in one place, and keeps your tasks in Reminders so they sync between your Mac and iPhone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            if store.eventAccess == .denied {
                Button("Open Privacy Settings") { CalendarStore.openPrivacySettings() }
            } else {
                Button("Allow Access") { Task { await store.requestAccess() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Morning brief (text)

/// The morning brief as text, as the scheduled task posts it to Reminders for the
/// iPhone. (The Mac shows the full drawn page instead; see BriefView.swift.)
struct BriefTextView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(BriefMarkdown.blocks(markdown).enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func view(for block: BriefMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.weight(.semibold) : .headline)
                .padding(.top, level == 1 ? 0 : 10)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\u{2022}").foregroundStyle(.secondary)
                Text(Self.inline(text))
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
                Text(Self.inline(text))
            }
        case .paragraph(let text):
            Text(Self.inline(text))
        }
    }

    /// Bold, italics and links within a line.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    /// "Today", "Yesterday", or "Mon, Oct 5" for a brief's "2026-10-05".
    static func label(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return key }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// Today's brief, as it pops up once a day.
struct BriefPopup: View {
    let brief: CalendarStore.PostedBrief
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BriefTextView(markdown: brief.markdown)
                .navigationTitle(BriefMarkdown.isWeekly(brief.markdown) ? "Week Ahead" : "Morning Brief")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Got It") { dismiss() } }
                }
        }
    }
}

/// Every brief Daybook has (the last two weeks), newest first, from the sun button.
struct BriefHistoryView: View {
    let briefs: [CalendarStore.PostedBrief]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(briefs) { brief in
                NavigationLink {
                    BriefTextView(markdown: brief.markdown)
                        .navigationTitle(BriefTextView.label(brief.date))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(BriefTextView.label(brief.date) + (BriefMarkdown.isWeekly(brief.markdown) ? " \u{00B7} Week ahead" : ""))
                            .font(.body.weight(.medium))
                        // The brief's headline, as a preview.
                        if case .heading(_, let headline)? = BriefMarkdown.blocks(brief.markdown).first {
                            Text(BriefTextView.inline(headline)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .overlay {
                if briefs.isEmpty {
                    ContentUnavailableView("No briefs yet", systemImage: "sun.horizon",
                                           description: Text("The morning brief shows up here after it runs on your Mac."))
                }
            }
            .navigationTitle("Briefs")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
