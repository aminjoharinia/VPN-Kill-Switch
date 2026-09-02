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
            guard let service = parse(String(line)) else { continue }
            if service.connected { return service }
            if fallback == nil, line.contains("(Connecting)") { fallback = service }
        }
        return fallback
    }

    /// Parses one `scutil --nc list` row.
    ///
    /// Two things make this less trivial than splitting on quotes:
    ///
    /// 1. scutil does not always emit the CLOSING quote. Outline, for
    ///    example, produces
    ///        ... (org.outline.macos.client) "%F0%9F... [VPN:org.outline.macos.client]
    ///    with no quote after the name, so a naive split ran the name to
    ///    the end of the line and swallowed the "[VPN:...]" marker.
    /// 2. Names may be percent-encoded — that same entry is really
    ///    "🧑🏼‍🚀 🔥 Astro 🇫🇮 فنلاند - SS 🔥".
    ///
    /// So the bundle id is located first and used as a hard right edge for
    /// the name, whether or not a closing quote shows up.
    static func parse(_ line: String) -> VPNService? {
        guard let vpnTag = line.range(of: "[VPN:"),
              let tagEnd = line.range(of: "]", range: vpnTag.upperBound..<line.endIndex)
        else { return nil }
        let bundle = String(line[vpnTag.upperBound..<tagEnd.lowerBound])

        var name = ""
        if let openQuote = line.range(of: "\"") {
            let rest = line[openQuote.upperBound...]
            // Whichever comes first: the closing quote, or the [VPN:] tag.
            var end = rest.endIndex
            if let closing = rest.range(of: "\"")?.lowerBound { end = closing }
            if let marker = rest.range(of: "[VPN:")?.lowerBound, marker < end { end = marker }
            name = String(rest[..<end])
        }

        name = name.trimmingCharacters(in: .whitespaces)
        name = name.removingPercentEncoding ?? name
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            name = bundle.components(separatedBy: ".").last ?? bundle
        }

        return VPNService(appName: name,
                          bundleID: bundle,
                          connected: line.contains("(Connected)"))
    }
}
