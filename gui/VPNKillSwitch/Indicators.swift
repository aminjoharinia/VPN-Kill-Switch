import SwiftUI

/// A live traffic-light pill. Colour is the primary signal; the text is
/// confirmation. Three states only — green means good, orange means
/// deliberately stopped, red means unprotected — so the meaning does not
/// have to be learned.
struct LivePill: View {
    let title: String
    let value: String
    let color: Color
    var detail: String?
    var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.25))
                        .frame(width: 16, height: 16)
                        .scaleEffect(pulsing ? 1.35 : 1)
                        .opacity(pulsing ? 0 : 1)
                        .animation(pulsing
                                   ? .easeOut(duration: 1.2).repeatForever(autoreverses: false)
                                   : .default,
                                   value: pulsing)
                    Circle()
                        .fill(color)
                        .frame(width: 9, height: 9)
                        .shadow(color: color.opacity(0.7), radius: 4)
                }
                .frame(width: 16, height: 16)

                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            }

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(spacing: 12) {
            LivePill(title: "Kill Switch",
                     value: power.label.capitalized,
                     color: switchColor,
                     detail: power == .on ? "watching" : nil,
                     pulsing: power.busy)

            LivePill(title: "VPN",
                     value: vpnValue,
                     color: vpnColor,
                     detail: vpnDetail,
                     pulsing: live && vpnUp)

            LivePill(title: "Traffic",
                     value: trafficValue,
                     color: trafficColor,
                     detail: live ? (blocked ? "cut by kill switch" : "over the tunnel") : nil,
                     pulsing: live && !blocked)
        }
    }

    private var vpnDetail: String? {
        guard let status, status.isFresh else { return nil }
        if !status.vpnAppName.isEmpty {
            return status.tunnelInterface.isEmpty
                ? status.vpnAppName
                : "\(status.vpnAppName) · \(status.tunnelInterface)"
        }
        return status.tunnelInterface.isEmpty ? nil : status.tunnelInterface
    }
}
