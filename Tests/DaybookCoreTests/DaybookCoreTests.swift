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
        let parsed = QuickAdd.parse("submit report friday 3pm", now: now)
        #expect(parsed.title == "submit report")
        #expect(parsed.hasTime)
        let due = try #require(parsed.due)
        // NSDataDetector reads "3pm" in the machine's own time zone (UTC on GitHub's
        // runners), so check it in that zone rather than the tests' Chicago one.
        #expect(Calendar.current.component(.weekday, from: due) == 6) // Friday
        #expect(Calendar.current.component(.hour, from: due) == 15)
    }

    @Test func dayOnlyHasNoTime() {
        let parsed = QuickAdd.parse("email Dr. Smith by tomorrow", now: now)
        #expect(parsed.title == "email Dr. Smith")
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
        event("Conference", at(10, 9), at(10, 10), allDay: true, calendar: "Deadlines"),
        event("Office hours", at(10, 7, 14), at(10, 7, 15)),
        event("Project deadline", at(12, 15), at(12, 16), allDay: true, calendar: "Deadlines"),
    ]
    let tasks = [
        TaskItem(id: "1", title: "Stage 2 tests", due: at(10, 6), list: "School"),
        TaskItem(id: "2", title: "Email the landlord", due: at(10, 5), list: "Home"),
        TaskItem(id: "3", title: "Read a book", due: nil),
        TaskItem(id: "4", title: "Done thing", due: at(10, 6), isCompleted: true),
    ]

    @Test func sortsEverythingIntoItsSection() {
        let summary = DailySummary(now: now, events: events, tasks: tasks, calendar: cal)
        #expect(summary.today.map(\.title) == ["Crypto lecture"])
        #expect(summary.tomorrow.map(\.title) == ["Office hours"])
        #expect(summary.tasksDueToday.map(\.title) == ["Stage 2 tests"])
        #expect(summary.tasksOverdue.map(\.title) == ["Email the landlord"])
        #expect(summary.tasksUndated.map(\.title) == ["Read a book"])
        #expect(summary.upcoming.map(\.title) == ["Conference"]) // the project deadline is beyond two weeks
    }

    @Test func markdownReadsLikeABrief() {
        let md = DailySummary(now: now, events: events, tasks: tasks, calendar: cal).markdown(calendar: cal, timeZone: chicago)
        #expect(md.hasPrefix("# Daybook: Tuesday, October 6\n"))
        #expect(md.contains("- 10:00 AM\u{2013}11:15 AM: Crypto lecture [Samford]"))
        #expect(md.contains("## Overdue tasks\n- Email the landlord (due Mon Oct 5) [Home]"))
        #expect(md.contains("- Fri Oct 9: Conference [Deadlines]"))
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

    @Test func priorityRoundTrips() {
        let marker = DaybookMarker.priority(eventID: "abc@1791349200", level: Priority.urgent.rawValue)
        #expect(DaybookMarker(url: nil, notes: marker.url.absoluteString) == marker)
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
        1. **Submit the report** due today
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
            .numbered(1, "**Submit the report** due today"),
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
            event("Conference", at(10, 10), at(10, 11), allDay: true),
            event("Project deadline", at(10, 16), at(10, 17), allDay: true), // the week after
            event("Today's thing", at(10, 6, 14), at(10, 6, 15)),       // today: not in the week
        ]
        let tasks = [TaskItem(id: "1", title: "Report draft", due: at(10, 8), list: "Home"),
                     TaskItem(id: "2", title: "Read paper", due: nil)]
        let week = WeekSummary(now: now, events: events, tasks: tasks, calendar: cal)
        #expect(week.days.count == 7)
        #expect(cal.isDate(week.days[0].date, inSameDayAs: at(10, 7)))
        #expect(week.days[0].booked == 2 * 3600)
        #expect(week.days[1].tasks.map(\.title) == ["Report draft"])
        #expect(week.followingWeek.map(\.title) == ["Project deadline"])
        #expect(week.undated.map(\.title) == ["Read paper"])
        let md = week.markdown(calendar: cal, timeZone: chicago)
        #expect(md.hasPrefix("# Daybook: the week of Wednesday, October 7\n"))
        #expect(md.contains("## Friday, October 9 (4h booked), the busiest day"))
        #expect(md.contains("## Saturday, October 10 (nothing booked)\n- All day: Conference [Samford]"))
        #expect(!md.contains("Today's thing"))
    }
}

