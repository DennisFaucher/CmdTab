import Cocoa

enum Log {
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/CmdTab.log")
    }

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) pid=\(getpid()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size > 256_000 {
            try? manager.removeItem(at: url)
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
