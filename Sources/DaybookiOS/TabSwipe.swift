import SwiftUI
import UIKit

/// The iPhone's tabs, in tab bar order, so a swipe knows which one is next door.
enum Screen: Int, CaseIterable {
    case today, week, month, tasks, time

    /// The tab beside this one, toward the given edge, or nil at the ends.
    func neighbor(toward edge: UIRectEdge) -> Screen? {
        Screen(rawValue: rawValue + (edge == .right ? 1 : -1))
    }
}

extension View {
    /// Edge swipes move between the tabs beside `screen`: in from the right edge for
    /// the next tab, from the left edge for the one before.
    func tabSwipes(_ screen: Binding<Screen>) -> some View {
        background(EdgeSwipes { edge in
            if let next = screen.wrappedValue.neighbor(toward: edge) { screen.wrappedValue = next }
        })
    }
}

/// Swipes in from the left and right edges of the screen. They sit on the window,
/// like the back swipe in Settings, so they win over the swipes inside the screens
/// (row actions, changing months); a swipe that starts mid-screen is left to those.
private struct EdgeSwipes: UIViewRepresentable {
    let action: (UIRectEdge) -> Void

    func makeUIView(context: Context) -> EdgeSwipeView { EdgeSwipeView() }

    func updateUIView(_ view: EdgeSwipeView, context: Context) { view.action = action }
}

private final class EdgeSwipeView: UIView, UIGestureRecognizerDelegate {
    var action: (UIRectEdge) -> Void = { _ in }
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
        guard pan.state == .ended, let view = pan.view else { return }
        // Far enough, or quick enough, in from the edge it started at.
        let inward: CGFloat = pan.edges == .left ? 1 : -1
        if pan.translation(in: view).x * inward > 60 || pan.velocity(in: view).x * inward > 500 { action(pan.edges) }
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
