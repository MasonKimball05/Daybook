# Daybook

[![Tests](https://github.com/MasonKimball05/Daybook/actions/workflows/tests.yml/badge.svg)](https://github.com/MasonKimball05/Daybook/actions/workflows/tests.yml)

One agenda for everything: every calendar on my Mac, my apps' dates, and my
tasks, in one window. It also writes a daily summary that a scheduled Claude
agent turns into my morning brief.

- **Every calendar macOS syncs**, through EventKit: iCloud, Samford's Outlook
  (added in System Settings ▸ Internet Accounts), and subscribed feeds.
- **My apps, as subscribed calendars** (Calendar ▸ File ▸ New Calendar Subscription):
  - Gradtrack deadlines: `http://<desktop>:8096/calendar.ics`
  - Job Tracker follow-ups: `http://<desktop>:5206/calendar.ics`
  - Parliament events: my personal feed from Parliament's calendar page

  Subscribe to the desktop feeds **On My Mac**, not iCloud: iCloud's servers
  can't reach the desktop over Tailscale. Calendar keeps a copy, so they stay
  visible when the desktop is off.
- **Tasks are Apple Reminders**, so they sync to my iPhone. Type
  "submit report friday 3pm" and it becomes a task due Friday at 3:00 PM.
- **Today, Week, Month and Tasks** views, and a Calendars menu to hide any calendar.
- **Mark anything done**: tasks complete in Reminders (and can be undone the same
  day), and calendar events get a check too. Events have no "done" of their own, so
  each mark is a completed reminder in a **Daybook** list in Reminders. iCloud syncs
  it, so a check made on the iPhone shows on the Mac.
- **iPhone app** from the same code (`Daybook.xcodeproj`): iCloud keeps the two in
  step with no server, desktop on or off.

Swift 6 and SwiftUI, no dependencies.

## Also

- **Widgets (iPhone):** the next event with a countdown and today's tasks, checkable from the home screen. Lock screen sizes too.
- **Menu bar (Mac):** the next event and time until it; click for today's agenda. ⌃⌥Space adds a task from any app (Tab switches to an event). "Open at Login" is in the panel.
- **Events:** add from the quick-add field (click its icon to switch to events), New Event (⌘N, or + on iPhone), and Edit or Delete from an event's details. Subscribed calendars are read-only.
- **Free time:** open stretches (8 AM to 10 PM, 30 minutes or more) show between events. Tap one, or drag a task onto it, to block the time.
- **Week ahead:** `week.md` is written with `today.md`; the "Week ahead (Daybook)" scheduled task turns it into a Sunday 6 PM preview, posted to the iPhone like the morning brief.
- **Priority and alerts:** set a task's or event's priority (None to Urgent) from its right-click / long-press menu, the event details, or by typing `!high` / `!urgent` when adding. High and urgent get an alert at each time you pick; everything else gets one; urgent tasks can keep nagging after they're due. Settings: ⌘, on the Mac, the gear on Tasks on the iPhone. Each device has its own switch (the Mac starts off). Task priorities are Reminders' own (urgent shows there as high); event priorities live in the Daybook list.
- **Siri and Shortcuts (iPhone):** "Add a task in Daybook", "Add an event in Daybook", "What's next in Daybook", "What's on today in Daybook". All four are in the Shortcuts app too, for the Action button.
- **Plan My Day:** fits urgent, overdue and due-today tasks into today's free time. Switch tasks off or change their length, then Add to Calendar.
- **Leave-by alerts (iPhone):** for events with a place in the next 12 hours, an alert when it's time to go, from Apple Maps travel time (driving or walking, plus extra time).
- **Task details:** tap a task for its notes, link, list, date, repeat (daily, weekdays, weekly...), priority, or to delete it.
- **Week grid (Mac):** the Week tab is hour by hour. Drag events to move them, drag the bottom edge to change the length, double-click for a new event. The 7-day list is the Agenda tab.
- **Undo:** a banner (and ⌘Z on the Mac) after checking off, deleting, blocking time, planning or moving.
- **Countdowns:** days left to deadlines (all-day items on calendars named like "deadlines" or "follow-ups", and anything high or urgent), on Today, in the menu bar panel, and in the Deadlines widget.
- **Waiting on replies (Mac):** the morning export checks Mail's Sent and Inbox for the last three weeks and lists conversations you started (or asked a question in) with no answer for 3+ days. They're in the brief and in Tasks, with Follow Up (a task due today) and Got a Reply.
- **Coding work (Mac):** commits from every repo in ~/Documents/GitHub (yours only, with change counts) and GitHub pull requests, issues, reviews and comments (through `gh`), gathered hourly and each morning. Commits close together become work sessions. They show in orange: session rows (expand for each commit's hash, time, repo and changes) in Today and any day, a commit line in the month grid, blocks in the week grid. `work.md` (yesterday) and `time.md` (the last 7 days, by calendar and repo) feed the briefs.
- **Time recap:** the Time tab, Sunday to Saturday: free time (8 AM to 10 PM with nothing on), hours by calendar, coding by repo, and time you log yourself (Log Activity, saved to a Time Log calendar in iCloud and counted by name).
- **Subscriptions (Mac):** billing emails from the last 13 months, read weekly in the background, find what renews on a rhythm. Renewals in the next two weeks join the countdowns; Tasks lists them with a monthly total. Remove one that's cancelled (right-click in the countdowns, or Remove in Tasks).
- **hop and daybook:// links:** Daybook writes `hop.json` for [hop](https://github.com/MasonKimball05/hop) and answers `daybook://add-task?text=`, `add-event?text=`, `log?title=&start=&end=`, `complete-task?id=`, `show?view=` and `brief`. They only add or check things off, never read or delete.
- **Search:** ⌘F on the Mac, the Search tab on the iPhone. Events six months back to a year ahead, and every task.

The scheduled briefs run only `Tools/brief.sh` (morning, week, check, post), so each unattended run needs a handful of approvals given once instead of a prompt for every step.

## Build and install

```bash
make test      # the summary, quick-add parsing and day grouping
make install   # builds Daybook.app into ~/Applications and opens it
```

The first launch asks for Calendars and Reminders access. Builds go to
`~/Library/Caches/Daybook`, because codesign refuses bundles in iCloud-synced folders.

## iPhone

```bash
xcodegen generate     # after changing project.yml
open Daybook.xcodeproj
```

Plug in the iPhone, pick it as the run destination, and press Run. The first time:
turn on **Developer Mode** (Settings ▸ Privacy & Security), and trust the developer
(Settings ▸ General ▸ VPN & Device Management). With a free Apple ID the app stops
opening after 7 days; press Run again to renew it. Nothing is lost, since the data
lives in iCloud.

### SideStore (no weekly replug)

SideStore re-signs the app on the phone every week by itself, over Wi-Fi.

```bash
make ipa              # writes build/Daybook.ipa
```

AirDrop `build/Daybook.ipa` to the iPhone and open it in SideStore (or use the + in
SideStore's My Apps). Delete the copy Xcode installed first: SideStore gives the app
its own bundle ID, so the two would sit side by side.

### The morning brief on the iPhone

The phone can't read files on the Mac, so the brief travels through Reminders. The
scheduled task writes `brief.md` and runs `open -n -g -a Daybook --args --post-brief`,
which saves it as a completed reminder in the hidden **Daybook** list in iCloud. The
iPhone app pops today's up once, and the sun button on Today lists the last two weeks.

## The daily summary

Daybook writes `~/Library/Application Support/Daybook/today.md` (and `today.json`)
whenever anything changes and every 15 minutes while it's open: today, tomorrow,
tasks due or overdue, undated tasks, and all-day items over the next two weeks.

To refresh it without opening a window (this is what the morning agent runs).
`-n` matters: without it, a Daybook that's already open just comes to the front
and ignores the arguments.

```bash
open -n -g -a Daybook --args --export
```

### Email

```bash
open -n -g -a Daybook --args --export --mail
```

`--mail` also writes `mail.md` and `mail.json`: unread inbox messages from the last
3 days in every account in Apple Mail (the first 600 characters of each), for the
brief to sort into "needs you" and "can wait". Daybook only reads; it never marks,
moves or sends anything. The first run asks to let Daybook control Mail
(Privacy & Security ▸ Automation), so run it once by hand before the morning task does.

## How it works

| Piece | File | Notes |
|---|---|---|
| Calendars and reminders | `Sources/Daybook/CalendarStore.swift` | EventKit, copied into plain value types so nothing else touches EventKit. Refreshes on `EKEventStoreChanged`. |
| Views | `Sources/Daybook/Views.swift` | Today and Week share one agenda list; Tasks groups reminders by due date. |
| Quick-add | `Sources/DaybookCore/QuickAdd.swift` | NSDataDetector finds the date, the rest is the title. A bare day ("friday") has no time; "3pm" does. |
| Days | `Sources/DaybookCore/Agenda.swift` | A multi-day event shows on every day it touches. |
| Summary | `Sources/DaybookCore/DailySummary.swift` | The Markdown the morning agent reads. |
| Daybook list | `Sources/DaybookCore/Markers.swift` | Done marks and briefs are completed reminders in a hidden iCloud list. What each stands for is a `daybook://` link in its URL and again on the first line of its notes, because Exchange drops URLs. |
