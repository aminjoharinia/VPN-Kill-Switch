import Foundation

/// Autostart is a setting, not a property of being installed:
///
///   autostart on   plist lives in /Library/LaunchDaemons, so launchd
///                  starts it at boot.
///   autostart off  plist lives in the state dir and is bootstrapped for
///                  the current boot only. Nothing starts on its own.
///
/// Either way it runs under launchd as root, so KeepAlive still restarts
/// it if it crashes.
enum Installer {
    static func plist(binary: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(Paths.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>daemon</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ThrottleInterval</key><integer>10</integer>
            <key>UserName</key><string>root</string>
            <key>StandardOutPath</key><string>\(Paths.stateDir)/daemon.out.log</string>
            <key>StandardErrorPath</key><string>\(Paths.stateDir)/daemon.err.log</string>
        </dict>
        </plist>
        """
    }

    /// `wait: false` returns as soon as launchd has the job, without the
    /// start-up check. The app passes it: it confirms the start itself by
    /// watching status.json, and it runs this while its window is frozen
    /// behind the password prompt — every second spent here is a second
    /// of a stuck window.
    static func install(config: Config, wait: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Paths.libexecDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: true)

        let source = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
        if source != Paths.installedBinary {
            if fm.fileExists(atPath: Paths.installedBinary) {
                try fm.removeItem(atPath: Paths.installedBinary)
            }
            try fm.copyItem(atPath: source, toPath: Paths.installedBinary)
        }
        try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0,
                              .posixPermissions: 0o755],
                             ofItemAtPath: Paths.installedBinary)

        stop()

        let target = config.autostart ? Paths.bootPlist : Paths.manualPlist
        let other  = config.autostart ? Paths.manualPlist : Paths.bootPlist
        try? fm.removeItem(atPath: other)
        try plist(binary: Paths.installedBinary).write(toFile: target,
                                                       atomically: true, encoding: .utf8)
        try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0,
                              .posixPermissions: 0o644],
                             ofItemAtPath: target)

        var result = Shell.run("/bin/launchctl", ["bootstrap", "system", target])
        if result.status != 0 {
            result = Shell.run("/bin/launchctl", ["load", "-w", target])
        }
        guard wait else {
            print(result.status == 0 ? "✓ vpnks installed; starting" : "✗ \(result.output)")
            return
        }
        Thread.sleep(forTimeInterval: 2)

        let running = Shell.run("/usr/bin/pgrep", ["-f", "vpnks daemon"]).status == 0
        if running {
            print("✓ vpnks installed and running from \(Paths.installedBinary)")
            print(config.autostart
                  ? "  It will also start automatically at boot."
                  : "  It will NOT start at boot (vpnks set autostart 1 to change).")
        } else {
            print("✗ Failed to start. Check \(Paths.stateDir)/daemon.err.log")
            print("  \(result.output)")
        }
    }

    /// Place or remove the boot plist without touching the running
    /// instance. Only ever one plist file exists, so launchd cannot end up
    /// with two jobs claiming the same label.
    static func applyAutostart(_ config: Config) {
        let target = config.autostart ? Paths.bootPlist : Paths.manualPlist
        let other  = config.autostart ? Paths.manualPlist : Paths.bootPlist
        try? FileManager.default.removeItem(atPath: other)
        try? plist(binary: Paths.installedBinary).write(toFile: target,
                                                        atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o644],
            ofItemAtPath: target)
    }

    /// Waits only as long as the daemon actually takes to exit (at most a
    /// second). The fixed one-second sleep it replaces was paid even when
    /// nothing was running, i.e. on every Turn On.
    static func stop() {
        Shell.run("/bin/launchctl", ["bootout", "system/\(Paths.label)"])
        Shell.run("/usr/bin/pkill", ["-f", "vpnks daemon"])
        for _ in 0..<20 {
            if Shell.run("/usr/bin/pgrep", ["-f", "vpnks daemon"]).status != 0 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    static func uninstall() {
        stop()
        // Never leave the machine firewalled with nothing left to unfirewall it.
        PacketFilter.clearBlock()
        try? FileManager.default.removeItem(atPath: Paths.bootPlist)
        try? FileManager.default.removeItem(atPath: Paths.manualPlist)
        PacketFilter.unregisterAnchor()
        print("✓ Removed. Traffic is unblocked.")
    }
}
