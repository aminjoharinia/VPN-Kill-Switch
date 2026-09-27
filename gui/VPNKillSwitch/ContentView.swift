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
            // Each page carries its own Daftar header (the Overview's is
            // the status card), so the toolbar title would only repeat it.
            .toolbar(removing: .title)
            .toolbar {
                // macOS 26 gives every toolbar item its own glass capsule.
                // For the chip that produced a dark rounded slab sitting
                // behind the coloured pill — two nested boxes. Opting out
                // of the shared background leaves only the pill drawn by
                // PowerStateChip itself.
                // With the title removed, nothing pushes the controls to
                // the trailing edge any more; this spacer does.
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .primaryAction) { PowerStateChip() }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) { PowerButton() }
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        // The amber accent for every control, not just the sidebar selection.
        .tint(Color("AccentColor"))
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
    /// A Daftar badge: tinted capsule, dot and label in the state's tone.
    enum Style {
        static let dotSize: CGFloat   = 7
        static let gap: CGFloat       = 6
        static let fontSize: CGFloat  = 11
        static let tracking: CGFloat  = 0.6
        static let paddingH: CGFloat  = 11
        static let paddingV: CGFloat  = 5
    }
    /// ---------------------------------------------------------------

    private var tint: Color { controller.powerState.color }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: Style.gap) {
            Circle()
                .fill(tint)
                .frame(width: Style.dotSize, height: Style.dotSize)
            // Sized to the widest label so the chip keeps one width as
            // it goes ON → STOPPING → OFF. When it resized, the toolbar
            // did not re-lay out in step and the chip slid under the button.
            WidestLabel(PowerState.allLabels, current: controller.powerState.label) {
                Text($0)
                    .font(.system(size: Style.fontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .tracking(Style.tracking)
            }
        }
        .padding(.horizontal, Style.paddingH)
        .padding(.vertical, Style.paddingV)
        .background(Capsule().fill(tint.tint(Daftar.chipAlpha, scheme)))
        .animation(.smooth(duration: 0.3), value: controller.powerState)
        .fixedSize()
    }
}

/// Lays out every candidate label invisibly and draws only the current
/// one, so the view is always as wide as its widest state.
struct WidestLabel<Content: View>: View {
    let labels: [String]
    let current: String
    let content: (String) -> Content

    init(_ labels: [String], current: String, @ViewBuilder content: @escaping (String) -> Content) {
        self.labels = labels
        self.current = current
        self.content = content
    }

    var body: some View {
        ZStack {
            ForEach(labels, id: \.self) { content($0).hidden() }
            content(current)
        }
    }
}

/// Always shows a word beside the icon, including the transient states, so
/// pressing it never looks like nothing happened while launchd starts up.
struct PowerButton: View {
    @Environment(Controller.self) private var controller

    private var state: PowerState { controller.powerState }

    private static func action(for state: PowerState) -> String {
        switch state {
        case .off:      return "Turn ON"
        case .on:       return "Turn OFF"
        case .starting: return "Starting\u{2026}"
        case .stopping: return "Stopping\u{2026}"
        }
    }
    private static let allActions = [PowerState.off, .on, .starting, .stopping].map(action(for:))

    /// The button says what pressing it will do: green to turn protection
    /// on, red to turn it off, orange while it is changing. Vivid fixed
    /// colours rather than the soft Daftar tones, because this is a solid
    /// glossy fill carrying white text, not a tint over the surface — and
    /// never the amber accent, which would say nothing about the action.
    private var fill: Color {
        switch state {
        case .off:                 return Color(red: 0.13, green: 0.62, blue: 0.29)  // #21A04A
        case .on:                  return Color(red: 0.84, green: 0.20, blue: 0.19)  // #D63330
        case .starting, .stopping: return Color(red: 0.90, green: 0.42, blue: 0.10)  // #E66B1A
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
                // Fixed width for the same reason as the chip.
                WidestLabel(Self.allActions, current: Self.action(for: state)) { Text($0) }
            }
        }
        .buttonStyle(.glassProminent)
        .tint(fill)
        .disabled(state.busy || (!controller.installed && state == .off))
        .animation(.smooth(duration: 0.3), value: state)
        .fixedSize()
    }
}

struct OverviewView: View {
    @Environment(Controller.self) private var controller

    /// Status only while the daemon is actually alive, so every section
    /// below judges "running" by the same signal as the toolbar.
    private var liveStatus: DaemonStatus? {
        controller.daemonRunning ? controller.status : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusCard(power: controller.powerState,
                           protection: controller.protection,
                           status: liveStatus)

                LiveIndicatorRow(power: controller.powerState, status: liveStatus)

                if !controller.installed {
                    DaftarHint(symbol: "exclamationmark.triangle.fill",
                               title: "Daemon not found",
                               message: "Build the CLI first, then press Turn On:",
                               code: "cd swift && swift build -c release")
                }

                if controller.daemonOutOfDate {
                    DaftarHint(symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                               title: "Daemon is out of date",
                               message: "Running \(controller.daemonVersionText), this app is \(controller.appVersion). Some values may display incorrectly until it is updated.") {
                        Button("Update") { controller.updateDaemon() }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.busy)
                    }
                }

                // While traffic is cut, the escape hatch must be visible. A
                // kill switch that strands you with no obvious way out is a
                // worse failure than one that reacts a second late.
                if controller.protection == .blocked, liveStatus?.verifying != true {
                    DaftarHint(symbol: "lifepreserver.fill",
                               title: "Stuck offline?",
                               message: "Turning the kill switch off restores traffic. From any terminal:",
                               code: "sudo /sbin/pfctl -a \(Paths.anchor) -F rules")
                }

                TunnelSection(status: liveStatus)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Daftar.page)
    }
}
