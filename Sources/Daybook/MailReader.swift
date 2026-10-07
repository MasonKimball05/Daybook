import DaybookCore
import Foundation

/// Asks Apple Mail for unread inbox messages from the last 3 days, in every
/// account, through AppleScript. The first time, macOS asks whether Daybook
/// may control Mail (Privacy & Security ▸ Automation).
///
/// Only the inbox, only unread, only the first 600 characters of each body:
/// enough for the brief to tell what matters, no more.
@MainActor
enum MailReader {
    enum Failure: Error, CustomStringConvertible {
        case notAllowed
        case script(String)

        var description: String {
            switch self {
            case .notAllowed: "Daybook isn't allowed to read Mail. Allow it in System Settings \u{25B8} Privacy & Security \u{25B8} Automation."
            case .script(let message): "Mail didn't answer: \(message)"
            }
        }
    }

    // Each account's inbox is its mailbox named "INBOX" (Gmail, iCloud, Proton).
    // Exchange has none, so for it the inbox comes from Mail's unified Inbox, which
    // knows every account's real one. Every account reports in with an "A" record: its
    // unread count, or the error that stopped it (Proton Mail Bridge not running,
    // an account that's offline). A message that can't be read is skipped alone.
    private static let source = """
    set cutoff to (current date) - (3 * days)
    set fieldSep to character id 31
    set recordSep to character id 30
    set out to ""
    tell application "Mail"
        repeat with acct in (accounts whose enabled is true)
            set acctName to name of acct
            try
                set box to missing value
                try
                    set box to mailbox "INBOX" of acct
                end try
                if box is missing value then
                    repeat with candidate in (mailboxes of inbox)
                        if name of (account of candidate) is acctName then set box to candidate
                    end repeat
                end if
                if box is missing value then error "no inbox found for this account"
                set unread to (messages of box whose read status is false and date received > cutoff)
                set out to out & "A" & fieldSep & acctName & fieldSep & "ok" & fieldSep & ((count of unread) as string) & recordSep
                repeat with m in unread
                    try
                        set body to content of m
                        if (length of body) > 600 then set body to text 1 thru 600 of body
                        set stamp to (date received of m) as «class isot» as string
                        set out to out & "M" & fieldSep & acctName & fieldSep & (sender of m) & fieldSep & (subject of m) & fieldSep & stamp & fieldSep & body & recordSep
                    end try
                end repeat
            on error errorText
                set out to out & "A" & fieldSep & acctName & fieldSep & "error" & fieldSep & errorText & recordSep
            end try
        end repeat
    end tell
    return out
    """

    static func unread() -> Result<MailDigest, Failure> {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(.script("couldn't build the script")) }
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743: the user hasn't allowed Daybook to send Apple Events to Mail.
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { return .failure(.notAllowed) }
            return .failure(.script(error[NSAppleScript.errorMessage] as? String ?? "unknown error"))
        }
        return .success(MailDigest.parse(result.stringValue ?? ""))
    }
}

/// Sent and received mail from the last three weeks, for working out which
/// conversations are waiting on a reply (see FollowUps). Read-only: subjects,
/// addresses and dates, plus the first 1,500 characters of what Mason sent (to
/// tell a question from a "thanks"). Received messages' text isn't read.
@MainActor
enum FollowUpReader {
    // Asking Mail to filter ("messages whose date sent > cutoff") goes message by
    // message and took over ten minutes. Instead each mailbox's dates and subjects
    // come back as whole lists, one request each, and only the last three weeks'
    // messages are looked at one by one. The unified Sent and Inbox list each
    // account's own mailbox.
    private static let source = """
    set cutoff to (current date) - (21 * days)
    set fieldSep to character id 31
    set recordSep to character id 30
    set out to ""
    tell application "Mail"
        repeat with acct in (accounts whose enabled is true)
            try
                set AppleScript's text item delimiters to ";"
                set addresses to (email addresses of acct) as string
                set AppleScript's text item delimiters to ""
                set out to out & "E" & fieldSep & (name of acct) & fieldSep & addresses & recordSep
            end try
        end repeat
        try
            repeat with box in (mailboxes of sent mailbox)
                try
                    set acctName to name of (account of box)
                    set stamps to date sent of every message of box
                    repeat with i from 1 to count of stamps
                        if item i of stamps > cutoff then
                            try
                                set m to message i of box
                                set addrs to ""
                                set names to ""
                                repeat with r in (to recipients of m)
                                    set addrs to addrs & (address of r) & ";"
                                    set theName to ""
                                    try
                                        set theName to name of r
                                        if theName is missing value then set theName to ""
                                    end try
                                    set names to names & theName & ";"
                                end repeat
                                set theSubject to subject of m
                                set body to ""
                                if theSubject starts with "Re" or theSubject starts with "RE" then
                                    set body to content of m
                                    if (length of body) > 1500 then set body to text 1 thru 1500 of body
                                end if
                                set stamp to (item i of stamps) as «class isot» as string
                                set out to out & "S" & fieldSep & acctName & fieldSep & theSubject & fieldSep & addrs & fieldSep & names & fieldSep & stamp & fieldSep & body & recordSep
                            end try
                        end if
                    end repeat
                end try
            end repeat
        end try
        try
            repeat with box in (mailboxes of inbox)
                try
                    set stamps to date received of every message of box
                    set subjects to subject of every message of box
                    set senders to sender of every message of box
                    repeat with i from 1 to count of stamps
                        if item i of stamps > cutoff then
                            try
                                set stamp to (item i of stamps) as «class isot» as string
                                set out to out & "R" & fieldSep & (extract address from (item i of senders)) & fieldSep & (item i of subjects) & fieldSep & stamp & recordSep
                            end try
                        end if
                    end repeat
                end try
            end repeat
        end try
    end tell
    return out
    """

