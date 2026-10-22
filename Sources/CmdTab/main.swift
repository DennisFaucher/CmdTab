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
