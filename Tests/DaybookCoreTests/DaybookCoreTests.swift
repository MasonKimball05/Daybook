import Foundation
import Testing
@testable import DaybookCore

/// Tuesday, October 6, 2026, 9:00 AM in Chicago.
let chicago = TimeZone(identifier: "America/Chicago")!
let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = chicago
    return c
}()
func at(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}
let now = at(10, 6, 9)

func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false, calendar: String = "Samford") -> AgendaItem {
    AgendaItem(id: title, title: title, start: start, end: end, isAllDay: allDay, calendar: calendar)
}

@Suite struct QuickAddTests {
    @Test func dayAndTime() throws {
        let parsed = QuickAdd.parse("submit SOP friday 3pm", now: now)
        #expect(parsed.title == "submit SOP")
        #expect(parsed.hasTime)
        let due = try #require(parsed.due)
        #expect(cal.component(.weekday, from: due) == 6) // Friday
        #expect(cal.component(.hour, from: due) == 15)
    }

    @Test func dayOnlyHasNoTime() {
        let parsed = QuickAdd.parse("email Dr. Garay by tomorrow", now: now)
        #expect(parsed.title == "email Dr. Garay")
        #expect(parsed.due != nil)
        #expect(!parsed.hasTime)
    }

    @Test func noDate() {
        let parsed = QuickAdd.parse("buy printer paper", now: now)
        #expect(parsed == QuickAdd.Parsed(title: "buy printer paper", due: nil, hasTime: false))
    }

    @Test func onlyADateKeepsTheText() {
        // Nothing left to call the task: keep what was typed rather than an empty title.
        #expect(QuickAdd.parse("tomorrow", now: now).title == "tomorrow")
    }
}

@Suite struct PlaceTests {
    @Test func multiLineLocationBecomesOneLine() {
        let item = AgendaItem(id: "1", title: "Interview", start: .now, end: .now, isAllDay: false, calendar: "Job",
                              location: "Samford University\n 800 Lakeshore Dr\r\n\nHomewood, AL ")
        #expect(item.place == "Samford University, 800 Lakeshore Dr, Homewood, AL")
    }

    @Test func blankLocationIsNone() {
        let item = AgendaItem(id: "1", title: "x", start: .now, end: .now, isAllDay: false, calendar: "c", location: " \n ")
        #expect(item.place == nil)
    }
}

@Suite struct AgendaTests {
    @Test func groupsByDayAndSpansMultipleDays() {
        let events = [
            event("Lecture", at(10, 6, 10), at(10, 6, 11)),
            event("Chapter meeting", at(10, 6, 18), at(10, 6, 19), calendar: "Parliament"),
            event("Conference", at(10, 6), at(10, 9), allDay: true),
            event("Next week", at(10, 13, 9), at(10, 13, 10)),
        ]
        let tasks = [TaskItem(id: "t", title: "Problem set", due: at(10, 7, 23, 59), dueHasTime: true)]
        let days = Agenda.days(from: now, count: 4, events: events, tasks: tasks, calendar: cal)
        #expect(days.count == 4)
        #expect(days[0].timed.map(\.title) == ["Lecture", "Chapter meeting"])
        #expect(days.prefix(3).allSatisfy { $0.allDay.map(\.title) == ["Conference"] })
        #expect(days[3].allDay.isEmpty) // ends at midnight Oct 9, so not on the 9th
        #expect(days[1].tasks.map(\.title) == ["Problem set"])
    }
}

@Suite struct DailySummaryTests {
    let events = [
        event("Crypto lecture", at(10, 6, 10), at(10, 6, 11, 15)),
        event("GRE", at(10, 9), at(10, 10), allDay: true, calendar: "Grad school deadlines"),
        event("Office hours", at(10, 7, 14), at(10, 7, 15)),
        event("A&M PhD deadline", at(12, 15), at(12, 16), allDay: true, calendar: "Grad school deadlines"),
    ]
    let tasks = [
        TaskItem(id: "1", title: "Stage 2 tests", due: at(10, 6), list: "School"),
        TaskItem(id: "2", title: "Email recommender", due: at(10, 5), list: "Grad"),
        TaskItem(id: "3", title: "Read lattice paper", due: nil),
        TaskItem(id: "4", title: "Done thing", due: at(10, 6), isCompleted: true),
    ]

