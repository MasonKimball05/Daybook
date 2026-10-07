import Charts
import DaybookCore
import SwiftUI

/// The weekly recap, Sunday to Saturday: free time, hours by calendar, coding
/// by repo, time logged by hand, and what shipped on GitHub, with a bar per day.
/// Log Activity adds time spent that isn't on the calendar ("Study, 10 to 11 PM").
struct TimeView: View {
    let store: CalendarStore
    @State private var week = TimeReport.weekStart(of: .now)
    @State private var logging = false
    /// The day the pointer is over (or was tapped), and how high up its bar.
    @State private var hoveredDay: Date?
    @State private var hoveredHours: Double?

    var body: some View {
        let report = store.timeReport(weekOf: week)
        let scheduled = report.categories.filter { $0.kind == .calendar }.map(\.hours).reduce(0, +)
        let coding = report.categories.filter { $0.kind == .coding }.map(\.hours).reduce(0, +)
        let logged = report.categories.filter { $0.kind == .logged }
        let nights = report.days.compactMap(\.slept)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(report)
                // The four totals.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    Tile(title: "Free time", value: TimeReport.hours(report.free),
                         note: nights.isEmpty ? "open, 8 AM to 10 PM" : "awake with nothing on", color: .secondary)
                    if !nights.isEmpty {
                        Tile(title: "Sleep", value: TimeReport.hours(nights.reduce(0, +) / Double(nights.count)),
                             note: "a night, from Health", color: Color(red: 0.42, green: 0.45, blue: 0.78))
                    }
                    Tile(title: "Scheduled", value: TimeReport.hours(scheduled), note: "on your calendars", color: .accentColor)
                    Tile(title: "Coding", value: TimeReport.hours(coding), note: "\(report.commits) commits", color: codingColor)
                    Tile(title: "Logged", value: TimeReport.hours(logged.map(\.hours).reduce(0, +)), note: "by you", color: loggedColor)
                }
                chart(report)
                if !report.categories.isEmpty {
                    Breakdown(title: "By kind", rows: report.categories.map { ($0.label, $0.hours, color(for: $0, in: report)) })
                }
                if !report.byRepo.isEmpty {
                    Breakdown(title: "Coding by repo", rows: report.byRepo.map { ($0.name, $0.hours, codingColor) })
                }
                if !report.activities.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shipped on GitHub").font(.headline)
                        ForEach(report.activities.prefix(12)) { ActivityRow(activity: $0) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { store.extraRange = (week, Calendar.current.date(byAdding: .day, value: 7, to: week)!) }
        .sheet(isPresented: $logging) { LogActivitySheet(store: store) }
    }

    private func header(_ report: TimeReport) -> some View {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: week)!
        let title = VStack(alignment: .leading, spacing: 2) {
            Text("Time").font(.title2.weight(.semibold))
            Text("\(week.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) \u{2013} \(end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                .foregroundStyle(.secondary)
        }
        let controls = HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Button("This Week") { week = TimeReport.weekStart(of: .now) }
                .disabled(Calendar.current.isDate(week, inSameDayAs: TimeReport.weekStart(of: .now)))
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
            Button { logging = true } label: { Label("Log Activity", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .padding(.leading, 6)
        }
        .buttonStyle(.borderless)
        // One line when it fits (the Mac), two on a phone.
        return ViewThatFits(in: .horizontal) {
            HStack { title; Spacer(); controls }
            VStack(alignment: .leading, spacing: 10) { title; controls }
        }
    }

    private func shift(_ weeks: Int) {
        week = Calendar.current.date(byAdding: .day, value: 7 * weeks, to: week)!
        store.extraRange = (week, Calendar.current.date(byAdding: .day, value: 7, to: week)!)
    }

    /// Stacked hours per day, one color per kind of time, with each day's free time under it.
    private func chart(_ report: TimeReport) -> some View {
        let names = report.categories.map(\.name)
        // The chart and its legend show labels ("Home – Calendar"); the day's hours are keyed by name.
        let labels = report.categories.map(\.label)
        let label = Dictionary(uniqueKeysWithValues: report.categories.map { ($0.name, $0.label) })
        let colors = report.categories.map { color(for: $0, in: report) }
        let calendar = Calendar.current
        let selected = hoveredDay.flatMap { date in report.days.first { calendar.isDate($0.date, inSameDayAs: date) } }
        return VStack(alignment: .leading, spacing: 8) {
            Text("By day").font(.headline)
            Chart {
                ForEach(report.days) { day in
                    ForEach(names, id: \.self) { name in
                        if let hours = day.hours[name] {
                            BarMark(x: .value("Day", day.date, unit: .day), y: .value("Hours", hours))
                                .foregroundStyle(by: .value("Kind", label[name] ?? name))
                                // The day being looked at stays bright; the rest dim.
                                .opacity(selected == nil || selected?.date == day.date ? 1 : 0.35)
                        }
                    }
                }
                // The card for the day under the pointer, beside its bar (not over
                // it): to the right early in the week, to the left later on.
                if let selected {
                    let late = (report.days.firstIndex { $0.date == selected.date } ?? 0) >= 4
                    // An invisible rectangle over the day's whole column (wider than
                    // its bar), so a card beside it never covers the bar.
                    RectangleMark(xStart: .value("Day", selected.date),
                                  xEnd: .value("Day", calendar.date(byAdding: .day, value: 1, to: selected.date)!),
                                  yStart: .value("Hours", 0), yEnd: .value("Hours", max(selected.total, 0.1)))
                        .foregroundStyle(.clear)
                        .annotation(position: late ? .leading : .trailing, alignment: .top, spacing: 2,
                                    overflowResolution: .init(x: .disabled, y: .fit(to: .chart))) {
                            DayCard(day: selected, names: names, labels: labels, colors: colors, segment: segment(in: selected, names: names))
                        }
                }
            }
            .chartForegroundStyleScale(domain: labels, range: colors)
            .chartXAxis {
                AxisMarks(values: report.days.map(\.date)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self), let day = report.days.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
                            VStack(spacing: 1) {
                                Text(date.formatted(.dateTime.weekday(.abbreviated)))
                                Text("\(TimeReport.hours(day.free)) free").foregroundStyle(.secondary)
                            }
                            .font(.caption2)
                        }
                    }
                }
            }
            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h))h") } } } }
            .chartLegend(position: .bottom, alignment: .leading)
            // Hover (Mac) or tap (iPhone): which day, and how high up the bar.
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        #if os(macOS)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point): pick(point, proxy: proxy, geometry: geometry)
                            case .ended: hoveredDay = nil; hoveredHours = nil
                            }
                        }
                        #endif
                        .gesture(SpatialTapGesture().onEnded { tap in
                            if let current = hoveredDay, let date: Date = proxy.value(atX: tap.location.x - (proxy.plotFrame.map { geometry[$0].origin.x } ?? 0)),
                               calendar.isDate(current, inSameDayAs: date) {
                                hoveredDay = nil // tapping the same day again closes the card
                            } else {
                                pick(tap.location, proxy: proxy, geometry: geometry)
                            }
                        })
                }
            }
            .frame(height: 260)
        }
    }

    /// Turns a point on the chart into the day and the height (in hours) under it.
    private func pick(_ point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let frame = proxy.plotFrame.map({ geometry[$0] }) else { return }
        let x = point.x - frame.origin.x, y = point.y - frame.origin.y
        guard x >= 0, x <= frame.width, let date: Date = proxy.value(atX: x) else {
            hoveredDay = nil
            return
        }
        hoveredDay = Calendar.current.startOfDay(for: date)
        hoveredHours = proxy.value(atY: y)
    }

    /// Which piece of the stacked bar is under the pointer: the bars stack in
    /// the order of `names`, so add them up until passing the pointer's height.
    private func segment(in day: TimeReport.Day, names: [String]) -> String? {
        guard let height = hoveredHours, height >= 0 else { return nil }
        var top = 0.0
        for name in names {
            guard let hours = day.hours[name] else { continue }
            top += hours
            if height <= top { return name }
        }
        return nil
    }

    private let loggedColor = Color(red: 0.18, green: 0.62, blue: 0.56)
    /// Muted indigo: sleep is the biggest piece of most days, so it stays quiet.
    private let sleepColor = Color(red: 0.36, green: 0.38, blue: 0.62).opacity(0.55)

    /// Coding orange, logged teal (in shades, so different activities stay
    /// apart), calendars their own colors.
    private func color(for category: TimeReport.Category, in report: TimeReport) -> Color {
        switch category.kind {
        case .coding:
            return codingColor
        case .sleep:
            return sleepColor
        case .logged:
            let logged = report.categories.filter { $0.kind == .logged }.map(\.name)
            let index = Double(logged.firstIndex(of: category.name) ?? 0)
            return loggedColor.opacity(max(1 - index * 0.18, 0.35))
        case .calendar:
            return store.calendars.first { $0.title == category.name }.map { Color(hex: $0.color) } ?? .gray
        }
    }
}

