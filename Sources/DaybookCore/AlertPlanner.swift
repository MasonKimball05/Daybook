import Foundation

/// Which alerts each priority gets. Saved per device: the iPhone and the Mac
/// each decide whether to alert, so they don't double up.
public struct AlertSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// High and urgent: one alert per entry, in minutes before (0 is "at the time").
    public var importantOffsets: [Int]
    /// Everything else: one alert, or nil for none.
    public var normalTaskOffset: Int?
    public var normalEventOffset: Int?
    /// Urgent tasks keep alerting this often after they're due, until checked off.
    public var urgentRepeatMinutes: Int?
    public var urgentRepeatCount: Int
    /// The hour used for all-day events and tasks with a day but no time.
    public var allDayHour: Int
    /// iPhone only: "leave by" alerts for events with a place, from travel time.
    public var leaveBy: Bool
    public var leaveBuffer: Int  // extra minutes on top of the travel time
    public var walking: Bool     // walking times instead of driving

    public init(enabled: Bool, importantOffsets: [Int] = [1440, 60, 15, 0], normalTaskOffset: Int? = 0,
                normalEventOffset: Int? = 15, urgentRepeatMinutes: Int? = 15, urgentRepeatCount: Int = 4, allDayHour: Int = 9,
                leaveBy: Bool = true, leaveBuffer: Int = 5, walking: Bool = false) {
        self.enabled = enabled
        self.importantOffsets = importantOffsets
        self.normalTaskOffset = normalTaskOffset
        self.normalEventOffset = normalEventOffset
        self.urgentRepeatMinutes = urgentRepeatMinutes
        self.urgentRepeatCount = urgentRepeatCount
        self.allDayHour = allDayHour
        self.leaveBy = leaveBy
        self.leaveBuffer = leaveBuffer
        self.walking = walking
    }

    /// Settings saved by an older version lack newer fields; those get their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertSettings(enabled: true)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        importantOffsets = try c.decodeIfPresent([Int].self, forKey: .importantOffsets) ?? d.importantOffsets
        normalTaskOffset = try c.decodeIfPresent(Int.self, forKey: .normalTaskOffset)
        normalEventOffset = try c.decodeIfPresent(Int.self, forKey: .normalEventOffset)
        urgentRepeatMinutes = try c.decodeIfPresent(Int.self, forKey: .urgentRepeatMinutes)
        urgentRepeatCount = try c.decodeIfPresent(Int.self, forKey: .urgentRepeatCount) ?? d.urgentRepeatCount
        allDayHour = try c.decodeIfPresent(Int.self, forKey: .allDayHour) ?? d.allDayHour
        leaveBy = try c.decodeIfPresent(Bool.self, forKey: .leaveBy) ?? d.leaveBy
        leaveBuffer = try c.decodeIfPresent(Int.self, forKey: .leaveBuffer) ?? d.leaveBuffer
        walking = try c.decodeIfPresent(Bool.self, forKey: .walking) ?? d.walking
    }

    /// The choices offered for "how long before".
    public static let offsetChoices = [10080, 2880, 1440, 180, 60, 30, 15, 5, 0]

    public static func describe(_ minutes: Int) -> String {
        switch minutes {
        case 0: "At the time"
        case let m where m % 10080 == 0: m == 10080 ? "1 week before" : "\(m / 10080) weeks before"
        case let m where m % 1440 == 0: m == 1440 ? "1 day before" : "\(m / 1440) days before"
        case let m where m % 60 == 0: m == 60 ? "1 hour before" : "\(m / 60) hours before"
        default: "\(minutes) minutes before"
        }
    }
}

public struct PlannedAlert: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let date: Date
}

/// Turns tasks and events into the notifications to schedule.
public enum AlertPlanner {
    public struct Event: Sendable {
        public let item: AgendaItem
        public let priority: Priority
        public init(_ item: AgendaItem, priority: Priority) {
            self.item = item
            self.priority = priority
        }
    }

    /// Alerts from now through `days` ahead, soonest first, at most `limit`
    /// (iOS keeps only 64 waiting notifications per app).
    public static func plan(events: [Event], tasks: [TaskItem], settings: AlertSettings, now: Date,
                            days: Int = 14, limit: Int = 60, calendar: Calendar = .current) -> [PlannedAlert] {
        guard settings.enabled else { return [] }
        let horizon = calendar.date(byAdding: .day, value: days, to: now)!
        var alerts: [PlannedAlert] = []

        func add(id: String, title: String, priority: Priority, at time: Date, timed: Bool, offsets: [Int], label: (Int) -> String) {
            for offset in Set(offsets) {
                let fire = time.addingTimeInterval(-Double(offset) * 60)
                guard fire > now, fire < horizon else { continue }
                alerts.append(PlannedAlert(id: "alert-\(id)-\(offset)", title: Self.title(title, priority),
                                           body: label(offset), date: fire))
            }
        }

        for event in events {
            let item = event.item
            let time = item.isAllDay ? calendar.date(bySettingHour: settings.allDayHour, minute: 0, second: 0, of: item.start)! : item.start
            let offsets = event.priority.isImportant ? settings.importantOffsets : settings.normalEventOffset.map { [$0] } ?? []
            let clock = item.start.formatted(date: .omitted, time: .shortened)
            add(id: item.id, title: item.title, priority: event.priority, at: time, timed: !item.isAllDay, offsets: offsets) { offset in
                if item.isAllDay { return offset == 0 ? "Today" : "\(Self.lead(offset)) \u{00B7} all day" }
                return offset == 0 ? "Starting now \u{00B7} \(clock)" : "In \(Self.lead(offset)) \u{00B7} \(clock)"
            }
        }

        for task in tasks where !task.isCompleted {
            guard let due = task.due else { continue }
            let time = task.dueHasTime ? due : calendar.date(bySettingHour: settings.allDayHour, minute: 0, second: 0, of: due)!
            let offsets = task.priority.isImportant ? settings.importantOffsets : settings.normalTaskOffset.map { [$0] } ?? []
            add(id: task.id, title: task.title, priority: task.priority, at: time, timed: task.dueHasTime, offsets: offsets) { offset in
                offset == 0 ? "Due now" : "Due in \(Self.lead(offset))"
            }
            // Urgent: keep at it after the due time until it's checked off.
            if task.priority == .urgent, let every = settings.urgentRepeatMinutes, every > 0 {
                for n in 1...max(settings.urgentRepeatCount, 1) {
                    let fire = time.addingTimeInterval(Double(n * every) * 60)
                    guard fire > now, fire < horizon else { continue }
                    alerts.append(PlannedAlert(id: "alert-\(task.id)-late\(n)", title: Self.title(task.title, .urgent),
                                               body: "Still not done \u{00B7} was due \(FreeTime.length(Double(n * every) * 60)) ago", date: fire))
                }
            }
        }
        return Array(alerts.sorted { $0.date < $1.date }.prefix(limit))
    }

    static func title(_ title: String, _ priority: Priority) -> String {
        switch priority {
        case .urgent: "Urgent: \(title)"
        case .high: "High: \(title)"
        default: title
        }
    }

    /// "1 day", "2 hours", "15 minutes"
    static func lead(_ minutes: Int) -> String {
        AlertSettings.describe(minutes).replacingOccurrences(of: " before", with: "")
    }
}
