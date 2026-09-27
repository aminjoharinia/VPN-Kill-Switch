import Foundation

struct TunnelInterface: Equatable {
    let name: String
    let ipv4: String
}

/// Interface enumeration straight from getifaddrs(3). The shell version
/// forked `ifconfig` and parsed its text for this, several times a
/// second; this is a single syscall with no process spawn, which is what
/// makes sub-millisecond reaction affordable.
enum Interfaces {
    static let tunnelPrefixes = ["utun", "ppp", "ipsec", "tun", "tap"]

    static func isTunnelName(_ name: String) -> Bool {
        tunnelPrefixes.contains { name.hasPrefix($0) }
    }

    /// First usable IPv4 address per interface (loopback and link-local excluded).
    static func ipv4ByInterface() -> [String: String] {
        var result: [String: String] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return result }
        defer { freeifaddrs(head) }

        var cursor = head
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let sa = entry.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip == "127.0.0.1" || ip.hasPrefix("169.254.") { continue }
            if result[name] == nil { result[name] = ip }
        }
        return result
    }

    static func tunnels() -> [TunnelInterface] {
        ipv4ByInterface()
            .filter { isTunnelName($0.key) }
            .map { TunnelInterface(name: $0.key, ipv4: $0.value) }
            .sorted { $0.name < $1.name }
    }

    /// Names of non-tunnel interfaces with an IPv4 address (en0, en1…).
    static func physicalNames() -> [String] {
        ipv4ByInterface().keys
            .filter { !isTunnelName($0) && $0 != "lo0" }
            .sorted()
    }

    static func physicalIPv4() -> Set<String> {
        Set(ipv4ByInterface()
            .filter { !isTunnelName($0.key) && $0.key != "lo0" }
            .map { $0.value })
    }
}
