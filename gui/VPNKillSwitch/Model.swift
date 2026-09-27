import Foundation

/// Mirrors the JSON the root daemon publishes. The app is unprivileged;
/// reading this file is how it learns pf state without prompting for
/// authorisation just to draw a status dot.
struct DaemonStatus: Codable, Equatable {
    var updatedAt: Date
    var running: Bool
    var vpnState: String
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
    /// Counter baseline for live totals; see `liveTotals(current:)`.
    var sessionBaseIn: UInt64
    var sessionBaseOut: UInt64
    var sessionCarriedIn: UInt64
    var sessionCarriedOut: UInt64
    /// False for daemons older than the baseline fields.
    var hasCounterBase: Bool
    /// When the current block went up (nil while traffic flows, and from
    /// daemons that predate it).
    var blockedSince: Date?
    /// DNS temporarily allowed so the VPN client can reconnect.
    var reconnectAssist: Bool
    /// Last tunnel and VPN app seen up, kept after a disconnect.
    var lastTunnelInterface: String
    var lastVPNAppName: String

    /// The VPN app to show: the live one, else the one last seen.
    var displayVPNName: String {
        let live = vpnAppName.cleanedVPNName
        return live.isEmpty ? lastVPNAppName.cleanedVPNName : live
    }

    // There is deliberately no "is this file recent" check any more. The
    // daemon writes the file only when something changes — a steady state
    // can leave it untouched for hours — so its age says nothing. Whether
    // the daemon is alive is judged from its process (Controller.isAlive).

    /// Session totals from the interface's live counters, so the daemon
    /// need not rewrite this file every few seconds to move a number.
    func liveTotals(current: InterfaceStats.Counters?) -> (down: UInt64, up: UInt64) {
        guard hasCounterBase, let current else { return (sessionBytesIn, sessionBytesOut) }
        // A counter below its base means the interface was recreated and
        // restarted from zero since the daemon last published.
        let down = current.bytesIn >= sessionBaseIn ? current.bytesIn - sessionBaseIn : current.bytesIn
        let up = current.bytesOut >= sessionBaseOut ? current.bytesOut - sessionBaseOut : current.bytesOut
        return (sessionCarriedIn &+ down, sessionCarriedOut &+ up)
    }

    /// A tunnel exists but has not yet passed its first probe. Traffic is
    /// held, but this is the normal first second of every connection —
    /// not a failure — so it is worded as "checking", not "down".
    var verifying: Bool { vpnState != "up" && reason.hasPrefix("awaiting-first-probe") }

    /// Decoded field by field with defaults rather than by the synthesised
    /// all-or-nothing initialiser.
    ///
    /// With the synthesised one, a daemon built before any field existed
    /// wrote a status file the app could not decode at all — and the app
    /// reported "the daemon did not start" while the daemon was in fact
    /// running perfectly. A status feed should degrade, never blank out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt         = try c.decode(Date.self, forKey: .updatedAt)
        running           = try c.decodeIfPresent(Bool.self,   forKey: .running) ?? true
        vpnState          = try c.decodeIfPresent(String.self, forKey: .vpnState) ?? "down"
        reason            = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        vpnAppName        = try c.decodeIfPresent(String.self, forKey: .vpnAppName) ?? ""
        vpnBundleID       = try c.decodeIfPresent(String.self, forKey: .vpnBundleID) ?? ""
        blocked           = try c.decodeIfPresent(Bool.self,   forKey: .blocked) ?? false
        alwaysArmed       = try c.decodeIfPresent(Bool.self,   forKey: .alwaysArmed) ?? false
        allowLAN          = try c.decodeIfPresent(Bool.self,   forKey: .allowLAN) ?? true
        blockDNS          = try c.decodeIfPresent(Bool.self,   forKey: .blockDNS) ?? true
        allowVPNReconnect = try c.decodeIfPresent(Bool.self,   forKey: .allowVPNReconnect) ?? true
        autostart         = try c.decodeIfPresent(Bool.self,   forKey: .autostart) ?? false
        mode              = try c.decodeIfPresent(String.self, forKey: .mode) ?? "ALL"
        tunnelInterface   = try c.decodeIfPresent(String.self, forKey: .tunnelInterface) ?? ""
        tunnelAddress     = try c.decodeIfPresent(String.self, forKey: .tunnelAddress) ?? ""
        defaultInterface  = try c.decodeIfPresent(String.self, forKey: .defaultInterface) ?? ""
        probeEnabled      = try c.decodeIfPresent(Bool.self,   forKey: .probeEnabled) ?? true
        probeTarget       = try c.decodeIfPresent(String.self, forKey: .probeTarget) ?? ""
        endpoints         = try c.decodeIfPresent([String].self, forKey: .endpoints) ?? []
        pid               = try c.decodeIfPresent(Int32.self,  forKey: .pid) ?? 0
        daemonVersion     = try c.decodeIfPresent(String.self, forKey: .daemonVersion) ?? ""
        sessionStartedAt  = try c.decodeIfPresent(Date.self,   forKey: .sessionStartedAt)
        sessionBytesIn    = try c.decodeIfPresent(UInt64.self, forKey: .sessionBytesIn) ?? 0
        sessionBytesOut   = try c.decodeIfPresent(UInt64.self, forKey: .sessionBytesOut) ?? 0
        let baseIn        = try c.decodeIfPresent(UInt64.self, forKey: .sessionBaseIn)
        sessionBaseIn     = baseIn ?? 0
        sessionBaseOut    = try c.decodeIfPresent(UInt64.self, forKey: .sessionBaseOut) ?? 0
        sessionCarriedIn  = try c.decodeIfPresent(UInt64.self, forKey: .sessionCarriedIn) ?? 0
        sessionCarriedOut = try c.decodeIfPresent(UInt64.self, forKey: .sessionCarriedOut) ?? 0
        hasCounterBase    = baseIn != nil
        blockedSince      = try c.decodeIfPresent(Date.self,   forKey: .blockedSince)
        reconnectAssist   = try c.decodeIfPresent(Bool.self,   forKey: .reconnectAssist) ?? false
        lastTunnelInterface = try c.decodeIfPresent(String.self, forKey: .lastTunnelInterface) ?? ""
        lastVPNAppName    = try c.decodeIfPresent(String.self, forKey: .lastVPNAppName) ?? ""
    }
}

