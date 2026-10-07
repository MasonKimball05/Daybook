import Foundation

/// The days shown in a month view: whole weeks, Sunday first, from the week the
/// month starts in to the week it ends in (so 4 to 6 rows), like Calendar's grid.
public struct MonthGrid: Sendable {
    public let month: Date      // first day of the month
    public let weeks: [[Date]]  // each week: 7 start-of-day dates

    public init(containing date: Date, calendar: Calendar = .current) {
        var cal = calendar
        cal.firstWeekday = 1 // Sunday, as in the US
        let first = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        let dayCount = cal.range(of: .day, in: .month, for: first)!.count
        let last = cal.date(byAdding: .day, value: dayCount - 1, to: first)!
        let gridStart = cal.date(byAdding: .day, value: -(cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7, to: first)!
        var weeks: [[Date]] = []
        var day = gridStart
        while day <= last {
            weeks.append((0..<7).map { cal.date(byAdding: .day, value: $0, to: day)! })
            day = cal.date(byAdding: .day, value: 7, to: day)!
        }
        self.month = first
        self.weeks = weeks
    }

    /// The first and last instant on the grid, for fetching its events.
    public var range: (start: Date, end: Date) {
        let start = weeks.first!.first!
        let end = Calendar.current.date(byAdding: .day, value: 1, to: weeks.last!.last!)!
        return (start, end)
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(date, equalTo: month, toGranularity: .month)
    }
}
