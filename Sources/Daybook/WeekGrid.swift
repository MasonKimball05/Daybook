#if os(macOS)
import DaybookCore
import SwiftUI

/// The week hour by hour, like Calendar's week view. Drag an event to move it
/// (to another time or day), drag its bottom edge to change its length, and
/// double-click an empty spot for a new event there. Read-only calendars
/// (subscribed feeds) can't be dragged.
struct WeekGridView: View {
    let store: CalendarStore
    @State private var weekStart = WeekGridView.startOfWeek(.now)
    @State private var newEventAt: NewSlot?

    struct NewSlot: Identifiable {
        let block: DateInterval
        var id: Date { block.start }
    }

    static let hourHeight: CGFloat = 48
    static let gutter: CGFloat = 52
    static let snap = 15 // minutes

    static func startOfWeek(_ date: Date) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 1
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    private var days: [Date] {
        (0..<7).map { Calendar.current.date(byAdding: .day, value: $0, to: weekStart)! }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Natural height only: without this the rows above the grid stretch to
            // take half the window.
            dayHeaders.fixedSize(horizontal: false, vertical: true)
            allDayStrip.fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    grid.padding(.bottom, 8)
                }
                .onAppear { proxy.scrollTo(7, anchor: .top) }
            }
        }
        .onAppear { load() }
        .onChange(of: weekStart) { load() }
        .sheet(item: $newEventAt) { slot in EventEditor(store: store, at: slot.block) }
    }

    private func load() {
        store.extraRange = (weekStart, Calendar.current.date(byAdding: .day, value: 7, to: weekStart)!)
    }

    // MARK: Header

    private var header: some View {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart)!
        return HStack {
            Text("\(weekStart.formatted(.dateTime.month(.abbreviated).day())) \u{2013} \(end.formatted(.dateTime.month(.abbreviated).day().year()))")
                .font(.title2.weight(.semibold))
            Spacer()
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Today") { weekStart = Self.startOfWeek(.now) }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func shift(_ weeks: Int) {
        weekStart = Calendar.current.date(byAdding: .day, value: 7 * weeks, to: weekStart)!
    }

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter, height: 1)
            ForEach(days, id: \.self) { day in
                let today = Calendar.current.isDateInToday(day)
                VStack(spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(day.formatted(.dateTime.day()))
                        .font(.callout.weight(today ? .bold : .regular))
                        .foregroundStyle(today ? Color.white : Color.primary)
                        .frame(width: 26, height: 26)
                        .background(today ? Color.red : .clear, in: Circle())
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
        }
        .padding(.bottom, 4)
    }

    private var allDayStrip: some View {
        let allDay = store.events.filter(\.isAllDay)
        return HStack(alignment: .top, spacing: 1) {
            Text("all-day").font(.caption2).foregroundStyle(.secondary).frame(width: Self.gutter - 1, alignment: .trailing)
            ForEach(days, id: \.self) { day in
                let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allDay.filter { $0.start < next && $0.end > day }.prefix(3)) { item in
                        AllDayChip(store: store, item: item)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 18, alignment: .topLeading)
                .clipped()
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Grid

    private var grid: some View {
        GeometryReader { geometry in
            let columnWidth = (geometry.size.width - Self.gutter) / 7
            ZStack(alignment: .topLeading) {
                // Hour lines and labels; ids for scrolling to the morning.
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        HStack(alignment: .top, spacing: 0) {
                            Text(hour == 0 ? "" : Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
                                .formatted(.dateTime.hour()))
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(width: Self.gutter - 6, alignment: .trailing)
                                .offset(y: -6)
                            Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
                        }
                        .frame(height: Self.hourHeight, alignment: .top)
                        .id(hour)
                    }
                }
                // Day columns: double-click empty time for a new event.
                HStack(spacing: 0) {
                    Color.clear.frame(width: Self.gutter)
                    ForEach(days, id: \.self) { day in
                        Rectangle()
                            .fill(Calendar.current.isDateInToday(day) ? Color.accentColor.opacity(0.04) : Color.clear)
                            .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1) }
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture(count: 2).onEnded { tap in
                                let minutes = Int(tap.location.y / Self.hourHeight * 60) / 30 * 30
                                let start = Calendar.current.date(byAdding: .minute, value: minutes, to: day)!
                                newEventAt = NewSlot(block: DateInterval(start: start, duration: 3600))
                            })
                    }
                }
                // Sleep, from Health: a faint indigo wash across the night, behind everything.
                ForEach(Array(days.enumerated()), id: \.element) { index, day in
                    let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                    ForEach(store.sleepNights.filter { $0.start < next && $0.end > day }) { night in
                        let top = max(night.start, day), bottom = min(night.end, next)
                        let height = CGFloat(bottom.timeIntervalSince(top) / 3600) * Self.hourHeight
                        Rectangle()
                            .fill(Color(red: 0.36, green: 0.38, blue: 0.62).opacity(0.12))
                            .overlay(alignment: night.end <= next ? .bottomLeading : .topLeading) {
                                // Labeled on the morning it ended, once.
                                if night.end <= next {
                                    Text("Slept \(TimeReport.hours(night.asleep / 3600))")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Color(red: 0.42, green: 0.45, blue: 0.78))
                                        .padding(3)
                                }
                            }
                            .frame(width: columnWidth, height: max(height, 1))
                            .position(x: Self.gutter + CGFloat(index) * columnWidth + columnWidth / 2,
                                      y: CGFloat(top.timeIntervalSince(day) / 3600) * Self.hourHeight + height / 2)
                            .allowsHitTesting(false)
                    }
                }
                // Coding sessions: faint orange, behind the events.
                ForEach(Array(days.enumerated()), id: \.element) { index, day in
                    let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                    ForEach(store.workSessions.filter { $0.start < next && $0.end > day }) { session in
                        let top = max(session.start, day), bottom = min(session.end, next)
                        let height = max(CGFloat(bottom.timeIntervalSince(top) / 3600) * Self.hourHeight, 14)
                        GridSessionBlock(session: session)
                            .frame(width: columnWidth - 4, height: height)
                            .position(x: Self.gutter + CGFloat(index) * columnWidth + 2 + (columnWidth - 4) / 2,
                                      y: CGFloat(top.timeIntervalSince(day) / 3600) * Self.hourHeight + height / 2)
                    }
                }
                // Events.
                ForEach(Array(days.enumerated()), id: \.element) { index, day in
                    let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                    let timed = store.events.filter { !$0.isAllDay && $0.start < next && $0.end > day }
                    let places = TimeGridLayout.place(timed)
                    ForEach(timed) { item in
                        let place = places[item.id] ?? .init(column: 0, columns: 1)
                        let width = (columnWidth - 4) / CGFloat(place.columns)
                        let top = max(item.start, day), bottom = min(item.end, next)
                        let height = max(CGFloat(bottom.timeIntervalSince(top) / 3600) * Self.hourHeight, 18)
                        let left = Self.gutter + CGFloat(index) * columnWidth + 2 + CGFloat(place.column) * width
                        let y = CGFloat(top.timeIntervalSince(day) / 3600) * Self.hourHeight
                        // `position` (not `offset`) so the block is really there: its details
                        // popover then opens beside it, not at the grid's top-left corner.
                        GridEventBlock(store: store, item: item, columnWidth: columnWidth, height: height)
                            .frame(width: width - 1, height: height)
                            .position(x: left + (width - 1) / 2, y: y + height / 2)
                    }
                }
                // Now.
                if let index = days.firstIndex(where: { Calendar.current.isDateInToday($0) }) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let y = CGFloat(context.date.timeIntervalSince(days[index]) / 3600) * Self.hourHeight
                        HStack(spacing: 0) {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Rectangle().fill(.red).frame(width: columnWidth - 8, height: 2)
                        }
                        .offset(x: Self.gutter + CGFloat(index) * columnWidth - 4, y: y - 4)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(height: Self.hourHeight * 24)
    }
}