    static func waiting(dismissed: Set<String>) -> Result<[FollowUps.Waiting], MailReader.Failure> {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(.script("couldn't build the script")) }
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { return .failure(.notAllowed) }
            return .failure(.script(error[NSAppleScript.errorMessage] as? String ?? "unknown error"))
        }
        let mail = FollowUps.parse(result.stringValue ?? "")
        return .success(FollowUps.waiting(sent: mail.sent, received: mail.received, mine: mail.mine, now: .now, dismissed: dismissed))
    }

    /// Conversations Mason has said are handled ("Got a Reply"), so they stop showing.
    static var dismissed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "dismissedFollowUps") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "dismissedFollowUps") }
    }
}

/// Billing emails from the last 13 months (receipts, renewal notices,
/// invoices), for finding subscriptions (see Bills). Read-only.
///
/// Two steps, to keep it quick. First each inbox hands back its dates, subjects
/// and senders as whole lists (AppleScript loops over thousands of messages are
/// slow, so Swift does the filtering). Then only the messages whose subjects
/// look like bills are opened, for the first 3,000 characters of their text.
@MainActor
enum BillReader {
    /// Step 1: every inbox's lists. The result is a list of
    /// {dates, subjects, senders}, one per account's inbox, in order.
    private static let listsSource = """
    tell application "Mail"
        set out to {}
        repeat with box in (mailboxes of inbox)
            try
                set end of out to {date received of every message of box, subject of every message of box, sender of every message of box}
            on error
                set end of out to {{}, {}, {}}
            end try
        end repeat
        return out
    end tell
    """

    /// Step 2: the text of chosen messages, by inbox number and message number.
    private static func bodiesSource(_ picks: [(box: Int, message: Int)]) -> String {
        let list = picks.map { "{\($0.box), \($0.message)}" }.joined(separator: ", ")
        return """
        set fieldSep to character id 31
        set recordSep to character id 30
        set out to ""
        tell application "Mail"
            set boxes to mailboxes of inbox
            repeat with pick in {\(list)}
                try
                    set body to content of message (item 2 of pick) of (item (item 1 of pick) of boxes)
                    if (length of body) > 3000 then set body to text 1 thru 3000 of body
                    set out to out & (item 1 of pick) & fieldSep & (item 2 of pick) & fieldSep & body & recordSep
                end try
            end repeat
        end tell
        return out
        """
    }

    private static func run(_ source: String) -> Result<NSAppleEventDescriptor, MailReader.Failure> {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(.script("couldn't build the script")) }
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { return .failure(.notAllowed) }
            return .failure(.script(error[NSAppleScript.errorMessage] as? String ?? "unknown error"))
        }
        return .success(result)
    }

    /// The items of an AppleScript list (descriptor lists count from 1).
    private static func items(_ list: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        list.numberOfItems == 0 ? [] : (1...list.numberOfItems).compactMap { list.atIndex($0) }
    }

    static func emails() -> Result<[Bills.Email], MailReader.Failure> {
        let cutoff = Date.now.addingTimeInterval(-400 * 86_400)
        let lists: NSAppleEventDescriptor
        switch run(listsSource) {
        case .success(let result): lists = result
        case .failure(let failure): return .failure(failure)
        }
        // Pick the recent messages whose subject reads like a bill.
        var picks: [(box: Int, message: Int)] = []
        var found: [String: (sender: String, subject: String, date: Date)] = [:]
        for (boxIndex, box) in items(lists).enumerated() {
            let parts = items(box)
            guard parts.count == 3 else { continue }
            let dates = items(parts[0]), subjects = items(parts[1]), senders = items(parts[2])
            for i in 0..<min(dates.count, subjects.count, senders.count) {
                guard let date = dates[i].dateValue, date > cutoff, let subject = subjects[i].stringValue,
                      Bills.isBilling(subject: subject) else { continue }
                picks.append((boxIndex + 1, i + 1))
                found["\(boxIndex + 1)|\(i + 1)"] = (senders[i].stringValue ?? "", subject, date)
            }
        }
        guard !picks.isEmpty else { return .success([]) }
        let bodies: NSAppleEventDescriptor
        switch run(bodiesSource(picks)) {
        case .success(let result): bodies = result
        case .failure(let failure): return .failure(failure)
        }
        let emails = (bodies.stringValue ?? "").split(separator: "\u{1E}").compactMap { record -> Bills.Email? in
            let f = record.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3, let message = found["\(f[0])|\(f[1])"] else { return nil }
            let body = String(f[2])
            return Bills.Email(merchant: Bills.merchant(fromSender: message.sender), subject: message.subject, date: message.date,
                               amount: Bills.amount(in: body), renews: Bills.renewalDate(in: body, after: message.date))
        }
        return .success(emails)
    }

    /// Reads Mail and saves bills.json / bills.md. Takes a while (the message
    /// texts may download), so the app runs it in the background, weekly.
    static func refresh() {
        guard case .success(let emails) = BillReader.emails() else { return }
        let subscriptions = Bills.subscriptions(emails, now: .now, ignored: ignored)
        try? Bills.Snapshot(gathered: .now, subscriptions: subscriptions).write()
    }

    /// Merchants Mason said aren't subscriptions ("Not a Subscription").
    static var ignored: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "ignoredBills") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "ignoredBills") }
    }
}
