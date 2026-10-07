import Foundation

/// Coding work, for "where your time goes": commits from the repos on the Mac,
/// and pull requests, issues, reviews and comments from GitHub. Daybook gathers
/// them on the Mac (WorkCollector) and works out sessions and totals here.
public enum Work {
    public struct Commit: Codable, Hashable, Sendable, Identifiable {
        public let hash: String
        public let repo: String
        public let date: Date
        public let message: String
        /// From `git log --shortstat`; nil for a commit known only from GitHub.
        public let files: Int?
        public let insertions: Int?
        public let deletions: Int?

        public init(hash: String, repo: String, date: Date, message: String,
                    files: Int? = nil, insertions: Int? = nil, deletions: Int? = nil) {
            self.hash = hash
            self.repo = repo
            self.date = date
            self.message = message
            self.files = files
            self.insertions = insertions
            self.deletions = deletions
        }

        public var id: String { hash }
        /// The first 7 characters, as GitHub shows it.
        public var shortHash: String { String(hash.prefix(7)) }

        /// "+120 −8 · 3 files"
        public var changes: String? {
            guard let files else { return nil }
            return "+\(insertions ?? 0) \u{2212}\(deletions ?? 0) \u{00B7} \(files) file\(files == 1 ? "" : "s")"
        }
    }

