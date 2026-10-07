#if os(macOS)
import AppKit
import Carbon.HIToolbox
import DaybookCore
import ServiceManagement
import SwiftUI

// The menu bar item: the next event and how long until it, and today's agenda in a
// panel below. Plus ⌃⌥Space from any app for a quick-add box.

/// The time, once a minute, for the menu bar label. (A TimelineView in a menu bar
/// label sends SwiftUI into an endless redraw at launch.)
@MainActor
@Observable
final class MinuteClock {
    private(set) var now = Date.now

    init() {
        Task { [weak self] in
            while !Task.isCancelled {
                // Wake at the top of each minute, so the countdown is never a minute stale.
                let seconds = 60 - Calendar.current.component(.second, from: .now)
                try? await Task.sleep(for: .seconds(seconds))
                self?.now = .now
            }
        }
    }
}

/// "Algorithms in 25m", "Algorithms · until 3:00 PM" while it's on, or just the icon.
struct MenuBarLabel: View {
    let store: CalendarStore
    let clock: MinuteClock

    var body: some View {
        if let text = Self.text(store.events.filter { !store.isDone($0) }, now: clock.now) {
            Text(text)
        } else {
            Image(systemName: "calendar")
        }
    }

    /// Only timed events today, and only from 4 hours out, so the bar stays quiet otherwise.
    static func text(_ events: [AgendaItem], now: Date) -> String? {
        let today = events.filter { !$0.isAllDay && $0.end > now && Calendar.current.isDate($0.start, inSameDayAs: now) }
            .sorted { $0.start < $1.start }
        guard let next = today.first else { return nil }
        let title = next.title.count > 22 ? next.title.prefix(21) + "\u{2026}" : next.title
        if next.start <= now {
            return "\(title) \u{00B7} until \(next.end.formatted(date: .omitted, time: .shortened))"
        }
        let minutes = Int(next.start.timeIntervalSince(now) / 60) + 1
        guard minutes <= 4 * 60 else { return nil }
        let wait = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
        return "\(title) in \(wait)"
    }
}

/// The panel under the menu bar item.
struct MenuBarPanel: View {
    let store: CalendarStore
    @Environment(\.openWindow) private var openWindow
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let now = Date.now
        let calendar = Calendar.current
        let events = store.events.filter { calendar.isDateInToday($0.start) || ($0.start < now && $0.end > now) }
            .filter { $0.isAllDay || $0.end > now }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
        let tasks = store.tasks.filter { task in task.due.map { $0 < calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))! } ?? false }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }

        VStack(alignment: .leading, spacing: 10) {
            Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.headline)
            QuickAddField(store: store)
            Divider()
            if events.isEmpty && tasks.isEmpty {
                Text("Nothing else today.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(events.prefix(8)) { EventRow(store: store, item: $0) }
                    if !tasks.isEmpty {
                        Text("Tasks").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(tasks.prefix(8)) { TaskRow(store: store, task: $0, showDate: false) }
                    }
                    if !store.countdowns.isEmpty {
                        Text("Counting down").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(store.countdowns.prefix(3)) { CountdownRow(store: store, item: $0) }
                    }
                }
            }
            .frame(maxHeight: 420)
            Divider()
            HStack {
                Button("Open Daybook") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Toggle("Open at Login", isOn: $opensAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: opensAtLogin) { setOpensAtLogin(opensAtLogin) }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            Text("\u{2303}\u{2325}Space adds a task from any app. Tab switches to an event.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 360)
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            opensAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: Quick add from anywhere

/// A floating quick-add box, shown by ⌃⌥Space.
@MainActor
final class QuickAddPanel {
    private static var panel: NSPanel?

    static func show(store: CalendarStore) {
        if panel == nil {
            let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 64),
                                 styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.hidesOnDeactivate = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: QuickAddBox(store: store) { Self.hide() })
            self.panel = panel
        }
        panel?.center()
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    static func hide() { panel?.orderOut(nil) }

    /// The box's window. Escape reaches the window as `cancelOperation` even
    /// when the text field doesn't pass it on, and clicking anywhere else takes
    /// away key status (`resignKey`): either way, the box goes away.
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }

        override func cancelOperation(_ sender: Any?) {
            orderOut(nil)
        }

        override func resignKey() {
            super.resignKey()
            orderOut(nil)
        }
    }
}

struct QuickAddBox: View {
    let store: CalendarStore
    let close: () -> Void
    @State private var text = ""
    @State private var makingEvent = false
    @FocusState private var focused: Bool

    var body: some View {
        let parsed = QuickAdd.parse(text)
        HStack(spacing: 10) {
            Button { makingEvent.toggle() } label: {
                Image(systemName: makingEvent ? "calendar.circle.fill" : "plus.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .help("Switch between a task and an event (Tab)")
            TextField(makingEvent ? "Add an event: \u{201C}coffee with Sam thu 2pm\u{201D}" : "Add a task: \u{201C}submit report friday 3pm\u{201D}", text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onKeyPress(.tab) {
                    makingEvent.toggle()
                    return .handled
                }
                .onSubmit {
                    if makingEvent { store.addEvent(text) } else { store.addTask(text) }
                    text = ""
                    close()
                }
            if !text.isEmpty, let due = parsed.due {
                Text(QuickAddField.label(due, hasTime: parsed.hasTime)).font(.callout).foregroundStyle(.secondary)
            }
            Button {
                text = ""
                close()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .frame(width: 560, height: 64)
        .onAppear { focused = true }
        .onExitCommand {
            text = ""
            close()
        }
    }
}

/// A system-wide keyboard shortcut. Carbon's hot keys need no Accessibility
/// permission, unlike watching every key press.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private let action: () -> Void

    init(key: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4459_4259), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}
#endif