@Suite struct PriorityTests {
    @Test func remindersNumbers() {
        // What Reminders writes for High, Medium, Low and none, and Daybook's urgent.
        #expect([1, 5, 9, 0, 2].map(Priority.init(reminderPriority:)) == [.high, .medium, .low, .none, .urgent])
        for priority in Priority.allCases {
            #expect(Priority(reminderPriority: priority.reminderPriority) == priority)
        }
    }

    @Test func summaryMarksHighAndUrgent() {
        let exam = event("Exam", at(10, 6, 13), at(10, 6, 14))
        let task = TaskItem(id: "t", title: "Pay rent", due: at(10, 6), priority: .urgent)
        let md = DailySummary(now: now, events: [exam], tasks: [task], eventPriorities: [exam.id: .high], calendar: cal)
            .markdown(calendar: cal, timeZone: chicago)
        #expect(md.contains("- 1:00 PM\u{2013}2:00 PM: HIGH PRIORITY: Exam [Samford]"))
        #expect(md.contains("- URGENT: Pay rent"))
    }

    @Test func quickAddWords() {
        let parsed = QuickAdd.parse("!urgent call the bank friday 3pm")
        #expect(parsed.title == "call the bank")
        #expect(parsed.priority == .urgent)
        #expect(parsed.hasTime)
        #expect(QuickAdd.parse("pay rent !!!").priority == .high)
        #expect(QuickAdd.parse("pay rent !!!").title == "pay rent")
        #expect(QuickAdd.parse("call mom!").priority == nil)
        #expect(QuickAdd.parse("call mom!").title == "call mom!")
    }
}

@Suite struct AlertPlannerTests {
    let settings = AlertSettings(enabled: true)

    @Test func importantGetsEveryOffsetNormalGetsOne() {
        let lecture = event("Lecture", at(10, 8, 10), at(10, 8, 11))
        let exam = event("Exam", at(10, 8, 14), at(10, 8, 16))
        let alerts = AlertPlanner.plan(events: [.init(lecture, priority: .none), .init(exam, priority: .high)],
                                       tasks: [], settings: settings, now: now, calendar: cal)
        #expect(alerts.filter { $0.title == "Lecture" }.map(\.date) == [at(10, 8, 9, 45)])
        #expect(alerts.filter { $0.title == "High: Exam" }.map(\.date)
            == [at(10, 7, 14), at(10, 8, 13), at(10, 8, 13, 45), at(10, 8, 14)])
        #expect(alerts.first { $0.date == at(10, 8, 13) }?.body.hasPrefix("In 1 hour") == true)
    }

    @Test func urgentTaskKeepsAlertingAfterItsDue() {
        let task = TaskItem(id: "t", title: "Pay rent", due: at(10, 6, 17), dueHasTime: true, priority: .urgent)
        let alerts = AlertPlanner.plan(events: [], tasks: [task], settings: settings, now: now, calendar: cal)
        // 1 day before is already past; then 1 hour, 15 minutes, at the time, and four repeats.
        #expect(alerts.map(\.date) == [at(10, 6, 16), at(10, 6, 16, 45), at(10, 6, 17),
                                      at(10, 6, 17, 15), at(10, 6, 17, 30), at(10, 6, 17, 45), at(10, 6, 18)])
        #expect(alerts.last?.body == "Still not done \u{00B7} was due 1h ago")
    }

    @Test func dayOnlyTasksUseTheMorningHourAndDoneOnesAreSkipped() {
        let open = TaskItem(id: "a", title: "Laundry", due: at(10, 7), dueHasTime: false)
        let done = TaskItem(id: "b", title: "Dishes", due: at(10, 7), isCompleted: true)
        let alerts = AlertPlanner.plan(events: [], tasks: [open, done], settings: settings, now: now, calendar: cal)
        #expect(alerts.map(\.title) == ["Laundry"])
        #expect(alerts.map(\.date) == [at(10, 7, 9)])
    }

    @Test func skipsMomentsTheTaskAlreadyAlertsAt() {
        // High: Daybook would alert 1 day, 1 hour and 15 minutes before, and at the time.
        // The task's own Reminders alerts cover 1 hour before and the due time.
        let task = TaskItem(id: "t", title: "Essay", due: at(10, 9, 17), dueHasTime: true, priority: .high,
                            alarms: [at(10, 9, 16), at(10, 9, 17)])
        let alerts = AlertPlanner.plan(events: [], tasks: [task], settings: settings, now: now, calendar: cal)
        #expect(alerts.map(\.date) == [at(10, 8, 17), at(10, 9, 16, 45)])
    }

    @Test func olderSavedSettingsStillLoad() throws {
        let old = #"{"enabled":false,"importantOffsets":[60],"urgentRepeatCount":2,"allDayHour":8}"#
        let settings = try JSONDecoder().decode(AlertSettings.self, from: Data(old.utf8))
        #expect(!settings.enabled && settings.importantOffsets == [60] && settings.allDayHour == 8)
        #expect(settings.leaveBy && settings.leaveBuffer == 5) // new fields: defaults
    }

    @Test func offMeansNothing() {
        var off = settings
        off.enabled = false
        let task = TaskItem(id: "a", title: "x", due: at(10, 7, 12), dueHasTime: true, priority: .urgent)
        #expect(AlertPlanner.plan(events: [], tasks: [task], settings: off, now: now, calendar: cal).isEmpty)
        var noNormal = settings
        noNormal.normalTaskOffset = nil
        let plain = TaskItem(id: "b", title: "y", due: at(10, 7, 12), dueHasTime: true)
        #expect(AlertPlanner.plan(events: [], tasks: [plain], settings: noNormal, now: now, calendar: cal).isEmpty)
    }
}

