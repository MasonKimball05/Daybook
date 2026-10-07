import AppKit
import Carbon.HIToolbox
import DaybookCore
import SwiftUI

// `open -n -g -a Daybook --args --export` writes the daily summary and quits without
// showing a window. The morning-brief agent uses it, so the summary is fresh even
// when Daybook isn't running. Adding `--mail` also writes mail.md: unread inbox
// messages from every account in Apple Mail.
if CommandLine.arguments.contains("--post-brief") {
    // The morning-brief task runs `open -n -g -a Daybook --args --post-brief` after
    // writing brief.md. That puts the brief in Reminders for the iPhone app, then quits.
    Task { @MainActor in
        let store = CalendarStore()
        await store.checkAccess()
        let file = DailySummary.folder.appending(path: "brief.md")
        guard let markdown = try? String(contentsOf: file, encoding: .utf8), !markdown.isEmpty else { exit(1) }
        exit(await store.postBrief(markdown) ? 0 : 1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.run()
} else if CommandLine.arguments.contains("--bills") {
    // `open -n -g -a Daybook --args --bills`: the weekly subscriptions scan, on its
    // own so it never holds up the morning export.
    Task { @MainActor in
        BillReader.refresh()
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.run()
} else if CommandLine.arguments.contains("--export") {
    Task { @MainActor in
        let store = CalendarStore()
        await store.checkAccess()
        // Commits and GitHub activity, for "where your time goes" (work.md, time.md).
        await store.refreshWork()
        if CommandLine.arguments.contains("--mail") {
            switch MailReader.unread() {
            case .success(let digest):
                try? digest.write()
            case .failure(let failure):
                // Leave a note the brief can pass on, instead of yesterday's mail.
                let note = "# Unread email\n\nCouldn\u{2019}t read Apple Mail: \(failure.description)\n"
                try? Data(note.utf8).write(to: DailySummary.folder.appending(path: "mail.md"), options: .atomic)
                try? FileManager.default.removeItem(at: DailySummary.folder.appending(path: "mail.json"))
            }
            // Emails waiting on a reply, for the brief's "Waiting on replies".
            switch FollowUpReader.waiting(dismissed: FollowUpReader.dismissed) {
            case .success(let waiting):
                try? FollowUps.write(waiting)
            case .failure(let failure):
                let note = "# Waiting on replies\n\nCouldn\u{2019}t check sent mail: \(failure.description)\n"
                try? Data(note.utf8).write(to: DailySummary.folder.appending(path: "followups.md"), options: .atomic)
            }
        }
        exit(store.eventAccess == .granted ? 0 : 1)
    }
    // A real (invisible) app event loop on the real main thread. While AppleScript
    // waits for Mail it pumps that loop, and AppKit's text-input code checks it's on
    // the main thread. dispatchMain() would park the main thread and run this work on
    // another one, which crashed with "unexpected thread".
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited) // no Dock icon, no menu bar
    app.run()
} else {
    DaybookApp.main()
}

struct DaybookApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Daybook", id: "main") {
            ContentView(store: delegate.store)
        }
        .defaultSize(width: 620, height: 720)

        MenuBarExtra {
            MenuBarPanel(store: delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store, clock: delegate.clock)
                .onAppear { delegate.openMain = { [openWindow] in openWindow(id: "main") } }
        }
        .menuBarExtraStyle(.window)

        Settings {
            AlertSettingsView(store: delegate.store).frame(width: 460, height: 620)
        }
    }
}

extension AppDelegate {
    /// Subscriptions change slowly and the scan reads a lot of mail, so it runs
    /// about once a week, as its own background copy of Daybook.
    static func refreshBillsIfStale() {
        let gathered = Bills.Snapshot.read()?.gathered ?? .distantPast
        guard gathered.timeIntervalSinceNow < -6 * 86_400 else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.arguments = ["--bills"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
    }
}

/// Startup work lives here, not on a view: it has to run whether or not the window
/// is open, and the menu bar label doesn't run view tasks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = CalendarStore()
    let clock = MinuteClock()
    private var hotKey: HotKey?
    /// Opens the main window; set by the menu bar label, which has SwiftUI's openWindow.
    var openMain: () -> Void = {}

    /// daybook:// links, from hop or anywhere (see DaybookLink). Adding and
    /// checking off happen in the background; showing a view brings Daybook forward.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let link = DaybookLink(url) else { continue }
            Task { @MainActor in await handle(link) }
        }
    }

    private func handle(_ link: DaybookLink) async {
        if store.eventAccess == .unknown { await store.checkAccess() }
        switch link {
        case .addTask(let text):
            store.addTask(text)
        case .addEvent(let text):
            store.addEvent(text)
        case .log(let title, let start, let end):
            store.logActivity(title, from: start, to: end)
        case .completeTask(let id):
            if let task = store.tasks.first(where: { $0.id == id }) { store.setDone(task, true, undoable: false) }
        case .show(let view):
            show(view)
        case .brief:
            show("brief")
        }
    }

    private func show(_ view: String) {
        openMain()
        NSApp.activate()
        // ContentView switches to it (see .onReceive there).
        NotificationCenter.default.post(name: .daybookShow, object: view)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKey = HotKey(key: kVK_Space, modifiers: controlKey | optionKey) { [store] in QuickAddPanel.show(store: store) }
        Task {
            await store.checkAccess()
            await store.refreshWork()
            Self.refreshBillsIfStale()
            // Keep "today" and the summary current while the app runs; coding work hourly.
            var rounds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                await store.reload()
                rounds += 1
                if rounds % 4 == 0 {
                    await store.refreshWork()
                    Self.refreshBillsIfStale()
                }
            }
        }
    }
}
