import Foundation

/// Which interface carries the IPv4 default route.
///
/// This asks the kernel the same question `route -n get default` asks —
/// an RTM_GET on a routing socket — rather than dumping the table and
/// guessing.
///
/// A dump-and-filter version of this was wrong in a way worth recording:
/// it required RTF_GATEWAY, and a tunnel's default route does not carry
/// that flag. On a live proxy VPN the table holds
///
///     default  link#25       UCSg   utun7      <- the real default, no 'G'
///     default  192.168.1.1   UGScIg en0
///
/// so the filter skipped the tunnel and reported en0. That would have
/// told the kill switch traffic was leaving in the clear at all times.
enum RouteTable {
    private static let RTM_VERSION: UInt8 = 5
    private static let RTM_GET: UInt8 = 4
    private static let RTA_DST: Int32 = 1

    static func defaultInterfaceName() -> String? {
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        let headerSize = MemoryLayout<rt_msghdr>.stride      // 92
        let addressSize = MemoryLayout<sockaddr_in>.stride   // 16
        let total = headerSize + addressSize
        let sequence = Int32.random(in: 1...Int32.max)
        let pid = getpid()

        var request = [UInt8](repeating: 0, count: total)
        request.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let header = base.assumingMemoryBound(to: rt_msghdr.self)
            header.pointee.rtm_msglen = UInt16(total)
            header.pointee.rtm_version = RTM_VERSION
            header.pointee.rtm_type = RTM_GET
            header.pointee.rtm_addrs = RTA_DST
            header.pointee.rtm_pid = pid
            header.pointee.rtm_seq = sequence

            // Destination 0.0.0.0 — the default route.
            let destination = base.advanced(by: headerSize)
                .assumingMemoryBound(to: sockaddr_in.self)
            destination.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.pointee.sin_family = sa_family_t(AF_INET)
            destination.pointee.sin_addr.s_addr = 0
        }

        let written = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == total else { return nil }

        var reply = [UInt8](repeating: 0, count: 4096)
        // The socket also carries unrelated routing chatter; read past
        // anything that is not the answer to our own request.
        for _ in 0..<32 {
            let received = reply.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard received >= headerSize else { return nil }

            let name: String? = reply.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return nil }
                let header = base.assumingMemoryBound(to: rt_msghdr.self).pointee
                guard header.rtm_seq == sequence, header.rtm_pid == pid else { return nil }
                var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                guard if_indextoname(UInt32(header.rtm_index), &buffer) != nil else { return nil }
                return String(cString: buffer)
            }
            if let name { return name }
        }
        return nil
    }
}
