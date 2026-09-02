import SwiftUI

struct DetailRow: View {
    let label: String
    let value: String
    var mono = false
    var warn = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "—" : value)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(warn ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(value)
        }
    }
}

/// Live tunnel facts. Every value here is measured, not assumed — the
/// default route in particular, because a tunnel interface that still
/// holds an address proves nothing about whether traffic flows.
struct TunnelSection: View {
    let status: DaemonStatus?

    var body: some View {
        Section("Tunnel") {
            if let status, status.isFresh {
                DetailRow(label: "VPN app",
                          value: status.vpnAppName.cleanedVPNName.isEmpty ? "not detected" : status.vpnAppName.cleanedVPNName)
                if !status.vpnBundleID.isEmpty {
                    DetailRow(label: "Bundle ID", value: status.vpnBundleID, mono: true)
                }
                DetailRow(label: "Interface",
                          value: status.tunnelInterface.isEmpty
                                 ? "none" : "\(status.tunnelInterface)  \(status.tunnelAddress)",
                          mono: true)
                DetailRow(label: "Default route",
                          value: status.defaultInterface,
                          mono: true,
                          warn: !status.defaultInterface.hasPrefix("utun")
                                && !status.defaultInterface.isEmpty)
                DetailRow(label: "Liveness probe",
                          value: status.probeEnabled ? status.probeTarget : "disabled",
                          mono: true)
                DetailRow(label: "Mode", value: status.mode)

                if let started = status.sessionStartedAt {
                    HStack {
                        Text("This session").foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 3) {
                            TrafficPair(down: status.sessionBytesIn,
                                        up: status.sessionBytesOut,
                                        compact: true)
                            Text(Format.duration(Date().timeIntervalSince(started)))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
            } else {
                Text("Waiting for the daemon…")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Addresses punched through the block so the VPN client can reconnect.
/// Shown because it is a deliberate hole in the firewall and the user
/// deserves to see exactly how wide it is.
struct EndpointsSection: View {
    let endpoints: [String]

    var body: some View {
        Section {
            if endpoints.isEmpty {
                Text("None learned yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(endpoints, id: \.self) { ip in
                    HStack {
                        Image(systemName: "arrow.up.forward.circle")
                            .foregroundStyle(.blue)
                        Text(ip).font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                }
            }
        } header: {
            Text("VPN server exceptions")
        } footer: {
            Text("Allowed through the block so your VPN can reconnect. Manage and pin them in the Exceptions tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
