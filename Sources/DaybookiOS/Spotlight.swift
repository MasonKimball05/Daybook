@preconcurrency import CoreSpotlight
import DaybookCore
import Foundation
import UniformTypeIdentifiers

/// Events and open tasks in Spotlight, so searching from the home screen finds
/// them. Only what Daybook shows: events on visible calendars, from yesterday to
/// two months ahead. Tapping one opens Daybook's search on it.
@MainActor
enum Spotlight {
    /// What was indexed last, so a refresh that changed nothing doesn't index again.
    private static var indexed: Int?

    static func index(_ store: CalendarStore) {
        var items: [CSSearchableItem] = store.events.map { event in
            let about = CSSearchableItemAttributeSet(contentType: .content)
            about.title = event.title
            // Spotlight shows the time and place itself, from the dates and location.
            about.contentDescription = event.calendar
            about.startDate = event.start
            about.endDate = event.end
            about.namedLocation = event.place
            return CSSearchableItem(uniqueIdentifier: "event:" + event.id, domainIdentifier: "events", attributeSet: about)
        }
        items += store.tasks.map { task in
            let about = CSSearchableItemAttributeSet(contentType: .content)
            about.title = task.title
            about.contentDescription = ["Task", task.due.map { "due " + $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }, task.list]
                .compactMap { $0 }.joined(separator: " \u{00B7} ")
            about.dueDate = task.due
            return CSSearchableItem(uniqueIdentifier: "task:" + task.id, domainIdentifier: "tasks", attributeSet: about)
        }

        var hasher = Hasher()
        for item in items {
            hasher.combine(item.uniqueIdentifier)
            hasher.combine(item.attributeSet.title)
            hasher.combine(item.attributeSet.contentDescription)
        }
        let fingerprint = hasher.finalize()
        guard fingerprint != indexed else { return }
        indexed = fingerprint

        // Start over each time, so deleted and past things drop out.
        let index = CSSearchableIndex.default()
        let all = items
        Task {
            try? await index.deleteAllSearchableItems()
            try? await index.indexSearchableItems(all)
        }
    }

    /// The title of the event or task a Spotlight result was for, to search for in Daybook.
    static func title(for identifier: String, in store: CalendarStore) -> String? {
        if identifier.hasPrefix("event:") {
            return store.events.first { "event:" + $0.id == identifier }?.title
        }
        return store.tasks.first { "task:" + $0.id == identifier }?.title
    }
}
