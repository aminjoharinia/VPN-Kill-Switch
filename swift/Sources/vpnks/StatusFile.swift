import Foundation

/// Snapshot the daemon publishes for any UI to read.
///
/// The GUI is unprivileged, but almost everything interesting here
/// (whether pf is actually enforcing, what the last event was) requires
/// root to determine. Rather than make the app ask for authorisation
/// just to display a status dot, the daemon — which is already root —
/// writes this file world-readable on every state change.
struct DaemonStatus: Codable {
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
