import Foundation

/// One continuous period during which the VPN was up on a given tunnel.
struct Session: Codable, Identifiable {
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var interfaceName: String
    var vpnAppName: String
    var bytesIn: UInt64
    var bytesOut: UInt64
    /// Times traffic was cut while this session was open.
    var blockCount: Int

    var isActive: Bool { endedAt == nil }
    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
}

/// Session history, newest first.
///
/// The active session is persisted continuously rather than only on
/// close, so an abrupt daemon exit cannot lose the run in progress.
enum SessionStore {
    static let path = "/usr/local/var/vpn_kill_switch/sessions.json"
    static let maxSessions = 200

    static func load() -> [Session] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Session].self, from: data)) ?? []
    }

    static func save(_ sessions: [Session]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(sessions.prefix(maxSessions))) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: path)
    }
}

/// Tracks the running session and turns raw interface counters into
/// per-session totals.
final class SessionTracker {
    private(set) var sessions: [Session] = []
    private var baseline: InterfaceStats.Counters?
    private var lastSeen: InterfaceStats.Counters?
    /// Carried forward when the kernel counter resets under us.
    private var carriedIn: UInt64 = 0
    private var carriedOut: UInt64 = 0
    private var lastPersist = Date.distantPast

    init() {
        sessions = SessionStore.load()
        // A session left open by a previous run cannot be resumed: its
        // interface counters are gone. Close it at its last known totals
        // rather than letting it look like it is still running.
        if let index = sessions.firstIndex(where: { $0.isActive }) {
            sessions[index].endedAt = sessions[index].startedAt
                .addingTimeInterval(sessions[index].duration)
            SessionStore.save(sessions)
        }
    }

    var active: Session? { sessions.first(where: { $0.isActive }) }

    func begin(interface: String, appName: String) {
        end()
        baseline = InterfaceStats.counters(for: interface)
        lastSeen = baseline
        carriedIn = 0
        carriedOut = 0
        sessions.insert(Session(id: UUID().uuidString,
                                startedAt: Date(),
                                endedAt: nil,
                                interfaceName: interface,
                                vpnAppName: appName,
                                bytesIn: 0,
                                bytesOut: 0,
                                blockCount: 0), at: 0)
        SessionStore.save(sessions)
    }

    func end() {
        guard let index = sessions.firstIndex(where: { $0.isActive }) else { return }
        sample()
        sessions[index].endedAt = Date()
        baseline = nil
        lastSeen = nil
        SessionStore.save(sessions)
    }

    func noteBlock() {
        guard let index = sessions.firstIndex(where: { $0.isActive }) else { return }
        sessions[index].blockCount += 1
    }

    /// Updates the active session's totals from the live counters.
    func sample() {
        guard let index = sessions.firstIndex(where: { $0.isActive }),
              let now = InterfaceStats.counters(for: sessions[index].interfaceName)
        else { return }

        guard var base = baseline else {
            baseline = now
            lastSeen = now
            return
        }

        // A utun recreated under the same name restarts its counters at
        // zero. Without this the delta would go negative and wrap into an
        // enormous number, so bank what we had and rebase.
        if let previous = lastSeen,
           now.bytesIn < previous.bytesIn || now.bytesOut < previous.bytesOut {
            carriedIn += previous.bytesIn &- base.bytesIn
            carriedOut += previous.bytesOut &- base.bytesOut
            base = InterfaceStats.Counters(bytesIn: 0, bytesOut: 0)
            baseline = base
        }
        lastSeen = now

        sessions[index].bytesIn = carriedIn &+ (now.bytesIn &- base.bytesIn)
        sessions[index].bytesOut = carriedOut &+ (now.bytesOut &- base.bytesOut)

        if Date().timeIntervalSince(lastPersist) >= 10 {
            lastPersist = Date()
            SessionStore.save(sessions)
        }
    }
}