/// The daemon's own lifecycle, distinct from whether the VPN is up.
/// Turning it on installs a launchd job and waits for the first status
/// publish, so there is a real interval to show rather than a button that
/// appears to do nothing.
enum PowerState {
    case off, starting, on, stopping

    var label: String {
        switch self {
        case .off:      return "OFF"
        case .starting: return "STARTING"
        case .on:       return "ON"
        case .stopping: return "STOPPING"
        }
    }

    var symbol: String {
        switch self {
        case .off:      return "power"
        case .starting: return "power.dotted"
        case .on:       return "power.circle.fill"
        case .stopping: return "power.dotted"
        }
    }

    var busy: Bool { self == .starting || self == .stopping }

    static let allLabels = [PowerState.off, .starting, .on, .stopping].map(\.label)
}

enum Protection {
    case off             // daemon not running — no protection at all
    case protected       // VPN healthy, traffic flowing through the tunnel
    case blocked         // tunnel down, traffic cut
    case armed           // always-armed: block permanently loaded

    var title: String {
        switch self {
        case .off:       return "Not Protected"
        case .protected: return "Protected"
        case .blocked:   return "Traffic Blocked"
        case .armed:     return "Always Armed"
        }
    }

    var symbol: String {
        switch self {
        case .off:       return "shield.slash"
        case .protected: return "checkmark.shield.fill"
        case .blocked:   return "hand.raised.fill"
        case .armed:     return "lock.shield.fill"
        }
    }
}

extension String {
    /// Tidies a VPN service name coming from `scutil --nc list`.
    ///
    /// Applied at the display layer as well as in the daemon, so a daemon
    /// older than this app still shows a readable name instead of a wall
    /// of percent escapes.
    var cleanedVPNName: String {
        var text = self
        if let marker = text.range(of: "[VPN:") { text = String(text[..<marker.lowerBound]) }
        text = text.trimmingCharacters(in: .whitespaces)
        text = text.removingPercentEncoding ?? text
        return text.trimmingCharacters(in: .whitespaces)
    }
}

enum Paths {
    static let cli = "/usr/local/libexec/vpn_kill_switch/vpnks"
    static let status = "/usr/local/var/vpn_kill_switch/status.json"
    static let log = "/usr/local/var/vpn_kill_switch/kill_switch.log"
    static let sessions = "/usr/local/var/vpn_kill_switch/sessions.json"
    static let anchor = "vpn_kill_switch"

    /// Prefer the installed daemon; fall back to a copy shipped inside
    /// the app so a fresh download can install itself.
    /// Prefer the copy shipped inside this app, NOT the one already
    /// installed.
    ///
    /// The other order looks harmless and is not: the app would invoke the
    /// stale installed binary, whose installer then sees source ==
    /// destination, skips the copy, and reinstalls the old version. The
    /// daemon could never be upgraded, and an app expecting newer status
    /// fields would sit there reporting that the daemon failed to start.
    static var resolvedCLI: String? {
        if let bundled = Bundle.main.url(forResource: "vpnks", withExtension: nil)?.path,
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        if FileManager.default.isExecutableFile(atPath: cli) { return cli }
        return nil
    }
}
