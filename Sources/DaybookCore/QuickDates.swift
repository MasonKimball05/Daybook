import Foundation

/// The days offered for a task with one tap (the chips above the iPhone keyboard,
/// swiping a task to Tomorrow), and where the Now line goes in a day.
public enum QuickDates {
    /// Today, Tomorrow, This Weekend (Saturday, or today on a Saturday) and Next
    /// Week (the coming Monday), each at the start of its day.
    public static func choices(now: Date, calendar: Calendar = .current) -> [(name: String, day: Date)] {
        let today = calendar.startOfDay(for: now)
        let day = { (n: Int) in calendar.date(byAdding: .day, value: n, to: today)! }
        let saturday = calendar.nextDate(after: day(-1), matching: DateComponents(weekday: 7), matchingPolicy: .nextTime) ?? day(1)
        let monday = calendar.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? day(7)
        return [("Today", today), ("Tomorrow", day(1)), ("This Weekend", saturday), ("Next Week", monday)]
    }

    /// Tomorrow, at the same time of day when the task has one (and 9 AM if its
    /// time can't be read), or the start of tomorrow.
    public static func tomorrow(keeping due: Date?, hasTime: Bool, now: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        guard hasTime, let due else { return day }
        let time = calendar.dateComponents([.hour, .minute], from: due)
        return calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    /// Where the Now line goes among a day's rows, given when each starts (in
    /// order): after everything that has started, before everything that hasn't.
    public static func nowPosition(starts: [Date], now: Date) -> Int {
        starts.firstIndex { $0 > now } ?? starts.count
    }
}
