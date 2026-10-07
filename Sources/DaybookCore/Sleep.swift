import Foundation

/// Sleep, from Apple Health (where Garmin Connect, an Apple Watch or a sleep
/// app writes it). The iPhone app reads Health's samples, turns them into
/// nights here, and shares the nights with the Mac through Daybook's hidden
/// Reminders list, since Health's data stays on the iPhone.
public enum Sleep {
    /// One stretch Health recorded: asleep (any stage) or just in bed.
    public struct Sample: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public let asleep: Bool

        public init(start: Date, end: Date, asleep: Bool) {
            self.start = start
            self.end = end
            self.asleep = asleep
        }
    }

    /// A night: when sleep started and ended, and how long was actually asleep
    /// (wake-ups in the middle don't count).
    public struct Night: Codable, Sendable, Equatable, Identifiable {
        public let start: Date
        public let end: Date
        public let asleep: TimeInterval
        public var id: Date { start }

        public init(start: Date, end: Date, asleep: TimeInterval) {
            self.start = start
            self.end = end
            self.asleep = asleep
        }
    }

    /// Groups samples into nights: asleep stretches less than `gap` apart are
    /// the same night. In-bed samples only count for a night with no asleep
    /// samples at all (some trackers write only those). Naps under an hour of
    /// sleep are left out; they'd make a "night" in the middle of the afternoon.
    public static func nights(_ samples: [Sample], gap: TimeInterval = 2 * 3600, minimum: TimeInterval = 3600) -> [Night] {
        let asleep = samples.filter(\.asleep)
        let used = asleep.isEmpty ? samples : asleep
        var nights: [Night] = []
        var group: [Sample] = []
        var groupEnd = Date.distantPast
        func close() {
            guard let first = group.first else { return }
            let total = covered(group)
            if total >= minimum {
                nights.append(Night(start: first.start, end: group.map(\.end).max()!, asleep: total))
            }
            group = []
        }
        for sample in used.sorted(by: { $0.start < $1.start }) where sample.end > sample.start {
            if !group.isEmpty, sample.start.timeIntervalSince(groupEnd) > gap { close() }
            group.append(sample)
            groupEnd = max(groupEnd, sample.end)
        }
        close()
        return nights
    }

    /// Time covered by samples, counting overlaps (two sources for one night) once.
    static func covered(_ samples: [Sample]) -> TimeInterval {
        var total: TimeInterval = 0
        var cursor = Date.distantPast
        for sample in samples.sorted(by: { $0.start < $1.start }) {
            let start = max(sample.start, cursor)
            if sample.end > start {
                total += sample.end.timeIntervalSince(start)
                cursor = sample.end
            }
        }
        return total
    }

    // MARK: Sharing with the Mac

    public static func encode(_ nights: [Night]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(nights)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    public static func decode(_ text: String) -> [Night] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Night].self, from: Data(text.utf8))) ?? []
    }
}
