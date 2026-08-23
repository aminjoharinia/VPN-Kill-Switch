import Foundation

/// Liveness probe: a real HTTP round trip pinned to one interface.
///
/// Why not ping, and why not a bare TCP connect — both measured on a
/// live transparent-proxy tunnel (Happ/sing-box class, the common case):
///
///   * bound ICMP fails even when the tunnel is perfectly healthy,
///     because the proxy does not forward pings. Trusting it means
///     blocking forever.
///   * a bound TCP connect SUCCEEDS against a black-holed address,
///     because the proxy accepts the socket locally before it has any
///     upstream. Trusting it means never noticing a dead tunnel.
///
/// Only bytes coming back from a real server distinguish the two. The
/// target is an IP literal so the probe needs no DNS — it still works
/// when our own block is in force and resolution would otherwise fail.
enum Probe {
    /// IP_BOUND_IF from <netinet/in.h>; the same mechanism `curl --interface` uses.
    private static let IP_BOUND_IF: Int32 = 25

    static func run(interface: String,
                    host: String,
                    port: UInt16,
                    hostHeader: String,
                    path: String,
                    timeout: TimeInterval) -> Bool {
        let index = if_nametoindex(interface)
        guard index != 0 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Pin the socket to the tunnel. Without this the probe would
        // happily succeed over the physical link — which is precisely
        // the leak we are trying to detect.
        var idx = UInt32(index)
        guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx,
                         socklen_t(MemoryLayout<UInt32>.size)) == 0 else { return false }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        // Non-blocking connect so the timeout is enforced by poll(), not
        // by the kernel's much longer default.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var connectResult: Int32 = -1
        withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connectResult = connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else { return false }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0,
                  soError == 0 else { return false }
        }
        _ = fcntl(fd, F_SETFL, flags)

        let request = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nUser-Agent: vpnks/1.0\r\nConnection: close\r\n\r\n"
        let payload = [UInt8](request.utf8)
        let sent = payload.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == payload.count else { return false }

        var response = [UInt8](repeating: 0, count: 256)
        let received = recv(fd, &response, response.count, 0)
        guard received > 0 else { return false }

        let head = String(decoding: response[0..<min(Int(received), 32)], as: UTF8.self)
        // Any well-formed 2xx/3xx proves bytes traversed the tunnel.
        guard head.hasPrefix("HTTP/1.") else { return false }
        let parts = head.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return false }
        return (200..<400).contains(code)
    }
}
