#if os(macOS)
import AppKit
import DaybookCore
import SwiftUI
import WebKit

/// The morning brief the scheduled Claude task writes each day. Daybook shows a
/// new one once, as a sheet, the next time it comes to the front.
enum Brief {
    static var file: URL { DailySummary.folder.appending(path: "brief.html") }

    static var exists: Bool { FileManager.default.fileExists(atPath: file.path()) }

    /// True when today's brief was written after the last one shown.
    static var isUnseen: Bool {
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        guard let written = values?.contentModificationDate, Calendar.current.isDateInToday(written) else { return false }
        let seen = UserDefaults.standard.object(forKey: "briefSeenAt") as? Date ?? .distantPast
        return seen < written
    }

    static func markSeen() { UserDefaults.standard.set(Date.now, forKey: "briefSeenAt") }
}

struct BriefSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            BriefWebView(file: Brief.file)
            Divider()
            HStack {
                Button("Open in Browser") { NSWorkspace.shared.open(Brief.file) }
                Spacer()
                Button("Got It") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 820, height: 760)
        .onAppear { Brief.markSeen() }
    }
}

/// The brief is a self-contained HTML page, so it renders as-is. Links in it open
/// in the browser rather than inside the sheet.
struct BriefWebView: NSViewRepresentable {
    let file: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            NSWorkspace.shared.open(url)
            return .cancel
        }
    }
}
#endif