@Suite struct DayPlannerTests {
    let tasks = [
        TaskItem(id: "plain", title: "Water plants", due: nil),
        TaskItem(id: "today", title: "Return library book", due: at(10, 6)),
        TaskItem(id: "late", title: "Email the landlord", due: at(10, 4)),
        TaskItem(id: "urgent", title: "Pay rent", due: at(10, 9), priority: .urgent),
        TaskItem(id: "medium", title: "Read a book", due: nil, priority: .medium),
        TaskItem(id: "later", title: "Plan trip", due: at(10, 20)),
        TaskItem(id: "done", title: "Dishes", due: at(10, 6), isCompleted: true),
    ]

    @Test func mostPressingFirstAndOnlyWhatMatters() {
        #expect(DayPlanner.candidates(tasks, now: now, calendar: cal).map(\.id) == ["urgent", "late", "today", "medium"])
    }

    @Test func fillsStretchesInOrderSkippingOnesTooShort() {
        let blocks = [DateInterval(start: at(10, 6, 9), end: at(10, 6, 9, 45)),  // 45 min: too short for the urgent hour
                      DateInterval(start: at(10, 6, 13), end: at(10, 6, 15))]
        let slots = DayPlanner.plan(DayPlanner.candidates(tasks, now: now, calendar: cal), into: blocks)
        #expect(slots.map(\.task.id) == ["urgent", "late", "today"])
        #expect(slots.map(\.start) == [at(10, 6, 13), at(10, 6, 9), at(10, 6, 14, 5)])
        #expect(slots[0].minutes == 60)
    }
}

@Suite struct TimeGridLayoutTests {
    @Test func overlapsSplitTheWidthAndSeparateGroupsDont() {
        let events = [
            event("A", at(10, 6, 9), at(10, 6, 11)),
            event("B", at(10, 6, 10), at(10, 6, 12)),
            event("C", at(10, 6, 11), at(10, 6, 12)),   // A has ended: reuses column 0
            event("D", at(10, 6, 14), at(10, 6, 15)),   // on its own
        ]
        let places = TimeGridLayout.place(events)
        #expect(places["A"] == .init(column: 0, columns: 2))
        #expect(places["B"] == .init(column: 1, columns: 2))
        #expect(places["C"] == .init(column: 0, columns: 2))
        #expect(places["D"] == .init(column: 0, columns: 1))
    }
}

@Suite struct CountdownTests {
    @Test func deadlineCalendarsAndImportantItemsOnly() {
        let events = [
            event("Project deadline", at(10, 18), at(10, 19), allDay: true, calendar: "Deadlines"),
            event("Recruiter follow-up", at(10, 7), at(10, 8), allDay: true, calendar: "Job follow-ups"),
            event("Birthday", at(10, 9), at(10, 10), allDay: true, calendar: "Birthdays"),
            event("Exam", at(10, 12, 9), at(10, 12, 11)),                          // marked high below
            event("Lecture", at(10, 8, 10), at(10, 8, 11)),
            event("Far off", at(12, 20), at(12, 21), allDay: true, calendar: "Deadlines"), // past 60 days
        ]
        let picked = Countdown.upcoming(events, priorities: ["Exam": .high], now: now, calendar: cal)
        #expect(picked.map(\.title) == ["Recruiter follow-up", "Exam", "Project deadline"])
        #expect(Countdown.label(until: at(10, 7), now: now, calendar: cal) == "Tomorrow")
        #expect(Countdown.label(until: at(10, 18), now: now, calendar: cal) == "12 days")
        #expect(Countdown.label(until: at(10, 6, 20), now: now, calendar: cal) == "Today")
    }
}

