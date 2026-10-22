import SwiftUI

struct SettingsPanel: View {
    @Environment(Controller.self) private var controller
    @AppStorage(MenuBarIcon.stripesKey) private var menuBarStripes = true

    private var status: DaemonStatus? { controller.status }
    private var live: Bool { controller.daemonRunning }
    private var armed: Bool { controller.setting("alwaysArmed", reported: status?.alwaysArmed == true) }

    private func toggle(_ key: String, _ current: Bool) -> Binding<Bool> {
        Binding(get: { controller.setting(key, reported: current) }, set: { controller.set(key, $0 ? "1" : "0") })
    }

    var body: some View {
        DaftarPage {
            DaftarHeader(symbol: "slider.horizontal.3",
                         title: "Settings",
                         subtitle: "How the kill switch behaves, and what it lets through") {
                DaftarPill(label: "Protection",
                           value: !live ? "Off" : (armed ? "Armed" : "On drop"),
                           tone: !live ? Daftar.danger.color
                                 : (armed ? Daftar.armed.color : Daftar.good.color))
            }
        } content: {
            if !live {
                DaftarHint(symbol: "power",
                           title: "The kill switch is off",
                           message: "Turn it on to change these settings.")
            }

            DaftarTable(title: "Protection",
                        footer: armed
                            ? "On: the rule stays loaded permanently and only the tunnel is ever allowed out, so there is nothing to detect and no gap. If the VPN will not connect, you will have no internet until you turn the kill switch off."
                            : "Off: the firewall rule is loaded only once the tunnel is found to be dead. Detection takes about a second, and traffic can escape during it.") {
                SettingRow(title: "Always armed",
                           detail: armed
                               ? "Traffic can leave only through the tunnel, right now and always."
                               : "Traffic is cut only after a drop is detected — under two seconds, never instant.",
                           symbol: "lock.shield",
                           tone: Daftar.armed.color,
                           isOn: toggle("alwaysArmed", armed))
                    .disabled(!live)
            }

            DaftarTable(title: "While traffic is blocked",
                        footer: "These apply within a second — no password needed.") {
                SettingRow(title: "Allow local network",
                           detail: "Printers, file shares and other machines at home stay reachable.",
                           symbol: "house",
                           isOn: toggle("allowLAN", status?.allowLAN ?? true))
                SettingRow(title: "Block DNS",
                           detail: "Stops name lookups leaking to your router and on to your ISP. If a VPN tunnel is up but not connecting for 6 seconds, DNS is allowed briefly so the VPN can look up its server.",
                           symbol: "text.magnifyingglass",
                           isOn: toggle("blockDNS", status?.blockDNS ?? true))
                SettingRow(title: "Let the VPN reconnect",
                           detail: "Keeps a hole open to your VPN server only. Turn off for a strict block — you would then have to clear it by hand.",
                           symbol: "arrow.triangle.2.circlepath",
                           isOn: toggle("allowVPNReconnect", status?.allowVPNReconnect ?? true))
            }
            .disabled(!live)

            DaftarTable(title: "Startup") {
                SettingRow(title: "Start at login",
                           detail: "Requires your password — it installs a system startup item.",
                           symbol: "sunrise",
                           isOn: toggle("autostart", status?.autostart ?? false))
                    .disabled(!live)
            }

            // A display preference kept by this app, not the daemon, so it
            // works — and is not greyed out — while the switch is off.
            DaftarTable(title: "Menu bar") {
                HStack(spacing: 12) {
                    HazardStripes(band: 4, gap: 4.5)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hazard-stripe background")
                            .font(.system(size: 13, weight: .medium))
                        Text("Shows the state on an amber-and-black pill, like the app icon, so it stands out in a busy menu bar.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("Hazard-stripe background", isOn: $menuBarStripes)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }

            DaftarTable(title: "Recovery",
                        footer: "Removing stops the daemon, clears any block and unregisters the firewall rule. It never leaves traffic cut.") {
                ActionRow(title: "Clear block now",
                          detail: "Restores traffic immediately; the switch keeps watching.",
                          symbol: "lock.open",
                          tone: Daftar.warning.color,
                          button: "Clear") { controller.unblockNow() }
                    .disabled(status?.blocked != true)
                ActionRow(title: "Remove kill switch",
                          detail: "Stops the daemon and removes its firewall rule.",
                          symbol: "trash",
                          tone: Daftar.danger.color,
                          button: "Remove…",
                          role: .destructive) { controller.turnOff() }
                    .disabled(!live)
            }
        }
    }
}

/// Icon chip, title and muted explanation, with a switch on the right.
struct SettingRow: View {
    let title: String
    let detail: String
    let symbol: String
    var tone = Daftar.accent.color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            DaftarIconTile(symbol: symbol, tone: tone, size: 28, radius: 8,
                           alpha: Daftar.chipAlpha)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// Same shape as SettingRow, with a button instead of a switch.
struct ActionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let tone: Color
    let button: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            DaftarIconTile(symbol: symbol, tone: tone, size: 28, radius: 8,
                           alpha: Daftar.chipAlpha)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(button, role: role, action: action)
                .controlSize(.small)
        }
    }
}