/// A coding session behind the events: faint orange; click for its commits.
private struct GridSessionBlock: View {
    let session: Work.Session
    @State private var showingCommits = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(codingColor.opacity(0.14))
            .overlay(alignment: .leading) { Rectangle().fill(codingColor.opacity(0.8)).frame(width: 2) }
            .overlay(alignment: .bottomTrailing) {
                Text("\(session.repos.joined(separator: ", ")) \u{00B7} \(session.commits)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(codingColor)
                    .lineLimit(1)
                    .padding(3)
            }
            .contentShape(RoundedRectangle(cornerRadius: 4))
            .onTapGesture { showingCommits = true }
            .popover(isPresented: $showingCommits, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Coding \(session.start.formatted(date: .omitted, time: .shortened)) \u{2013} \(session.end.formatted(date: .omitted, time: .shortened))")
                            .font(.headline)
                        Text("\(session.repos.joined(separator: ", ")) \u{00B7} \(session.commits) commit\(session.commits == 1 ? "" : "s") \u{00B7} \(TimeReport.hours(session.duration / 3600))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(session.items.reversed()) { CommitRow(commit: $0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .frame(width: 400)
                .frame(maxHeight: 480)
            }
            .help("Coding: \(session.commits) commits. Click for them.")
    }
}

/// An all-day item at the top of the week: click for its details.
private struct AllDayChip: View {
    let store: CalendarStore
    let item: AgendaItem
    @State private var showingDetails = false

