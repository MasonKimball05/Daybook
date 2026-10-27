import ActivityKit
import DaybookCore
import Foundation

/// The Live Activity: the next event on the lock screen and in the Dynamic Island,
/// from two hours before it until it ends, with "leave by" when it has a place.
/// Kept in step after every refresh (opening the app, or iOS waking it in the
/// background), so it can trail a change made elsewhere until the next one.
@MainActor
enum NextUp {
    /// How long before an event its Live Activity starts.
    static let lead: TimeInterval = 2 * 3600

    static func refresh(_ store: CalendarStore) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let now = Date.now
        let next = store.events
            .filter { !$0.isAllDay && $0.end > now && $0.start < now.addingTimeInterval(lead) && !store.isDone($0) }
            .min { $0.start < $1.start }
        if let next {
            await show(next.id, await state(for: next))
        } else {
            await show(nil, nil)
        }
    }

    /// Ends any other event's Live Activity, then starts or updates this one's (or
    /// ends them all for none). Off the main actor, where ActivityKit's objects live.
    nonisolated private static func show(_ eventID: String?, _ state: NextEventAttributes.ContentState?) async {
        let running = Activity<NextEventAttributes>.activities
        for activity in running where activity.attributes.eventID != eventID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard let eventID, let state else { return }
        let content = ActivityContent(state: state, staleDate: state.end)
        if let current = running.first(where: { $0.attributes.eventID == eventID }) {
            await current.update(content)
        } else {
            _ = try? Activity.request(attributes: NextEventAttributes(eventID: eventID), content: content)
        }
    }

    private static func state(for item: AgendaItem) async -> NextEventAttributes.ContentState {
        var state = NextEventAttributes.ContentState(title: item.title, start: item.start, end: item.end,
                                                     place: item.place, color: item.color)
        let settings = AlertScheduler.settings
        // Same travel time as the leave-by alert; a few minutes away means already there.
        if settings.leaveBy, item.start > .now,
           let minutes = await LeaveBy.travelMinutes(to: item, walking: settings.walking), minutes >= 3 {
            state.leaveBy = item.start.addingTimeInterval(-Double(minutes + settings.leaveBuffer) * 60)
            state.travel = "\(minutes) min \(settings.walking ? "walk" : "drive")"
        }
        return state
    }
}