/// "Wed, Oct 7": each kind of time that day with its hours, the one under the
/// pointer in bold, and free time at the bottom.
private struct DayCard: View {
    let day: TimeReport.Day
    let names: [String]
    let labels: [String]
    let colors: [Color]
    let segment: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.caption.weight(.semibold))
            ForEach(Array(names.enumerated()), id: \.element) { index, name in
                if let hours = day.hours[name] {
                    HStack(spacing: 6) {
                        Circle().fill(colors[index]).frame(width: 7, height: 7)
                        Text(labels[index]).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(TimeReport.hours(hours)).monospacedDigit()
                    }
                    .font(.caption.weight(name == segment ? .bold : .regular))
                    .foregroundStyle(segment == nil || name == segment ? Color.primary : Color.secondary)
                }
            }
            if day.hours.isEmpty { Text("Nothing recorded").font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Text("Free")
                Spacer(minLength: 12)
                Text(TimeReport.hours(day.free)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

private struct Tile: View {
    let title: String
    let value: String
    let note: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value).font(.title.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Rows of "name ........ 6.5h" with a bar for the share of the biggest.
private struct Breakdown: View {
    let title: String
    let rows: [(name: String, hours: Double, color: Color)]

    /// Room for "Chapter Events - Mason Kimball – Calendar" on the Mac; a phone has less.
    #if os(macOS)
    static let nameWidth: CGFloat = 320
    #else
    static let nameWidth: CGFloat = 150
    #endif

    var body: some View {
        let most = rows.map(\.hours).max() ?? 1
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(rows, id: \.name) { row in
                HStack(spacing: 10) {
                    Circle().fill(row.color).frame(width: 8, height: 8)
                    Text(row.name).lineLimit(1).frame(width: Self.nameWidth, alignment: .leading)
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 3).fill(row.color.opacity(0.75))
                            .frame(width: max(geometry.size.width * row.hours / most, 3))
                    }
                    .frame(height: 8)
                    Text(TimeReport.hours(row.hours)).font(.callout.monospacedDigit()).frame(width: 52, alignment: .trailing)
                }
            }
        }
    }
}

