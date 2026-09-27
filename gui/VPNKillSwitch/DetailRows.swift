import SwiftUI

/// Live tunnel facts. Every value here is measured, not assumed — the
/// default route in particular, because a tunnel interface that still
/// holds an address proves nothing about whether traffic flows.
struct TunnelSection: View {
    let status: DaemonStatus?

    var body: some View {
        DaftarTable(title: "Tunnel") {
            if let status {
                // After a disconnect, name what was there and say it is
                // down, rather than "not detected" / "none" — which read as
                // if the switch had lost track of the VPN altogether.
                let tunnelGone = status.tunnelInterface.isEmpty && !status.lastTunnelInterface.isEmpty
                DaftarDetail(label: "VPN app",
                             value: vpnAppText(status),
                             tone: status.vpnAppName.isEmpty && !status.lastVPNAppName.isEmpty
                                   ? Daftar.warning.color : nil)
                if !status.vpnBundleID.isEmpty {
                    DaftarDetail(label: "Bundle ID", value: status.vpnBundleID, mono: true)
                }
                DaftarDetail(label: "Interface",
                             value: !status.tunnelInterface.isEmpty
                                    ? "\(status.tunnelInterface)  \(status.tunnelAddress)"
                                    : tunnelGone ? "\(status.lastTunnelInterface) · down" : "none",
                             mono: true,
                             tone: tunnelGone ? Daftar.warning.color : nil)
                // Leaving the tunnel is the one fact here that means
                // traffic is escaping, so it is the one that gets a colour.
                DaftarDetail(label: "Default route",
                             value: tunnelGone && !status.defaultInterface.isEmpty
                                    ? "\(status.lastTunnelInterface) → \(status.defaultInterface)"
                                    : status.defaultInterface,
                             mono: true,
                             tone: !status.defaultInterface.hasPrefix("utun")
                                   && !status.defaultInterface.isEmpty
                                   ? Daftar.warning.color : nil)
                DaftarDetail(label: "Liveness probe",
                             value: status.probeEnabled ? status.probeTarget : "disabled",
                             mono: true)
                DaftarDetail(label: "Mode", value: status.mode)
            } else {
                Text("Waiting for the daemon…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private func vpnAppText(_ status: DaemonStatus) -> String {
    let live = status.vpnAppName.cleanedVPNName
    if !live.isEmpty { return live }
    let last = status.lastVPNAppName.cleanedVPNName
    return last.isEmpty ? "not detected" : "\(last) · disconnected"
}
