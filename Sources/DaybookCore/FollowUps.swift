import Foundation

/// Emails Mason sent that are still waiting on a reply: the ones worth a nudge
/// for job and grad-school threads. Daybook asks Mail for sent and received
/// messages from the last three weeks (see FollowUpReader in the app); this
/// works out which conversations went quiet after his message.
public enum FollowUps {
    public struct Sent: Sendable, Equatable {
        public let account: String
        public let subject: String
        public let recipients: [String]   // addresses
        public let names: [String]        // display names, "" when there's none
        public let date: Date
        /// The start of what he wrote, without the quoted message below it.
        public let opening: String

        public init(account: String, subject: String, recipients: [String], names: [String], date: Date, opening: String) {
            self.account = account
            self.subject = subject
            self.recipients = recipients
            self.names = names
            self.date = date
            self.opening = opening
        }
    }

    public struct Received: Sendable, Equatable {
        public let from: String
        public let subject: String
        public let date: Date

        public init(from: String, subject: String, date: Date) {
            self.from = from
            self.subject = subject
            self.date = date
        }
    }

    public struct Waiting: Codable, Hashable, Sendable, Identifiable {
        /// The conversation (its subject, without Re:) and who it's with.
        public let id: String
        public let account: String
        public let subject: String
        public let to: [String]           // names where known, else addresses
        public let sent: Date
        public let days: Int
    }

    /// "Re: Fwd: RE: Interview" -> "interview"
    public static func normalize(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        while let match = text.firstMatch(of: /^(?i)(re|fwd?|aw|sv)\s*(\[\d+\])?\s*:\s*/) {
            text = String(text[match.range.upperBound...])
        }
        return text.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Addresses no person reads: noreply@, notifications@, support@ and the like.
    public static func isAutomated(_ address: String) -> Bool {
        address.firstMatch(of: #/(?i)^(no-?reply|do-?not-?reply|notifications?|alerts?|mailer-daemon|bounce|postmaster|updates?|news(letter)?|info|support|billing|receipts?|team)[@+.]/#) != nil
    }

    /// What he wrote, cut off where a quoted earlier message starts.
    public static func ownText(_ body: String) -> String {
        let markers = [#/\n\s*On .{0,200}wrote:/#, #/\n\s*-{2,} ?Original Message/#, #/\n\s*From: /#, #/\n\s*>/#]
        var cut = body.endIndex
        for marker in markers {
            if let match = body.firstMatch(of: marker), match.range.lowerBound < cut { cut = match.range.lowerBound }
        }
        return String(body[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Conversations whose latest message is his, unanswered for `after` days or
    /// more (and sent within `within` days), longest waiting first. Only ones that
    /// expect an answer: he started them, or his last message asks something.
    public static func waiting(sent: [Sent], received: [Received], mine: Set<String>, now: Date,
                               after: Int = 3, within: Int = 21, dismissed: Set<String> = [],
                               calendar: Calendar = .current) -> [Waiting] {
        let me = Set(mine.map { $0.lowercased() })
        let oldest = calendar.date(byAdding: .day, value: -within, to: now)!
        let threads = Dictionary(grouping: sent.filter { !normalize($0.subject).isEmpty }) { normalize($0.subject) }
        var result: [Waiting] = []
        for (key, messages) in threads {
            guard let last = messages.max(by: { $0.date < $1.date }), last.date >= oldest else { continue }
            let people = zip(last.recipients, last.names + Array(repeating: "", count: max(0, last.recipients.count - last.names.count)))
                .filter { !me.contains($0.0.lowercased()) && !isAutomated($0.0) }
            guard !people.isEmpty else { continue }
            // Anyone writing back in the conversation after his last message counts.
            let answered = received.contains { normalize($0.subject) == key && $0.date > last.date && !me.contains($0.from.lowercased()) }
            guard !answered else { continue }
            let startedIt = messages.contains { normalize($0.subject) == $0.subject.lowercased().trimmingCharacters(in: .whitespaces) }
            guard startedIt || ownText(last.opening).contains("?") else { continue }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last.date), to: calendar.startOfDay(for: now)).day ?? 0
            guard days >= after else { continue }
            let id = key + "|" + people.map { $0.0.lowercased() }.sorted().joined(separator: ",")
            guard !dismissed.contains(id) else { continue }
            result.append(Waiting(id: id, account: last.account, subject: last.subject,
                                  to: people.map { $0.1.isEmpty ? $0.0 : $0.1 }, sent: last.date, days: days))
        }
        return result.sorted { $0.sent < $1.sent }
    }

    // MARK: Mail's answer

    /// Records separated by ASCII 30, fields by ASCII 31, as in MailDigest:
    ///   E, account, its addresses (joined by ";")
    ///   S, account, subject, recipient addresses (";"), recipient names (";"), date, opening
    ///   R, sender address, subject, date
    /// Dates are Mail's local "yyyy-MM-ddTHH:mm:ss".
    public static func parse(_ raw: String, timeZone: TimeZone = .current) -> (sent: [Sent], received: [Received], mine: Set<String>) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        func list(_ field: Substring) -> [String] {
            field.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var sent: [Sent] = [], received: [Received] = [], mine: Set<String> = []
        for record in raw.split(separator: "\u{1E}") {
            let f = record.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            switch f.first {
            case "E" where f.count >= 3:
                mine.formUnion(list(f[2]).filter { !$0.isEmpty })
            case "S" where f.count >= 7:
                guard let date = formatter.date(from: String(f[5])) else { continue }
                var addresses = list(f[3]), names = list(f[4])
                if addresses.last == "" { addresses.removeLast() }
                if names.count > addresses.count { names = Array(names.prefix(addresses.count)) }
                sent.append(Sent(account: String(f[1]), subject: String(f[2]), recipients: addresses, names: names,
                                 date: date, opening: f[6...].joined(separator: "\u{1F}")))
            case "R" where f.count >= 4:
                guard let date = formatter.date(from: String(f[3])) else { continue }
                received.append(Received(from: String(f[1]).lowercased(), subject: String(f[2]), date: date))
            default:
                continue
            }
        }
        return (sent, received, mine)
    }

    // MARK: Files

    public static func markdown(_ waiting: [Waiting], timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE MMM d"
        var out = ["# Waiting on replies", ""]
        if waiting.isEmpty {
            out.append("- Nothing waiting: every conversation you started in the last three weeks has an answer.")
        }
        for item in waiting {
            out.append("- \(item.to.joined(separator: ", ")): \u{201C}\(item.subject)\u{201D} (\(item.account), sent \(formatter.string(from: item.sent)), \(item.days) days ago)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    public static func write(_ waiting: [Waiting], to folder: URL = DailySummary.folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(markdown(waiting).utf8).write(to: folder.appending(path: "followups.md"), options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(waiting).write(to: folder.appending(path: "followups.json"), options: .atomic)
    }

    public static func read(from folder: URL = DailySummary.folder) -> [Waiting] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appending(path: "followups.json")) else { return [] }
        return (try? decoder.decode([Waiting].self, from: data)) ?? []
    }
}
