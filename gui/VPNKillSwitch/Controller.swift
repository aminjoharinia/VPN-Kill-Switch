import Foundation
import Observation

@MainActor
@Observable
final class Controller {
    var status: DaemonStatus?
    var logLines: [String] = []
    var busy = false
    var lastError: String?
    var powerState: PowerState = .off

    private var timer: Timer?
    private var transitionStarted: Date?

    // MARK: - Derived state

    var daemonRunning: Bool { status?.isFresh == true }

    /// Resolves the transient states. A transition gives up after 25s so a
    /// failed install cannot leave the button spinning forever.
    private func updatePowerState() {
        let running = daemonRunning
        switch powerState {
        case .starting:
            if running { powerState = .on; transitionStarted = nil }
            else if let t = transitionStarted, Date().timeIntervalSince(t) > 25 {
                powerState = .off; transitionStarted = nil
                // Distinguish "never started" from "started but I cannot
                // read it" — they need completely different fixes, and
                // reporting the wrong one sends you hunting the wrong bug.
                if FileManager.default.fileExists(atPath: Paths.status) {
                    lastError = """
                        The daemon is running but this app cannot read its status.

                        That usually means the installed daemon is older than this app.                         Rebuild both and try again:

                            ./gui/run.sh
                        """
                } else {
                    lastError = """
                        The daemon did not start.

                        Check Activity, or run it by hand to see why:

                            sudo \(Paths.cli) daemon
                        """
                }
            }
        case .stopping:
            if !running { powerState = .off; transitionStarted = nil }
            else if let t = transitionStarted, Date().timeIntervalSince(t) > 25 {
                powerState = .on; transitionStarted = nil
            }
        case .on, .off:
            powerState = running ? .on : .off
        }
    }

    var protection: Protection {
        guard let status, status.isFresh else { return .off }
        if status.blocked { return status.alwaysArmed ? .armed : .blocked }
        return status.alwaysArmed ? .armed : .protected
    }

    var installed: Bool { Paths.resolvedCLI != nil }

    // MARK: - Polling

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        if let data = FileManager.default.contents(atPath: Paths.status) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            status = try? decoder.decode(DaemonStatus.self, from: data)
        } else {
            status = nil
        }
        logLines = Self.tail(Paths.log, lines: 200)
        updatePowerState()
    }

    private static func tail(_ path: String, lines: Int) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines)
            .map(String.init)
            .reversed()
    }

    // MARK: - Privileged actions

    /// Runs the CLI through osascript's authorisation dialog. The app
    /// itself holds no elevated rights; every privileged action is an
    /// explicit, user-approved prompt.
    /// Runs osascript off the main actor. Kept `nonisolated static` so
    /// no part of the observable model is captured by the background
    /// closure — that capture is what the compiler flags as non-Sendable.
    private nonisolated static func runOsascript(_ script: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Every privileged action is an explicit, user-approved macOS
    /// authorisation prompt. The app itself holds no elevated rights and
    /// installs no privileged helper.
    @discardableResult
    private func privileged(_ arguments: String) async -> Bool {
        guard let cli = Paths.resolvedCLI else {
            lastError = "vpnks CLI not found. Build it first (see README)."
            return false
        }
        let command = "\(shellQuote(cli)) \(arguments)"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let result = await Task.detached { Controller.runOsascript(script) }.value
        // -128 is the user cancelling the auth dialog; not an error.
        if result.status != 0 && !result.output.contains("-128") {
            lastError = result.output.isEmpty ? "Command failed." : result.output
        }
        return result.status == 0
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func perform(_ arguments: String) {
        Task { @MainActor in
            busy = true
            lastError = nil
            await privileged(arguments)
            busy = false
            refresh()
        }
    }

    func turnOn() {
        powerState = .starting
        transitionStarted = Date()
        perform("install")
    }

    func turnOff() {
        powerState = .stopping
        transitionStarted = Date()
        perform("uninstall")
    }

    func unblockNow() { perform("unblock") }

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