    /// Commits from `git log --shortstat` run with the format
    /// "%x1e%H%x1f%at%x1f%an%x1f%ae%x1f%s": each commit starts with ASCII 30,
    /// then its fields split by ASCII 31, then (on later lines) a summary like
    /// " 3 files changed, 120 insertions(+), 8 deletions(-)". `isMine` gets the
    /// author's name and email and keeps only your commits.
    public static func parseGitLog(_ output: String, repo: String, isMine: (String, String) -> Bool) -> [Commit] {
        output.split(separator: "\u{1E}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let first = lines.first else { return nil }
            let f = first.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard f.count >= 5, let stamp = Double(f[1]), isMine(String(f[2]), String(f[3])) else { return nil }
            let stat = lines.dropFirst().joined(separator: " ")
            func number(_ pattern: Regex<(Substring, Substring)>) -> Int? {
                stat.firstMatch(of: pattern).flatMap { Int($0.1) }
            }
            let files = number(#/(\d+) files? changed/#)
            return Commit(hash: String(f[0]), repo: repo, date: Date(timeIntervalSince1970: stamp), message: String(f[4]),
                          files: files ?? 0,
                          insertions: number(#/(\d+) insertions?\(\+\)/#) ?? 0,
                          deletions: number(#/(\d+) deletions?\(-\)/#) ?? 0)
        }
    }

    /// A stretch of coding, worked out from commit times.
    public struct Session: Codable, Hashable, Sendable, Identifiable {
        public let start: Date
        public let end: Date
        public let repos: [String]    // most commits first
        public let items: [Commit]    // oldest first
        public var commits: Int { items.count }
        public var id: Date { start }
        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// Commits don't say how long the work took, so this estimates it the usual
    /// way: commits less than `gap` apart are one session, which starts `lead`
    /// before its first commit (the work that went into it) and ends at its last.
    public static func sessions(_ commits: [Commit], gap: TimeInterval = 2 * 3600, lead: TimeInterval = 30 * 60) -> [Session] {
        var sessions: [Session] = []
        var current: [Commit] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            let counts = Dictionary(grouping: current, by: \.repo).mapValues(\.count)
            let repos = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
            sessions.append(Session(start: first.date.addingTimeInterval(-lead), end: last.date, repos: repos, items: current))
            current = []
        }
        for commit in commits.sorted(by: { $0.date < $1.date }) {
            if let last = current.last, commit.date.timeIntervalSince(last.date) > gap { close() }
            current.append(commit)
        }
        close()
        return sessions
    }

    // MARK: GitHub

    public struct Activity: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case prOpened, prMerged, prClosed, issueOpened, issueClosed, review, comment, push
        }
        public let kind: Kind
        public let repo: String      // "gradtrack" (without the owner)
        public let title: String
        public let number: Int?
        public let date: Date
        public var id: String { "\(kind.rawValue)|\(repo)|\(number ?? 0)|\(date.timeIntervalSince1970)" }

        /// "Merged PR #12" and the like.
        public var label: String {
            let number = number.map { " #\($0)" } ?? ""
            switch kind {
            case .prOpened: return "Opened PR\(number)"
            case .prMerged: return "Merged PR\(number)"
            case .prClosed: return "Closed PR\(number)"
            case .issueOpened: return "Opened issue\(number)"
            case .issueClosed: return "Closed issue\(number)"
            case .review: return "Reviewed PR\(number)"
            case .comment: return "Commented on\(number)"
            case .push: return "Pushed"
            }
        }
    }

    /// GitHub's events API (`gh api /users/<you>/events`) as activities. Only the
    /// kinds that are work; stars, forks and branch housekeeping are left out.
    public static func activities(fromEvents data: Data) -> [Activity] {
        guard let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return events.compactMap { event -> Activity? in
            guard let type = event["type"] as? String,
                  let repoName = (event["repo"] as? [String: Any])?["name"] as? String,
                  let created = (event["created_at"] as? String).flatMap(iso.date(from:)),
                  let payload = event["payload"] as? [String: Any] else { return nil }
            let repo = repoName.split(separator: "/").last.map(String.init) ?? repoName
            let action = payload["action"] as? String
            func item(_ key: String) -> (String, Int?) {
                let object = payload[key] as? [String: Any]
                return (object?["title"] as? String ?? "", object?["number"] as? Int)
            }
            switch type {
            case "PullRequestEvent":
                let (title, number) = item("pull_request")
                // Newer events can leave out "merged"; a merge date says the same.
                let pr = payload["pull_request"] as? [String: Any]
                let merged = pr?["merged"] as? Bool == true || pr?["merged_at"] is String
                let kind: Activity.Kind? = switch action {
                case "opened", "reopened": .prOpened
                case "closed": merged ? .prMerged : .prClosed
                default: nil
                }
                return kind.map { Activity(kind: $0, repo: repo, title: title, number: number, date: created) }
            case "IssuesEvent":
                let (title, number) = item("issue")
                let kind: Activity.Kind? = switch action {
                case "opened", "reopened": .issueOpened
                case "closed": .issueClosed
                default: nil
                }
                return kind.map { Activity(kind: $0, repo: repo, title: title, number: number, date: created) }
            case "PullRequestReviewEvent":
                let (title, number) = item("pull_request")
                return Activity(kind: .review, repo: repo, title: title, number: number, date: created)
            case "IssueCommentEvent":
                let (title, number) = item("issue")
                return Activity(kind: .comment, repo: repo, title: title, number: number, date: created)
            case "PushEvent":
                return Activity(kind: .push, repo: repo, title: "", number: nil, date: created)
            default:
                return nil
            }
        }
    }

    // MARK: Saved snapshot

    /// What the Mac gathered, saved to work.json for the app and the briefs.
    public struct Snapshot: Codable, Sendable {
        public let gathered: Date
        public let commits: [Commit]
        public let activities: [Activity]
        public let problems: [String]

        public init(gathered: Date, commits: [Commit], activities: [Activity], problems: [String]) {
            self.gathered = gathered
            self.commits = commits
            self.activities = activities
            self.problems = problems
        }

        /// Sessions from local commits, plus pushes to repos that aren't on this
        /// Mac (each push standing in for the commits behind it).
        public var sessions: [Session] {
            let local = Set(commits.map(\.repo))
            let remote = activities.filter { $0.kind == .push && !local.contains($0.repo) }
                .map { Commit(hash: $0.id, repo: $0.repo, date: $0.date, message: "") }
            return Work.sessions(commits + remote)
        }

        /// One day's sessions (those starting that day) and GitHub activity (not pushes).
        public func day(_ date: Date, calendar: Calendar = .current) -> (sessions: [Session], activities: [Activity]) {
            (sessions.filter { calendar.isDate($0.start, inSameDayAs: date) || calendar.isDate($0.end, inSameDayAs: date) },
             activities.filter { $0.kind != .push && calendar.isDate($0.date, inSameDayAs: date) }.sorted { $0.date < $1.date })
        }

        /// Commits made on a day, for the month grid.
        public func commitCount(on date: Date, calendar: Calendar = .current) -> Int {
            commits.filter { calendar.isDate($0.date, inSameDayAs: date) }.count
        }

        // MARK: Sharing with the iPhone

        /// The last `days` days, trimmed for a reminder's notes: short hashes and
        /// first lines of commit messages. The whole file is ~90 KB; this, zipped, a few.
        public func trimmed(days: Int = 63, now: Date = .now) -> Snapshot {
            let since = now.addingTimeInterval(-Double(days) * 86400)
            let commits = commits.filter { $0.date >= since }.map {
                Commit(hash: $0.shortHash, repo: $0.repo, date: $0.date, message: String($0.message.prefix(80)),
                       files: $0.files, insertions: $0.insertions, deletions: $0.deletions)
            }
            return Snapshot(gathered: gathered, commits: commits, activities: activities.filter { $0.date >= since }, problems: [])
        }

        /// JSON, zlib-compressed, as base64 text (notes only hold text).
        public func encodedForSharing() -> String? {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let json = try? encoder.encode(self),
                  let zipped = try? (json as NSData).compressed(using: .zlib) else { return nil }
            return (zipped as Data).base64EncodedString()
        }

        public static func decodeShared(_ text: String) -> Snapshot? {
            guard let zipped = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let json = try? (zipped as NSData).decompressed(using: .zlib) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Snapshot.self, from: json as Data)
        }

        public static func read(from folder: URL = DailySummary.folder) -> Snapshot? {
            guard let data = try? Data(contentsOf: folder.appending(path: "work.json")) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Snapshot.self, from: data)
        }

        public func write(to folder: URL = DailySummary.folder) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: folder.appending(path: "work.json"), options: .atomic)
        }
    }
}