    @Test func sortsEverythingIntoItsSection() {
        let summary = DailySummary(now: now, events: events, tasks: tasks, calendar: cal)
        #expect(summary.today.map(\.title) == ["Crypto lecture"])
        #expect(summary.tomorrow.map(\.title) == ["Office hours"])
        #expect(summary.tasksDueToday.map(\.title) == ["Stage 2 tests"])
        #expect(summary.tasksOverdue.map(\.title) == ["Email recommender"])
        #expect(summary.tasksUndated.map(\.title) == ["Read lattice paper"])
        #expect(summary.upcoming.map(\.title) == ["GRE"]) // the A&M deadline is beyond two weeks
    }

    @Test func markdownReadsLikeABrief() {
        let md = DailySummary(now: now, events: events, tasks: tasks, calendar: cal).markdown(calendar: cal, timeZone: chicago)
        #expect(md.hasPrefix("# Daybook: Tuesday, October 6\n"))
        #expect(md.contains("- 10:00 AM\u{2013}11:15 AM: Crypto lecture [Samford]"))
        #expect(md.contains("## Overdue tasks\n- Email recommender (due Mon Oct 5) [Grad]"))
        #expect(md.contains("- Fri Oct 9: GRE [Grad school deadlines]"))
        #expect(!md.contains("Done thing"))
    }

    @Test func jsonRoundTrips() throws {
        let data = try DailySummary(now: now, events: events, tasks: tasks, calendar: cal).json()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(DailySummary.self, from: data)
        #expect(back.today.first?.title == "Crypto lecture")
    }
}

@Suite struct MailDigestTests {
    let us = "\u{1F}", rs = "\u{1E}"

    @Test func parsesAccountsAndMessagesNewestFirst() throws {
        let raw = "A\(us)Samford\(us)ok\(us)1\(rs)"
            + "M\(us)Samford\(us)Dr. Smith <smith@example.edu>\(us)Lab report, revised\(us)2026-10-05T16:20:00\(us)Hi Mason,\n\n  please resubmit by Friday.\(rs)"
            + "A\(us)Google\(us)ok\(us)1\(rs)"
            + "M\(us)Google\(us)GitHub <noreply@github.com>\(us)\(us)2026-10-06T07:05:00\(us)A new sign-in\(rs)"
            + "A\(us)Proton\(us)error\(us)Mail can't connect to 127.0.0.1\(rs)"
            + "A\(us)iCloud\(us)ok\(us)0\(rs)"
        let digest = MailDigest.parse(raw, timeZone: chicago)
        #expect(digest.accounts.map(\.name) == ["Google", "Proton", "Samford", "iCloud"])
        #expect(digest.accounts.first { $0.name == "iCloud" }?.unread == 0)
        #expect(digest.accounts.first { $0.name == "Proton" }?.error == "Mail can't connect to 127.0.0.1")
        #expect(digest.items.map(\.account) == ["Google", "Samford"])
        #expect(digest.items[0].subject == "(no subject)")
        #expect(digest.items[1].subject == "Lab report, revised") // commas survive
        #expect(digest.items[1].snippet == "Hi Mason, please resubmit by Friday.")
        #expect(digest.items[1].received == at(10, 5, 16, 20))
    }

    @Test func skipsBrokenRecords() {
        let digest = MailDigest.parse("M\(us)only\(us)three\(rs)A\(us)x\(rs)\(rs)")
        #expect(digest.items.isEmpty && digest.accounts.isEmpty)
        #expect(MailDigest.parse("").items.isEmpty)
    }

    @Test func markdownListsEveryAccountIncludingEmptyAndBroken() {
        let digest = MailDigest(
            accounts: [MailAccount(name: "Google", unread: 1, error: nil),
                       MailAccount(name: "Proton", unread: nil, error: "Bridge isn't running"),
                       MailAccount(name: "iCloud", unread: 0, error: nil)],
            items: [MailItem(account: "Google", from: "GitHub", subject: "New sign-in", received: at(10, 6, 7, 5), snippet: "")])
        let md = digest.markdown(now: now, timeZone: chicago)
        #expect(md.contains("## Google (1 unread)\n- Tue 7:05 AM \u{00B7} GitHub \u{00B7} New sign-in"))
        #expect(md.contains("## Proton: couldn\u{2019}t read the inbox\nBridge isn't running"))
        #expect(md.contains("## iCloud (0 unread)"))
        #expect(MailDigest(accounts: [], items: []).markdown(now: now, timeZone: chicago).contains("No accounts found in Apple Mail."))
    }
}

