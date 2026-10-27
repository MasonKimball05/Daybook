import AppIntents
import SwiftUI
import WidgetKit

/// Add Task, for Control Center, the lock screen or the Action button: opens
/// Daybook on Today with the quick-add field ready to type in.
struct QuickAddControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "DaybookQuickAdd") {
            ControlWidgetButton(action: OpenQuickAddIntent()) {
                Label("Add Task", systemImage: "checklist")
            }
        }
        .displayName("Add Task")
        .description("Opens Daybook ready to type a task.")
    }
}
