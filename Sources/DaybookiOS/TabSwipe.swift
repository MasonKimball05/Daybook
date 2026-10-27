import SwiftUI
import UIKit

/// The iPhone's tabs, in tab bar order, so a swipe knows which one is next door.
enum Screen: Int, CaseIterable {
    case today, week, month, tasks, time

    /// The tab beside this one, toward the given edge, or nil at the ends.
    func neighbor(toward edge: UIRectEdge) -> Screen? {
        Screen(rawValue: rawValue + (edge == .right ? 1 : -1))
    }

    // As in the tab bar.
    var title: String { ["Today", "Week", "Month", "Tasks", "Time"][rawValue] }
    var icon: String { ["sun.max", "calendar.day.timeline.left", "calendar", "checklist", "chart.bar"][rawValue] }
}

extension View {
    /// Edge swipes move between the tabs beside `screen`: in from the right edge for
    /// the next tab, from the left edge for the one before.
    func tabSwipes(_ screen: Binding<Screen>) -> some View {
        modifier(TabSwipes(screen: screen))
    }
}

/// How far in from the edge a swipe has to come to change tabs when let go.
private let reach: CGFloat = 60

/// While a swipe is under way, the next tab's icon slides in from the edge after
/// the finger, filling in (with a tap) once letting go would change tabs. Letting
/// go short of that slides it back out; past it, the icon pops as the tab changes.
/// At the first and last tab nothing comes in.
///
/// Nothing here moves or fades the tabs themselves: shifting the tab view throws
/// off the navigation bar's large title for good, and the tab bar changes tabs a
/// moment after SwiftUI draws, so a fade would land on the old tab.
private struct TabSwipes: ViewModifier {
    @Binding var screen: Screen
    @State private var drag: Drag?
    /// The tab a swipe just went to, while its icon pops.
    @State private var popped: Pop?

    struct Drag: Equatable {
        var edge: UIRectEdge
        /// How far in from the edge, in points.
        var distance: CGFloat
        var armed: Bool { distance > reach }
    }

    struct Pop: Equatable {
        var edge: UIRectEdge
        var screen: Screen
        var done = false
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) { bubble(at: .left) }
            .overlay(alignment: .trailing) { bubble(at: .right) }
            .background(EdgeSwipes(
                changed: { edge, distance in drag = Drag(edge: edge, distance: max(0, distance)) },
                ended: finish))
            .sensoryFeedback(.impact(weight: .light), trigger: drag?.armed == true) { _, armed in armed }
    }

    @ViewBuilder private func bubble(at edge: UIRectEdge) -> some View {
        let inward: CGFloat = edge == .left ? 1 : -1
        if let drag, drag.edge == edge, let next = screen.neighbor(toward: edge) {
            let progress = min(drag.distance / reach, 1)
            Bubble(screen: next, filled: drag.armed)
                .scaleEffect(0.6 + 0.4 * progress)
                .opacity(progress)
                // Starts tucked behind the edge and comes in with the finger.
                .offset(x: inward * (min(drag.distance, 120) - 56))
                .animation(.snappy(duration: 0.15), value: drag.armed)
        } else if let popped, popped.edge == edge {
            Bubble(screen: popped.screen, filled: true)
                .scaleEffect(popped.done ? 1.5 : 1)
                .opacity(popped.done ? 0 : 1)
                .offset(x: inward * 64)
        }
    }

    private func finish(_ edge: UIRectEdge, _ commit: Bool) {
        guard commit, let next = screen.neighbor(toward: edge) else {
            withAnimation(.spring(duration: 0.3)) { drag = nil }
            return
        }
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) {
            screen = next
            drag = nil
            popped = Pop(edge: edge, screen: next)
        }
        withAnimation(.easeOut(duration: 0.3)) {
            popped?.done = true
        } completion: {
            popped = nil
        }
    }
}

/// The next tab's icon and name, in a circle.
private struct Bubble: View {
    let screen: Screen
    let filled: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: screen.icon).font(.title3.weight(.semibold))
            Text(screen.title).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(filled ? Color.white : Color.primary)
        .frame(width: 66, height: 66)
        .background(filled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial), in: Circle())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .allowsHitTesting(false)
    }
}

/// Swipes in from the left and right edges of the screen. They sit on the window,
/// like the back swipe in Settings, so they win over the swipes inside the screens
/// (row actions, changing months); a swipe that starts mid-screen is left to those.
private struct EdgeSwipes: UIViewRepresentable {
    /// How far in from the edge the finger is, as it moves.
    let changed: (UIRectEdge, CGFloat) -> Void
    /// Let go (or cancelled): whether that changes tabs.
    let ended: (UIRectEdge, Bool) -> Void

    func makeUIView(context: Context) -> EdgeSwipeView { EdgeSwipeView() }

    func updateUIView(_ view: EdgeSwipeView, context: Context) {
        view.changed = changed
        view.ended = ended
    }
}

private final class EdgeSwipeView: UIView, UIGestureRecognizerDelegate {
    var changed: (UIRectEdge, CGFloat) -> Void = { _, _ in }
    var ended: (UIRectEdge, Bool) -> Void = { _, _ in }
    private lazy var pans: [UIScreenEdgePanGestureRecognizer] = [UIRectEdge.left, .right].map { edge in
        let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swiped))
        pan.edges = edge
        pan.delegate = self
        return pan
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func willMove(toWindow newWindow: UIWindow?) {
        pans.forEach { $0.view?.removeGestureRecognizer($0) }
        pans.forEach { newWindow?.addGestureRecognizer($0) }
    }

    @objc private func swiped(_ pan: UIScreenEdgePanGestureRecognizer) {
        guard let view = pan.view else { return }
        let inward: CGFloat = pan.edges == .left ? 1 : -1
        let distance = pan.translation(in: view).x * inward
        switch pan.state {
        case .began, .changed:
            changed(pan.edges, distance)
        case .ended:
            // Far enough, or quick enough, in from the edge it started at.
            ended(pan.edges, distance > reach || pan.velocity(in: view).x * inward > 500)
        case .cancelled, .failed:
            ended(pan.edges, false)
        default:
            break
        }
    }

    // Not while a sheet is up: the tabs are behind it.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        window?.rootViewController?.presentedViewController == nil
    }

    // Scrolling and row swipes wait for an edge swipe to fail first; one that
    // doesn't start at the edge fails straight away.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        !(other is UIScreenEdgePanGestureRecognizer) && other.view?.window == window
    }
}
