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
} else if CommandLine.arguments.contains("--export") {
    Task { @MainActor in
        let store = CalendarStore()
        await store.checkAccess()
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

    var body: some Scene {
        Window("Daybook", id: "main") {
            ContentView(store: delegate.store)
        }
        .defaultSize(width: 620, height: 720)

        MenuBarExtra {
            MenuBarPanel(store: delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store, clock: delegate.clock)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Startup work lives here, not on a view: it has to run whether or not the window
/// is open, and the menu bar label doesn't run view tasks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = CalendarStore()
    let clock = MinuteClock()
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKey = HotKey(key: kVK_Space, modifiers: controlKey | optionKey) { [store] in QuickAddPanel.show(store: store) }
        Task {
            await store.checkAccess()
            // Keep "today" and the summary current while the app runs.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                await store.reload()
            }
        }
    }
}
