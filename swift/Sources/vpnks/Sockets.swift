import Foundation

/// The VPN client's own sockets: what lets a proxy-style client (Happ,
/// v2RayTun, sing-box…) reconnect through a block.
///
/// Their core reaches its server through an ordinary socket on the
/// physical interface: no host route, nothing in the routing table. Behind
/// a CDN the server comes back on a different address on every reconnect
/// (Happ through Cloudflare: 188.114.97.x, a new one each time), so the
/// allow-list learned while connected does not name it, the attempt is
/// dropped, the probe fails forever and traffic stays cut until the switch
/// is turned off. The attempt itself is visible, as a socket in SYN_SENT.
///
/// Only the process that owns the tunnel is read — any other app's
/// connection attempt during a block is exactly what must stay blocked —
/// and DNS ports are skipped (the reconnect assist handles lookups).
enum Sockets {
    /// The process holding the utun's kernel control socket. For a Network
    /// Extension client that is its provider (Happ's "Tunnel.appex"), not
    /// the app. utunN is unit N+1 of com.apple.net.utun_control.
    static func tunnelOwner(interface: String) -> pid_t? {
        guard interface.hasPrefix("utun"),
              let n = Int(interface.dropFirst("utun".count)) else { return nil }
        let wanted = "[ctl com.apple.net.utun_control id "
        let unit = " unit \(n + 1)]"
        var pid: pid_t?
        // -F pn: one "p<pid>" line per process, then "n<name>" per file.
        for line in Shell.run("/usr/sbin/lsof", ["-nP", "-F", "pn"]).output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = pid_t(line.dropFirst())
            } else if line.hasPrefix("n"), line.contains(wanted), line.hasSuffix(unit) {
                return pid
            }
        }
        return nil
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Public IPv4 addresses `pid`'s sockets are connected — or still
    /// trying to connect — to, with a count of sockets per address.
    static func remotes(pid: pid_t) -> [String: Int] {
        var observed: [String: Int] = [:]
        for proto in ["tcp", "udp"] {
            let output = Shell.run("/usr/sbin/netstat", ["-anv", "-p", proto, "-f", "inet"]).output
            for (ip, n) in parseNetstat(output, pid: pid) { observed[ip, default: 0] += n }
        }
        return observed
    }

    /// Split out from `remotes` so it can be tested without root.
    /// "tcp4  0 0  192.168.1.19.63968  188.114.97.6.2087  SYN_SENT … Tunnel:81257 …"
    static func parseNetstat(_ output: String, pid: pid_t) -> [String: Int] {
        var observed: [String: Int] = [:]
        let owner = ":\(pid)"
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 5, fields[0].hasPrefix("tcp4") || fields[0].hasPrefix("udp4"),
                  fields.contains(where: { $0.hasSuffix(owner) }),
                  let dot = fields[4].lastIndex(of: ".") else { continue }
            let ip = String(fields[4][..<dot])
            guard let port = Int(fields[4][fields[4].index(after: dot)...]),
                  port != 0, port != 53, port != 853,
                  EndpointStore.isValidIPv4(ip), !Endpoints.isPrivate(ip) else { continue }
            observed[ip, default: 0] += 1
        }
        return observed
    }
}

extension Sockets {
    /// Local ports of `pid`'s unconnected UDP sockets — how QUIC cores
    /// (Hysteria, TUIC, sing-box's QUIC transports) talk to their server.
    /// Such a socket names no peer (netstat shows "*.*"), so `remotes`
    /// cannot learn the server; a client switching to one it has never
    /// used stayed blocked for good. The port, though, is the process's
    /// own, so pf can pass by it without knowing the destination.
    static func udpPorts(pid: pid_t) -> [Int] {
        parseUnconnectedUDP(Shell.run("/usr/sbin/netstat", ["-anv", "-p", "udp"]).output, pid: pid)
    }

    /// "udp46  0 0  *.55673  *.*  …  Tunnel:45500 …"
    static func parseUnconnectedUDP(_ output: String, pid: pid_t) -> [Int] {
        var ports = Set<Int>()
        let owner = ":\(pid)"
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 5, fields[0].hasPrefix("udp"),
                  fields[4] == "*.*",
                  fields.contains(where: { $0.hasSuffix(owner) }),
                  let dot = fields[3].lastIndex(of: ".") else { continue }
            // Bound to loopback only: nothing it sends can leave anyway.
            let address = fields[3][..<dot]
            guard address != "127.0.0.1", address != "::1",
                  let port = Int(fields[3][fields[3].index(after: dot)...]),
                  port != 0, port != 53 else { continue }
            ports.insert(port)
        }
        return ports.sorted()
    }
}
