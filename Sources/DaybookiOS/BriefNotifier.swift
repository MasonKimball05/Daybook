import BackgroundTasks
import DaybookCore
import Foundation
import UserNotifications

/// Daybook's own "your brief is ready" notification on the iPhone. Without a paid
/// developer account nothing can wake the app the moment the Mac posts a brief,
/// so two things share the job:
///  - Background refresh: iOS wakes Daybook now and then (when is up to iOS); if a
///    new brief has arrived, Daybook says so right away.
///  - A backup at a set time, for days the refresh doesn't get a turn.
/// Whichever comes first cancels the other, and opening the brief cancels both.
@MainActor
enum BriefNotifier {
    static let refreshTask = "com.masonkimball.Daybook.refresh"

    /// When briefs arrive: the morning brief every day at 7:30, and the week-ahead
    /// preview on Sunday at 6 PM. Times are (hour, minute).
    struct Slot {
        let weekday: Int?              // 1 = Sunday; nil = every day
        let since: (Int, Int)          // a brief opened or announced after this counts
        let refreshFrom: (Int, Int)    // start looking
        let backup: (Int, Int)         // the backup notification
        let until: (Int, Int)          // stop looking
        let backupText: String
    }

    static let slots = [
        Slot(weekday: nil, since: (7, 0), refreshFrom: (7, 35), backup: (8, 0), until: (12, 0),
             backupText: "Today\u{2019}s brief should be ready. Tap to read it."),
        Slot(weekday: 1, since: (18, 0), refreshFrom: (18, 5), backup: (18, 30), until: (21, 0),
             backupText: "Your week-ahead preview should be ready. Tap to read it."),
    ]

    private static var center: UNUserNotificationCenter { .current() }
    private static var defaults: UserDefaults { .standard }
    private static var today: String { BriefNote.dayKey(.now) }

    static func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Today's newest brief, if it's one not yet opened. Tracked by posting, not by
    /// date, so a later brief the same day (a rerun, or Sunday's preview) still counts.
    static func unseen(_ store: CalendarStore) -> CalendarStore.PostedBrief? {
        guard let brief = store.brief, brief.date == today,
              defaults.string(forKey: "briefSeenVersion") != brief.version else { return nil }
        return brief
    }

    /// From a background refresh: announce a new brief, then line up what's next.
    static func check(_ store: CalendarStore) async {
        if let brief = unseen(store), defaults.string(forKey: "briefNotifiedVersion") != brief.version {
            let content = UNMutableNotificationContent()
            content.title = "Your brief is ready"
            content.body = headline(brief.markdown) ?? "Tap to read it."
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "brief-\(brief.version)", content: content, trigger: nil))
            defaults.set(brief.version, forKey: "briefNotifiedVersion")
            defaults.set(Date.now, forKey: "briefNotifiedAt")
        }
        await scheduleBackups()
        scheduleRefresh()
    }

    /// The brief was opened (as the popup, or from the list): clear its
    /// notification and the backup it would have needed.
    static func markSeen(_ brief: CalendarStore.PostedBrief) async {
        defaults.set(brief.version, forKey: "briefSeenVersion")
        defaults.set(Date.now, forKey: "briefSeenAt")
        center.removeAllDeliveredNotifications()
        await scheduleBackups()
    }

    /// A brief was opened or announced since this time.
    private static func handled(since: Date) -> Bool {
        let seen = defaults.object(forKey: "briefSeenAt") as? Date ?? .distantPast
        let notified = defaults.object(forKey: "briefNotifiedAt") as? Date ?? .distantPast
        return max(seen, notified) >= since
    }

    private static func at(_ time: (Int, Int), on day: Date) -> Date {
        Calendar.current.date(bySettingHour: time.0, minute: time.1, second: 0, of: day)!
    }

    private static func applies(_ slot: Slot, on day: Date) -> Bool {
        slot.weekday.map { Calendar.current.component(.weekday, from: day) == $0 } ?? true
    }

    /// Backups for the next week, minus any already handled. One-off notifications
    /// rather than repeating ones, since some days need skipping. Rebuilt each time.
    static func scheduleBackups() async {
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("backup-") }
        center.removePendingNotificationRequests(withIdentifiers: old)
        let calendar = Calendar.current
        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now))!
            for (index, slot) in slots.enumerated() where applies(slot, on: day) {
                let fire = at(slot.backup, on: day)
                guard fire > .now, !handled(since: at(slot.since, on: day)) else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Your brief"
                content.body = slot.backupText
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
                try? await center.add(UNNotificationRequest(identifier: "backup-\(BriefNote.dayKey(day))-\(index)",
                                                            content: content, trigger: trigger))
            }
        }
    }

    /// Asks iOS to wake Daybook to look for a brief: about every 15 minutes inside
    /// a slot's window until it turns up, otherwise at the start of the next window.
    /// iOS treats the time as "not before", and may run it later.
    static func scheduleRefresh() {
        let calendar = Calendar.current
        let now = Date.now
        var earliest: Date?
        for offset in 0...7 {
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
            for slot in slots where applies(slot, on: day) {
                let from = at(slot.refreshFrom, on: day), until = at(slot.until, on: day)
                let candidate: Date? = if now < from {
                    from
                } else if now < until && !handled(since: at(slot.since, on: day)) {
                    now.addingTimeInterval(15 * 60)
                } else {
                    nil
                }
                if let candidate, candidate < (earliest ?? .distantFuture) { earliest = candidate }
            }
            if earliest != nil { break }
        }
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The brief's first heading, without Markdown, for the notification text.
    private static func headline(_ markdown: String) -> String? {
        guard case .heading(_, let text)? = BriefMarkdown.blocks(markdown).first else { return nil }
        return String(BriefTextView.inline(text).characters)
    }
}
