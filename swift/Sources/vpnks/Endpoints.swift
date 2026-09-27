import Foundation

/// One address allowed out through the block.
struct Endpoint: Codable, Equatable {
    var ip: String
    var lastSeen: Date
    var hits: Int
    /// Pinned addresses are never aged out, never crowded out by newer
    /// observations, and are only removed when you remove them.
    var pinned: Bool
}

/// The addresses punched through the kill switch so the VPN client can
/// reach its own server and reconnect.
///
/// This used to be a plain list that each scan OVERWROTE with whatever
/// sockets happened to be open at that moment. During a reconnect only
/// one connection is usually established, so a list of five collapsed to
/// one — discarding exactly the addresses the next reconnect needed. The
/// store now merges observations, ages them slowly, and keeps pinned
/// entries forever.
enum EndpointStore {
    static let path = "/usr/local/var/vpn_kill_switch/endpoints.json"
    static let legacyPath = "/usr/local/var/vpn_kill_switch/vpn_endpoints"

    /// How long an unseen address stays before being forgotten.
    static let retention: TimeInterval = 14 * 24 * 3600
    /// Cap on automatically learned entries. Pinned ones are extra.
    static let maxLearned = 16

    // MARK: - Persistence

    static func load() -> [Endpoint] {
        if let data = FileManager.default.contents(atPath: path),
           let stored = try? decoder.decode([Endpoint].self, from: data) {
            return stored
        }
        // One-time migration from the old newline-separated file.
        if let text = try? String(contentsOfFile: legacyPath, encoding: .utf8) {
            let migrated = text.split(separator: "\n")
                .map { Endpoint(ip: String($0), lastSeen: Date(), hits: 1, pinned: false) }
                .filter { isValidIPv4($0.ip) }
            if !migrated.isEmpty { save(migrated) }
            return migrated
        }
        return []
    }

    static func save(_ endpoints: [Endpoint]) {
        guard let data = try? encoder.encode(endpoints) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        // root:admin 0664, matching config.json: the UI can add or remove
        // an exception without raising an authorisation prompt each time.
        try? FileManager.default.setAttributes(
            [.groupOwnerAccountID: 80, .posixPermissions: 0o664],
            ofItemAtPath: path)
    }

    static func modifiedAt() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    // MARK: - Rules

    /// Addresses to punch through the block: every pinned one, plus the
    /// most RECENTLY seen learned ones.
    ///
    /// This used to take the most-seen by lifetime hit count. Hits only
    /// ever grow, so servers from weeks ago held every slot while the one
    /// the VPN client moved to yesterday could never catch up — it was
    /// listed under Exceptions but not in the firewall, and reconnecting
    /// to it was blocked.
    static func allowList() -> [String] {
        let all = load()
        let pinned = all.filter(\.pinned).map(\.ip)
        let learned = all.filter { !$0.pinned }
            .sorted { ($0.lastSeen, $0.hits) > ($1.lastSeen, $1.hits) }
            .prefix(maxLearned)
            .map(\.ip)
        return Array(Set(pinned + learned)).sorted()
    }

    // MARK: - Editing

    static func add(_ ip: String, pinned: Bool) -> Bool {
        guard isValidIPv4(ip) else { return false }
        var all = load()
        if let index = all.firstIndex(where: { $0.ip == ip }) {
            all[index].pinned = all[index].pinned || pinned
            all[index].lastSeen = Date()
        } else {
            all.append(Endpoint(ip: ip, lastSeen: Date(), hits: 1, pinned: pinned))
        }
        save(all)
        return true
    }

    static func remove(_ ip: String) {
        save(load().filter { $0.ip != ip })
    }

    static func setPinned(_ ip: String, _ pinned: Bool) {
        var all = load()
        guard let index = all.firstIndex(where: { $0.ip == ip }) else { return }
        all[index].pinned = pinned
        save(all)
    }