@Suite struct FollowUpTests {
    let mine: Set<String> = ["mason@example.edu", "mason@example.com"]

    func sent(_ subject: String, to: String, name: String = "", _ date: Date, opening: String = "Hello") -> FollowUps.Sent {
        .init(account: "Samford", subject: subject, recipients: [to], names: [name], date: date, opening: opening)
    }

    @Test func subjects() {
        #expect(FollowUps.normalize("Re: FWD: RE[2]: Interview times") == "interview times")
        #expect(FollowUps.isAutomated("noreply@github.com"))
        #expect(FollowUps.isAutomated("no-reply+abc@accounts.google.com"))
        #expect(!FollowUps.isAutomated("smith@example.edu"))
        #expect(FollowUps.ownText("Sounds good, thanks!\n\nOn Oct 2, 2026, Dr. Smith wrote:\n> Can you send it?") == "Sounds good, thanks!")
    }

    @Test func findsQuietConversationsWorthChasing() {
        let sentMail = [
            // Started by him, no answer: waiting.
            sent("Research position", to: "smith@example.edu", name: "Dr. Smith", at(10, 1, 10)),
            // Answered after his message: not waiting.
            sent("Lab meeting", to: "lee@example.edu", at(10, 1, 9)),
            // His reply that asks nothing: not waiting.
            sent("Re: Your application", to: "hr@company.com", at(9, 30, 9), opening: "Thank you!\n\nOn Sep 29 HR wrote:\n> Any questions?"),
            // His reply with a question: waiting.
            sent("Re: Offer details", to: "recruiter@company.com", name: "Jordan", at(10, 2, 9), opening: "When would I hear back?"),
            // Too recent (sent yesterday).
            sent("Coffee chat", to: "alum@company.com", at(10, 5, 9)),
            // Only to an automated address.
            sent("Support ticket", to: "support@service.com", at(9, 28, 9)),
            // Older than three weeks.
            sent("Old thread", to: "old@example.edu", at(9, 1, 9)),
        ]
        let receivedMail = [
            FollowUps.Received(from: "lee@example.edu", subject: "RE: Lab meeting", date: at(10, 2, 9)),
            FollowUps.Received(from: "smith@example.edu", subject: "Research position", date: at(9, 30, 9)), // before his
        ]
        let waiting = FollowUps.waiting(sent: sentMail, received: receivedMail, mine: mine, now: now, calendar: cal)
        #expect(waiting.map(\.subject) == ["Research position", "Re: Offer details"])
        #expect(waiting.map(\.to) == [["Dr. Smith"], ["Jordan"]])
        #expect(waiting.map(\.days) == [5, 4])
        let dismissed = FollowUps.waiting(sent: sentMail, received: receivedMail, mine: mine, now: now,
                                          dismissed: [waiting[0].id], calendar: cal)
        #expect(dismissed.map(\.subject) == ["Re: Offer details"])
    }

    @Test func parsesMailsAnswer() {
        let fs = "\u{1F}", rs = "\u{1E}"
        let raw = "E\(fs)Samford\(fs)mason@example.edu;\(rs)"
            + "S\(fs)Samford\(fs)Research position\(fs)smith@example.edu;lab@example.edu;\(fs)Dr. Smith;;\(fs)2026-10-01T10:00:00\(fs)Hello?\(rs)"
            + "R\(fs)Smith@Example.edu\(fs)Re: Research position\(fs)2026-10-03T08:00:00\(rs)"
        let parsed = FollowUps.parse(raw, timeZone: chicago)
        #expect(parsed.mine == ["mason@example.edu"])
        #expect(parsed.sent.first?.recipients == ["smith@example.edu", "lab@example.edu"])
        #expect(parsed.sent.first?.names == ["Dr. Smith", ""])
        #expect(parsed.received.first?.from == "smith@example.edu")
        #expect(FollowUps.waiting(sent: parsed.sent, received: parsed.received, mine: parsed.mine, now: now, calendar: cal).isEmpty)
    }
}

