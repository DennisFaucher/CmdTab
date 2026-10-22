import Cocoa

/// `--history-test` exercises AppHistory.sort and the row-0 selection rule with
/// synthetic data, so the ordering contract can be checked without a GUI.
/// Prints app names only.
enum HistoryTest {
    static func run() -> Int32 {
        _ = NSApplication.shared
        var failures = 0

        func window(_ pid: pid_t, _ name: String, _ title: String) -> SwitchWindow {
            SwitchWindow(pid: pid, appName: name, title: title, element: nil)
        }

        func check(_ label: String, _ got: [String], _ want: [String]) {
            let ok = got == want
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(label)")
            if !ok {
                print("      got:  \(got)")
                print("      want: \(want)")
            }
        }

        // Scenario from the request: switch AppA -> AppB, then press Cmd+Tab.
        // History is most-recent-first: [B, A].
        AppHistory.reset()
        AppHistory.record(200)   // AppB, activated last
        AppHistory.record(100)   // AppA, the one we came from

        // Stacking order says B is in front (it is active), A behind it.
        let stacked = [
            window(200, "AppB", "B window"),
            window(100, "AppA", "A window"),
            window(300, "AppC", "C window"),
        ]
        check(
            "most recently used app sorts first",
            AppHistory.sort(stacked).map(\.appName),
            ["AppA", "AppB", "AppC"]
        )

        // Where stacking and history disagree, history must win.
        // Activate AppC, then AppA is the most recent, then AppB is pressed last.
        AppHistory.reset()
        AppHistory.record(300)   // AppC
        AppHistory.record(100)   // AppA
        AppHistory.record(200)   // AppB, activated most recently of all
        // Z-order claims AppB is frontmost, which agrees here; the point is that
        // AppC and AppA are ordered by activation, not by where they sit in the stack.
        check(
            "history beats stacking order",
            AppHistory.sort([
                window(300, "AppC", "c"),
                window(100, "AppA", "a"),
                window(200, "AppB", "b"),
            ]).map(\.appName),
            ["AppB", "AppA", "AppC"]
        )

        // Unknown apps keep their incoming (stacking) order and land at the end.
        AppHistory.reset()
        AppHistory.record(100)
        check(
            "unknown apps keep stacking order, after known ones",
            AppHistory.sort([
                window(400, "X", "x"),
                window(500, "Y", "y"),
                window(100, "A", "a"),
            ]).map(\.appName),
            ["A", "X", "Y"]
        )

        // Multiple windows of one app keep their relative order (frontmost first).
        AppHistory.reset()
        AppHistory.record(100)
        check(
            "windows of one app stay in stacking order",
            AppHistory.sort([
                window(100, "A", "a1"),
                window(100, "A", "a2"),
                window(200, "B", "b"),
            ]).map(\.title),
            ["a1", "a2", "b"]
        )

        // Re-activating an app moves it to the front, and does not duplicate it.
        AppHistory.reset()
        AppHistory.record(100)
        AppHistory.record(200)
        AppHistory.record(100)
        check(
            "re-activation moves to front without duplicating",
            AppHistory.sort([window(100, "A", "a"), window(200, "B", "b")]).map(\.appName),
            ["A", "B"]
        )

        // Empty history must not disturb the existing order.
        AppHistory.reset()
        check(
            "empty history preserves stacking order",
            AppHistory.sort([
                window(7, "Seven", "s"),
                window(8, "Eight", "e"),
            ]).map(\.appName),
            ["Seven", "Eight"]
        )

        // The selection rule: row 0 is "where I am", row 1 is "where I came from".
        // A -> B means history is [B, A], so pressing Cmd+Tab must land on A at row 1.
        AppHistory.reset()
        AppHistory.record(100)   // AppA
        AppHistory.record(200)   // AppB (activated second)
        let ordered = AppHistory.sort([
            window(200, "AppB", "b"),
            window(100, "AppA", "a"),
        ])
        check("recent order is [AppB, AppA]", ordered.map(\.appName), ["AppB", "AppA"])
        check(
            "row 0 is the app you are in",
            [ordered[0].appName], ["AppB"]
        )
        check(
            "row 1 is the app you came from (the selection)",
            [ordered[1].appName], ["AppA"]
        )

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
