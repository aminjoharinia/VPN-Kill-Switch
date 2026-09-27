import SwiftUI

/// Live tunnel facts. Every value here is measured, not assumed — the
/// default route in particular, because a tunnel interface that still
/// holds an address proves nothing about whether traffic flows.
struct TunnelSection: View {
    let status: DaemonStatus?

    var body: some View {
        DaftarTable(title: "Tunnel") {
            if let status, status.isFresh {
                DaftarDetail(label: "VPN app",
                             value: status.vpnAppName.cleanedVPNName.isEmpty
                                    ? "not detected" : status.vpnAppName.cleanedVPNName)
                if !status.vpnBundleID.isEmpty {
                    DaftarDetail(label: "Bundle ID", value: status.vpnBundleID, mono: true)
                }
                DaftarDetail(label: "Interface",
                             value: status.tunnelInterface.isEmpty
                                    ? "none" : "\(status.tunnelInterface)  \(status.tunnelAddress)",
                             mono: true)
                // Leaving the tunnel is the one fact here that means
                // traffic is escaping, so it is the one that gets a colour.
                DaftarDetail(label: "Default route",
                             value: status.defaultInterface,
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
