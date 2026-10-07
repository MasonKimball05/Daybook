import Foundation

/// The open stretches in a day: the gaps between timed events, inside waking
/// hours, long enough to use. All-day items (deadlines, birthdays) don't block time.
public enum FreeTime {
    public static func blocks(on day: Date, events: [AgendaItem], now: Date = .now,
                              from startHour: Int = 8, to endHour: Int = 22,
                              minimum: TimeInterval = 30 * 60, calendar: Calendar = .current) -> [DateInterval] {
        guard var windowStart = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day),
              let windowEnd = calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: day) else { return [] }
        // Today, time already gone isn't free. Start at the next five minutes.
        if now > windowStart {
            let next = ceil(now.timeIntervalSinceReferenceDate / 300) * 300
            windowStart = Date(timeIntervalSinceReferenceDate: next)
        }
        guard windowStart < windowEnd else { return [] }

        let busy = events.filter { !$0.isAllDay && $0.end > windowStart && $0.start < windowEnd }
            .sorted { $0.start < $1.start }
        var blocks: [DateInterval] = []
        var cursor = windowStart
        for event in busy {
            if event.start.timeIntervalSince(cursor) >= minimum {
                blocks.append(DateInterval(start: cursor, end: event.start))
            }
            cursor = max(cursor, event.end) // overlapping events just extend the busy stretch
        }
        if windowEnd.timeIntervalSince(cursor) >= minimum {
            blocks.append(DateInterval(start: cursor, end: windowEnd))
        }
        return blocks
    }

    /// "2h 30m", "45m"
    public static func length(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
