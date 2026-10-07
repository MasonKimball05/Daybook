import Foundation

/// What a reminder in the hidden Daybook list stands for. Daybook keeps two kinds
/// there, both completed (so Reminders hides them) and both synced by iCloud:
/// done marks for calendar events, and the morning brief for the iPhone.
/// (`ready` was a "brief is ready" reminder an earlier version used as the
/// notification; it's only read now, to clean those up.)
public enum DaybookMarker: Equatable, Sendable {
    case done(eventID: String)
    case brief(date: String) // "2026-10-07"
    case ready(date: String)
    /// An event's priority (calendar events have none of their own).
    case priority(eventID: String, level: Int)

    public var url: URL {
        var components = URLComponents()
        components.scheme = "daybook"
        switch self {
        case .done(let eventID):
            components.host = "done"
            components.queryItems = [URLQueryItem(name: "event", value: eventID)]
        case .brief(let date):
            components.host = "brief"
            components.queryItems = [URLQueryItem(name: "date", value: date)]
        case .ready(let date):
            components.host = "ready"
            components.queryItems = [URLQueryItem(name: "date", value: date)]
        case .priority(let eventID, let level):
            components.host = "priority"
            components.queryItems = [URLQueryItem(name: "event", value: eventID), URLQueryItem(name: "level", value: String(level))]
        }
        return components.url!
    }

    public init?(_ url: URL?) {
        guard let url, url.scheme == "daybook",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host() {
        case "done": guard let id = value("event") else { return nil }; self = .done(eventID: id)
        case "brief": guard let date = value("date") else { return nil }; self = .brief(date: date)
        case "ready": guard let date = value("date") else { return nil }; self = .ready(date: date)
        case "priority":
            guard let id = value("event"), let level = value("level").flatMap(Int.init) else { return nil }
            self = .priority(eventID: id, level: level)
        default: return nil
        }
    }

    /// Reads a reminder's marker from its URL or, failing that, the first line of
    /// its notes. Exchange (Samford) drops a reminder's URL when it syncs; notes survive.
    public init?(url: URL?, notes: String?) {
        if let marker = Self(url) {
            self = marker
            return
        }
        guard let first = notes?.split(separator: "\n", maxSplits: 1).first,
              let marker = Self(URL(string: first.trimmingCharacters(in: .whitespaces))) else { return nil }
        self = marker
    }
}

/// The morning brief as it's stored on a reminder: the marker on the first line,
/// a blank line, then the brief as Markdown.
public enum BriefNote {
    public static func compose(date: String, markdown: String) -> String {
        DaybookMarker.brief(date: date).url.absoluteString + "\n\n" + markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func body(_ notes: String?) -> String {
        guard let notes, let split = notes.firstIndex(of: "\n") else { return "" }
        return notes[split...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "2026-10-07" for a date, in the local time zone.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

/// Just enough Markdown for the brief: headings, bullet and numbered lists, and
/// paragraphs. Bold, italics and links inside a line are left for the view.
public enum BriefMarkdown {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case bullet(String)
        case numbered(Int, String)
        case paragraph(String)
    }

    /// The Sunday preview starts "# Your week ahead"; the daily brief doesn't.
    public static func isWeekly(_ text: String) -> Bool {
        guard case .heading(_, let title)? = blocks(text).first else { return false }
        return title.localizedCaseInsensitiveContains("week ahead")
    }

    public static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.wholeMatch(of: /[-*_]{3,}/) != nil {
                flush()
            } else if let match = line.wholeMatch(of: /(#{1,6})\s+(.+)/) {
                flush()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
            } else if let match = line.wholeMatch(of: /[-*•]\s+(.+)/) {
                flush()
                blocks.append(.bullet(String(match.1)))
            } else if let match = line.wholeMatch(of: /(\d+)[.)]\s+(.+)/) {
                flush()
                blocks.append(.numbered(Int(match.1) ?? 1, String(match.2)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}
