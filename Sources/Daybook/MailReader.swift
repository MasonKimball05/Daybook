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