/// "Study, 10 to 11 PM": time spent that isn't on the calendar.
///
/// The day and the times are picked separately, so the time fields' arrows only
/// ever move hours and minutes. Length buttons set the end from the start, and
/// Ended Now fits the stretch to finish now.
struct LogActivitySheet: View {
    let store: CalendarStore
    @State private var name = ""
    @State private var day: Date
    @State private var from: Date
    @State private var to: Date
    @Environment(\.dismiss) private var dismiss

    private static let lengths: [(String, Int)] = [("30m", 30), ("45m", 45), ("1h", 60), ("1.5h", 90), ("2h", 120), ("3h", 180)]

    init(store: CalendarStore) {
        self.store = store
        let end = Self.roundedNow()
        _day = State(initialValue: Calendar.current.startOfDay(for: end))
        _to = State(initialValue: end)
        _from = State(initialValue: end.addingTimeInterval(-3600))
    }

    /// Now, to the nearest quarter hour.
    private static func roundedNow() -> Date {
        let quarter: TimeInterval = 15 * 60
        return Date(timeIntervalSinceReferenceDate: (Date.now.timeIntervalSinceReferenceDate / quarter).rounded() * quarter)
    }

    /// The picked day with a picked time's hour and minute.
    private func on(_ day: Date, at time: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: day) ?? day
    }

    /// The stretch to log: an end before the start means it ran past midnight.
    private var interval: (start: Date, end: Date) {
        let start = on(day, at: from)
        var end = on(day, at: to)
        if end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: end)! }
        return (start, end)
    }

    private var minutes: Int { Int(interval.end.timeIntervalSince(interval.start) / 60) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What was it?", text: $name, prompt: Text("Study"))
                    let suggestions = store.loggedNames.filter { name.isEmpty || ($0.localizedCaseInsensitiveContains(name) && $0 != name) }
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(suggestions, id: \.self) { suggestion in
                                    Button(suggestion) { name = suggestion }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                Section("Day") {
                    let calendar = Calendar.current
                    let today = calendar.startOfDay(for: .now)
                    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
                    HStack {
                        Button("Today") { day = today }
                            .buttonStyle(.bordered)
                            .tint(calendar.isDate(day, inSameDayAs: today) ? .accentColor : nil)
                        Button("Yesterday") { day = yesterday }
                            .buttonStyle(.bordered)
                            .tint(calendar.isDate(day, inSameDayAs: yesterday) ? .accentColor : nil)
                        Spacer()
                        DatePicker("Day", selection: $day, in: ...today, displayedComponents: .date)
                            .labelsHidden()
                    }
                }

                Section {
                    // Times only: their arrows change hours and minutes, never the day.
                    // Moving the start keeps the length: the end moves with it.
                    DatePicker("From", selection: Binding(get: { from }, set: { new in
                        to = to.addingTimeInterval(new.timeIntervalSince(from))
                        from = new
                    }), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: $to, displayedComponents: .hourAndMinute)
                    HStack(spacing: 6) {
                        ForEach(Self.lengths, id: \.1) { label, length in
                            Button(label) { to = from.addingTimeInterval(Double(length) * 60) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(minutes == length ? .accentColor : nil)
                        }
                        Spacer()
                        Button("Ended Now") {
                            // Keep the length; finish now (to the quarter hour), today.
                            let length = Double(minutes) * 60
                            let end = Self.roundedNow()
                            day = Calendar.current.startOfDay(for: end.addingTimeInterval(-length))
                            to = end
                            from = end.addingTimeInterval(-length)
                        }
                        .controlSize(.small)
                    }
                } header: {
                    Text("Time")
                } footer: {
                    let (start, end) = interval
                    let crosses = !Calendar.current.isDate(start, inSameDayAs: end)
                    Text("\(start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) \u{2013} \(end.formatted(date: .omitted, time: .shortened))\(crosses ? " the next day" : "") \u{00B7} \(TimeReport.hours(Double(minutes) / 60))")
                }

                Section {
                } footer: {
                    Text("Saved to a Time Log calendar in iCloud, so it\u{2019}s on your calendar too and counts in the weekly recap under its name.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Log Activity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        let (start, end) = interval
                        if store.logActivity(name, from: start, to: end) { dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || minutes < 1)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 470)
        #endif
    }
}
