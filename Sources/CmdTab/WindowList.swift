import Cocoa

struct SwitchWindow {
    let pid: pid_t
    let appName: String
    let title: String
    let element: AXUIElement?

    var displayTitle: String { title.isEmpty ? "Untitled Window" : title }

    func focus() {
        guard let element else { AX.activate(app: pid); return }
        // Rebuild a Window record for the raise path.
        AX.focus(window: AX.Window(element: element, rect: .zero, title: title), pid: pid)
    }
}

enum SortMode: String, CaseIterable {
    case recent
    case alphabetical

    var label: String {
        switch self {
        case .recent: return "Most Recently Used"
        case .alphabetical: return "Alphabetical"
        }
    }
}

enum WindowList {
    /// Front-to-back list of every on-screen, standard window on the current Space.
    static func current(mode: SortMode) -> [SwitchWindow] {
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        // 1. Cheap, permission-free pass: which apps have real windows, in stacking order.
        var rectsByPid: [pid_t: [CGRect]] = [:]
        var pidOrder: [pid_t] = []
        let selfPid = ProcessInfo.processInfo.processIdentifier

        for info in raw {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let rawPid = info[kCGWindowOwnerPID as String] as? Int else { continue }
            let pid = pid_t(rawPid)
            if pid == selfPid { continue }
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 60, rect.height >= 40
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.02 { continue }

            if rectsByPid[pid] == nil {
                pidOrder.append(pid)
                rectsByPid[pid] = []
            }
            rectsByPid[pid]?.append(rect)
        }

        // 2. Expensive pass: titles + AX handles, only for apps that actually have windows.
        var result: [SwitchWindow] = []
        result.reserveCapacity(32)

        for pid in pidOrder {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular
            else { continue }

            let name = app.localizedName ?? "Unknown"
            let axWindows = AX.windows(for: pid)
            var claimed = [Bool](repeating: false, count: axWindows.count)

            for rect in rectsByPid[pid] ?? [] {
                var best = -1
                var bestDistance = CGFloat.greatestFiniteMagnitude
                for (index, candidate) in axWindows.enumerated() where !claimed[index] {
                    let d = abs(candidate.rect.minX - rect.minX)
                        + abs(candidate.rect.minY - rect.minY)
                        + abs(candidate.rect.width - rect.width)
                        + abs(candidate.rect.height - rect.height)
                    if d < bestDistance {
                        bestDistance = d
                        best = index
                    }
                }
                if best >= 0, bestDistance < 40 {
                    claimed[best] = true
                    let w = axWindows[best]
                    result.append(SwitchWindow(pid: pid, appName: name, title: w.title, element: w.element))
                } else {
                    // Accessibility gave us nothing usable; still list the window.
                    result.append(SwitchWindow(pid: pid, appName: name, title: "", element: nil))
                }
            }
        }

        if mode == .alphabetical {
            result.sort { lhs, rhs in
                let appOrder = lhs.appName.localizedStandardCompare(rhs.appName)
                if appOrder != .orderedSame { return appOrder == .orderedAscending }
                // Windows whose title Accessibility didn't give us sink to the bottom.
                if lhs.title.isEmpty != rhs.title.isEmpty { return rhs.title.isEmpty }
                let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                return lhs.pid < rhs.pid
            }
        } else {
            // Recent mode: real activation history, not stacking order. The raw list
            // above is in front-to-back z-order, which is only a proxy for recency.
            result = AppHistory.sort(result)
        }
        return result
    }
}

/// Snapshot kept warm in the background so Cmd+Tab shows a panel without waiting on AX.
enum WindowCache {
    private static var windows: [SwitchWindow] = []
    private static var stamp = Date.distantPast
    private(set) static var lastDuration: TimeInterval = 0

    private static let queue = DispatchQueue(label: "com.faucher.cmdtab.windowlist", qos: .userInitiated)
    private static var inFlight = false
    private static var pending: SortMode?

    /// Last known list. Only touched on the main thread.
    static var current: [SwitchWindow] { windows }

    /// Blocking refresh — used once at launch, where a cold ~100 ms is invisible.
    static func refresh(mode: SortMode) {
        let started = CFAbsoluteTimeGetCurrent()
        windows = WindowList.current(mode: mode)
        lastDuration = CFAbsoluteTimeGetCurrent() - started
        stamp = Date()
    }

    /// Blocking refresh on the hot path.
    ///
    /// Enumeration costs ~10-30 ms warm, which is inside a single frame, and it must
    /// happen *before* the panel is ordered front. The panel is a window: once it is
    /// frontmost it tops the front-to-back stack, so any list read after that ranks the
    /// previously-focused window below where it belongs — which makes "the second row
    /// is the window you came from" quietly false. Reading first is the whole point.
    static func refreshBlocking(mode: SortMode) {
        refresh(mode: mode)
    }

    /// Non-blocking refresh — the hot path. Enumeration is all cross-process IPC,
    /// so it runs off the main thread and the panel never waits for it.
    static func refreshAsync(mode: SortMode, completion: (() -> Void)? = nil) {
        guard !inFlight else {
            pending = mode
            return
        }
        inFlight = true
        queue.async {
            let started = CFAbsoluteTimeGetCurrent()
            let list = WindowList.current(mode: mode)
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            DispatchQueue.main.async {
                windows = list
                lastDuration = elapsed
                stamp = Date()
                inFlight = false
                completion?()
                if let next = pending {
                    pending = nil
                    refreshAsync(mode: next)
                }
            }
        }
    }

    static func describe() -> String {
        let titled = windows.filter { !$0.title.isEmpty }.count
        return String(
            format: "window list: %d windows, %d with AX titles, %.1f ms",
            windows.count, titled, lastDuration * 1000
        )
    }
}
