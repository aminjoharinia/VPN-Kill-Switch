import SwiftUI

/// Keeps the process alive when the window is closed, so the menu bar
/// item — and the status it reports — survives. Without this the app
/// quits with its last window and the menu bar entry vanishes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct VPNKillSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = Controller()
    @AppStorage("appearance") private var appearance = Appearance.auto
    @AppStorage(MenuBarIcon.stripesKey) private var menuBarStripes = true

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(controller)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear { controller.start() }
                .alert("Something went wrong",
                       isPresented: Binding(
                           get: { controller.lastError != nil },
                           set: { if !$0 { controller.lastError = nil } })) {
                    Button("OK", role: .cancel) { controller.lastError = nil }
                } message: {
                    Text(controller.lastError ?? "")
                }
        }
        .windowToolbarStyle(.unified)
        .commands { CommandGroup(replacing: .newItem) { } }

        // Glanceable state without keeping the window open — the thing
        // you actually want from a kill switch day to day.
        MenuBarExtra {
            MenuBarPanel().environment(controller)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: controller.powerState,
                                             protection: controller.protection,
                                             striped: menuBarStripes))
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarPanel: View {
    @Environment(Controller.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.protection.title)

        if controller.daemonRunning, let status = controller.status {
            let app = status.vpnAppName.cleanedVPNName.isEmpty ? "VPN" : status.vpnAppName.cleanedVPNName
            let iface = status.tunnelInterface.isEmpty ? "no tunnel" : status.tunnelInterface
            Text("\(app) \(status.vpnState) · \(iface)")
            Text(status.blocked ? "Traffic blocked" : "Traffic flowing")
        }

        Divider()

        Button("Open VPN Kill Switch") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Divider()

        if controller.daemonRunning {
            Button("Turn Off Kill Switch") { controller.turnOff() }
            if controller.status?.blocked == true {
                Button("Clear Block Now") { controller.unblockNow() }
            }
        } else {
            Button("Turn On Kill Switch") { controller.turnOn() }
                .disabled(!controller.installed)
        }

        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
