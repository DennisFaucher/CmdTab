import Cocoa

// Diagnostic: `CmdTab --dump` prints the window list it would show and how long it took.
// Runs before the single-instance guard so it works while the app is already up.
if CommandLine.arguments.contains("--dump") {
    let started = CFAbsoluteTimeGetCurrent()
    let windows = WindowList.current(mode: Preferences.sortMode)
    let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
    print("accessibility trusted: \(AXIsProcessTrusted())")
    print("sort mode: \(Preferences.sortMode.rawValue)")
    print("\(windows.count) windows in \(String(format: "%.1f", elapsed)) ms")
    for (index, window) in windows.enumerated() {
        let title = window.title.isEmpty ? "«no AX title»" : window.title
        print(String(format: "%2d  pid %-6d  %@: %@", index, window.pid, window.appName, title))
    }
    exit(0)
}

// Diagnostic: shows what history the running app has recorded, by asking it via its log.
// `--dump-history` reads the log, since history lives in the running process.
if CommandLine.arguments.contains("--dump-history") {
    AppHistory.start()
    // Give the observer a moment to catch up, then report.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        print(AppHistory.describe())
        let ranked = WindowList.current(mode: .recent)
        print("\nrecent order with history applied:")
        for (index, window) in ranked.prefix(10).enumerated() {
            print(String(format: "%2d  %@", index, window.appName))
        }
        exit(0)
    }
    RunLoop.main.run()
}

// Screenshot mode: `CmdTab --fake --out=panel.png` draws the panel from invented window
// titles and exits. Also before the instance guard — it never touches the system.
if CommandLine.arguments.contains("--fake") {
    exit(FakeShot.run())
}

// Diagnostic: checks the MRU ordering contract against synthetic data.
if CommandLine.arguments.contains("--history-test") {
    exit(HistoryTest.run())
}
// Single instance guard: two copies of the app (e.g. one in ~/Applications and one
// built in the repo) would install two event taps and fight over Cmd+Tab.
if let identifier = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication
        .runningApplications(withBundleIdentifier: identifier)
        .filter { $0.processIdentifier != getpid() }
    if let existing = others.first {
        Log.write("another instance is already running (pid \(existing.processIdentifier)); exiting")
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
