import Cocoa

final class SwitcherPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        // Above the menu bar, visible over full-screen apps.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Never becomes key: we drive every keystroke from the event tap.
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Switcher {
    static let shared = Switcher()

    private let panel = SwitcherPanel()
    private let list = ListView()

    private var all: [SwitchWindow] = []
    private var shown: [SwitchWindow] = []
    private var query = ""
    private var selection = 0
    private var interacted = false
    private var idleTimer: Timer?

    private init() {
        panel.contentView = list
        list.onClick = { [weak self] index in
            guard let self, index < self.shown.count else { return }
            self.selection = index
            self.commit()
        }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Presentation

    func show() {
        // Render immediately from the last snapshot, then correct it in the background.
        all = WindowCache.current
        query = ""
        interacted = false
        selection = initialSelection()
        applyFilter(resetSelection: false)
        panel.orderFrontRegardless()
        bumpIdleTimer()

        WindowCache.refreshAsync(mode: Preferences.sortMode) { [weak self] in
            self?.adoptRefreshedList()
        }
    }

    /// Most-recently-used order means "previous window" is the useful default;
    /// an alphabetical list has no such thing, so start at the top.
    private func initialSelection() -> Int {
        Preferences.sortMode == .recent && all.count > 1 ? 1 : 0
    }

    /// Apply a background refresh, unless the user has already started driving the list.
    private func adoptRefreshedList() {
        guard panel.isVisible, !interacted else { return }
        let previous = shown.indices.contains(selection) ? shown[selection] : nil

        all = WindowCache.current
        shown = Self.filter(all, query: query)

        if let previous,
           let index = shown.firstIndex(where: { $0.pid == previous.pid && $0.title == previous.title }) {
            selection = index
        } else {
            selection = initialSelection()
        }

        list.rows = shown
        list.query = query
        list.setSelection(selection)
        relayout()
        bumpIdleTimer()
    }

    /// The panel swallows keys while it is up, so make sure it can never outstay its
    /// welcome if the keyboard goes elsewhere (secure input, screensaver, a cat).
    private func bumpIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    private func hide() {
        idleTimer?.invalidate()
        idleTimer = nil
        panel.orderOut(nil)
        all = []
        shown = []
        query = ""
        selection = 0
        interacted = false
    }

    private func applyFilter(resetSelection: Bool) {
        shown = Self.filter(all, query: query)
        if resetSelection { selection = 0 }
        selection = max(0, min(selection, max(0, shown.count - 1)))
        list.rows = shown
        list.query = query
        list.setSelection(selection)
        relayout()
    }

    private func relayout() {
        let size = list.desiredSize()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: (area.midX - size.width / 2).rounded(),
            y: (area.maxY - size.height - area.height * 0.16).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        list.frame = NSRect(origin: .zero, size: size)
    }

    // MARK: - Input

    /// Returns true when the event should be swallowed.
    /// The panel is sticky: it stays up after Cmd is released so you can type.
    /// Enter opens the selected window; Escape dismisses.
    func handleKeyDown(keyCode: Int64, flags: CGEventFlags, characters: String?) -> Bool {
        guard panel.isVisible else {
            guard keyCode == 48,
                  flags.contains(.maskCommand),
                  !flags.contains(.maskAlternate),
                  !flags.contains(.maskControl)
            else { return false }
            show()
            return true
        }

        switch keyCode {
        case 48:                                    // Tab
            move(flags.contains(.maskShift) ? -1 : 1)
        case 126, 116:                              // Up, Page Up
            move(-1)
        case 125, 121:                              // Down, Page Down
            move(1)
        case 36, 76:                                // Return, Enter
            commit()
        case 53:                                    // Escape
            hide()
        case 51:                                    // Delete
            if !query.isEmpty {
                query.removeLast()
                interacted = true
                applyFilter(resetSelection: true)
            }
        default:
            if let characters, let text = Self.printable(characters) {
                query += text
                interacted = true
                applyFilter(resetSelection: true)
            }
        }
        if panel.isVisible { bumpIdleTimer() }
        return true
    }

    func handleMouseDown() {
        guard panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        hide()
    }

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        interacted = true
        selection = (selection + delta + shown.count) % shown.count
        list.setSelection(selection)
    }

    private func commit() {
        guard selection < shown.count else { hide(); return }
        let target = shown[selection]
        hide()
        target.focus()
    }

    // MARK: - Filtering

    private static func printable(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }   // function keys
        }
        return text
    }

    private static func filter(_ windows: [SwitchWindow], query: String) -> [SwitchWindow] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return windows }

        var scored: [(index: Int, score: Int, window: SwitchWindow)] = []
        for (index, window) in windows.enumerated() {
            let app = window.appName.lowercased()
            let title = window.title.lowercased()
            guard let score = score(app: app, title: title, needle: needle) else { continue }
            scored.append((index, score, window))
        }
        scored.sort { $0.score == $1.score ? $0.index < $1.index : $0.score < $1.score }
        return scored.map(\.window)
    }

    private static func score(app: String, title: String, needle: String) -> Int? {
        if app.hasPrefix(needle) { return 0 }
        if app.contains(needle) { return 1 }
        if title.hasPrefix(needle) { return 2 }
        if title.contains(needle) { return 3 }
        if (app + " " + title).contains(needle) { return 4 }
        if isSubsequence(needle, of: app + " " + title) { return 5 }
        return nil
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in needle {
            var found = false
            while let next = iterator.next() {
                if next == character { found = true; break }
            }
            if !found { return false }
        }
        return true
    }
}

enum Preferences {
    private static let sortKey = "sortMode"

    static var sortMode: SortMode {
        get { SortMode(rawValue: UserDefaults.standard.string(forKey: sortKey) ?? "") ?? .alphabetical }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sortKey) }
    }
}
