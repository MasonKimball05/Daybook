import Foundation

/// Subscriptions and bills, found in billing emails (receipts, renewal notices,
/// invoices) that Daybook reads from Apple Mail on the Mac (see BillReader).
/// Only merchants, amounts and dates come out of them; nothing like a card
/// number is looked for or kept.
public enum Bills {
    /// One billing email.
    public struct Email: Codable, Hashable, Sendable {
        public let merchant: String
        public let subject: String
        public let date: Date
        public let amount: Double?
        /// A renewal date the email states ("renews on October 21, 2026").
        public let renews: Date?

        public init(merchant: String, subject: String, date: Date, amount: Double?, renews: Date?) {
            self.merchant = merchant
            self.subject = subject
            self.date = date
            self.amount = amount
            self.renews = renews
        }
    }

    public enum Cadence: String, Codable, Sendable {
        case weekly, monthly, quarterly, yearly

        public var days: Int {
            switch self {
            case .weekly: 7
            case .monthly: 30
            case .quarterly: 91
            case .yearly: 365
            }
        }

        /// The cadence a typical gap between charges points to, if any.
        static func from(gap days: Double) -> Cadence? {
            switch days {
            case 5...9: .weekly
            case 25...35: .monthly
            case 80...100: .quarterly
            case 340...390: .yearly
            default: nil
            }
        }
    }

    public struct Subscription: Codable, Hashable, Sendable, Identifiable {
        public let merchant: String
        public let amount: Double?
        public let cadence: Cadence?
        public let lastCharged: Date
        public let nextRenewal: Date?
        public let charges: Int
        public var id: String { merchant }

        /// About what it costs a month, if the amount and cadence are known.
        public var monthly: Double? {
            guard let amount, let cadence else { return nil }
            return amount * 30 / Double(cadence.days)
        }
    }

    // MARK: Reading emails

    /// Subjects that say "this is a bill". Shipping updates and account
    /// notices share words with them, so those are ruled out first.
    public static func isBilling(subject: String) -> Bool {
        let s = subject.lowercased()
        let not = ["shipped", "delivered", "out for delivery", "password", "verify", "sign-in", "sign in", "security alert", "refund"]
        if not.contains(where: s.contains) { return false }
        let yes = ["receipt", "invoice", "your subscription", "subscription renew", "renewal", "renews", "will renew",
                   "payment received", "payment confirmation", "billing", "charged", "membership", "your plan",
                   "auto-renew", "trial ends", "trial is ending", "statement"]
        return yes.contains(where: s.contains)
    }

