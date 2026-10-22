import Cocoa

/// Real most-recently-used history, maintained by observation.
///
/// The switcher's "recent" order used to be `CGWindowListCopyWindowInfo`'s front-to-back
/// stacking order, which is not the same thing as recency: clicking a background window,
/// a window opening or closing, or switching between two windows of one app all reshuffle
/// the stack without changing which app you actually used last. This type records
/// activations instead, so "most recent" means most recent.
///
/// Scope is deliberately **per app**, not per window: window-level focus changes are
/// noisy to observe (they need Accessibility on every app, and fire constantly while
/// typing between panes) and the useful question when you press Cmd+Tab is almost always
/// "which app was I just in".
enum AppHistory {
    /// Ordered most-recent first. Only touched on the main thread.
    private static var order: [pid_t] = []
    private static var started = false

    /// Cap on remembered apps. Far more than anyone cycles between, and it keeps the
    /// list cheap to scan on every open.
    private static let limit = 40

    /// Begin observing app activations. Safe to call more than once.
    static func start() {
        guard !started else { return }
        started = true

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            record(app.processIdentifier)
        }

        // Seed with the frontmost app so the very first Cmd+Tab is not history-free.
        if let front = NSWorkspace.shared.frontmostApplication {
            record(front.processIdentifier)
        }
    }

    /// Move `pid` to the front. Called on activation, and also on commit, because
    /// switching to a window does not always re-activate an already-active app.
    static func record(_ pid: pid_t) {
        guard pid > 0 else { return }
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
        if order.count > limit { order.removeLast(order.count - limit) }
    }

    /// Most recent first. Apps not in the history keep their relative stacking order and
    /// are placed after every remembered app.
    static func rank(of pid: pid_t) -> Int? {
        order.firstIndex(of: pid)
    }

    /// Reorder windows so remembered apps come first, most recent first.
    ///
    /// Within one app the incoming stacking order is preserved, so the app's frontmost
    /// window is still the first of its rows.
    static func sort(_ windows: [SwitchWindow]) -> [SwitchWindow] {
        // Assign each app a rank once; unknown apps share rank Int.max and keep the
        // position they arrived in (Swift's sort is not stable, so index breaks ties).
        var rankByPid: [pid_t: Int] = [:]
        for (index, pid) in order.enumerated() {
            rankByPid[pid] = index
        }

        return windows.enumerated()
            .sorted { lhs, rhs in
                let l = rankByPid[lhs.element.pid] ?? Int.max
                let r = rankByPid[rhs.element.pid] ?? Int.max
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }

    /// For `--dump`: what the history currently believes.
    static func describe() -> String {
        guard !order.isEmpty else { return "history: (empty)" }
        let names = order.prefix(8).map { pid -> String in
            NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        }
        return "history (most recent first): \(names.joined(separator: ", "))"
    }

    /// Test seam.
    static func reset() {
        order.removeAll()
    }
}
