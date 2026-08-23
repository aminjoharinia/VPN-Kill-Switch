import SwiftUI

struct ContentView: View {
    @Environment(Controller.self) private var controller
    @State private var selection: Panel = .overview

    enum Panel: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case settings = "Settings"
        case activity = "Activity"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .overview: return "shield.lefthalf.filled"
            case .settings: return "slider.horizontal.3"
            case .activity: return "list.bullet.rectangle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Panel.allCases, selection: $selection) { panel in
                Label(panel.rawValue, systemImage: panel.symbol)
                    .tag(panel)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 260)
            .safeAreaInset(edge: .bottom) { AppearancePicker() }
        } detail: {
            Group {
                switch selection {
                case .overview: OverviewView()
                case .settings: SettingsPanel()
                case .activity: ActivityView()
                }
            }
            .navigationTitle(selection.rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { PowerStateChip() }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) { PowerButton() }
            }
        }
        .frame(minWidth: 780, minHeight: 560)
    }
}

/// The one control that matters, kept in the toolbar so it is reachable
/// from every panel.
/// The state chip. Plain — no glass, no tint — so the only tinted surface
/// in the toolbar is the button itself. Previously the chip and the button
/// sat in one HStack inside a single ToolbarItem, and the prominent style
/// painted the whole group blue rather than just the control.
struct PowerStateChip: View {
    @Environment(Controller.self) private var controller

    private var tint: Color {
        switch controller.powerState {
        case .on:                  return .green
        case .starting, .stopping: return .orange
        case .off:                 return .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(controller.powerState.label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .tracking(0.5)
        }
        .animation(.smooth(duration: 0.3), value: controller.powerState)
    }
}

/// Always shows a word beside the icon, including the transient states, so
/// pressing it never looks like nothing happened while launchd starts up.
struct PowerButton: View {
    @Environment(Controller.self) private var controller

    private var state: PowerState { controller.powerState }

    private var action: String {
        switch state {
        case .off:      return "Turn On"
        case .on:       return "Turn Off"
        case .starting: return "Starting\u{2026}"
        case .stopping: return "Stopping\u{2026}"
        }
    }

    var body: some View {
        Button {
            state == .on ? controller.turnOff() : controller.turnOn()
        } label: {
            HStack(spacing: 6) {
                if state.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state.symbol)
                }
                Text(action)
            }
        }
        .buttonStyle(state == .on ? AnyButtonStyle(.glass) : AnyButtonStyle(.glassProminent))
        .disabled(state.busy || (!controller.installed && state == .off))
        .animation(.smooth(duration: 0.3), value: state)
    }
}

/// Lets the two glass button styles share one call site.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: GlassButtonStyle) {
        make = { AnyView(Button($0).buttonStyle(style)) }
    }
    init(_ style: GlassProminentButtonStyle) {
        make = { AnyView(Button($0).buttonStyle(style)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct OverviewView: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                LiveIndicatorRow(power: controller.powerState, status: controller.status)

                StatusCard(protection: controller.protection, status: controller.status)

                if !controller.installed {
                    NotInstalledNotice()
                }

                if controller.protection == .blocked {
                    EmergencyNotice()
                }

                Form {
                    TunnelSection(status: controller.status)
                    EndpointsSection(endpoints: controller.status?.endpoints ?? [])
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(minHeight: 320)
            }
            .padding(20)
        }
        .background(.background.secondary)
    }
}

struct NotInstalledNotice: View {
    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Daemon not found").fontWeight(.semibold)
                    Text("Build the CLI first, then press Turn On:")
                        .foregroundStyle(.secondary)
                    Text("cd swift && swift build -c release")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(6)
        }
    }
}

/// While traffic is cut, the escape hatch must be visible. A kill switch
/// that strands you with no obvious way out is a worse failure than one
/// that reacts a second late.
struct EmergencyNotice: View {
    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lifepreserver.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stuck offline?").fontWeight(.semibold)
                    Text("Turning the kill switch off restores traffic. From any terminal:")
                        .foregroundStyle(.secondary)
                    Text("sudo /sbin/pfctl -a \(Paths.anchor) -F rules")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(6)
        }
    }
}
