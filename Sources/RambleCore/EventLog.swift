import Foundation

/// Append-only log at `~/Library/Logs/Ramble.log`.
///
/// Intermittent faults are the ones you cannot debug live: by the time you
/// notice a spurious trigger, the evidence has scrolled away or the process was
/// never attached to a terminal at all. Every frame and every fire goes here so
/// "it randomly triggered twenty minutes ago" is answerable.
public final class EventLog {
    public static let shared = EventLog()

    public static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Ramble.log")
    }

    /// Rotate past this size so an always-running menu bar app can't fill a disk.
    private let maxBytes = 4 * 1024 * 1024

    private let queue = DispatchQueue(label: "io.ramble.log")
    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    public func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async { [weak self] in
            guard let self, let data = line.data(using: .utf8) else { return }
            let url = EventLog.path
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)

            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > self.maxBytes {
                let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: url, to: rotated)
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
}
