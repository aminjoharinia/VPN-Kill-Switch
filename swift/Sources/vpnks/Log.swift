import Foundation

/// The daemon's activity log.
///
/// Retention is by month: the live file is always `kill_switch.log`, and
/// when a new month begins it is renamed `kill_switch-YYYY-MM.log`.
/// Archives older than the previous month are deleted, so at most about
/// two months are ever on disk. Deleting whole files costs nothing; trimming
/// old lines out of one file would mean rewriting it, which is exactly the
/// kind of SSD churn this daemon avoids.
///
/// A 5 MB cap remains as a safety net against anything flooding the log:
/// past it the live file is archived early, still under its month. (The
/// shell version's predecessor reached 18 GB because nothing ever rotated.)
final class Log {
    static let shared = Log()
    private let queue = DispatchQueue(label: "vpnks.log")
    private var path = "/usr/local/var/vpn_kill_switch/kill_switch.log"
    private let maxBytes = 5 * 1024 * 1024
    /// Month ("yyyy-MM") of the lines in the live file.
    private var fileMonth: String?

    /// Lines were also printed to stderr, which launchd saves to
    /// daemon.err.log — a second, uncapped copy of every line, doubling
    /// the writes. Now only when stderr is a terminal, i.e. when someone
    /// runs `vpnks daemon` by hand to watch it.
    private let echoToTerminal = isatty(STDERR_FILENO) != 0

    private lazy var stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private lazy var monthFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f
    }()

    func setPath(_ p: String) { queue.sync { self.path = p; self.fileMonth = nil } }

    func write(_ message: String) {
        queue.async {
            let now = Date()
            let line = "\(self.stamp.string(from: now)) \(message)\n"
            if self.echoToTerminal { FileHandle.standardError.write(Data(line.utf8)) }
            self.rotateIfNeeded(month: self.monthFormat.string(from: now))
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

    private func rotateIfNeeded(month: String) {
        let fm = FileManager.default
        if fileMonth == nil { fileMonth = monthOfFirstLine() ?? month }
        let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int ?? 0

        guard let current = fileMonth, current != month || size > maxBytes else { return }
        if size > 0 { archive(as: current) }
        fileMonth = month
        pruneArchives(keepingFrom: previousMonth(of: month))
    }

    /// Renames the live file to kill_switch-<month>.log, or -2, -3… if the
    /// size cap already archived part of that month.
    private func archive(as month: String) {
        let base = (path as NSString).deletingPathExtension
        var target = "\(base)-\(month).log"
        var n = 2
        while FileManager.default.fileExists(atPath: target) {
            target = "\(base)-\(month)-\(n).log"
            n += 1
        }
        try? FileManager.default.moveItem(atPath: path, toPath: target)
    }

    /// Deletes archives from months before `oldest`, and the old
    /// size-rotation file (.log.1) the previous scheme left behind.
    private func pruneArchives(keepingFrom oldest: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        try? fm.removeItem(atPath: path + ".1")
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            guard name.hasPrefix(stem + "-"), name.hasSuffix(".log") else { continue }
            let month = String(name.dropFirst(stem.count + 1).prefix(7))   // yyyy-MM
            if month.count == 7, month < oldest {
                try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
            }
        }
    }

    private func previousMonth(of month: String) -> String {
        guard let date = monthFormat.date(from: month),
              let previous = Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: date)
        else { return month }
        return monthFormat.string(from: previous)
    }

    /// The month of the first dated line in the live file, so a log carried
    /// over from before a restart is archived under the right month.
    private func monthOfFirstLine() -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8192) else { return nil }
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n") {
            let prefix = line.prefix(7)
            if prefix.count == 7, prefix.dropFirst(4).first == "-",
               prefix.allSatisfy({ $0.isNumber || $0 == "-" }) {
                return String(prefix)
            }
        }
        return nil
    }

    /// launchd appends the daemon's stderr to daemon.err.log and never
    /// trims it. Before this daemon stopped echoing to stderr, that file
    /// had grown into a full duplicate of the log; reclaim it once. Later
    /// it holds only genuine crash output, which stays.
    static func trimDuplicatedStderrFile() {
        guard isatty(STDERR_FILENO) == 0 else { return }
        var info = stat()
        guard fstat(STDERR_FILENO, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 1024 * 1024 else { return }
        _ = ftruncate(STDERR_FILENO, 0)
    }
}

func log(_ m: String) { Log.shared.write(m) }
