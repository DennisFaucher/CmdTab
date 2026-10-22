import Cocoa
import ServiceManagement

enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func request() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let tap = EventTap()
    private var statusItem: NSStatusItem?
    private var retryTimer: Timer?
    private var healthTimer: Timer?
    private var activity: NSObjectProtocol?

    private var statusMenuItem: NSMenuItem!
    private var sortItems: [NSMenuItem] = []
    private var loginItem: NSMenuItem!
    private var grantItem: NSMenuItem!

    private var isTrusted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App Nap can throttle a background agent that owns no windows.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "CmdTab intercepts Cmd+Tab globally"
        )

        setupStatusItem()
        wireTap()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Dev aid: `open CmdTab.app --args --demo` renders the panel without the hotkey.
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Switcher.shared.show()
                if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--text=") }) {
                    for character in arg.dropFirst("--text=".count) {
                        _ = Switcher.shared.handleKeyDown(keyCode: 0, flags: [], characters: String(character))
                    }
                }
            }
        }

        if CommandLine.arguments.contains("--selftest") { runSelfTest() }

        isTrusted = Permissions.isTrusted
        Log.write("launch path=\(Bundle.main.bundlePath) trusted=\(isTrusted)")
        DispatchQueue.main.async { [weak self] in
            if let window = self?.statusItem?.button?.window {
                Log.write("status item frame=\(window.frame) onScreen=\(window.isVisible)")
            } else {
                Log.write("status item has no window yet")
            }
        }

        if isTrusted {
            startTap()
            WindowCache.refresh(mode: Preferences.sortMode)
            Log.write(WindowCache.describe())
        } else {
            Permissions.request()
            startRetryTimer()
            Log.write("accessibility not granted; prompting")
            if !CommandLine.arguments.contains("--demo") { showPermissionAlert() }
        }
    }

    // MARK: - Event tap

    private func wireTap() {
        let logAllKeys = CommandLine.arguments.contains("--logkeys")
        tap.onKeyDown = { event in
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let isHotkey = keyCode == 48 && event.flags.contains(.maskCommand)
            let wasActive = Switcher.shared.isVisible
            let swallowed = Switcher.shared.handleKeyDown(
                keyCode: keyCode,
                flags: event.flags,
                characters: NSEvent(cgEvent: event)?.charactersIgnoringModifiers
            )
            if logAllKeys || isHotkey || wasActive {
                Log.write("key code=\(keyCode) cmd=\(event.flags.contains(.maskCommand)) active=\(wasActive) swallowed=\(swallowed)")
            }
            return swallowed
        }

        tap.onMouseDown = { _ in
            Switcher.shared.handleMouseDown()
        }
    }

    private func startTap() {
        let running = tap.start()
        statusItem?.button?.image = running ? Self.onImage : Self.offImage
        Log.write("event tap start -> \(running ? "running" : "FAILED")")
        if running { startHealthCheck() }
    }

    /// The system can silently disable an event tap (secure input, launchd restarts,
    /// a stuck callback). Poll cheaply and bring it back.
    private func startHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.checkTapHealth()
        }
    }

    private func checkTapHealth() {
        guard isTrusted else { return }
        if !tap.isRunning {
            Log.write("tap port lost; restarting")
            startTap()
        } else if !tap.isEnabled {
            Log.write("tap had been disabled by the system; re-enabling")
            tap.reenable()
        }
    }

    private func startRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard Permissions.isTrusted else { return }
            timer.invalidate()
            self.retryTimer = nil
            self.isTrusted = true
            Log.write("accessibility granted; starting tap")
            self.startTap()
            WindowCache.refreshAsync(mode: Preferences.sortMode) {
                Log.write(WindowCache.describe())
            }
        }
    }

    // MARK: - Cache warming

    @objc private func applicationActivated() {
        guard isTrusted else { return }
        WindowCache.refreshAsync(mode: Preferences.sortMode)
    }

    // MARK: - Status item

    private static let onImage = NSImage(
        systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "CmdTab"
    )
    private static let offImage = NSImage(
        systemSymbolName: "rectangle.on.rectangle.slash", accessibilityDescription: "CmdTab needs Accessibility access"
    )

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Permissions.isTrusted ? Self.onImage : Self.offImage
        statusItem = item

        let menu = NSMenu()
        menu.delegate = self

        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show Window List", action: #selector(showSwitcher), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let sortRoot = NSMenuItem(title: "Sort Order", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        for mode in SortMode.allCases {
            let entry = NSMenuItem(title: mode.label, action: #selector(setSortMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            sortMenu.addItem(entry)
            sortItems.append(entry)
        }
        sortRoot.submenu = sortMenu
        menu.addItem(sortRoot)

        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        grantItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "")
        grantItem.target = self
        menu.addItem(grantItem)

        menu.addItem(.separator())
        let log = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        let quit = NSMenuItem(title: "Quit CmdTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
    }

    /// Runs every time the menu opens, so the state shown is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        isTrusted = Permissions.isTrusted
        statusMenuItem.title = isTrusted ? "Accessibility: On" : "Accessibility: Off"
        grantItem.isHidden = isTrusted
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for entry in sortItems {
            entry.state = (entry.representedObject as? String) == Preferences.sortMode.rawValue ? .on : .off
        }
        statusItem?.button?.image = isTrusted ? Self.onImage : Self.offImage
    }

    @objc private func showSwitcher() {
        Switcher.shared.show()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func setSortMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = SortMode(rawValue: raw) else { return }
        Preferences.sortMode = mode
        WindowCache.refreshAsync(mode: mode)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("login item error: \(error.localizedDescription)")
        }
    }

    @objc private func grantAccess() {
        Permissions.request()
        Permissions.openSettings()
        startRetryTimer()
    }

    // MARK: - Self test

    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    /// Drives the real event path: synthesize ⌘⇥, type a filter, press Return, report where we landed.
    private func runSelfTest() {
        let keyCodes: [Character: CGKeyCode] = ["t": 17, "e": 14, "r": 15, "m": 46]
        let query = Array("term")
        Log.write("selftest: begin, frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Self.postKey(48, flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Log.write("selftest: after cmd-tab, panel visible=\(Switcher.shared.isVisible)")

                for character in query {
                    if let code = keyCodes[character] { Self.postKey(code) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    Self.postKey(36)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                        Log.write("selftest: after return, frontmost=\(front) panelVisible=\(Switcher.shared.isVisible)")
                        Log.write("selftest: end")
                        exit(0)
                    }
                }
            }
        }
    }

    private func showPermissionAlert() {        let alert = NSAlert()
        alert.messageText = "CmdTab needs Accessibility access"
        alert.informativeText = """
        Grant access to the copy at:
        \(Bundle.main.bundlePath)

        System Settings → Privacy & Security → Accessibility. There may be more than \
        one entry named “CmdTab” in that list — pick the one whose path matches the \
        line above. CmdTab starts working within ~2 seconds, no relaunch needed.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openSettings()
        }
    }
}