/// Where a stretch of days went: hours in calendar events by calendar, hours
/// logged by hand by what they were ("Study"), hours coding by repo, free
/// time, and what shipped on GitHub.
public struct TimeReport: Sendable {
    /// The calendar Daybook's "Log Activity" writes to. Its events count by
    /// their titles, not as one lump.
    public static let logCalendar = "Time Log"
    public static let coding = "Coding"
    public static let sleep = "Sleep"
    /// Waking hours, for free time.
    public static let dayStart = 8, dayEnd = 22

    public enum Kind: String, Sendable { case calendar, logged, coding, sleep }

    public struct Category: Sendable, Identifiable {
        public let name: String
        public let hours: Double
        public let kind: Kind
        public var id: String { name }

        /// What to call it on screen: a calendar says it's one ("Home – Calendar"),
        /// unless its name already does; coding, sleep and logged time keep their names.
        public var label: String { TimeReport.label(name, kind: kind) }
    }

    public static func label(_ name: String, kind: Kind) -> String {
        guard kind == .calendar, !name.localizedCaseInsensitiveContains("calendar") else { return name }
        return "\(name) \u{2013} Calendar"
    }

    public struct Day: Sendable, Identifiable {
        public let date: Date
        /// Hours by category name.
        public let hours: [String: Double]
        /// Waking hours with nothing in them: from waking to falling asleep when
        /// sleep is known, else 8 AM to 10 PM.
        public let free: Double
        /// Hours slept in the night that ended this day, if known.
        public let slept: Double?
        public var id: Date { date }
        public var total: Double { hours.values.reduce(0, +) }
    }

    public let start: Date
    public let days: [Day]
    public let categories: [Category]                       // biggest first
    public let byRepo: [(name: String, hours: Double)]
    public let free: Double
    public let commits: Int
    public let activities: [Work.Activity]                  // not pushes, newest first

    /// `days` days from `start`. Calendar time counts timed events only (all-day
    /// items are deadlines, not time spent), and overlaps once per category.
    public init(start: Date, days count: Int = 7, events: [AgendaItem], snapshot: Work.Snapshot?,
                nights: [Sleep.Night] = [], calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: start)
        let end = calendar.date(byAdding: .day, value: count, to: start)!
        let sessions = snapshot?.sessions ?? []
        let timed = events.filter { !$0.isAllDay }
        func category(_ event: AgendaItem) -> String {
            event.calendar == Self.logCalendar ? event.title.trimmingCharacters(in: .whitespaces) : event.calendar
        }

