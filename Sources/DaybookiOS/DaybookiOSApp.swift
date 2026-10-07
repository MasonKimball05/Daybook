import DaybookCore
import SwiftUI

/// Daybook on the iPhone: the same store and views as the Mac app, with tabs
/// instead of the Mac's toolbar picker. iCloud keeps the two in step: tasks are
/// Reminders and "done" marks live in the Daybook list there.
@main
struct DaybookiOSApp: App {
    @State private var store = CalendarStore()
    @Environment(\.scenePhase) private var phase
    @State private var showingBrief = false
    @State private var showingHistory = false
    @State private var addingEvent = false
    @State private var query = ""

    var body: some Scene {
        WindowGroup {
            Group {
                if store.eventAccess == .granted || store.reminderAccess == .granted {
                    TabView {
                        Tab("Today", systemImage: "sun.max") {
                            NavigationStack {
                                DayListView(store: store, start: .now, days: 1)
                                    .navigationTitle("Today")
                                    .toolbar {
                                        // Today's brief again, and the ones before it.
                                        Button { showingHistory = true } label: { Label("Morning Briefs", systemImage: "sun.horizon") }
                                        newEventButton
                                    }
                            }
                        }
                        Tab("Week", systemImage: "calendar.day.timeline.left") {
                            NavigationStack {
                                DayListView(store: store, start: .now, days: 7)
                                    .navigationTitle("This Week")
                                    .toolbar { newEventButton }
                            }
                        }
                        Tab("Month", systemImage: "calendar") {
                            NavigationStack {
                                MonthView(store: store)
                                    .navigationTitle("Month")
                                    .toolbarTitleDisplayMode(.inline)
                                    .toolbar { newEventButton }
                            }
                        }
                        Tab("Search", systemImage: "magnifyingglass", role: .search) {
                            NavigationStack {
                                SearchResultsView(store: store, query: query)
                                    .navigationTitle("Search")
                                    .searchable(text: $query, prompt: "Events and tasks")
                            }
                        }
                        Tab("Tasks", systemImage: "checklist") {
                            NavigationStack {
                                TasksView(store: store)
                                    .navigationTitle("Tasks")
                                    .toolbar { CalendarFilter(store: store) }
                            }
                        }
                    }
                    .refreshable { await store.reload() }
                    .sheet(isPresented: $showingBrief) {
                        if let brief = store.brief {
                            BriefPopup(brief: brief)
                                .onAppear {
                                    store.briefSeen()
                                    Task { await BriefNotifier.markSeen(brief) }
                                }
                        }
                    }
                    .sheet(isPresented: $addingEvent) { EventEditor(store: store) }
                    .sheet(isPresented: $showingHistory) {
                        BriefHistoryView(briefs: store.briefs).onAppear {
                            store.briefSeen()
                            if let brief = BriefNotifier.unseen(store) { Task { await BriefNotifier.markSeen(brief) } }
                        }
                    }
                    // Today's brief pops up once, as soon as it arrives from the Mac.
                    .onChange(of: store.brief?.date, initial: true) { showNewBrief() }
                } else {
                    PermissionView(store: store)
                }
            }
            .task {
                await store.checkAccess()
                showNewBrief()
                await BriefNotifier.requestPermission()
                await BriefNotifier.scheduleBackups()
            }
            // Coming back to the app: pick up anything changed on the Mac.
            .onChange(of: phase) {
                if phase == .active {
                    Task {
                        await store.reload()
                        showNewBrief()
                    }
                } else if phase == .background {
                    BriefNotifier.scheduleRefresh()
                }
            }
        }
        // iOS woke Daybook in the background: look for today's brief.
        .backgroundTask(.appRefresh(BriefNotifier.refreshTask)) { [store] in
            await store.checkAccess()
            await BriefNotifier.check(store)
        }
    }

    private var newEventButton: some View {
        Button { addingEvent = true } label: { Label("New Event", systemImage: "plus") }
    }

    private func showNewBrief() {
        guard BriefNotifier.unseen(store) != nil, !showingBrief, !showingHistory else { return }
        showingBrief = true
    }
}
