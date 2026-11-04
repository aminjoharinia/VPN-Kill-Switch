import Foundation

/// pf enforcement.
///
/// This still shells out to pfctl, and deliberately so: filtering
/// packets from Swift directly would need a NetworkExtension system
/// extension plus an Apple-granted entitlement.
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

    /// `dnsAssist`: physical interfaces DNS may leave through despite
    /// blockDNS — the reconnect assist (see KillSwitch.updateDNSAssist).
    /// `vpnUDPPorts`: the VPN process's own UDP ports, see Sockets.udpPorts.
    /// `reconnectWindow`: physical interfaces opened while a VPN client
    /// connects to a new server (see KillSwitch.updateReconnectWindow).
    static func buildRules(config: Config,
                           tunnels: [TunnelInterface],
                           endpoints: [String],
                           dnsAssist: [String] = [],
                           vpnUDPPorts: [Int] = [],
                           reconnectWindow: [String] = []) -> String {
        var lines: [String] = ["pass out quick on lo0 all"]

        // Allow traffic out over the tunnels themselves. This is not a
        // leak: a live tunnel encrypts it, a dead tunnel discards it
        // because nothing is reading the other end. It is also what
        // keeps our own liveness probe working while the block is on —
        // without it the switch could never observe recovery and would
        // stay latched down forever after the first drop.
        //
        // "flags any": pf's default (flags S/SA) creates state only from a
        // SYN. The block flushes the state table, so every connection the
        // VPN client already had open — to its server, which is exactly
        // what must keep working — then sent packets matching no pass
        // rule and was silently dropped. The client sat on its stalled
        // connections until its own timeouts gave up, ten seconds to
        // minutes, and only then reconnected.
        for tunnel in tunnels {
            lines.append("pass out quick on \(tunnel.name) all flags any keep state")
        }

        if config.allowVPNReconnect {
            for ip in endpoints {
                lines.append("pass out quick on ! lo0 to \(ip) flags any keep state")
            }
        }

        // Before the LAN passes, so queries cannot leak to the router
        // and onward to the ISP. Loopback resolvers still work via the
        // quick lo0 pass above.
        if config.blockDNS && !dnsAssist.isEmpty {
            lines.append("pass out quick on { \(dnsAssist.joined(separator: ", ")) } proto { tcp, udp } to any port { 53, 853 } flags any keep state")
        }

        if config.blockDNS {
            for proto in ["tcp", "udp"] {
                lines.append("block drop out quick proto \(proto) from any to any port 53")
                lines.append("block drop out quick proto \(proto) from any to any port 853")
            }
        }

        // A QUIC client's server, by the socket it leaves from. After the
        // DNS block, so a core that also forwards lookups cannot leak them.
        if config.allowVPNReconnect && !vpnUDPPorts.isEmpty {
            let ports = vpnUDPPorts.map(String.init).joined(separator: ", ")
            lines.append("pass out quick on ! lo0 proto udp from any port { \(ports) } keep state")
        }

        // After the DNS block too: the window opens the link, not lookups.
        if config.allowVPNReconnect && !reconnectWindow.isEmpty {
            lines.append("pass out quick on { \(reconnectWindow.joined(separator: ", ")) } all flags any keep state")
        }

        if config.allowLAN {
            for net in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                        "169.254.0.0/16", "224.0.0.0/4"] {
                lines.append("pass out quick on ! lo0 to \(net) flags any keep state")
            }
            lines.append("pass out quick on ! lo0 inet6 to fe80::/10 flags any keep state")
            lines.append("pass out quick on ! lo0 inet6 to ff00::/8 flags any keep state")
        }

        lines.append("block drop out quick on ! lo0 all")
        return lines.joined(separator: "\n") + "\n"
    }

    /// - Parameter flushStates: drop pf's state table too. Required when
    ///   newly blocking, because pf keeps state for connections opened
    ///   before the block — an in-flight download would otherwise keep
    ///   streaming over the real IP. Skipped on re-assert so we do not
    ///   tear down healthy LAN connections repeatedly.
    /// Returns whether the rules were loaded.
    @discardableResult
    static func applyBlock(rules: String, flushStates: Bool) -> Bool {
        try? rules.write(toFile: Paths.anchorFile, atomically: true, encoding: .utf8)
        if !anchorRegistered { ensureAnchorRegistered() }
        let result = Shell.run(pfctl, ["-a", Paths.anchorName, "-f", Paths.anchorFile])
        if result.status != 0 {
            log("ERROR: pfctl failed to load anchor rules: \(result.output)")
            return false
        }
        if !isEnabled { Shell.run(pfctl, ["-e"]) }
        if flushStates {
            Shell.run(pfctl, ["-F", "states"])
            log("flushed pf state table")
        }
        return true
    }

    /// Loaded in place of the block while the VPN is healthy. Every rule
    /// here PASSES — traffic behaves exactly as with an empty anchor — but
    /// pf now keeps a state entry for each connection leaving through the
    /// physical interfaces, and those entries name the remote address.
    ///
    /// That is the only reliable way to learn a VPN server's address from
    /// a Network Extension client such as Happ: it sends from an
    /// unconnected UDP socket (netstat shows no remote at all) and adds no
    /// host route. Without its server in the allow-list, a block stops the
    /// client reaching it, the tunnel cannot recover, and the probe fails
    /// forever — traffic stays cut until the switch is turned off.
    static func observeRules(physical: [String]) -> String {
        guard !physical.isEmpty else { return "# vpn_kill_switch anchor (idle)\n" }
        return """
            # vpn_kill_switch anchor (observing; pass-only)
            table <vpnks_private> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 127.0.0.0/8 }
            pass out on { \(physical.joined(separator: ", ")) } inet proto { tcp, udp } to ! <vpnks_private> keep state

            """
    }

    /// Swaps the block for the pass-only observing rules.
    static func loadObserve(physical: [String]) {
        let rules = observeRules(physical: physical)
        try? rules.write(toFile: Paths.anchorFile, atomically: true, encoding: .utf8)
        let result = Shell.run(pfctl, ["-a", Paths.anchorName, "-f", Paths.anchorFile])
        if result.status != 0 {
            // Never leave a failed load standing in for "no block".
            log("WARN: could not load observing rules (\(result.output)); clearing instead")
            clearBlock()
            return
        }
        if !isEnabled { Shell.run(pfctl, ["-e"]) }
    }

    /// Outbound connections pf is tracking from one of `localAddresses`,
    /// as remote address → total bytes both ways. Reads the kernel's state
    /// table; nothing touches the disk.
    static func stateRemotes(localAddresses: Set<String>) -> [String: UInt64] {
        parseStates(Shell.run(pfctl, ["-vss"]).output, localAddresses: localAddresses)
    }

    /// Split out from `stateRemotes` so it can be tested without root.
    static func parseStates(_ output: String, localAddresses: Set<String>) -> [String: UInt64] {
        var totals: [String: UInt64] = [:]
        var pendingRemote: String?

        for line in output.split(separator: "\n") {
            if let arrow = line.range(of: " -> ") {
                pendingRemote = nil
                // "ALL udp 192.168.1.12:57920 -> 185.206.92.123:443   STATE"
                let left = line[..<arrow.lowerBound].split(separator: " ")
                let right = line[arrow.upperBound...].split(separator: " ")
                guard let local = left.last.flatMap(address), localAddresses.contains(local),
                      let remote = right.first.flatMap(address) else { continue }
                pendingRemote = remote
                continue
            }
            // The byte counts follow on an indented line: "…, 1234:5678 bytes, …"
            guard let remote = pendingRemote,
                  let range = line.range(of: #"(\d+):(\d+) bytes"#, options: .regularExpression)
            else { continue }
            let pair = line[range].dropLast(" bytes".count).split(separator: ":")
            let bytes = pair.compactMap { UInt64($0) }.reduce(0, &+)
            totals[remote, default: 0] &+= bytes
            pendingRemote = nil
        }
        return totals
    }

    /// "1.2.3.4:443" → "1.2.3.4"; nil for anything that is not IPv4.
    private static func address<S: StringProtocol>(_ token: S) -> String? {
        guard let colon = token.lastIndex(of: ":") else { return nil }
        let ip = String(token[..<colon])
        let parts = ip.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return ip
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
