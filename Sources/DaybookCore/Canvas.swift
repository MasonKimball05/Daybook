import Foundation

/// Canvas assignments, from Samford's Canvas calendar feed (subscribed in
/// Calendar), as Reminders tasks. Each feed item is an all-day event titled
/// "Lab 4 - MNIST digits [COSC490.01]" whose id is "event-assignment-<number>".
public enum Canvas {
    public struct Assignment: Equatable, Sendable {
        public let id: String       // the assignment number
        public let title: String    // "Lab 4 - MNIST digits"
        public let course: String   // "COSC 490"
        public let due: Date
        public let url: URL?

        /// Canvas's number for the course, from the feed link ("include_contexts=course_12345").
        public var courseID: String? {
            guard let link = url?.absoluteString, let match = link.firstMatch(of: #/course_(\d+)/#) else { return nil }
            return String(match.1)
        }

        /// The task's name: "COSC 490: Lab 4 - MNIST digits"
        public var taskTitle: String { course.isEmpty ? title : "\(course): \(title)" }
    }

    /// The assignment behind a feed event, or nil for anything else.
    public static func assignment(_ item: AgendaItem) -> Assignment? {
        guard let id = assignmentID(item.id) else { return nil }
        var title = item.title.trimmingCharacters(in: .whitespaces)
        var course = ""
        if let match = title.firstMatch(of: #/\s*\[([^\]]+)\]\s*$/#) {
            course = courseName(String(match.1))
            title = String(title[..<match.range.lowerBound])
        }
        return Assignment(id: id, title: title, course: course, due: item.start, url: item.url)
    }

    /// "event-assignment-123@1791349200" (Daybook's event id) -> "123"
    public static func assignmentID(_ eventID: String) -> String? {
        guard let match = eventID.firstMatch(of: #/^event-assignment-(\d+)/#) else { return nil }
        return String(match.1)
    }

    /// "COSC490.01" -> "COSC 490" (the section number is noise).
    public static func courseName(_ code: String) -> String {
        if let match = code.firstMatch(of: #/^([A-Za-z]+)\s*(\d+)/#) { return "\(match.1.uppercased()) \(match.2)" }
        return code
    }

    /// Canvas course numbers to course names, {"12345": "COSC 490"}, written to
    /// canvas-courses.json for sift (the file sorter), which sees course numbers
    /// in Canvas download links but not names.
    public static func courses(_ assignments: [Assignment]) -> [String: String] {
        var map: [String: String] = [:]
        for assignment in assignments where !assignment.course.isEmpty {
            if let id = assignment.courseID { map[id] = assignment.course }
        }
        return map
    }

    public static func writeCourses(_ map: [String: String], to folder: URL = DailySummary.folder) throws {
        guard !map.isEmpty else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(map).write(to: folder.appending(path: "canvas-courses.json"), options: .atomic)
    }

    /// What an existing task (found by its Canvas marker) looks like now.
    public struct Existing: Equatable, Sendable {
        public let reminderID: String
        public let title: String
        public let due: Date?
        public let isCompleted: Bool
        public init(reminderID: String, title: String, due: Date?, isCompleted: Bool) {
            self.reminderID = reminderID
            self.title = title
            self.due = due
            self.isCompleted = isCompleted
        }
    }

    public enum Change: Equatable, Sendable {
        case create(Assignment)
        case update(reminderID: String, Assignment)
    }

    /// New assignments due today or later become tasks; open tasks follow
    /// changes to the title or due date. Finished tasks, and past assignments
    /// that never had one, are left alone. Nothing is ever deleted.
    public static func changes(assignments: [Assignment], existing: [String: Existing], now: Date,
                               calendar: Calendar = .current) -> [Change] {
        let today = calendar.startOfDay(for: now)
        return assignments.compactMap { assignment in
            if let task = existing[assignment.id] {
                guard !task.isCompleted else { return nil }
                let sameDay = task.due.map { calendar.isDate($0, inSameDayAs: assignment.due) } ?? false
                return task.title == assignment.taskTitle && sameDay ? nil : .update(reminderID: task.reminderID, assignment)
            }
            return assignment.due >= today ? .create(assignment) : nil
        }
    }
}
