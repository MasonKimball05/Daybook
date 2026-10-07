import Foundation

/// Unread email from every account in Apple Mail, for the morning brief to
/// sort into "important" and "can wait". Daybook asks Mail for it with
/// AppleScript (see MailReader in the app); this file turns Mail's answer into
/// values and writes mail.md / mail.json next to the daily summary.
public struct MailItem: Codable, Hashable, Sendable {
    public let account: String
    public let from: String
    public let subject: String
    public let received: Date?
    /// The first few hundred characters of the body, whitespace collapsed.
    public let snippet: String
}

/// How reading one account went: its unread count, or why it couldn't be read
/// (Proton Mail Bridge not running, an account that's offline). Every account
/// reports in, so "0 unread" and "couldn't read it" never look the same.
public struct MailAccount: Codable, Hashable, Sendable {
    public let name: String
    public let unread: Int?
    public let error: String?
}

public struct MailDigest: Codable, Sendable {
    public let accounts: [MailAccount]
    public let items: [MailItem]

    public init(accounts: [MailAccount], items: [MailItem]) {
        self.accounts = accounts
        self.items = items
    }

    /// Mail's answer is one string of records separated by ASCII 30, with fields
    /// separated by ASCII 31 (characters that never appear in email text, unlike
    /// commas or tabs). The first field says what the record is:
    ///   A, account, "ok", unread count       an account that was read
    ///   A, account, "error", message         an account that couldn't be
    ///   M, account, sender, subject, date (yyyy-MM-ddTHH:mm:ss local), body
    public static func parse(_ raw: String, timeZone: TimeZone = .current) -> MailDigest {
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.timeZone = timeZone
        dates.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var accounts: [MailAccount] = []
        var items: [MailItem] = []
        for record in raw.split(separator: "\u{1E}") {
            let f = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            let kind = f.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == "A", f.count >= 4 {
                let name = f[1].trimmingCharacters(in: .whitespaces)
                accounts.append(f[2] == "ok"
                    ? MailAccount(name: name, unread: Int(f[3].trimmingCharacters(in: .whitespaces)), error: nil)
                    : MailAccount(name: name, unread: nil, error: f[3].trimmingCharacters(in: .whitespacesAndNewlines)))
            } else if kind == "M", f.count >= 6 {
                let snippet = f[5].split(whereSeparator: \.isWhitespace).joined(separator: " ")
                items.append(MailItem(account: f[1].trimmingCharacters(in: .whitespaces),
                                      from: f[2].trimmingCharacters(in: .whitespaces),
                                      subject: f[3].isEmpty ? "(no subject)" : f[3],
                                      received: dates.date(from: f[4].trimmingCharacters(in: .whitespaces)),
                                      snippet: String(snippet.prefix(400))))
            }
        }
        items.sort { ($0.received ?? .distantPast) > ($1.received ?? .distantPast) }
        return MailDigest(accounts: accounts.sorted { $0.name < $1.name }, items: items)
    }

    /// Every account with its count (or error), then its unread mail, newest first.
    public func markdown(now: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = timeZone
        f.dateFormat = "EEE h:mm a"
        var out = ["# Unread email, last 3 days", ""]
        if accounts.isEmpty { out += ["No accounts found in Apple Mail.", ""] }
        for account in accounts {
            if let error = account.error {
                out += ["## \(account.name): couldn\u{2019}t read the inbox", "\(error)", ""]
                continue
            }
            let mail = items.filter { $0.account == account.name }
            out.append("## \(account.name) (\(account.unread ?? mail.count) unread)")
            for item in mail {
                let when = item.received.map { f.string(from: $0) } ?? "unknown time"
                out.append("- \(when) \u{00B7} \(item.from) \u{00B7} \(item.subject)")
                if !item.snippet.isEmpty { out.append("  > \(item.snippet)") }
            }
            out.append("")
        }
        f.dateFormat = "MMM d, h:mm a"
        out.append("_Read from Apple Mail \(f.string(from: now))_")
        return out.joined(separator: "\n") + "\n"
    }

    public func write(now: Date = .now, to folder: URL = DailySummary.folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(markdown(now: now).utf8).write(to: folder.appending(path: "mail.md"), options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: folder.appending(path: "mail.json"), options: .atomic)
    }
}