        var days: [Day] = []
        var repoHours: [String: Double] = [:]
        var kinds: [String: Kind] = [Self.coding: .coding, Self.sleep: .sleep]
        for offset in 0..<count {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let onDay = timed.filter { $0.start < next && $0.end > day }
            var hours: [String: Double] = [:]
            for (name, group) in Dictionary(grouping: onDay, by: category) {
                hours[name] = WeekSummary.booked(group, from: day, to: next) / 3600
                kinds[name] = group[0].calendar == Self.logCalendar ? .logged : .calendar
            }
            let daySessions = sessions.filter { $0.start < next && $0.end > day }
            for session in daySessions {
                let overlap = min(session.end, next).timeIntervalSince(max(session.start, day)) / 3600
                guard overlap > 0 else { continue }
                hours[Self.coding, default: 0] += overlap
                // A session that touched several repos is split evenly between them.
                for repo in session.repos { repoHours[repo, default: 0] += overlap / Double(session.repos.count) }
            }
            // Sleep: the night that ended this morning counts for this day.
            let lastNight = nights.last { calendar.isDate($0.end, inSameDayAs: day) }
            let tonight = nights.first { $0.start > (lastNight?.end ?? day) && $0.start < next.addingTimeInterval(6 * 3600) }
            if let lastNight { hours[Self.sleep] = lastNight.asleep / 3600 }

            // Free: waking hours not covered by any event or coding session. Awake
            // from this morning's wake-up to tonight's bedtime when Health says so
            // (bedtime can be after midnight); otherwise 8 AM to 10 PM.
            let wakeStart = lastNight?.end ?? calendar.date(bySettingHour: Self.dayStart, minute: 0, second: 0, of: day)!
            let wakeEnd = tonight.map(\.start) ?? calendar.date(bySettingHour: Self.dayEnd, minute: 0, second: 0, of: day)!
            let busy = timed.filter { $0.start < wakeEnd && $0.end > wakeStart }.map { ($0.start, $0.end) }
                + sessions.filter { $0.start < wakeEnd && $0.end > wakeStart }.map { ($0.start, $0.end) }
            let free = wakeEnd > wakeStart ? Self.uncovered(from: wakeStart, to: wakeEnd, busy: busy) / 3600 : 0
            days.append(Day(date: day, hours: hours.filter { $0.value > 0.01 }, free: free, slept: lastNight.map { $0.asleep / 3600 }))
        }
        var totals: [String: Double] = [:]
        for day in days { for (name, hours) in day.hours { totals[name, default: 0] += hours } }

        self.start = start
        self.days = days
        categories = totals.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { Category(name: $0.key, hours: $0.value, kind: kinds[$0.key] ?? .calendar) }
        byRepo = repoHours.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) }
        free = days.map(\.free).reduce(0, +)
        commits = (snapshot?.commits ?? []).filter { $0.date >= start && $0.date < end }.count
        activities = (snapshot?.activities ?? []).filter { $0.kind != .push && $0.date >= start && $0.date < end }
            .sorted { $0.date > $1.date }
    }

    /// Seconds between `from` and `to` that no busy stretch covers.
    static func uncovered(from: Date, to: Date, busy: [(Date, Date)]) -> TimeInterval {
        var covered: TimeInterval = 0
        var cursor = from
        for (start, end) in busy.map({ (max($0.0, from), min($0.1, to)) }).filter({ $0.0 < $0.1 }).sorted(by: { $0.0 < $1.0 }) {
            let begin = max(start, cursor)
            if end > begin {
                covered += end.timeIntervalSince(begin)
                cursor = end
            }
        }
        return max(to.timeIntervalSince(from) - covered, 0)
    }

    /// The Sunday that starts the week `date` is in.
    public static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        var calendar = calendar
        calendar.firstWeekday = 1
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// "6.5h", "45m"
    public static func hours(_ value: Double) -> String {
        value < 1 ? "\(Int((value * 60).rounded()))m" : String(format: value < 10 ? "%.1fh" : "%.0fh", value)
    }

    public func markdown(title: String, timeZone: TimeZone = .current) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US")
        day.timeZone = timeZone
        day.dateFormat = "EEE MMM d"
        var out = ["# \(title)", ""]
        out += ["## Hours by kind"] + (categories.isEmpty ? ["- Nothing recorded"] : categories.map {
            "- \($0.label): \(Self.hours($0.hours))" + ($0.kind == .logged ? " (logged)" : "")
        }) + [""]
        out += ["Free time (8 AM to 10 PM, nothing scheduled, coded or logged): \(Self.hours(free))", ""]
        if !byRepo.isEmpty {
            out += ["## Coding by repo (\(commits) commits)"] + byRepo.map { "- \($0.name): \(Self.hours($0.hours))" } + [""]
        }
        if !activities.isEmpty {
            out += ["## Shipped on GitHub"] + activities.map { "- \(day.string(from: $0.date)): \($0.label) in \($0.repo): \($0.title)" } + [""]
        }
        out += ["## By day"] + days.map { d in
            let parts = d.hours.sorted { $0.value > $1.value }.map { "\($0.key) \(Self.hours($0.value))" }
            return "- \(day.string(from: d.date)): " + (parts.isEmpty ? "nothing recorded" : parts.joined(separator: ", "))
        }
        return out.joined(separator: "\n") + "\n"
    }
}
