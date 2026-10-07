import CoreGraphics
import DaybookCore
@preconcurrency import EventKit
import SwiftUI

/// EventKit objects to Daybook's plain values. Shared by the apps and the iPhone
/// widget (which can't use CalendarStore: it runs in its own small process).
enum EKConvert {
    static func item(_ event: EKEvent) -> AgendaItem {
        // calendarItemExternalIdentifier is the server's id, the same on the Mac and
        // the iPhone (eventIdentifier is per device). A repeating event shares it
        // across occurrences, so the start time tells them apart.
        let base = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString
        let id = base + "@" + String(Int(event.startDate.timeIntervalSince1970))
        return AgendaItem(id: id, title: event.title ?? "Untitled", start: event.startDate, end: event.endDate,
                          isAllDay: event.isAllDay, calendar: event.calendar?.title ?? "", color: hex(event.calendar?.cgColor),
                          location: event.location, url: event.url)
    }

    static func task(_ reminder: EKReminder) -> TaskItem {
        let components = reminder.dueDateComponents
        return TaskItem(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Untitled",
                        due: components.flatMap { Calendar.current.date(from: $0) },
                        dueHasTime: components?.hour != nil, list: reminder.calendar?.title ?? "Reminders",
                        isCompleted: reminder.isCompleted, priority: Priority(reminderPriority: reminder.priority),
                        repeats: reminder.hasRecurrenceRules)
    }

    static func hex(_ color: CGColor?) -> String {
        guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components, c.count >= 3 else { return "#888888" }
        return String(format: "#%02X%02X%02X", Int(c[0] * 255), Int(c[1] * 255), Int(c[2] * 255))
    }}

extension Color {
    /// "#RRGGBB" from CalendarStore.hex.
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0x888888
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