@Suite struct CanvasTests {
    func feedItem(_ number: Int, _ title: String, _ due: Date) -> AgendaItem {
        AgendaItem(id: "event-assignment-\(number)@\(Int(due.timeIntervalSince1970))", title: title, start: due,
                   end: due.addingTimeInterval(86_400), isAllDay: true, calendar: "Canvas")
    }

    @Test func readsTheFeedsTitles() {
        let a = Canvas.assignment(feedItem(42, "Lab 4 - MNIST digits [COSC490.01]", at(10, 9)))
        #expect(a?.id == "42")
        #expect(a?.title == "Lab 4 - MNIST digits")
        #expect(a?.course == "COSC 490")
        #expect(a?.taskTitle == "COSC 490: Lab 4 - MNIST digits")
        #expect(Canvas.assignment(event("Lecture", at(10, 9, 10), at(10, 9, 11))) == nil)
        #expect(DaybookMarker(url: nil, notes: DaybookMarker.canvas(assignment: "42").url.absoluteString) == .canvas(assignment: "42"))
    }

    @Test func createsUpdatesAndLeavesAlone() {
        let new = Canvas.assignment(feedItem(1, "Essay [ENGL201.02]", at(10, 9)))!
        let moved = Canvas.assignment(feedItem(2, "Quiz 3 [COSC470.01]", at(10, 12)))!
        let finished = Canvas.assignment(feedItem(3, "Lab 2 [COSC490.01]", at(10, 8)))!
        let past = Canvas.assignment(feedItem(4, "Lab 1 [COSC490.01]", at(9, 20)))!
        let same = Canvas.assignment(feedItem(5, "Reading [COSC470.01]", at(10, 10)))!
        let existing = [
            "2": Canvas.Existing(reminderID: "r2", title: "COSC 470: Quiz 3", due: at(10, 11), isCompleted: false),
            "3": Canvas.Existing(reminderID: "r3", title: "COSC 490: Lab 2", due: at(10, 7), isCompleted: true),
            "5": Canvas.Existing(reminderID: "r5", title: "COSC 470: Reading", due: at(10, 10), isCompleted: false),
        ]
        let changes = Canvas.changes(assignments: [new, moved, finished, past, same], existing: existing, now: now, calendar: cal)
        #expect(changes == [.create(new), .update(reminderID: "r2", moved)])
    }

    @Test func courseNumbersFromFeedLinks() {
        let item = AgendaItem(id: "event-assignment-9@1", title: "Quiz [COSC470.01]", start: at(10, 9), end: at(10, 10),
                              isAllDay: true, calendar: "Canvas",
                              url: URL(string: "https://samford.instructure.com/calendar?include_contexts=course_55120&month=10&year=2026"))
        let assignment = Canvas.assignment(item)!
        #expect(assignment.courseID == "55120")
        #expect(Canvas.courses([assignment]) == ["55120": "COSC 470"])
    }

    @Test func assignmentsCountDown() {
        let item = feedItem(7, "Final project [COSC490.01]", at(10, 20))
        #expect(Countdown.upcoming([item], now: now, calendar: cal).map(\.title) == ["Final project [COSC490.01]"])
    }
}

@Suite struct WorkTests {
    func commit(_ repo: String, _ date: Date) -> Work.Commit {
        Work.Commit(hash: "\(repo)\(date.timeIntervalSince1970)", repo: repo, date: date, message: "x")
    }

    @Test func commitsCloseTogetherAreOneSession() {
        let commits = [
            commit("daybook", at(10, 6, 9)), commit("daybook", at(10, 6, 10, 30)), commit("sift", at(10, 6, 11)),
            commit("sift", at(10, 6, 15)), // over 2 hours later: a new session
        ]
        let sessions = Work.sessions(commits)
        #expect(sessions.count == 2)
        #expect(sessions[0].start == at(10, 6, 8, 30)) // half an hour before the first commit
        #expect(sessions[0].end == at(10, 6, 11))
        #expect(sessions[0].repos == ["daybook", "sift"])
        #expect(sessions[1].duration == 30 * 60)
    }

