import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class Controller {
    var status: DaemonStatus?
    var logLines: [String] = []
    var sessions: [Session] = []
    var endpoints: [Endpoint] = []
    var busy = false
    var lastError: String?
    var powerState: PowerState = .off
    /// Current session totals, refreshed each second from the interface.
    var liveBytes: LiveBytes?

    struct LiveBytes: Equatable {
        var down: UInt64
        var up: UInt64
    }

    private var timer: Timer?
    private var transitionStarted: Date?
    /// pid of the daemon that was running when a start began, if any.
    /// Update reinstalls over a live daemon; without this the old one's
    /// "up" status ended Starting at once and showed green before the new
    /// daemon had even launched.
    private var transitionFromPid: Int32?

    // MARK: - Derived state

    /// Updated by `refresh()`; see `isAlive`.
    private(set) var daemonRunning = false

    /// Resolves the transient states. A transition gives up after 25s so a
    /// failed install cannot leave the button spinning forever.
    private func updatePowerState() {
        let running = daemonRunning
        switch powerState {
        case .starting:
            if running, status?.pid != transitionFromPid {
                powerState = .on; transitionStarted = nil; transitionFromPid = nil
            }
            else if !busy, let t = transitionStarted, Date().timeIntervalSince(t) > 25 {
                let replacedNothing = running
                endTransition()
                lastError = startFailureMessage(oldDaemonStillRunning: replacedNothing)
            }
        case .stopping:
            if !running { powerState = .off; transitionStarted = nil }
            else if !busy, let t = transitionStarted, Date().timeIntervalSince(t) > 25 {
                endTransition()
                lastError = "The kill switch did not stop. Check Activity, or run it by hand:\n\n    sudo \(Paths.cli) uninstall"
            }
        case .on, .off:
            powerState = running ? .on : .off
        }
    }

    /// Follows `daemonRunning`, the same signal the toolbar chip uses, so
    /// the card, the pills and the chip can never disagree.
    var protection: Protection {
        guard daemonRunning, let status else { return .off }
        if status.blocked { return status.alwaysArmed ? .armed : .blocked }
        return status.alwaysArmed ? .armed : .protected
    }

    var installed: Bool { Paths.resolvedCLI != nil }

    /// Version this app was built with, matching what build.sh stamped
    /// into the daemon during the same run.
    var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(short)+\(build)"
    }

    /// True when the running daemon is not the one shipped with this app.
    ///
    /// This drift is the single most confusing failure mode here: the
    /// daemon keeps working, so nothing looks broken, but it publishes an
    /// older status shape and the UI quietly shows stale or malformed
    /// values. Surfacing it beats letting the user wonder why a fix they
    /// just built has not taken effect.
    var daemonOutOfDate: Bool {
        guard daemonRunning, let status else { return false }
        return status.daemonVersion != appVersion
    }

    var daemonVersionText: String {
        guard daemonRunning, let status else { return "not running" }
        return status.daemonVersion.isEmpty ? "older than 26.08.23" : status.daemonVersion
    }

    /// Reinstalls the bundled daemon over the running one.
    func updateDaemon() { turnOn() }

    /// Drops a transition and shows whatever is actually true now.
    private func endTransition() {
        transitionStarted = nil
        transitionFromPid = nil
        powerState = daemonRunning ? .on : .off
    }

    /// Why a start timed out, judged from what is on disk rather than from
    /// the file merely existing — it always exists, left by the last run,
    /// so that check blamed an "older daemon" for every failure, including
    /// a cancelled password prompt.
    private func startFailureMessage(oldDaemonStillRunning: Bool) -> String {
        if oldDaemonStillRunning {
            return """
                The kill switch kept running the previous daemon; the new one did not take over.

                Check Activity, or reinstall by hand:

                    sudo \(Paths.resolvedCLI ?? Paths.cli) install
                """
        }
        if FileManager.default.fileExists(atPath: Paths.status), status == nil {
            return """
                The daemon is running but this app cannot read its status.

                That usually means the installed daemon is older than this app. Rebuild both and try again:

                    ./gui/run.sh
                """
        }
        return """
            The daemon did not start.

            Check Activity, or run it by hand to see why:

                sudo \(Paths.cli) daemon
            """
    }

    private func beginStarting() {
        powerState = .starting
        transitionStarted = Date()
        transitionFromPid = daemonRunning ? status?.pid : nil
    }

    // MARK: - Polling

    func start() {
        // onAppear fires every time the window is reopened from the Dock.
        // Without this guard each reopen stacked another timer, so the
        // app did its polling work two, three, four times a second.
        guard timer == nil else { refresh(); return }
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Modification stamps of the files polled below. Each is only
    /// re-read and re-decoded when it has actually changed.
    private var stamps: [String: FileStamp] = [:]

    private func changed(_ path: String) -> Bool {
        let stamp = FileStamp(path: path)
        if stamps[path] == stamp { return false }
        stamps[path] = stamp
        return true
    }

    /// Every assignment to an @Observable property invalidates the views
    /// reading it — even when the value is identical. Assigning on every
    /// tick redrew the whole window (glass effects included) once a
    /// second, so only assign what differs.
    private func assign<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Controller, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    func refresh() {
        if changed(Paths.status) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = FileManager.default.contents(atPath: Paths.status)
            assign(\.status, data.flatMap { try? decoder.decode(DaemonStatus.self, from: $0) })
        }
        if changed(Paths.log) {
            assign(\.logLines, Self.recentLog(lines: 200))
        }
        if changed(Paths.sessions), let data = FileManager.default.contents(atPath: Paths.sessions) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            assign(\.sessions, (try? decoder.decode([Session].self, from: data)) ?? [])
        }
        if changed(ExceptionStore.path) {
            assign(\.endpoints, ExceptionStore.load())
        }
        // Freshness depends on the clock, not just the file, so this is
        // re-evaluated every tick even when nothing was re-read.
        assign(\.daemonRunning, Self.isAlive(status))
        updatePowerState()
        updateLiveBytes()

        // The menu bar label is not a template image, so it cannot
        // auto-invert; drop the cached renderings when the menu bar
        // switches between light and dark.
        let appearance = NSApp?.effectiveAppearance.name.rawValue ?? ""
        if appearance != lastAppearance {
            lastAppearance = appearance
            MenuBarIcon.flush()
        }
    }

    /// Alive = the pid the daemon published is a running process, and
    /// that process is vpnks.
    ///
    /// The file's age cannot tell: the daemon writes it only when something
    /// changes, so a quiet, healthy daemon can leave it untouched for hours.
    /// Checking the program path as well as the pid means a stale file
    /// whose pid has since been reused by some other process is not taken
    /// for a running kill switch. Both calls read the kernel, not the disk.
    private static func isAlive(_ status: DaemonStatus?) -> Bool {
        guard let status, status.running, status.pid > 0 else { return false }
        var path = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(status.pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path).hasSuffix("/vpnks")
    }

    /// The running session's totals, from the tunnel's own counters.
    private func updateLiveBytes() {
        guard daemonRunning, let status, status.sessionStartedAt != nil,
              !status.tunnelInterface.isEmpty else {
            assign(\.liveBytes, nil)
            return
        }
        let totals = status.liveTotals(current: InterfaceStats.counters(for: status.tunnelInterface))
        assign(\.liveBytes, LiveBytes(down: totals.down, up: totals.up))
    }

    private var lastAppearance = ""

    /// The newest `lines` log lines, newest first. The daemon starts a new
    /// file each month (older months become kill_switch-YYYY-MM.log), so
    /// early in a month the live file is short — top it up from the most
    /// recent archive rather than showing a near-empty Activity page.
    private static func recentLog(lines: Int) -> [String] {
        var result = tail(Paths.log, lines: lines)
        guard result.count < lines, let archive = newestLogArchive() else { return result }
        result += tail(archive, lines: lines - result.count)
        return result
    }

    private static func newestLogArchive() -> String? {
        let dir = (Paths.log as NSString).deletingLastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        // yyyy-MM (and -2, -3 for early size rotations) sorts by name.
        return names.filter { $0.hasPrefix("kill_switch-") && $0.hasSuffix(".log") }
            .max { a, b in a.compare(b, options: .numeric) == .orderedAscending }
            .map { (dir as NSString).appendingPathComponent($0) }
    }

    /// Reads only the end of the log. The daemon caps it at 5 MB, and
    /// reading and splitting all of it on the main thread every second
    /// was what made the whole app sluggish.
    private static func tail(_ path: String, lines: Int) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let window: UInt64 = 64 * 1024
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return [] }
        var text = Substring(String(decoding: data, as: UTF8.self))
        // Drop the partial first line when the read began mid-file.
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = text[text.index(after: newline)...]
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines)
            .map(String.init)
            .reversed()
    }

    // MARK: - Privileged actions

    /// Every privileged action is an explicit, user-approved macOS
    /// authorisation prompt. The app itself holds no elevated rights and
    /// installs no privileged helper.
    enum Outcome { case done, cancelled, failed }

    /// What the password is for, shown in the prompt under the app's name.
    private static func reason(for arguments: String) -> String {
        let verb = arguments.split(separator: " ").first.map(String.init) ?? ""
        switch verb {
        case "install":   return "VPN Kill Switch needs your password to turn on the kill switch."
        case "uninstall": return "VPN Kill Switch needs your password to turn off the kill switch."
        case "unblock":   return "VPN Kill Switch needs your password to clear the block."
        case "pin":       return "VPN Kill Switch needs your password to change the VPN server exceptions."
        case "set" where arguments.hasPrefix("set autostart"):
            return "VPN Kill Switch needs your password to change Start at Login."
        default:          return "VPN Kill Switch needs your password to change the kill switch."
        }
    }

    /// Runs the CLI as root after an administrator prompt that carries
    /// this app's name, icon and `reason(for:)`.
    ///
    /// History, because each step fixed one thing and broke another:
    ///  - spawning /usr/bin/osascript: the dialog said "osascript wants to
    ///    make changes" under a generic padlock — exactly what a malicious
    ///    prompt looks like;
    ///  - NSAppleScript in-process: right name and icon, but it must run
    ///    on the main thread and blocks until the command finishes, so the
    ///    window froze for as long as the dialog was open.
    ///
    /// Authorization Services does the same job as `do shell script … with
    /// administrator privileges` (it is what that uses underneath) and is
    /// safe to call off the main thread, so the window stays live. If the
    /// execute call ever disappears from macOS, fall back to NSAppleScript:
    /// a frozen window beats a switch that cannot be turned off.
    private func privileged(_ arguments: String) async -> Outcome {
        guard let cli = Paths.resolvedCLI else {
            lastError = "vpnks CLI not found. Build it first (see README)."
            return .failed
        }
        let command = "\(shellQuote(cli)) \(arguments)"
        let reason = Self.reason(for: arguments)

        let result = await Task.detached {
            PrivilegedRunner.run(command: command, prompt: reason)
        }.value

        switch result {
        case .done:
            return .done
        case .cancelled:
            return .cancelled
        case .failed(let message):
            lastError = message.isEmpty ? "Command failed." : message
            return .failed
        case .unavailable:
            return runWithAppleScript(command: command, reason: reason)
        }
    }

    /// Fallback only; see `privileged`. Freezes the window while it runs.
    private func runWithAppleScript(command: String, reason: String) -> Outcome {
        let script = "do shell script \(Self.appleScriptString(command)) "
            + "with prompt \(Self.appleScriptString(reason)) "
            + "with administrator privileges"
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            lastError = "Could not prepare the authorisation request."
            return .failed
        }
        appleScript.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .done }
        // -128 is the user cancelling the auth dialog; not an error.
        if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? ""
        lastError = message.isEmpty ? "Command failed." : message
        return .failed
    }

    /// An AppleScript string literal.
    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func perform(_ arguments: String, then finish: ((Outcome) -> Void)? = nil) {
        Task { @MainActor in
            busy = true
            lastError = nil
            let outcome = await privileged(arguments)
            busy = false
            finish?(outcome)
            stamps.removeAll()
            refresh()
        }
    }

    /// A cancelled or failed prompt means nothing changed, so go straight
    /// back to the state before the click. Waiting it out left the button
    /// spinning for 25 seconds and then raised a misleading error.
    ///
    /// On success the 25-second allowance starts now, not at the click:
    /// time spent typing a password is not time the daemon took to start.
    private func endTransitionUnlessDone(_ outcome: Outcome) {
        if outcome == .done {
            if powerState.busy { transitionStarted = Date() }
        } else {
            endTransition()
        }
    }

    func turnOn() {
        beginStarting()
        perform("install --no-wait", then: endTransitionUnlessDone)
    }

    func turnOff() {
        powerState = .stopping
        transitionStarted = Date()
        perform("uninstall", then: endTransitionUnlessDone)
    }

    func unblockNow() { perform("unblock") }

    // MARK: - Exceptions
    //
    // Written straight to the store, which the daemon watches. Falls back
    // to the privileged CLI only if the file is not writable — for example
    // on an install that predates the group-writable store.

    private func reloadEndpoints() {
        stamps[ExceptionStore.path] = nil
        refresh()
    }

    @discardableResult
    func addException(_ ip: String) -> Bool {
        var all = ExceptionStore.load()
        if let index = all.firstIndex(where: { $0.ip == ip }) {
            all[index].pinned = true
        } else {
            all.append(Endpoint(ip: ip, lastSeen: Date(), hits: 1, pinned: true))
        }
        if ExceptionStore.save(all) { reloadEndpoints(); return true }
        perform("pin add \(ip)")
        return true
    }

    func removeException(_ ip: String) {
        let remaining = ExceptionStore.load().filter { $0.ip != ip }
        if ExceptionStore.save(remaining) { reloadEndpoints(); return }
        perform("pin remove \(ip)")
    }

    func setPinned(_ ip: String, _ pinned: Bool) {
        var all = ExceptionStore.load()
        guard let index = all.firstIndex(where: { $0.ip == ip }) else { return }
        all[index].pinned = pinned
        if ExceptionStore.save(all) { reloadEndpoints(); return }
        perform("pin \(pinned ? "keep" : "unpin") \(ip)")
    }

    /// Most settings live only in config.json, which the daemon owns but
    /// leaves group-writable, and re-reads within a second. Writing it
    /// directly means toggling a switch does not raise an authorisation
    /// prompt every single time.
    ///
    /// `autostart` is the exception: it places a plist in
    /// /Library/LaunchDaemons, so it genuinely needs root.
    func set(_ key: String, _ value: String) {
        if key == "autostart" || !writeConfigDirectly(key: key, value: value) {
            perform("set \(key) \(value)")
            return
        }
        refresh()
    }

    private func writeConfigDirectly(key: String, value: String) -> Bool {
        let path = "/usr/local/var/vpn_kill_switch/config.json"
        guard FileManager.default.isWritableFile(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }

        if value == "0" || value == "1" {
            object[key] = (value == "1")
        } else if let number = Double(value) {
            object[key] = number
        } else {
            object[key] = value
        }

        guard let encoded = try? JSONSerialization.data(withJSONObject: object,
                                                        options: [.prettyPrinted, .sortedKeys])
        else { return false }
        // Written in place, NOT atomically. An atomic write replaces the
        // file, and the replacement would lose the root:admin 0664 the
        // daemon relies on — so the next write would fail. (It cannot even
        // succeed here: the enclosing directory is root-owned, so this user
        // may not create the temporary file an atomic write needs.)
        guard let handle = FileHandle(forWritingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: encoded)
            try handle.synchronize()
            return true
        } catch {
            return false
        }
    }
}

/// Cheap change detection for a polled file: a stat, not a read.
private struct FileStamp: Equatable {
    let modified: Date?
    let size: Int?

    init(path: String) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        modified = attributes?[.modificationDate] as? Date
        size = attributes?[.size] as? Int
    }
}
