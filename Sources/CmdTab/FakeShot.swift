import Cocoa

/// `--fake` renders the switcher panel from invented window titles and writes it to a
/// PNG, then exits. Nothing is read from the system: no window enumeration, no
/// Accessibility, no event tap. That is deliberate — a screenshot for the README must
/// not be able to leak whatever the author happens to have open.
///
///     ./.build/release/CmdTab --fake --out=panel.png
///     ./.build/release/CmdTab --fake --text=doc --out=panel.png
///
/// Used as a batch tool: `main.swift` runs this before anything else, so no window is
/// ever shown and no permission is touched.
enum FakeShot {
    private static let samples: [(String, String)] = [
        ("Calendar", "Today"),
        ("Finder", "/Applications"),
        ("iTerm2", "vim ~/projects/api/src/server.ts"),
        ("Mail", "Inbox"),
        ("Notes", "Release checklist"),
        ("Preview", "invoice.pdf"),
        ("Safari", "Docs — Apple Developer"),
        ("Safari", "OpenCode — Documentation"),
        ("Slack", "#engineering"),
        ("Terminal", "make dist"),
        ("Xcode", "CmdTab — Switcher.swift"),
    ]

    static func run() -> Int32 {
        let args = CommandLine.arguments
        let out = value(of: "--out=", in: args) ?? "CmdTab-panel.png"
        let query = value(of: "--text=", in: args) ?? ""

        _ = NSApplication.shared   // NSScreen/font machinery needs an app instance

        let rows = samples
            .map { SwitchWindow(pid: 0, appName: $0.0, title: $0.1, element: nil) }
            .filter {
                query.isEmpty
                    || $0.appName.localizedCaseInsensitiveContains(query)
                    || $0.title.localizedCaseInsensitiveContains(query)
            }

        let list = ListView()
        list.rows = rows
        list.query = query
        list.setSelection(0)

        let size = list.desiredSize()
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.appearance = NSAppearance(named: .aqua)   // fixed colours, any Mac
        list.frame = NSRect(origin: .zero, size: size)
        container.addSubview(list)

        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
            FileHandle.standardError.write(Data("fake: could not allocate bitmap\n".utf8))
            return 1
        }
        container.cacheDisplay(in: container.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("fake: PNG encoding failed\n".utf8))
            return 1
        }
        do {
            try png.write(to: URL(fileURLWithPath: out))
        } catch {
            FileHandle.standardError.write(Data("fake: \(error.localizedDescription)\n".utf8))
            return 1
        }

        print("wrote \(out)  \(Int(size.width))x\(Int(size.height))pt  rows=\(rows.count)  query=\(query.isEmpty ? "(none)" : query)")
        return 0
    }

    private static func value(of prefix: String, in args: [String]) -> String? {
        args.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