    @Test func readsGitLogWithChangeCounts() {
        let rs = "\u{1E}", fs = "\u{1F}"
        let output = "\(rs)abc1234def\(fs)1791300000\(fs)Mason Kimball\(fs)me@example.com\(fs)Add free time\n\n 3 files changed, 120 insertions(+), 8 deletions(-)\n"
            + "\(rs)fff0000aaa\(fs)1791200000\(fs)dependabot[bot]\(fs)bot@github.com\(fs)Bump x\n\n 1 file changed, 2 insertions(+)\n"
            + "\(rs)0001112223\(fs)1791100000\(fs)Mason Kimball\(fs)me@example.com\(fs)Delete old file\n\n 1 file changed, 40 deletions(-)\n"
        let commits = Work.parseGitLog(output, repo: "daybook") { name, _ in name == "Mason Kimball" }
        #expect(commits.map(\.shortHash) == ["abc1234", "0001112"])
        #expect(commits[0].changes == "+120 \u{2212}8 \u{00B7} 3 files")
        #expect(commits[1].insertions == 0 && commits[1].deletions == 40 && commits[1].files == 1)
    }

    @Test func readsGitHubEvents() throws {
        let json = """
        [
          {"type":"PullRequestEvent","created_at":"2026-10-06T15:00:00Z","repo":{"name":"MasonKimball05/gradtrack"},
           "payload":{"action":"closed","pull_request":{"number":12,"title":"Calendar feed","merged":true}}},
          {"type":"IssuesEvent","created_at":"2026-10-05T15:00:00Z","repo":{"name":"MasonKimball05/sift"},
           "payload":{"action":"opened","issue":{"number":3,"title":"Docx text"}}},
          {"type":"WatchEvent","created_at":"2026-10-05T16:00:00Z","repo":{"name":"someone/thing"},"payload":{"action":"started"}},
          {"type":"PushEvent","created_at":"2026-10-04T15:00:00Z","repo":{"name":"MasonKimball05/hackathon-2026"},"payload":{}}
        ]
        """
        let activities = Work.activities(fromEvents: Data(json.utf8))
        #expect(activities.map(\.kind) == [.prMerged, .issueOpened, .push])
        #expect(activities[0].repo == "gradtrack")
        #expect(activities[0].label == "Merged PR #12")
        let slim = #"[{"type":"PullRequestEvent","created_at":"2026-10-06T15:00:00Z","repo":{"name":"a/b"},"payload":{"action":"closed","pull_request":{"number":3,"merged_at":"2026-10-06T15:00:00Z"}}}]"#
        #expect(Work.activities(fromEvents: Data(slim.utf8)).first?.kind == .prMerged)
    }

    @Test func weeklyHoursByCalendarAndRepo() {
        let events = [
            event("Lecture", at(10, 6, 10), at(10, 6, 11, 30), calendar: "Samford"),
            event("Lab", at(10, 6, 11), at(10, 6, 12), calendar: "Samford"),          // overlaps: counted once
            event("Chapter", at(10, 7, 19), at(10, 7, 20), calendar: "Parliament"),
            event("Deadline", at(10, 7), at(10, 8), allDay: true, calendar: "Deadlines"), // all day: not time
        ]
        let snapshot = Work.Snapshot(gathered: now, commits: [commit("sift", at(10, 7, 14)), commit("sift", at(10, 7, 15))],
                                     activities: [], problems: [])
        let logged = [event("Study", at(10, 6, 21), at(10, 6, 23), calendar: TimeReport.logCalendar)] // to 11 PM; free time stops at 10
        let report = TimeReport(start: at(10, 6), days: 2, events: events + logged, snapshot: snapshot, calendar: cal)
        #expect(report.categories.map(\.name) == ["Samford", "Study", "Coding", "Parliament"])
        #expect(report.categories.map(\.kind) == [.calendar, .logged, .coding, .calendar])
        #expect(report.categories[0].hours == 2)
        #expect(report.categories[2].hours == 1.5) // 1:30 to 3:00
        // Free, 8 AM to 10 PM: day one loses 10-12 (classes) and 9-10 PM (study): 11h.
        // Day two loses 1:30-3 (coding) and 7-8 PM (chapter): 11.5h.
        #expect(report.days.map(\.free) == [11, 11.5])
        #expect(report.free == 22.5)
        #expect(report.byRepo.map(\.name) == ["sift"])
        #expect(report.commits == 2)
        #expect(TimeReport.hours(1.5) == "1.5h" && TimeReport.hours(0.75) == "45m" && TimeReport.hours(12) == "12h")
        let md = report.markdown(title: "Where your time went", timeZone: chicago)
        #expect(md.contains("## Hours by kind\n- Samford \u{2013} Calendar: 2.0h\n- Study: 2.0h (logged)\n- Coding: 1.5h\n- Parliament \u{2013} Calendar: 1.0h"))
        #expect(TimeReport.label("Calendar", kind: .calendar) == "Calendar")
        #expect(TimeReport.label("Home", kind: .calendar) == "Home \u{2013} Calendar")
        #expect(TimeReport.label("Study", kind: .logged) == "Study")
        #expect(md.contains("Free time (8 AM to 10 PM, nothing scheduled, coded or logged): 22h"))
        #expect(cal.isDate(TimeReport.weekStart(of: at(10, 8), calendar: cal), inSameDayAs: at(10, 4))) // Thu -> Sun
    }
}

