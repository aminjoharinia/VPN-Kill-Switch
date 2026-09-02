import SwiftUI

/// A live traffic-light pill. Colour is the primary signal; the text is
/// confirmation. Three states only — green means good, orange means
/// deliberately stopped, red means unprotected — so the meaning does not
/// have to be learned.
struct LivePill: View {
    let title: String
    let value: String
    let color: Color
    /// Not optional on purpose. When one pill omitted this line it grew a
    /// line shorter than its neighbours, so the VPN box visibly shrank
    /// whenever it had nothing to say.
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            HStack(spacing: 8) {
                // A plain filled dot.
                //
                // This used to sit under an animated halo — a second
                // circle scaled and faded on a repeatForever animation.
                // The pill is rebuilt every second by the status poll, so
                // that animation was re-attached to a fresh view identity
                // on each rebuild and restarted mid-phase: the halo
                // appeared to jump around and never faded cleanly. A
                // steady dot says the same thing and cannot desynchronise.
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)

                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            }

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .glassEffect(.regular.tint(color.opacity(0.12)), in: .rect(cornerRadius: 14))
        .animation(.smooth(duration: 0.3), value: color)
        .animation(.smooth(duration: 0.3), value: value)
    }
}

/// The three things worth knowing at a glance, side by side: is the
/// switch running, is the VPN up, is traffic moving.
struct LiveIndicatorRow: View {
    let power: PowerState
    let status: DaemonStatus?

    private var live: Bool { status?.isFresh == true }

    private var switchColor: Color {
        switch power {
        case .on:                   return .green
        case .starting, .stopping:  return .orange
        case .off:                  return .red
        }
    }

    private var vpnUp: Bool { live && status?.vpnState == "up" }
    private var vpnColor: Color { !live ? .secondary : (vpnUp ? .green : .red) }
    private var vpnValue: String { !live ? "Unknown" : (vpnUp ? "Connected" : "Down") }

    private var blocked: Bool { live && status?.blocked == true }
    private var trafficColor: Color {
        guard live else { return .secondary }
        return blocked ? .red : .green
    }
    private var trafficValue: String {
        guard live else { return "Unprotected" }
        return blocked ? "Blocked" : "Flowing"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LivePill(title: "Kill Switch",
                     value: power.label.capitalized,
                     color: switchColor,
                     detail: switchDetail)

            LivePill(title: "VPN",
                     value: vpnValue,
                     color: vpnColor,
                     detail: vpnDetail)

            LivePill(title: "Traffic",
                     value: trafficValue,
                     color: trafficColor,
                     detail: live ? (blocked ? "cut by kill switch" : "over the tunnel")
                                  : "kill switch is off")
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
        guard let status, status.isFresh else { return "no daemon" }
        let name = status.vpnAppName.cleanedVPNName
        let iface = status.tunnelInterface
        if name.isEmpty && iface.isEmpty { return "no tunnel" }
        if name.isEmpty { return iface }
        if iface.isEmpty { return name }
        return "\(name) · \(iface)"
    }
}
