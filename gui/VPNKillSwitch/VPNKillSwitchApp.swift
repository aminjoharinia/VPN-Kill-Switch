import SwiftUI

@main
struct VPNKillSwitchApp: App {
    @State private var controller = Controller()
    @AppStorage("appearance") private var appearance = Appearance.auto

    var body: some Scene {
        WindowGroup {
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
            Image(systemName: controller.protection.symbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarPanel: View {
    @Environment(Controller.self) private var controller

    var body: some View {
        Text(controller.protection.title)

        if let status = controller.status, status.isFresh {
            Text("VPN \(status.vpnState) · \(status.tunnelInterface.isEmpty ? "no tunnel" : status.tunnelInterface)")
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
