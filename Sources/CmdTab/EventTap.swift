import Cocoa

/// A session-level event tap. This sits ahead of the Dock, so swallowing Cmd+Tab
/// here stops the system app switcher from ever seeing it.
final class EventTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var onKeyDown: ((CGEvent) -> Bool)?
    var onMouseDown: ((CGEvent) -> Void)?

    @discardableResult
    func start() -> Bool {
        stop()

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.port = port
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            self.port = nil
            return false
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        source = nil
        port = nil
    }

    func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    var isRunning: Bool { port != nil }

    var isEnabled: Bool {
        guard let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Log.write("tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"); re-enabling")
        tap.reenable()
        return Unmanaged.passUnretained(event)
    }

    switch type {
    case .keyDown:
        if tap.onKeyDown?(event) == true { return nil }
    case .leftMouseDown:
        tap.onMouseDown?(event)
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
