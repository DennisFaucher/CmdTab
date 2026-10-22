import Cocoa
import ApplicationServices

/// Thin, allocation-light wrappers around the Accessibility C API.
enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        attr(el, name) as? Bool
    }

    static func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attr(el, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    static func size(_ el: AXUIElement, _ name: String) -> CGSize? {
        guard let value = attr(el, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &s) else { return nil }
        return s
    }

    static func appElement(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        // Never let one hung app stall the switcher.
        AXUIElementSetMessagingTimeout(el, 0.12)
        return el
    }

    struct Window {
        let element: AXUIElement
        let rect: CGRect
        let title: String
    }

    /// Standard, non-minimised, on-screen windows belonging to `pid`, front to back.
    static func windows(for pid: pid_t) -> [Window] {
        guard AXIsProcessTrusted() else { return [] }
        let app = appElement(pid)
        guard let raw = attr(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var result: [Window] = []
        result.reserveCapacity(raw.count)
        for el in raw {
            if let subrole = string(el, kAXSubroleAttribute), subrole != "AXStandardWindow" { continue }
            if bool(el, kAXMinimizedAttribute) == true { continue }
            guard let pos = point(el, kAXPositionAttribute),
                  let size = size(el, kAXSizeAttribute),
                  size.width >= 40, size.height >= 40
            else { continue }
            result.append(Window(
                element: el,
                rect: CGRect(origin: pos, size: size),
                title: string(el, kAXTitleAttribute) ?? ""
            ))
        }
        return result
    }

    /// Bring a specific window of `pid` to the front.
    static func focus(window: Window, pid: pid_t) {
        let appEl = appElement(pid)
        let app = NSRunningApplication(processIdentifier: pid)

        if let app {
            if #available(macOS 14.0, *) {
                _ = app.activate(from: .current, options: [])
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }

        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, window.element)

        // Some apps (Terminal, Electron) reassign focus while coming forward; re-assert once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, window.element)
        }
    }

    static func activate(app pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if #available(macOS 14.0, *) {
            _ = app.activate(from: .current, options: [])
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
