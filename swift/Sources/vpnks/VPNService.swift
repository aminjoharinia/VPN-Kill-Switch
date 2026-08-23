import Foundation

/// Which VPN app owns the tunnel.
///
/// `scutil --nc list` names the service directly — for a NetworkExtension
/// app the tunnel runs in a plug-in ("Tunnel.appex"), so scanning the
/// process table for the app's own name finds nothing useful.
struct VPNService {
    var appName: String      // "Happ"
    var bundleID: String     // "su.ffg.happ"
    var connected: Bool

    static func current() -> VPNService? {
        let output = Shell.run("/usr/sbin/scutil", ["--nc", "list"]).output
        var fallback: VPNService?

        for line in output.split(separator: "\n") {
            let text = String(line)
            guard text.contains("[VPN:") else { continue }

            // ... VPN (su.ffg.happ) "Happ"  [VPN:su.ffg.happ]
            let name = text.split(separator: "\"").dropFirst().first.map(String.init) ?? ""
            var bundle = ""
            if let open = text.range(of: "[VPN:"),
               let close = text.range(of: "]", range: open.upperBound..<text.endIndex) {
                bundle = String(text[open.upperBound..<close.lowerBound])
            }
            guard !name.isEmpty else { continue }

            if text.contains("(Connected)") {
                return VPNService(appName: name, bundleID: bundle, connected: true)
            }
            if fallback == nil, text.contains("(Connecting)") {
                fallback = VPNService(appName: name, bundleID: bundle, connected: false)
            }
        }
        return fallback
    }
}
