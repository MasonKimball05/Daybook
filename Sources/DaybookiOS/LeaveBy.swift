import CoreLocation
import DaybookCore
import Foundation
import MapKit
import UserNotifications

/// "Leave by 1:35 for Interview, 18 min drive": travel time from Apple Maps to
/// events with a place in the next 12 hours, as an alert at the time to go.
@MainActor
enum LeaveBy {
    private static let manager = CLLocationManager()
    /// Travel times by event, kept half an hour so refreshes don't keep asking Maps.
    private static var cache: [String: (minutes: Int, at: Date)] = [:]

    static func authorize() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    static var allowed: Bool { [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) }

    /// Minutes to get to the event's place from here, or nil when there's no place,
    /// it's a video call, Maps can't find it, or location isn't allowed.
    static func travelMinutes(to item: AgendaItem, walking: Bool) async -> Int? {
        guard allowed, let place = item.place, !place.contains("http"),
              MeetingLink.find(in: [item.location]) == nil else { return nil }
        let key = "\(item.id)|\(walking)"
        if let hit = cache[key], hit.at.timeIntervalSinceNow > -1800 { return hit.minutes }

        let search = MKLocalSearch.Request()
        search.naturalLanguageQuery = place
        if let here = manager.location {
            search.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        guard let destination = try? await MKLocalSearch(request: search).start().mapItems.first else { return nil }
        let request = MKDirections.Request()
        request.source = .forCurrentLocation()
        request.destination = destination
        request.transportType = walking ? .walking : .automobile
        guard let eta = try? await MKDirections(request: request).calculateETA() else { return nil }
        let minutes = Int((eta.expectedTravelTime / 60).rounded(.up))
        cache[key] = (minutes, .now)
        return minutes
    }

    /// Part of AlertScheduler's rebuild: one "leave by" alert per nearby event.
    static func schedule(_ store: CalendarStore, settings: AlertSettings) async {
        guard settings.leaveBy, allowed else { return }
        let now = Date.now
        let soon = store.events
            .filter { !$0.isAllDay && $0.start > now && $0.start < now.addingTimeInterval(12 * 3600) && $0.place != nil && !store.isDone($0) }
            .sorted { $0.start < $1.start }
            .prefix(5)
        let center = UNUserNotificationCenter.current()
        for item in soon {
            // Under a few minutes away means already there.
            guard let minutes = await travelMinutes(to: item, walking: settings.walking), minutes >= 3 else { continue }
            let leave = item.start.addingTimeInterval(-Double(minutes + settings.leaveBuffer) * 60)
            guard leave > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Leave by \(leave.formatted(date: .omitted, time: .shortened)) for \(item.title)"
            content.body = "\(minutes) min \(settings.walking ? "walk" : "drive") to \(item.place ?? "")"
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: leave), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "alert-leave-\(item.id)", content: content, trigger: trigger))
        }
    }
}
