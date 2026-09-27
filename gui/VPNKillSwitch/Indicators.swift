import SwiftUI

/// The one colour vocabulary for every indicator in the app — toolbar
/// chip, stat tiles, status card and menu bar. Each view used to pick its
/// own, so the same moment showed a red dot beside an orange card beside a
/// grey word. Change a tone here and it changes everywhere.
///
///  - good:    protected, traffic over the tunnel
///  - caution: in transition, or traffic deliberately held by the switch
///  - danger:  unprotected — the kill switch is not running
///  - armed:   always-armed mode
enum StateColor {
    static let good    = Daftar.good
    static let caution = Daftar.warning
    static let danger  = Daftar.danger
    static let armed   = Daftar.armed
    static let unknown = Daftar.muted
}

extension PowerState {
    var tone: DaftarTone {
        switch self {
        case .on:                  return StateColor.good
        case .starting, .stopping: return StateColor.caution
        case .off:                 return StateColor.danger
        }
    }
    var color: Color { tone.color }
}

extension Protection {
    var tone: DaftarTone {
        switch self {
        case .off:       return StateColor.danger
        case .protected: return StateColor.good
        case .blocked:   return StateColor.caution
        case .armed:     return StateColor.armed
        }
    }
    var color: Color { tone.color }
}

/// The things worth knowing at a glance, side by side: is the switch
/// running, is the VPN up, is traffic moving, and how much has moved.
struct LiveIndicatorRow: View {
    let power: PowerState
    let status: DaemonStatus?
    /// Live session totals from the Controller; nil with no session.
    var bytes: Controller.LiveBytes? = nil

    private var live: Bool { status != nil }

    // While starting or stopping, whatever status is on disk belongs to
    // the daemon being replaced — show the transition, not its verdict.
    private var changing: Bool { power.busy }

    private var vpnUp: Bool { live && status?.vpnState == "up" }
    private var verifying: Bool { live && status?.verifying == true }
    private var blocked: Bool { live && status?.blocked == true }

    // A tunnel that is down while the switch runs means traffic is held —
    // the same "caution" the card and the Traffic tile show.
    private var vpnTone: DaftarTone {
        changing ? StateColor.caution
            : !live ? StateColor.unknown
            : vpnUp ? StateColor.good : StateColor.caution
    }
    private var vpnValue: String {
        changing ? "Waiting"
            : !live ? "Unknown"
            : vpnUp ? "Connected" : (verifying ? "Checking" : "Down")
    }

    private var trafficTone: DaftarTone {
        if changing { return StateColor.caution }
        guard live else { return StateColor.danger }
        return blocked ? StateColor.caution : StateColor.good
    }
    private var trafficValue: String {
        if changing { return "Waiting" }
        guard live else { return "Unprotected" }
        if blocked { return verifying ? "Held" : "Blocked" }
        return "Flowing"
    }
    private var trafficDetail: String {
        if changing { return "for the kill switch" }
        guard live else { return "kill switch is off" }
        if blocked { return verifying ? "until the tunnel is verified" : "cut by the kill switch" }
        return "over the tunnel"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DaftarStat(label: "Kill switch",
                       value: power.label.capitalized,
                       symbol: "power",
                       tone: power.color,
                       detail: switchDetail)

            DaftarStat(label: "VPN",
                       value: vpnValue,
                       symbol: "network",
                       tone: vpnTone.color,
                       detail: vpnDetail)

            DaftarStat(label: "Traffic",
                       value: trafficValue,
                       symbol: blocked ? "hand.raised.fill" : "arrow.up.arrow.down",
                       tone: trafficTone.color,
                       detail: trafficDetail)

            DaftarStat(label: "This session",
                       value: sessionValue,
                       symbol: "arrow.down.circle",
                       tone: Daftar.armed.color,
                       detail: sessionDetail)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var switchDetail: String {
        switch power {
        case .on:       return "watching"
        case .off:      return "not running"
        case .starting: return "starting up"
        case .stopping: return "shutting down"
        }
    }

    private var vpnDetail: String {
        guard let status, live else { return "no daemon" }
        let name = status.vpnAppName.cleanedVPNName
        let iface = status.tunnelInterface
        if iface.isEmpty, !status.lastTunnelInterface.isEmpty {
            let last = status.displayVPNName
            return last.isEmpty ? "\(status.lastTunnelInterface) down"
                                : "\(last) · \(status.lastTunnelInterface) down"
        }
        if name.isEmpty && iface.isEmpty { return "no tunnel" }
        if name.isEmpty { return iface }
        if iface.isEmpty { return name }
        return "\(name) · \(iface)"
    }

    private var session: (down: UInt64, up: UInt64, started: Date)? {
        guard live, let status, let started = status.sessionStartedAt else { return nil }
        let totals = bytes ?? Controller.LiveBytes(down: status.sessionBytesIn, up: status.sessionBytesOut)
        return (totals.down, totals.up, started)
    }

    private var sessionValue: String {
        guard let session else { return "—" }
        return Format.bytes(session.down)
    }

    private var sessionDetail: String {
        guard let session else { return "no active session" }
        // Upload only: the status card's "Connected for" pill already
        // shows how long the session has run.
        return "↑ \(Format.bytes(session.up)) uploaded"
    }
}
