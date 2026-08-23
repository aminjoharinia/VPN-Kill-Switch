import SwiftUI

/// Hero card. macOS 26 Liquid Glass: the card floats on a tinted glass
/// surface whose colour carries the meaning, so state is legible from
/// across the room without reading a word.
struct StatusCard: View {
    let protection: Protection
    let status: DaemonStatus?

    private var tint: Color {
        switch protection {
        case .off:       return .secondary
        case .protected: return .green
        case .blocked:   return .orange
        case .armed:     return .blue
        }
    }

    private var subtitle: String {
        guard let status, status.isFresh else {
            return "The kill switch is not running. Traffic is unprotected."
        }
        switch protection {
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

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: protection.symbol)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 56)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 6) {
                Text(protection.title)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Only worth showing when something is wrong. While
                // protected it just repeats the interface and route already
                // listed under Tunnel below.
                if let status, status.isFresh, protection == .blocked {
                    Text(status.reason)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(tint.opacity(0.16)), in: .rect(cornerRadius: 22))
        .animation(.smooth(duration: 0.35), value: protection)
    }
}
