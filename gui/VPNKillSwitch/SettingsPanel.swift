import SwiftUI

struct SettingsPanel: View {
    @Environment(Controller.self) private var controller

    private var status: DaemonStatus? { controller.status }
    private var live: Bool { controller.daemonRunning }

    private func toggle(_ key: String, _ current: Bool) -> Binding<Bool> {
        Binding(get: { current }, set: { controller.set(key, $0 ? "1" : "0") })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: toggle("alwaysArmed", status?.alwaysArmed ?? false)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Always armed")
                        Text(status?.alwaysArmed == true
                             ? "Traffic can leave only through the tunnel, right now and always."
                             : "Traffic is cut only after a drop is detected — under two seconds, never instant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(!live)
            } header: {
                Text("Protection")
            } footer: {
                Text("""
                     This is not a test — it changes how the firewall behaves from the moment you flip it.

                     Off: the firewall rule is loaded only once the tunnel is found to be dead. Detection takes about a second, and traffic can escape during it.

                     On: the rule stays loaded permanently and only the tunnel is ever allowed out, so there is nothing to detect and no gap. If the VPN will not connect, you will have no internet until you turn the kill switch off.
                     """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: toggle("allowLAN", status?.allowLAN ?? true)) {
                    Text("Allow local network while blocked")
                    Text("Printers, file shares and other machines at home stay reachable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: toggle("blockDNS", status?.blockDNS ?? true)) {
                    Text("Block DNS while blocked")
                    Text("Stops name lookups leaking to your router and on to your ISP.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: toggle("allowVPNReconnect", status?.allowVPNReconnect ?? true)) {
                    Text("Let the VPN reconnect")
                    Text("Keeps a hole open to your VPN server only. Turn off for a strict block — you would then have to clear it by hand.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("While traffic is blocked")
            } footer: {
                Text("These apply within a second — no password needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: toggle("autostart", status?.autostart ?? false)) {
                    Text("Start at login")
                    Text("Requires your password — it installs a system startup item.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!live)
            } header: {
                Text("Startup")
            }

            Section {
                Button("Clear Block Now", systemImage: "lock.open") { controller.unblockNow() }
                    .disabled(status?.blocked != true)
                Button("Remove Kill Switch…", systemImage: "trash", role: .destructive) {
                    controller.turnOff()
                }
                .disabled(!live)
            } header: {
                Text("Recovery")
            } footer: {
                Text("Removing stops the daemon, clears any block and unregisters the firewall rule. It never leaves traffic cut.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .overlay(alignment: .top) {
            if !live {
                Text("Turn the kill switch on to change these.")
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .capsule)
                    .padding(.top, 6)
            }
        }
    }
}
