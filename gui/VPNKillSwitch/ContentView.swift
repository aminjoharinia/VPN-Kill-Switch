import SwiftUI

struct ContentView: View {
    @Environment(Controller.self) private var controller
    @State private var selection: Panel = .overview

    enum Panel: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case settings = "Settings"
        case exceptions = "Exceptions"
        case history  = "History"
        case activity = "Activity"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .overview: return "shield.lefthalf.filled"
            case .settings: return "slider.horizontal.3"
            case .exceptions: return "pin"
            case .history:  return "clock.arrow.trianglehead.counterclockwise.rotate.90"
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
                case .exceptions: ExceptionsView()
                case .history:  HistoryView()
                case .activity: ActivityView()
                }
            }
            .navigationTitle(selection.rawValue)
            .toolbar {
                // macOS 26 gives every toolbar item its own glass capsule.
                // For the chip that produced a dark rounded slab sitting
                // behind the coloured pill — two nested boxes. Opting out
                // of the shared background leaves only the pill drawn by
                // PowerStateChip itself.
                ToolbarItem(placement: .primaryAction) { PowerStateChip() }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) { PowerButton() }
            }
        }
        .frame(minWidth: 780, minHeight: 560)
    }
}

/// The one control that matters, kept in the toolbar so it is reachable
/// from every panel.
/// The ON / OFF status chip in the toolbar.
///
/// Everything you would want to restyle is gathered in `Style` below —
/// change a number or a colour there and nothing else needs touching.
///
/// It is deliberately *not* given a glass background. The chip and the
/// button used to share one ToolbarItem, and the prominent button style
/// painted the entire group blue rather than just the control.
struct PowerStateChip: View {
    @Environment(Controller.self) private var controller

    /// --- Restyle the chip here -------------------------------------
    enum Style {
        static let dotSize: CGFloat        = 8      // coloured circle diameter
        static let gap: CGFloat            = 6      // circle-to-text spacing
        static let fontSize: CGFloat       = 11
        static let tracking: CGFloat       = 0.5    // letter spacing
        static let paddingH: CGFloat       = 10     // left/right padding
        static let paddingV: CGFloat       = 4      // top/bottom padding
        static let cornerRadius: CGFloat   = 7
        static let backgroundOpacity       = 0.14   // 0 = no pill behind it
        static let borderOpacity           = 0.30

        // The three state colours.
        static let on       = Color.green
        static let off      = Color.red
        static let changing = Color.orange
    }
    /// ---------------------------------------------------------------

    private var tint: Color {
        switch controller.powerState {
        case .on:                  return Style.on
        case .starting, .stopping: return Style.changing
        case .off:                 return Style.off
        }
    }

    var body: some View {
        HStack(spacing: Style.gap) {
            Circle()
                .fill(tint)
                .frame(width: Style.dotSize, height: Style.dotSize)
            Text(controller.powerState.label)
                .font(.system(size: Style.fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .tracking(Style.tracking)
        }
        .padding(.horizontal, Style.paddingH)
        .padding(.vertical, Style.paddingV)
        .background(
            RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                .fill(tint.opacity(Style.backgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                        .strokeBorder(tint.opacity(Style.borderOpacity), lineWidth: 1)
                )
        )
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

                if controller.daemonOutOfDate {
                    DaemonOutOfDateNotice()
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

/// The daemon and the app are versioned together by gui/build.sh. When
/// they disagree the daemon still runs, so nothing appears broken — it
/// just publishes an older status shape. Say so, and offer the one-click
/// fix, rather than leaving the user to guess.
struct DaemonOutOfDateNotice: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Daemon is out of date").fontWeight(.semibold)
                    Text("Running \(controller.daemonVersionText), this app is \(controller.appVersion). Some values may display incorrectly until it is updated.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Update") { controller.updateDaemon() }
                    .buttonStyle(.glassProminent)
                    .disabled(controller.busy)
            }
            .padding(6)
        }
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