@Suite struct BillsTests {
    @Test func spotsBillingSubjects() {
        #expect(Bills.isBilling(subject: "Your Spotify Premium receipt"))
        #expect(Bills.isBilling(subject: "Your subscription will renew soon"))
        #expect(!Bills.isBilling(subject: "Your order has shipped"))
        #expect(!Bills.isBilling(subject: "Verify your billing email"))
        #expect(!Bills.isBilling(subject: "Lunch on Friday?"))
    }

    @Test func merchantNames() {
        #expect(Bills.merchant(fromSender: "Spotify <no-reply@spotify.com>") == "Spotify")
        #expect(Bills.merchant(fromSender: "\"Netflix via Stripe\" <invoice@stripe.com>") == "Netflix")
        #expect(Bills.merchant(fromSender: "billing@mail.github.com") == "Github")
        #expect(Bills.merchant(fromSender: "Notion Billing <team@makenotion.com>") == "Notion")
    }

    @Test func amountsAndRenewalDates() {
        #expect(Bills.amount(in: "Thanks! Subtotal $10.99 Tax $1.00 Total: $11.99") == 11.99)
        #expect(Bills.amount(in: "You were charged $1,299.00 today") == 1299)
        #expect(Bills.amount(in: "Plan $4.99 and add-on $2.00") == 4.99)
        #expect(Bills.amount(in: "No money here") == nil)
        let renews = Bills.renewalDate(in: "Your plan renews on October 21, 2026 automatically.", after: at(10, 1))
        #expect(renews.map { cal.component(.day, from: $0) } == 21)
    }

    func email(_ merchant: String, _ date: Date, _ amount: Double?, renews: Date? = nil) -> Bills.Email {
        Bills.Email(merchant: merchant, subject: "Receipt", date: date, amount: amount, renews: renews)
    }

    @Test func findsSubscriptionsByRhythm() {
        let emails = [
            email("Spotify", at(7, 10), 11.99), email("Spotify", at(8, 10), 11.99), email("Spotify", at(9, 10), 11.99),
            email("Spotify", at(9, 11), nil),                   // a second email for the same charge
            email("Amazon", at(9, 2), 23.17),                   // a one-off order
            email("iCloud", at(9, 25), 0.99, renews: at(10, 25)),// one email, but says when it renews
            email("Old Gym", at(3, 1), 30), email("Old Gym", at(4, 1), 30), // stopped in April
        ]
        let subs = Bills.subscriptions(emails, now: now, calendar: cal)
        #expect(subs.map(\.merchant) == ["Spotify", "iCloud", "Old Gym"])
        #expect(subs[0].cadence == .monthly && subs[0].charges == 3 && subs[0].amount == 11.99)
        #expect(subs[0].nextRenewal.map { cal.isDate($0, inSameDayAs: at(10, 10)) } == true)
        #expect(subs[2].nextRenewal == nil)                    // looks cancelled
        #expect(abs((subs[0].monthly ?? 0) - 11.99) < 0.01)
        #expect(Bills.subscriptions(emails, now: now, ignored: ["Spotify"], calendar: cal).count == 2)
        let md = Bills.Snapshot(gathered: now, subscriptions: subs).markdown(now: now, timeZone: chicago)
        #expect(md.contains("- Spotify: $11.99 monthly, renews Sat Oct 10 (in 4 days)"))
    }
}

@Suite struct SleepTests {
    func sample(_ start: Date, _ end: Date, asleep: Bool = true) -> Sleep.Sample {
        Sleep.Sample(start: start, end: end, asleep: asleep)
    }

