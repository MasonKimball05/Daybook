import DaybookCore
import Foundation
import UserNotifications

/// Schedules Daybook's own alerts for tasks and events, by priority (see
/// AlertPlanner). Rebuilt after every refresh, so a change made anywhere is
/// picked up the next time this device's Daybook runs.
@MainActor
enum AlertScheduler {
    /// On by default on the iPhone; off on the Mac, so the two don't double up.
    static var settings: AlertSettings {
        get {
            if let data = UserDefaults.standard.data(forKey: "alertSettings"),
               let saved = try? JSONDecoder().decode(AlertSettings.self, from: data) { return saved }
            #if os(iOS)
            return AlertSettings(enabled: true)
            #else
            return AlertSettings(enabled: false)
            #endif
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "alertSettings") }
    }

    static func reschedule(_ store: CalendarStore) async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("alert-") }
        center.removePendingNotificationRequests(withIdentifiers: old)
        let settings = settings
        guard settings.enabled else { return }
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        let events = store.events.filter { !store.isDone($0) }.map { AlertPlanner.Event($0, priority: store.priority(of: $0)) }
        // 50 of iOS's 64 slots, leaving room for the brief's notifications.
        let calendar = Calendar.current
        for alert in AlertPlanner.plan(events: events, tasks: store.tasks, settings: settings, now: .now, limit: 50) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: alert.date), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger))
        }
        #if os(iOS)
        await LeaveBy.schedule(store, settings: settings)
        #endif
    }
}
