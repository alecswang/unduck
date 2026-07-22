import Foundation

/// Appends to a plain text file in Application Support.
///
/// A menu-bar app with no window has nowhere to show what went wrong, and NSLog
/// from this bundle does not reliably reach the unified log. Since the failure mode
/// that matters here is silent — a denied tap returns zeros rather than an error —
/// there has to be somewhere to look.
enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Unduck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("unduck.log")
    }()

    private static let queue = DispatchQueue(label: "unduck.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
