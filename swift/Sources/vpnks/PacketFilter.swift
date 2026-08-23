import Foundation

/// pf enforcement.
///
/// This still shells out to pfctl, and deliberately so: filtering
/// packets from Swift directly would need a NetworkExtension system
/// extension plus an Apple-granted entitlement. pf is the same
/// mechanism the shell version drives, so both agree on the anchor.
enum PacketFilter {
    private static let pfctl = "/sbin/pfctl"
    private static let marker = "# --- vpn_kill_switch (managed) ---"

    static var isEnabled: Bool {
        Shell.run(pfctl, ["-s", "info"]).output.contains("Status: Enabled")
    }

    static var anchorRegistered: Bool {
        Shell.run(pfctl, ["-s", "Anchors"]).output.contains(Paths.anchorName)
    }

    static var blockRuleCount: Int {
        Shell.run(pfctl, ["-a", Paths.anchorName, "-s", "rules"]).output
            .split(separator: "\n")
            .filter { $0.hasPrefix("block") }
            .count
    }

    static var isEnforced: Bool {
        isEnabled && anchorRegistered && blockRuleCount > 0
    }

    /// Registers our anchor inside /etc/pf.conf rather than replacing the
    /// main ruleset, so other tools' anchors survive — and so ours
    /// survives when another tool reloads /etc/pf.conf.
    static func ensureAnchorRegistered() {
        let anchorDir = (Paths.anchorFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: anchorDir,
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Paths.anchorFile) {
            try? "# vpn_kill_switch anchor\n".write(toFile: Paths.anchorFile,
                                                    atomically: true, encoding: .utf8)
        }
        let conf = (try? String(contentsOfFile: Paths.pfConf, encoding: .utf8)) ?? ""
        if !conf.contains("load anchor \"\(Paths.anchorName)\"") {
            let backup = Paths.pfConf + ".vpnks.bak"
            if !FileManager.default.fileExists(atPath: backup) {
                try? FileManager.default.copyItem(atPath: Paths.pfConf, toPath: backup)
            }
            let addition = """

            \(marker)
            anchor "\(Paths.anchorName)"
            load anchor "\(Paths.anchorName)" from "\(Paths.anchorFile)"

            """
            try? (conf + addition).write(toFile: Paths.pfConf,
                                         atomically: true, encoding: .utf8)
            log("registered pf anchor in \(Paths.pfConf)")
        }
        Shell.run(pfctl, ["-f", Paths.pfConf])
    }

    static func buildRules(config: Config,
                           tunnels: [TunnelInterface],
                           endpoints: [String]) -> String {
        var lines: [String] = ["pass out quick on lo0 all"]

        // Allow traffic out over the tunnels themselves. This is not a
        // leak: a live tunnel encrypts it, a dead tunnel discards it
        // because nothing is reading the other end. It is also what
        // keeps our own liveness probe working while the block is on —
        // without it the switch could never observe recovery and would
        // stay latched down forever after the first drop.
        for tunnel in tunnels {
            lines.append("pass out quick on \(tunnel.name) all")
        }

        if config.allowVPNReconnect {
            for ip in endpoints {
                lines.append("pass out quick on ! lo0 to \(ip)")
            }
        }

        // Before the LAN passes, so queries cannot leak to the router
        // and onward to the ISP. Loopback resolvers still work via the
        // quick lo0 pass above.
        if config.blockDNS {
            for proto in ["tcp", "udp"] {
                lines.append("block drop out quick proto \(proto) from any to any port 53")
                lines.append("block drop out quick proto \(proto) from any to any port 853")
            }
        }

        if config.allowLAN {
            for net in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                        "169.254.0.0/16", "224.0.0.0/4"] {
                lines.append("pass out quick on ! lo0 to \(net)")
            }
            lines.append("pass out quick on ! lo0 inet6 to fe80::/10")
            lines.append("pass out quick on ! lo0 inet6 to ff00::/8")
        }

        lines.append("block drop out quick on ! lo0 all")
        return lines.joined(separator: "\n") + "\n"
    }

    /// - Parameter flushStates: drop pf's state table too. Required when
    ///   newly blocking, because pf keeps state for connections opened
    ///   before the block — an in-flight download would otherwise keep
    ///   streaming over the real IP. Skipped on re-assert so we do not
    ///   tear down healthy LAN connections repeatedly.
    static func applyBlock(rules: String, flushStates: Bool) {
        try? rules.write(toFile: Paths.anchorFile, atomically: true, encoding: .utf8)
        if !anchorRegistered { ensureAnchorRegistered() }
        let result = Shell.run(pfctl, ["-a", Paths.anchorName, "-f", Paths.anchorFile])
        if result.status != 0 {
            log("ERROR: pfctl failed to load anchor rules: \(result.output)")
            return
        }
        if !isEnabled { Shell.run(pfctl, ["-e"]) }
        if flushStates {
            Shell.run(pfctl, ["-F", "states"])
            log("flushed pf state table")
        }
    }

    static func clearBlock() {
        try? "# vpn_kill_switch anchor (idle)\n".write(toFile: Paths.anchorFile,
                                                       atomically: true, encoding: .utf8)
        Shell.run(pfctl, ["-a", Paths.anchorName, "-F", "rules"])
    }

    static func unregisterAnchor() {
        guard let conf = try? String(contentsOfFile: Paths.pfConf, encoding: .utf8) else { return }
        let kept = conf.split(separator: "\n", omittingEmptySubsequences: false).filter {
            let line = String($0)
            return line != marker
                && line != "anchor \"\(Paths.anchorName)\""
                && !line.hasPrefix("load anchor \"\(Paths.anchorName)\"")
        }
        try? kept.joined(separator: "\n").write(toFile: Paths.pfConf,
                                                atomically: true, encoding: .utf8)
        Shell.run(pfctl, ["-f", Paths.pfConf])
    }
}
