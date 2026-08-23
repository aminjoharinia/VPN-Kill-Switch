import Foundation

/// Learns which public addresses the VPN client reaches over the
/// PHYSICAL interface, so the block can let it reconnect.
///
/// Without this, ALL mode blocks the VPN's own handshake: the switch
/// fires once and the machine can never get back online without manual
/// intervention.
///
/// Filtering is by local address, not by process. An earlier attempt
/// used `lsof -p PID -i`, which ORs those selectors instead of ANDing
/// them and therefore returned every socket on the machine — it would
/// have punched holes for unrelated hosts.
enum Endpoints {
    static func load() -> [String] {
        guard let text = try? String(contentsOfFile: Paths.endpointsFile, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func isPrivate(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        switch (parts[0], parts[1]) {
        case (0, _), (10, _), (127, _): return true
        case (169, 254): return true
        case (192, 168): return true
        case (172, 16...31): return true
        case (224...255, _): return true
        default: return false
        }
    }

    /// While the tunnel is healthy, rank remote peers reached from a
    /// physical address by how many sockets point at them. A VPN client
    /// holds many concurrent connections to its server; an app merely
    /// bypassing the tunnel holds one or two. Keeping the top few aims
    /// the hole at the server and keeps it narrow.
    static func learn() {
        let physical = Interfaces.physicalIPv4()
        guard !physical.isEmpty else { return }

        var counts: [String: Int] = [:]

        // Host routes pinned to a non-tunnel interface are how most VPN
        // clients keep reaching their server after handing over the
        // default route.
        let netstat = Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).output
        for line in netstat.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4 else { continue }
            let destination = String(fields[0])
            let netif = String(fields[3])
            guard !Interfaces.isTunnelName(netif), netif != "lo0" else { continue }
            guard destination.split(separator: ".").count == 4,
                  !isPrivate(destination) else { continue }
            counts[destination, default: 0] += 3   // strong signal
        }

        let sockets = Shell.run("/usr/sbin/netstat", ["-an", "-f", "inet"]).output
        for line in sockets.split(separator: "\n") where line.contains("ESTABLISHED") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 5 else { continue }
            let local = String(fields[3]), remote = String(fields[4])
            guard let localIP = stripPort(local), physical.contains(localIP),
                  let remoteIP = stripPort(remote), !isPrivate(remoteIP) else { continue }
            counts[remoteIP, default: 0] += 1
        }

        let ranked = counts.sorted { $0.value > $1.value }.prefix(6).map { $0.key }
        guard !ranked.isEmpty else { return }
        try? ranked.joined(separator: "\n")
            .write(toFile: Paths.endpointsFile, atomically: true, encoding: .utf8)
    }

    /// netstat prints "1.2.3.4.443" — address and port share the dot separator.
    private static func stripPort(_ s: String) -> String? {
        let parts = s.split(separator: ".")
        guard parts.count == 5 else { return nil }
        return parts.prefix(4).joined(separator: ".")
    }
}