    @Test func samplesBecomeNights() {
        let samples = [
            sample(at(10, 5, 23), at(10, 6, 2)),
            sample(at(10, 6, 2, 20), at(10, 6, 7)),               // woke 20 min: same night, not counted
            sample(at(10, 5, 22, 30), at(10, 6, 7, 10), asleep: false), // in bed: ignored when stages exist
            sample(at(10, 6, 14), at(10, 6, 14, 30)),             // a 30-minute nap: left out
            sample(at(10, 6, 23, 30), at(10, 7, 6, 30)),          // the next night
            sample(at(10, 7, 1), at(10, 7, 3)),                   // a second source, overlapping: counted once
        ]
        let nights = Sleep.nights(samples)
        #expect(nights.count == 2)
        #expect(nights[0].start == at(10, 5, 23) && nights[0].end == at(10, 6, 7))
        #expect(nights[0].asleep == 3 * 3600 + 4 * 3600 + 40 * 60) // 11-2 and 2:20-7
        #expect(nights[1].asleep == 7 * 3600)
        #expect(Sleep.decode(Sleep.encode(nights)) == nights)
    }

    @Test func inBedOnlyStillMakesANight() {
        let nights = Sleep.nights([sample(at(10, 5, 23), at(10, 6, 7), asleep: false)])
        #expect(nights.map(\.asleep) == [8 * 3600])
    }

    @Test func freeTimeRunsFromWakingToSleeping() {
        let nights = [
            Sleep.Night(start: at(10, 5, 23), end: at(10, 6, 7, 30), asleep: 8 * 3600),
            Sleep.Night(start: at(10, 7, 0, 30), end: at(10, 7, 8), asleep: 7 * 3600), // after midnight
        ]
        let events = [event("Lecture", at(10, 6, 10), at(10, 6, 11))]
        let report = TimeReport(start: at(10, 6), days: 2, events: events, snapshot: nil, nights: nights, calendar: cal)
        // Day one: awake 7:30 AM to 12:30 AM (17h), minus the hour of lecture: 16h free.
        #expect(report.days[0].free == 16)
        #expect(report.days[0].slept == 8)
        #expect(report.days[0].hours[TimeReport.sleep] == 8)
        // Day two has last night's sleep but no bedtime: 8 AM (after the 8 AM wake-up) to 10 PM.
        #expect(report.days[1].free == 14)
        #expect(report.categories.first { $0.name == TimeReport.sleep }?.kind == .sleep)
    }
}

@Suite struct HopTests {
    @Test func feedHasWhatsLeftOfToday() {
        let events = [
            event("Lecture", at(10, 6, 8), at(10, 6, 8, 50)),     // over
            event("Lab", at(10, 6, 13), at(10, 6, 15)),
            event("Fair", at(10, 6), at(10, 7), allDay: true),
            event("Tomorrow", at(10, 7, 9), at(10, 7, 10)),
        ]
        let tasks = [
            TaskItem(id: "a", title: "Essay", due: at(10, 6), priority: .high),
            TaskItem(id: "b", title: "Late", due: at(10, 4)),
            TaskItem(id: "c", title: "Later", due: at(10, 9)),
        ]
        let feed = HopFeed.build(now: now, events: events, tasks: tasks, countdowns: [], waitingOnReplies: 2,
                                 sessions: [], commitsToday: 0, calendar: cal)
        #expect(feed.today.map(\.title) == ["Fair", "Lab"])
        #expect(feed.tasks.map(\.id) == ["a", "b"])   // high priority first, then by due date
        #expect(feed.tasks[1].overdue)
        #expect(feed.tasks[0].priority == "high")
    }

    @Test func linksDaybookAnswers() {
        #expect(DaybookLink(URL(string: "daybook://add-task?text=submit%20report%20friday")!) == .addTask("submit report friday"))
        #expect(DaybookLink(URL(string: "daybook://complete-task?id=XYZ")!) == .completeTask(id: "XYZ"))
        #expect(DaybookLink(URL(string: "daybook://show?view=time")!) == .show("time"))
        let log = DaybookLink(URL(string: "daybook://log?title=Study&start=2026-10-07T03:00:00Z&end=2026-10-07T04:00:00Z")!)
        #expect(log == .log(title: "Study", start: Date(timeIntervalSince1970: 1_791_342_000), end: Date(timeIntervalSince1970: 1_791_345_600)))
        #expect(DaybookLink(URL(string: "daybook://log?title=Study&start=2026-10-07T04:00:00Z&end=2026-10-07T03:00:00Z")!) == nil)
        #expect(DaybookLink(URL(string: "daybook://delete-everything")!) == nil)
        #expect(DaybookLink(URL(string: "https://add-task?text=x")!) == nil)
    }
}