    /// "Spotify <no-reply@spotify.com>" -> "Spotify"; a bare address -> its
    /// domain's name ("billing@apple.com" -> "Apple").
    public static func merchant(fromSender sender: String) -> String {
        let trimmed = sender.trimmingCharacters(in: .whitespaces)
        if let angle = trimmed.firstIndex(of: "<") {
            let name = trimmed[..<angle].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return cleanName(name) }
        }
        let address = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard let domain = address.split(separator: "@").last else { return trimmed }
        let parts = domain.split(separator: ".")
        // "mail.spotify.com" -> "spotify"; "apple.com" -> "apple".
        let name = parts.count >= 2 ? parts[parts.count - 2] : parts.first ?? Substring(domain)
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// "Spotify Billing", "Netflix via Stripe", "Apple (no-reply)" -> the brand.
    static func cleanName(_ name: String) -> String {
        var text = name
        if let via = text.range(of: " via ", options: .caseInsensitive) { text = String(text[..<via.lowerBound]) }
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        text = text.trimmingCharacters(in: .whitespaces)
        for noise in [" billing", " receipts", " receipt", " payments", " team", " support", " no-reply", " noreply"]
        where text.lowercased().hasSuffix(noise) {
            text = String(text.dropLast(noise.count))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The amount charged: a dollar figure just after "total", "amount" or
    /// "charged" if there is one, else the largest dollar figure in the text.
    public static func amount(in text: String) -> Double? {
        let money = #/\$\s?(\d{1,3}(?:,\d{3})+(?:\.\d{2})?|\d+(?:\.\d{2})?)/#
        func value(_ match: Regex<(Substring, Substring)>.Match) -> Double? {
            Double(match.1.replacingOccurrences(of: ",", with: ""))
        }
        let lower = text.lowercased()
        for keyword in ["total", "amount charged", "amount paid", "amount due", "charged", "amount"] {
            var search = lower.startIndex
            while let found = lower.range(of: keyword, range: search..<lower.endIndex) {
                search = found.upperBound
                // Whole words only: "total" mustn't match inside "subtotal".
                if found.lowerBound > lower.startIndex, lower[lower.index(before: found.lowerBound)].isLetter { continue }
                // The first dollar figure within 60 characters after the keyword.
                let end = lower.index(found.upperBound, offsetBy: 60, limitedBy: lower.endIndex) ?? lower.endIndex
                if let match = text[found.upperBound..<end].firstMatch(of: money), let number = value(match), number > 0 {
                    return number
                }
            }
        }
        return text.matches(of: money).compactMap(value).filter { $0 > 0 && $0 < 10_000 }.max()
    }

    /// A date the text says it renews on ("renews on Oct 21, 2026", "next
    /// billing date: November 3"), found by NSDataDetector right after the words.
    public static func renewalDate(in text: String, after sent: Date) -> Date? {
        let lower = text.lowercased()
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        for keyword in ["renews on", "will renew", "renewal date", "next billing date", "next payment", "will be charged on", "trial ends"] {
            guard let found = lower.range(of: keyword) else { continue }
            let end = lower.index(found.upperBound, offsetBy: 50, limitedBy: lower.endIndex) ?? lower.endIndex
            let window = String(text[found.upperBound..<end])
            if let date = detector.firstMatch(in: window, range: NSRange(window.startIndex..., in: window))?.date, date > sent {
                return date
            }
        }
        return nil
    }

    // MARK: Finding subscriptions

    /// Merchants that bill on a rhythm, or that say when they'll renew.
    /// One-off purchases (a single receipt with no renewal date) are left out.
    public static func subscriptions(_ emails: [Email], now: Date, ignored: Set<String> = [],
                                     calendar: Calendar = .current) -> [Subscription] {
        var found: [Subscription] = []
        for (merchant, list) in Dictionary(grouping: emails, by: \.merchant) where !ignored.contains(merchant) {
            let sorted = list.sorted { $0.date < $1.date }
            // Emails a few days apart are the same bill (a receipt and an invoice).
            var charges: [Email] = []
            for email in sorted {
                if let last = charges.last, email.date.timeIntervalSince(last.date) < 4 * 86_400 {
                    if last.amount == nil && email.amount != nil { charges[charges.count - 1] = email }
                    continue
                }
                charges.append(email)
            }
            let gaps = zip(charges, charges.dropFirst()).map { $1.date.timeIntervalSince($0.date) / 86_400 }.sorted()
            let cadence = gaps.isEmpty ? nil : Cadence.from(gap: gaps[gaps.count / 2])
            let stated = sorted.compactMap(\.renews).filter { $0 > now }.min()
            guard cadence != nil || stated != nil, let last = charges.last else { continue }

            var next = stated
            if next == nil, let cadence {
                // Step forward from the last charge until it's in the future.
                var date = last.date
                while date <= now { date = calendar.date(byAdding: .day, value: cadence.days, to: date)! }
                // Two cycles with no charge suggests it was cancelled: keep it, with no date.
                if date.timeIntervalSince(last.date) <= Double(cadence.days * 2) * 86_400 { next = date }
            }
            found.append(Subscription(merchant: merchant, amount: charges.reversed().compactMap(\.amount).first,
                                      cadence: cadence, lastCharged: last.date, nextRenewal: next, charges: charges.count))
        }
        return found.sorted { ($0.nextRenewal ?? .distantFuture, $0.merchant) < ($1.nextRenewal ?? .distantFuture, $1.merchant) }
    }

    /// "$11.99"
    public static func dollars(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    // MARK: Saved files

    public struct Snapshot: Codable, Sendable {
        public let gathered: Date
        public let subscriptions: [Subscription]

        public init(gathered: Date, subscriptions: [Subscription]) {
            self.gathered = gathered
            self.subscriptions = subscriptions
        }

        public var monthlyTotal: Double { subscriptions.filter { $0.nextRenewal != nil }.compactMap(\.monthly).reduce(0, +) }

        public static func read(from folder: URL = DailySummary.folder) -> Snapshot? {
            guard let data = try? Data(contentsOf: folder.appending(path: "bills.json")) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Snapshot.self, from: data)
        }

        public func write(to folder: URL = DailySummary.folder) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: folder.appending(path: "bills.json"), options: .atomic)
            try Data(markdown().utf8).write(to: folder.appending(path: "bills.md"), options: .atomic)
        }

        public func markdown(now: Date = .now, timeZone: TimeZone = .current) -> String {
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US")
            day.timeZone = timeZone
            day.dateFormat = "EEE MMM d"
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            var out = ["# Subscriptions and bills", ""]
            if subscriptions.isEmpty { out.append("- None found in the last year of email.") }
            for sub in subscriptions {
                var line = "- \(sub.merchant)"
                if let amount = sub.amount { line += ": \(dollars(amount))" }
                if let cadence = sub.cadence { line += " \(cadence.rawValue)" }
                if let next = sub.nextRenewal {
                    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: next)).day ?? 0
                    line += ", renews \(day.string(from: next)) (in \(days) day\(days == 1 ? "" : "s"))"
                } else {
                    line += ", last charged \(day.string(from: sub.lastCharged)); no recent charge, may be cancelled"
                }
                out.append(line)
            }
            if monthlyTotal > 0 { out += ["", "About \(dollars(monthlyTotal)) a month for the active ones."] }
            return out.joined(separator: "\n") + "\n"
        }
    }
}
