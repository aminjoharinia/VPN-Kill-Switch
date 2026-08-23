import Foundation

struct Config: Codable {
    var mode: String = "ALL"                 // ALL | LIST
    var vpnInterface: String = ""            // "" = auto-track
    var probeEnabled: Bool = true
    var probeHost: String = "1.1.1.1"        // IP literal: no DNS needed
    var probePort: UInt16 = 80
    var probeHostHeader: String = "1.1.1.1"
    var probePath: String = "/"
    var probeTimeoutSeconds: Double = 3
    var probeIntervalSeconds: Double = 1
    var probeFailThreshold: Int = 1
    var requireDefaultRoute: Bool = true
    var allowLAN: Bool = true
    var blockDNS: Bool = true
    var allowVPNReconnect: Bool = true
    var alwaysArmed: Bool = false
    var autostart: Bool = false

    static let path = "/usr/local/var/vpn_kill_switch/config.json"

    /// Modification time, used to notice edits made while the daemon runs.
    static func modifiedAt() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func load() -> Config { loadIfValid() ?? Config() }

    /// nil when the file is absent or does not parse. The reload path uses
    /// this rather than `load()`, so catching the file mid-write keeps the
    /// current settings instead of silently resetting every one of them to
    /// defaults.
    static func loadIfValid() -> Config? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    func save() throws {
        let dir = (Config.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: Config.path))

        // root:admin 0664. Tuning settings is then a plain file write, so
        // the GUI does not have to raise an authorisation prompt for every
        // toggle. Starting/stopping the daemon and clearing a block still
        // require root, which is where the real authority lives — an admin
        // who can edit this file could equally just authenticate.
        try? FileManager.default.setAttributes(
            [.groupOwnerAccountID: 80, .posixPermissions: 0o664],
            ofItemAtPath: Config.path)
    }
}

enum Paths {
    static let stateDir = "/usr/local/var/vpn_kill_switch"
    static let libexecDir = "/usr/local/libexec/vpn_kill_switch"
    static let installedBinary = "/usr/local/libexec/vpn_kill_switch/vpnks"
    static let logFile = "/usr/local/var/vpn_kill_switch/kill_switch.log"
    static let endpointsFile = "/usr/local/var/vpn_kill_switch/vpn_endpoints"
    static let anchorFile = "/etc/pf.anchors/vpn_kill_switch"
    static let anchorName = "vpn_kill_switch"
    static let pfConf = "/etc/pf.conf"
    static let label = "com.user.vpnkillswitch.swift"
    static let bootPlist = "/Library/LaunchDaemons/com.user.vpnkillswitch.swift.plist"
    static let manualPlist = "/usr/local/var/vpn_kill_switch/com.user.vpnkillswitch.swift.plist"
}