@Suite struct MonthGridTests {
    @Test func octoberStartsOnThursday() {
        let grid = MonthGrid(containing: at(10, 6), calendar: cal)
        #expect(grid.weeks.count == 5)
        #expect(grid.weeks.allSatisfy { $0.count == 7 })
        #expect(grid.weeks[0][0] == at(9, 27))     // Sunday Sep 27
        #expect(grid.weeks[0][4] == at(10, 1))     // Thursday Oct 1
        #expect(grid.weeks[4][6] == at(10, 31))    // Saturday Oct 31
        #expect(grid.contains(at(10, 15), calendar: cal) && !grid.contains(at(9, 27), calendar: cal))
    }

    @Test func monthStartingOnSundayHasNoLeadingDays() {
        let grid = MonthGrid(containing: at(11, 20), calendar: cal) // Nov 1, 2026 is a Sunday
        #expect(grid.weeks[0][0] == at(11, 1))
        #expect(grid.weeks.last!.contains(at(11, 30)))
    }
}

@Suite struct MarkerTests {
    @Test func doneMarkRoundTripsThroughURL() {
        let marker = DaybookMarker.done(eventID: "A468CF26-9E56@1791349200")
        #expect(DaybookMarker(marker.url) == marker)
    }

    @Test func fallsBackToNotesWhenTheURLWasDropped() {
        // Exchange strips a reminder's URL; the copy in the notes still says what it is.
        let marker = DaybookMarker.done(eventID: "abc@1")
        #expect(DaybookMarker(url: nil, notes: marker.url.absoluteString) == marker)
        #expect(DaybookMarker(url: nil, notes: "just a note") == nil)
        #expect(DaybookMarker(url: nil, notes: nil) == nil)
    }

    @Test func readyRoundTrips() {
        let marker = DaybookMarker.ready(date: "2026-10-07")
        #expect(DaybookMarker(url: nil, notes: marker.url.absoluteString) == marker)
    }

    @Test func briefNoteKeepsDateAndBody() {
        let notes = BriefNote.compose(date: "2026-10-07", markdown: "# Hi\n\n- one\n")
        #expect(DaybookMarker(url: nil, notes: notes) == .brief(date: "2026-10-07"))
        #expect(BriefNote.body(notes) == "# Hi\n\n- one")
    }

    @Test func dayKeyUsesLocalDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        // 11:30 PM in Chicago is already the next day in UTC.
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 23, minute: 30))!
        #expect(BriefNote.dayKey(date, calendar: calendar) == "2026-10-07")
    }
}

@Suite struct BriefMarkdownTests {
    @Test func readsHeadingsListsAndParagraphs() {
        let text = """
        # A steady climb until 2, Mason.

        ## Needs attention
        1. **Submit the SOP** due today
        2. Reply to Dr. Lee

        - Gmail: 3 unread
        * iCloud: none
        ---
        A short paragraph
        that wraps.
        """
        #expect(BriefMarkdown.blocks(text) == [
            .heading(level: 1, text: "A steady climb until 2, Mason."),
            .heading(level: 2, text: "Needs attention"),
            .numbered(1, "**Submit the SOP** due today"),
            .numbered(2, "Reply to Dr. Lee"),
            .bullet("Gmail: 3 unread"),
            .bullet("iCloud: none"),
            .paragraph("A short paragraph that wraps."),
        ])
    }
}

@Suite struct MeetingLinkTests {
    @Test func findsTheCallLinkAmongOthers() {
        let notes = """
        Agenda: https://docs.google.com/document/d/abc
        Join Microsoft Teams Meeting
        https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=y
        """
        #expect(MeetingLink.find(in: [nil, "Room 210", notes])?.host() == "teams.microsoft.com")
    }

