import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity's look: the next event with a countdown on the lock screen,
/// and in the Dynamic Island. The app starts and updates it (NextUp).
struct NextEventActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NextEventAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(14)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text(state.title).lineLimit(1) } icon: { Dot(color: state.color) }
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: state).font(.headline).foregroundStyle(Color(hex: state.color))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Details(state: state).font(.caption)
                }
            } compactLeading: {
                Dot(color: state.color)
            } compactTrailing: {
                Countdown(state: state).frame(maxWidth: 52).foregroundStyle(Color(hex: state.color))
            } minimal: {
                Dot(color: state.color)
            }
            .keylineTint(Color(hex: state.color))
        }
    }
}

private struct LockScreenView: View {
    let state: NextEventAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: state.color)).frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.headline).lineLimit(1)
                    Details(state: state).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Countdown(state: state).font(.title2.weight(.semibold))
                    Text(state.start > .now ? "until it starts" : "left").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            // Fills up while the event is on; empty until then.
            ProgressView(timerInterval: state.start...max(state.end, state.start.addingTimeInterval(60)), countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(Color(hex: state.color))
        }
    }
}

/// "9:00 – 10:15 AM · Brooks Hall", and "Leave by 8:35 AM · 18 min drive" under it.
private struct Details: View {
    let state: NextEventAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(state.start.formatted(date: .omitted, time: .shortened)) \u{2013} \(state.end.formatted(date: .omitted, time: .shortened))"
                 + (state.place.map { " \u{00B7} \($0)" } ?? ""))
                .lineLimit(1)
            if let leave = state.leaveBy, let travel = state.travel {
                Label("Leave by \(leave.formatted(date: .omitted, time: .shortened)) \u{00B7} \(travel)", systemImage: "car")
                    .lineLimit(1)
            }
        }
    }
}

/// Counts down to the start, then (once the app has refreshed it) to the end.
private struct Countdown: View {
    let state: NextEventAttributes.ContentState

    var body: some View {
        let now = Date.now
        let target = state.start > now ? state.start : max(state.end, now)
        Text(timerInterval: now...target, countsDown: true)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

private struct Dot: View {
    let color: String

    var body: some View {
        Circle().fill(Color(hex: color)).frame(width: 10, height: 10)
    }
}
