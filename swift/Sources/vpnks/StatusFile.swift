import Foundation

/// Snapshot the daemon publishes for any UI to read.
///
/// The GUI is unprivileged, but almost everything interesting here
/// (whether pf is actually enforcing, what the last event was) requires
/// root to determine. Rather than make the app ask for authorisation
/// just to display a status dot, the daemon — which is already root —
/// writes this file world-readable on every state change.
struct DaemonStatus: Codable, Equatable {
    var updatedAt: Date
    var running: Bool
    var vpnState: String          // up | down
    var reason: String
    var vpnAppName: String
    var vpnBundleID: String
    var blocked: Bool
    var alwaysArmed: Bool
    var allowLAN: Bool
    var blockDNS: Bool
    var allowVPNReconnect: Bool
    var autostart: Bool
    var mode: String
    var tunnelInterface: String
    var tunnelAddress: String
    var defaultInterface: String
    var probeEnabled: Bool
    var probeTarget: String
    var endpoints: [String]
    var pid: Int32
    var daemonVersion: String
    var sessionStartedAt: Date?
    var sessionBytesIn: UInt64
    var sessionBytesOut: UInt64
    /// Interface counters at the session's start (or last counter reset),
    /// plus what was carried over a reset. With these the app computes
    /// live byte totals itself — the interface counters are readable
    /// without root — so the daemon need not rewrite this file every few
    /// seconds just to move a number.
    var sessionBaseIn: UInt64
    var sessionBaseOut: UInt64
    var sessionCarriedIn: UInt64
    var sessionCarriedOut: UInt64
    /// When the current block went up; nil while traffic flows.
    var blockedSince: Date?
    /// DNS is temporarily allowed so the VPN client can reconnect.
    var reconnectAssist: Bool
    /// The physical link is briefly open so a VPN client switching servers
    /// can reach one it has never used. See KillSwitch.updateReconnectWindow.
    var reconnectWindow: Bool
    /// The tunnel and VPN app last seen up. Kept after they go away, so a
    /// disconnect reads "Happ · utun7 (down)" rather than "not detected".
    var lastTunnelInterface: String
    var lastVPNAppName: String

    /// Equal apart from the fields that change on their own every few
    /// seconds without anything the app shows having changed.
    func sameContent(as other: DaemonStatus) -> Bool {
        var a = self, b = other
        a.updatedAt = b.updatedAt
        a.sessionBytesIn = b.sessionBytesIn
        a.sessionBytesOut = b.sessionBytesOut
        return a == b
    }

    static let path = "/usr/local/var/vpn_kill_switch/status.json"

    static func read() -> DaemonStatus? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DaemonStatus.self, from: data)
    }

    func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        let url = URL(fileURLWithPath: DaemonStatus.path)
        try? data.write(to: url, options: .atomic)
        // World-readable: the GUI runs as the logged-in user.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: DaemonStatus.path)
    }
}
