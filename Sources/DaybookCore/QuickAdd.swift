import Foundation

/// Turns typed text into a task: "submit SOP friday 3pm" becomes the task
/// "submit SOP", due Friday at 3:00 PM. The date is found with NSDataDetector,
/// the same parser Mail and Messages use, then cut out of the title.
public enum QuickAdd {
    public struct Parsed: Equatable, Sendable {
        public let title: String
        public let due: Date?
        public let hasTime: Bool
    }

    public static func parse(_ text: String, now: Date = .now) -> Parsed {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
              let date = match.date, let range = Range(match.range, in: trimmed) else {
            return Parsed(title: trimmed, due: nil, hasTime: false)
        }
        var title = trimmed
        title.removeSubrange(range)
        // Tidy what's left: "submit SOP by" -> "submit SOP".
        title = title.trimmingCharacters(in: .whitespaces)
        for word in [" by", " on", " at", " due"] where title.lowercased().hasSuffix(word) {
            title = String(title.dropLast(word.count))
        }
        title = title.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        // NSDataDetector reports a time of noon for a bare day ("friday"); a time was
        // typed only if the matched text has digits with am/pm/":" or words like noon.
        let matched = trimmed[range].lowercased()
        let hasTime = matched.range(of: #"\d\s*(am|pm|a\.m\.|p\.m\.)|\d:\d\d|noon|midnight"#, options: .regularExpression) != nil
        guard !title.isEmpty else { return Parsed(title: trimmed, due: nil, hasTime: false) }
        return Parsed(title: title, due: date, hasTime: hasTime)
    }
}
