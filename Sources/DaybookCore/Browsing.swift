import Foundation

/// Time in Eclipse (the browser, github.com/MasonKimball05/PythonBrowser), a day
/// at a time: how long in each of its Spaces and on each site. Eclipse counts
/// only while you're using it (its window in front, and not idle) and writes
/// browsing.json in Daybook's folder once a minute; Daybook only reads it, on the Mac.
public struct Browsing: Codable, Sendable, Equatable {
    public struct Space: Codable, Sendable, Equatable {
        public let name: String
        public let seconds: Double
    }

    public struct Site: Codable, Sendable, Equatable {
        public let host: String     // "github.com", without the www
        public let seconds: Double
    }

    public struct Day: Codable, Sendable, Equatable {
        public let date: String     // "2026-10-27", the local day
        public let seconds: Double
        public let spaces: [Space]  // biggest first
        public let sites: [Site]    // biggest first, the busiest 40

        public init(date: String, seconds: Double, spaces: [Space], sites: [Site]) {
            self.date = date
            self.seconds = seconds
            self.spaces = spaces
            self.sites = sites
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(String.self, forKey: .date)
            seconds = try c.decode(Double.self, forKey: .seconds)
            spaces = try c.decodeIfPresent([Space].self, forKey: .spaces) ?? []
            sites = try c.decodeIfPresent([Site].self, forKey: .sites) ?? []
        }
    }

    public let days: [Day]          // newest first, the last 35

    public init(days: [Day]) {
        self.days = days
    }

    /// "2026-10-27" for a date, as Eclipse names its days.
    static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func day(_ date: Date, calendar: Calendar = .current) -> Day? {
        let key = Self.key(date, calendar: calendar)
        return days.first { $0.date == key }
    }

    /// Hours over a stretch of days: in all, by Space and by site (biggest first).
    public struct Summary: Sendable {
        public let hours: Double
        public let bySpace: [(name: String, hours: Double)]
        public let bySite: [(name: String, hours: Double)]
    }

    /// `count` days from `start`; nil when nothing was counted in them.
    public func summary(from start: Date, days count: Int, calendar: Calendar = .current) -> Summary? {
        let start = calendar.startOfDay(for: start)
        let days = (0..<count).compactMap { day(calendar.date(byAdding: .day, value: $0, to: start)!, calendar: calendar) }
        let total = days.map(\.seconds).reduce(0, +)
        guard total > 0 else { return nil }
        var spaces: [String: Double] = [:], sites: [String: Double] = [:]
        for day in days {
            for space in day.spaces { spaces[space.name.isEmpty ? "Unnamed Space" : space.name, default: 0] += space.seconds }
            for site in day.sites { sites[site.host, default: 0] += site.seconds }
        }
        func ranked(_ totals: [String: Double]) -> [(name: String, hours: Double)] {
            totals.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value / 3600) }
        }
        return Summary(hours: total / 3600, bySpace: ranked(spaces), bySite: ranked(sites))
    }

    public static func read(from folder: URL = DailySummary.folder) -> Browsing? {
        guard let data = try? Data(contentsOf: folder.appending(path: "browsing.json")) else { return nil }
        return try? JSONDecoder().decode(Browsing.self, from: data)
    }
}