    static func isValidIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let n = Int(part), n >= 0, n <= 255, !part.isEmpty else { return false }
            return true
        }
    }

    // MARK: - Observation

    /// How stale an entry's lastSeen may get before an observation is
    /// worth a write. Ranking is by recency in days, so hourly is ample.
    static let refreshAfter: TimeInterval = 3600

    /// Folds a fresh set of observations into the store. Existing entries
    /// are updated, unseen ones are kept until they age out, and pinned
    /// ones are untouchable.
    ///
    /// Writes only when something that matters changed: a new address, an
    /// entry aged out, or a lastSeen more than an hour old. It used to
    /// rewrite the file on every observation — every 30 s while connected
    /// and every 2 s while blocked — just to bump hit counters.
    static func merge(observed: [String: Int]) {
        var all = load()
        let now = Date()
        var changed = false

        for (ip, hits) in observed {
            guard isValidIPv4(ip) else { continue }
            if let index = all.firstIndex(where: { $0.ip == ip }) {
                if now.timeIntervalSince(all[index].lastSeen) >= refreshAfter {
                    all[index].hits += hits
                    all[index].lastSeen = now
                    changed = true
                }
            } else {
                all.append(Endpoint(ip: ip, lastSeen: now, hits: hits, pinned: false))
                changed = true
            }
        }

        // Age out only unpinned entries, and only after a long silence.
        let kept = all.filter { $0.pinned || now.timeIntervalSince($0.lastSeen) < retention }
        if kept.count != all.count { changed = true }
        all = kept

        // Keep the store itself bounded, pinned entries exempt. Newest
        // first, for the same reason as allowList().
        let pinned = all.filter(\.pinned)
        let learned = all.filter { !$0.pinned }
            .sorted { ($0.lastSeen, $0.hits) > ($1.lastSeen, $1.hits) }
        if learned.count > maxLearned * 2 { changed = true }

        guard changed else { return }
        save(pinned + Array(learned.prefix(maxLearned * 2)))
    }
}

enum Endpoints {
    /// Observes which public addresses the VPN client reaches over the
    /// PHYSICAL interface, and folds them into the store.
    ///
    /// Two sources: host routes a VPN client adds for its server, and the
    /// connections pf tracks out of the physical interface. The latter
    /// replaced a netstat scan, which cannot see a Network Extension
    /// client's server at all (unconnected UDP socket, no remote shown).
    static func learn() {
        let physical = Interfaces.physicalIPv4()
        guard !physical.isEmpty else { return }

        var observed = serverRoutes()

        // Connections pf is tracking out of the physical interface (see
        // PacketFilter.observeRules). While a full-tunnel VPN is up,
        // ordinary traffic goes into the tunnel, so what leaves directly is
        // the VPN client talking to its server — and that one flow carries
        // everything, so it dwarfs the rest. Learn it, and anything else
        // of real size, but not every small system service that bypasses
        // the tunnel.
        let states = PacketFilter.stateRemotes(localAddresses: physical)
            .filter { !isPrivate($0.key) }
        if let largest = states.values.max(), largest >= 64 * 1024 {
            for (remote, bytes) in states where bytes >= 1_048_576 || bytes == largest {
                observed[remote, default: 0] += 3
            }
        }

        guard !observed.isEmpty else { return }
        EndpointStore.merge(observed: observed)
    }

    /// Learns from host routes only. Safe to run while traffic is blocked,
    /// which `learn()` is not: a VPN client reconnecting to a server it
    /// has never used before adds a host route for it first, and unless
    /// that address is picked up now, the block stops the client reaching
    /// it and the tunnel never comes back.
    ///
    /// Only root can add routes, so a public host routed around the tunnel
    /// is a VPN client's doing — ordinary apps cannot open holes this way.
    /// Returns true if the store gained an address.
    @discardableResult
    static func learnFromRoutes() -> Bool {
        let observed = serverRoutes()
        guard !observed.isEmpty else { return false }
        let known = Set(EndpointStore.load().map(\.ip))
        EndpointStore.merge(observed: observed)
        return !Set(observed.keys).isSubset(of: known)
    }

    /// Host routes pinned to a non-tunnel interface: how most VPN clients
    /// keep reaching their server after handing over the default route.
    /// Weighted heavily — it is a strong signal.
    private static func serverRoutes() -> [String: Int] {
        var observed: [String: Int] = [:]
        let routes = Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).output
        for line in routes.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4 else { continue }
            let destination = String(fields[0]), netif = String(fields[3])
            guard !Interfaces.isTunnelName(netif), netif != "lo0",
                  EndpointStore.isValidIPv4(destination),
                  !isPrivate(destination) else { continue }
            observed[destination, default: 0] += 3
        }
        return observed
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
}
