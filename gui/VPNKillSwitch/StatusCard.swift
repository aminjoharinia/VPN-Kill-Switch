import SwiftUI

/// Hero card, in Daftar's card style: a gradient tint of the state's tone
/// with a border in it, so state is legible from across the room without
/// reading a word.
struct StatusCard: View {
    let power: PowerState
    let protection: Protection
    let status: DaemonStatus?

    // While turning on or off the card follows the toolbar chip, rather
    // than showing the previous state's colour for several seconds.
    private var tint: Color { power.busy ? power.color : protection.color }

    private var title: String {
        switch power {
        case .starting: return "Starting\u{2026}"
        case .stopping: return "Stopping\u{2026}"
        default:
            if protection == .blocked, status?.verifying == true { return "Verifying Tunnel" }
            return protection.title
        }
    }

    private var symbol: String {
        power.busy ? "shield.lefthalf.filled" : protection.symbol
    }

    private var subtitle: String {
        switch power {
        case .starting: return "Waiting for the kill switch to report in."
        case .stopping: return "Removing the firewall rules and stopping the daemon."
        default: break
        }
        guard let status, status.isFresh else {
            return "The kill switch is not running. Traffic is unprotected."
        }
        switch protection {
        case .blocked where status.verifying:
            return "Tunnel found. Holding traffic until a test request confirms it works."
        case .blocked:
            return "The tunnel stopped carrying traffic. Everything except your LAN is cut."
        case .armed:
            return status.vpnState == "up"
                ? "Traffic leaves only through the tunnel. No detection delay."
                : "Tunnel is down. Traffic stays cut until it returns."
        case .protected:
            return "Tunnel is carrying traffic. Traffic will be cut the moment it stops."
        case .off:
            return "The kill switch is not running."
        }
    }

    /// The card's one headline figure: how long the tunnel has been up,
    /// or the switch's own state when there is no session to time.
    @ViewBuilder private var headline: some View {
        if !power.busy, let status, status.isFresh,
           let started = status.sessionStartedAt, status.vpnState == "up" {
            DaftarPill(label: "Connected for",
                       value: Format.duration(Date().timeIntervalSince(started)),
                       tone: tint)
        } else if !power.busy {
            DaftarPill(label: "Kill switch", value: power.label, tone: power.color)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            DaftarIconTile(symbol: symbol, tone: tint, size: 56, radius: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .contentTransition(.numericText())

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Only worth showing when something is wrong. While
                // protected it just repeats the facts under Tunnel below.
                if let status, status.isFresh, protection == .blocked, !power.busy {
                    DaftarBadge(label: status.reason, symbol: "info.circle", tone: tint)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            headline
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .daftarCard(tint)
        .animation(.smooth(duration: 0.35), value: protection)
        .animation(.smooth(duration: 0.35), value: power)
    }
}