    @Test func zoomSubdomainInTheLocation() {
        #expect(MeetingLink.find(in: ["https://samford.zoom.us/j/123456789", nil])?.absoluteString == "https://samford.zoom.us/j/123456789")
    }

    @Test func noCallLink() {
        #expect(MeetingLink.find(in: ["Lunch at https://example.com", nil]) == nil)
        #expect(MeetingLink.find(in: ["notzoom.us.example.com/x"]) == nil)
    }
}

@Suite struct FreeTimeTests {
    @Test func gapsBetweenEventsWithinWakingHours() {
        let events = [
            event("Lecture", at(10, 7, 10), at(10, 7, 11, 15)),
            event("Lab", at(10, 7, 11, 30), at(10, 7, 13)),   // 15 min gap before it: too short
            event("Overlaps lab", at(10, 7, 12), at(10, 7, 14)),
            event("Deadline", at(10, 7), at(10, 8), allDay: true), // doesn't block time
        ]
        let blocks = FreeTime.blocks(on: at(10, 7), events: events, now: now, calendar: cal)
        #expect(blocks == [
            DateInterval(start: at(10, 7, 8), end: at(10, 7, 10)),
            DateInterval(start: at(10, 7, 14), end: at(10, 7, 22)),
        ])
    }

    @Test func todayStartsFromNow() {
        // now is 9:00; at 9:02 the day's free time starts at 9:05.
        let blocks = FreeTime.blocks(on: at(10, 6), events: [], now: at(10, 6, 9, 2), calendar: cal)
        #expect(blocks == [DateInterval(start: at(10, 6, 9, 5), end: at(10, 6, 22))])
        #expect(FreeTime.blocks(on: at(10, 6), events: [], now: at(10, 6, 22, 30), calendar: cal).isEmpty)
    }

    @Test func lengths() {
        #expect(FreeTime.length(45 * 60) == "45m")
        #expect(FreeTime.length(2 * 3600) == "2h")
        #expect(FreeTime.length(150 * 60) == "2h 30m")
    }

    @Test func summaryListsOpenTime() {
        let md = DailySummary(now: now, events: [event("Lecture", at(10, 6, 10), at(10, 6, 11, 15))], tasks: [], calendar: cal)
            .markdown(calendar: cal, timeZone: chicago)
        #expect(md.contains("## Open time today\n- 9:00 AM\u{2013}10:00 AM (1h)\n- 11:15 AM\u{2013}10:00 PM (10h 45m), the longest"))
    }
}

@Suite struct WeekSummaryTests {
    @Test func sevenDaysFromTomorrow() {
        let events = [
            event("Lecture", at(10, 7, 10), at(10, 7, 11)),
            event("Lab", at(10, 7, 10, 30), at(10, 7, 12)), // overlaps: booked counts 10 to 12 once
            event("Interview", at(10, 9, 13), at(10, 9, 17)),
            event("GRE", at(10, 10), at(10, 11), allDay: true),
            event("A&M deadline", at(10, 16), at(10, 17), allDay: true), // the week after
            event("Today's thing", at(10, 6, 14), at(10, 6, 15)),       // today: not in the week
        ]
        let tasks = [TaskItem(id: "1", title: "SOP draft", due: at(10, 8), list: "Grad"),
                     TaskItem(id: "2", title: "Read paper", due: nil)]
        let week = WeekSummary(now: now, events: events, tasks: tasks, calendar: cal)
        #expect(week.days.count == 7)
        #expect(cal.isDate(week.days[0].date, inSameDayAs: at(10, 7)))
        #expect(week.days[0].booked == 2 * 3600)
        #expect(week.days[1].tasks.map(\.title) == ["SOP draft"])
        #expect(week.followingWeek.map(\.title) == ["A&M deadline"])
        #expect(week.undated.map(\.title) == ["Read paper"])
        let md = week.markdown(calendar: cal, timeZone: chicago)
        #expect(md.hasPrefix("# Daybook: the week of Wednesday, October 7\n"))
        #expect(md.contains("## Friday, October 9 (4h booked), the busiest day"))
        #expect(md.contains("## Saturday, October 10 (nothing booked)\n- All day: GRE [Samford]"))
        #expect(!md.contains("Today's thing"))
    }
}
