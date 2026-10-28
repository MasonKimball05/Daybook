import CoreSpotlight
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
    @State private var showingSettings = false
    @State private var planning = false
    @State private var searching = false
    @State private var searchFieldActive = false
    @State private var screen = Screen.today
    /// Goes up for a tab each time it's tapped while already open: back to now, or this month.
    @State private var reselected: [Screen: Int] = [:]
    private let requests = AppRequests.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if store.eventAccess == .granted || store.reminderAccess == .granted {
                    TabView(selection: tabSelection) {
                        Tab("Today", systemImage: "sun.max", value: .today) {
                            NavigationStack {
                                DayListView(store: store, start: .now, days: 1, quickAddFocus: requests.quickAdd,
                                            jumpToNow: reselected[.today, default: 0], startsAtNow: true)
                                    .navigationTitle("Today")
                                    .toolbar {
                                        // Search lives here: a sixth tab would push Time into "More".
                                        Button { searching = true } label: { Label("Search", systemImage: "magnifyingglass") }
                                        // Today's brief again, and the ones before it.
                                        Button { showingHistory = true } label: { Label("Morning Briefs", systemImage: "sun.horizon") }
                                        Button { planning = true } label: { Label("Plan My Day", systemImage: "wand.and.stars") }
                                        newEventButton
                                    }
                            }
                        }
                        Tab("Week", systemImage: "calendar.day.timeline.left", value: .week) {
                            NavigationStack {
                                DayListView(store: store, start: .now, days: 7, jumpToNow: reselected[.week, default: 0])
                                    .navigationTitle("This Week")
                                    .toolbar { newEventButton }
                            }
                        }
                        Tab("Month", systemImage: "calendar", value: .month) {
                            NavigationStack {
                                // The month's own header says "October 2026"; no title above it.
                                MonthView(store: store, jumpToToday: reselected[.month, default: 0])
                                    .toolbarTitleDisplayMode(.inline)
                                    .toolbar { newEventButton }
                            }
                        }
                        Tab("Tasks", systemImage: "checklist", value: .tasks) {
                            NavigationStack {
                                TasksView(store: store)
                                    .navigationTitle("Tasks")
                                    .toolbar {
                                        CalendarFilter(store: store)
                                        Button { showingSettings = true } label: { Label("Alerts", systemImage: "gearshape") }
                                    }
                            }
                        }
                        Tab("Time", systemImage: "chart.bar", value: .time) {
                            NavigationStack { TimeView(store: store).toolbar(.hidden, for: .navigationBar) }
                        }
                    }
                    .refreshable { await store.reload() }
                    // Swipe in from either edge for the tab beside this one.
                    .tabSwipes($screen)
                    .sensoryFeedback(.selection, trigger: screen)
                    // The Add Task control: Today, ready to type.
                    .onChange(of: requests.quickAdd) { screen = .today }
                    // A Spotlight result: Daybook's search, on that event or task.
                    .onContinueUserActivity(CSSearchableItemActionType) { activity in
                        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                              let title = Spotlight.title(for: id, in: store) else { return }
                        query = title
                        searching = true
                    }
                    // A Focus with a Daybook filter turned on or off.
                    .onReceive(NotificationCenter.default.publisher(for: .focusFilterChanged)) { _ in
                        Task { await store.reload() }
                    }
                    // Above the tab bar.
                    .overlay(alignment: .bottom) {
                        UndoBanner(store: store).padding(.bottom, 52).animation(.snappy, value: store.undoAction?.id)
                    }
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
                    .sheet(isPresented: $planning) { PlanDayView(store: store) }
                    .sheet(isPresented: $searching, onDismiss: { query = ""; searchFieldActive = false }) {
                        NavigationStack {
                            SearchResultsView(store: store, query: query)
                                .navigationTitle("Search")
                                .navigationBarTitleDisplayMode(.inline)
                                .searchable(text: $query, isPresented: $searchFieldActive,
                                            placement: .navigationBarDrawer(displayMode: .always), prompt: "Events and tasks")
                                // Ready to type once the sheet has slid up (any sooner and iOS ignores it).
                                .task {
                                    try? await Task.sleep(for: .milliseconds(400))
                                    searchFieldActive = true
                                }
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) { Button("Done") { searching = false } }
                                }
                        }
                    }
                    .sheet(isPresented: $showingSettings) {
                        NavigationStack {
                            AlertSettingsView(store: store)
                                .navigationTitle("Alerts")
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } }
                                }
                        }
                    }
                    .sheet(isPresented: $showingHistory) {
                        BriefHistoryView(briefs: store.briefs, loading: !store.loaded).onAppear {
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
                #if DEBUG && targetEnvironment(simulator)
                await DemoSeed.runIfAsked()
                #endif
                await store.checkAccess()
                showNewBrief()
                await BriefNotifier.requestPermission()
                await SleepReader.refresh(store)
                await BriefNotifier.scheduleBackups()
            }
            // Coming back to the app: pick up anything changed on the Mac.
            .onChange(of: phase) {
                if phase == .active {
                    Task {
                        await store.reload()
                        showNewBrief()
                        await SleepReader.refresh(store)
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

    /// The tab bar's selection, which also notices a tap on the tab that's already open.
    private var tabSelection: Binding<Screen> {
        Binding {
            screen
        } set: { tapped in
            if tapped == screen { reselected[tapped, default: 0] += 1 } else { screen = tapped }
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
