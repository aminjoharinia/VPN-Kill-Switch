import Foundation

/// Size-capped logger. The shell version's predecessor reached 18 GB
/// because nothing ever rotated; every write here checks the cap first.
final class Log {
    static let shared = Log()
    private let queue = DispatchQueue(label: "vpnks.log")
    private var path = "/usr/local/var/vpn_kill_switch/kill_switch.log"
    private let maxBytes = 5 * 1024 * 1024
    private lazy var stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func setPath(_ p: String) { queue.sync { self.path = p } }

    func write(_ message: String) {
        queue.async {
            let line = "\(self.stamp.string(from: Date())) \(message)\n"
            FileHandle.standardError.write(Data(line.utf8))
            self.rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            if let fh = FileHandle(forWritingAtPath: self.path) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
            } else {
                try? data.write(to: URL(fileURLWithPath: self.path))
            }
        }
    }

    private func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = attrs?[.size] as? Int, size > maxBytes else { return }
        try? FileManager.default.removeItem(atPath: path + ".1")
        try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
    }
}

func log(_ m: String) { Log.shared.write(m) }