    var body: some View {
        Text(item.title)
            .font(.caption2).lineLimit(1)
            .strikethrough(store.isDone(item))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: item.color).opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .onTapGesture { showingDetails = true }
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                EventDetailView(store: store, item: item).frame(width: 380).frame(maxHeight: 620)
            }
            .help(item.title)
    }
}

/// One event in the grid: tap for details, drag to move, drag the bottom edge
/// to change the length.
private struct GridEventBlock: View {
    let store: CalendarStore
    let item: AgendaItem
    let columnWidth: CGFloat
    let height: CGFloat
    @State private var move = CGSize.zero
    @State private var stretch: CGFloat = 0
    @State private var showingDetails = false

    var body: some View {
        let editable = store.canEdit(item)
        let done = store.isDone(item)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                PriorityBadge(priority: store.priority(of: item))
                Text(item.title).font(.caption.weight(.semibold)).lineLimit(height > 40 ? 2 : 1).strikethrough(done)
            }
            if height > 32 {
                Text(item.start.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: max(height + stretch, 18), alignment: .topLeading)
        .background(Color(hex: item.color).opacity(done ? 0.12 : 0.25), in: RoundedRectangle(cornerRadius: 4))
        // A solid backing under the tint, so coding blocks behind don't show through the text.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: item.color)).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottom) {
            if editable {
                // The resize handle.
                Color.clear.frame(height: 6).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { stretch = snapped($0.translation.height) }
                        .onEnded { _ in commit(moveMinutes: 0, days: 0, lengthen: minutes(stretch)); stretch = 0 })
            }
        }
        .offset(move)
        .opacity(move == .zero ? 1 : 0.8)
        .contentShape(RoundedRectangle(cornerRadius: 4)) // the whole block, not just its text
        .onTapGesture { showingDetails = true }
        .gesture(editable ? DragGesture(minimumDistance: 4)
            .onChanged { drag in
                move = CGSize(width: (drag.translation.width / columnWidth).rounded() * columnWidth, height: snapped(drag.translation.height))
            }
            .onEnded { _ in
                commit(moveMinutes: minutes(move.height), days: Int((move.width / columnWidth).rounded()), lengthen: 0)
                move = .zero
            } : nil)
        .popover(isPresented: $showingDetails, arrowEdge: .trailing) {
            EventDetailView(store: store, item: item).frame(width: 380).frame(maxHeight: 620)
        }
        .help(editable ? "Drag to move. Drag the bottom edge to change the length." : "\(item.calendar) is read-only")
    }

    private func snapped(_ y: CGFloat) -> CGFloat {
        let step = WeekGridView.hourHeight * CGFloat(WeekGridView.snap) / 60
        return (y / step).rounded() * step
    }

    private func minutes(_ y: CGFloat) -> Int { Int((y / WeekGridView.hourHeight * 60).rounded()) }

    private func commit(moveMinutes: Int, days: Int, lengthen: Int) {
        guard moveMinutes != 0 || days != 0 || lengthen != 0, var draft = store.draft(for: item) else { return }
        let shift = TimeInterval(moveMinutes * 60 + days * 86_400)
        draft.start = draft.start.addingTimeInterval(shift)
        draft.end = max(draft.end.addingTimeInterval(shift + TimeInterval(lengthen * 60)),
                        draft.start.addingTimeInterval(TimeInterval(WeekGridView.snap * 60)))
        // A repeating event: moving one occurrence changes just that one.
        guard let before = store.draft(for: item), store.save(draft, editing: item, futureToo: false),
              let id = store.lastSavedEventID else { return }
        store.offerUndo(lengthen != 0 ? "Changed \u{201C}\(item.title)\u{201D}" : "Moved \u{201C}\(item.title)\u{201D}") {
            store.restoreEvent(id, to: before)
        }
    }
}
#endif
