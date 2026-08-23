import Foundation

func requireRoot(_ action: String) {
    guard getuid() == 0 else {
        FileHandle.standardError.write(Data("vpnks: '\(action)' needs root. Re-run with sudo.\n".utf8))
        exit(1)
    }
}

func usage() -> Never {
    print("""
    vpnks — VPN kill switch daemon (macOS)

      vpnks daemon              run the watcher in the foreground (root)
      vpnks status              show current state
      vpnks unblock             clear the block immediately (root)
      vpnks install [--autostart|--no-autostart]
                                install to \(Paths.libexecDir) and start (root)
      vpnks uninstall           stop, unblock, remove launchd + pf anchor (root)
      vpnks set <key> <value>   change a setting (root)
      vpnks config              print current configuration

    Emergency unblock without this tool:
      sudo /sbin/pfctl -a \(Paths.anchorName) -F rules
    """)
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

switch command {
case "daemon":
    requireRoot("daemon")
    try? FileManager.default.createDirectory(atPath: Paths.stateDir,
                                             withIntermediateDirectories: true)
    Log.shared.setPath(Paths.logFile)
    KillSwitch(config: Config.load()).run()

case "status":
    let config = Config.load()
    let tunnels = Interfaces.tunnels()
    print("version:      swift-1.0")
    print("tunnels:      \(tunnels.map { "\($0.name)(\($0.ipv4))" }.joined(separator: " "))")
    print("default route: \(RouteTable.defaultInterfaceName() ?? "none")")
    if let service = VPNService.current() {
        print("vpn app:      \(service.appName) (\(service.bundleID))\(service.connected ? " — connected" : "")")
    } else {
        print("vpn app:      none detected")
    }
    print("mode:         \(config.mode)")
    print("always armed: \(config.alwaysArmed)")
    print("autostart:    \(config.autostart)")
    if getuid() == 0 {
        print("pf enabled:   \(PacketFilter.isEnabled)")
        print("blocked:      \(PacketFilter.isEnforced) (\(PacketFilter.blockRuleCount) rules)")
    } else {
        print("blocked:      (run with sudo to read pf state)")
    }
    if config.probeEnabled, let tunnel = tunnels.first {
        let ok = Probe.run(interface: tunnel.name, host: config.probeHost,
                           port: config.probePort, hostHeader: config.probeHostHeader,
                           path: config.probePath, timeout: config.probeTimeoutSeconds)
        print("probe:        \(ok ? "alive" : "DEAD") via \(tunnel.name) -> \(config.probeHost)")
    }
    print("endpoints:    \(Endpoints.load().joined(separator: " "))")

case "probe":
    // Diagnostic: prove the probe is really pinned to the interface.
    // `vpnks probe utun7 1.1.1.1` should succeed while
    // `vpnks probe utun7 192.0.2.1` (a black hole) must fail.
    guard arguments.count >= 3 else { usage() }
    let config = Config.load()
    let started = Date()
    let alive = Probe.run(interface: arguments[1], host: arguments[2],
                          port: config.probePort, hostHeader: arguments[2],
                          path: config.probePath,
                          timeout: config.probeTimeoutSeconds)
    let elapsed = Date().timeIntervalSince(started)
    print("\(alive ? "alive" : "DEAD")  via \(arguments[1]) -> \(arguments[2])  (\(String(format: "%.3f", elapsed))s)")
    exit(alive ? 0 : 1)

case "bench":
    // How long one structural evaluation costs. This is the number that
    // decides how immediate the switch can be.
    let iterations = 200
    let started = Date()
    for _ in 0..<iterations {
        _ = RouteTable.defaultInterfaceName()
        _ = Interfaces.tunnels()
    }
    let each = Date().timeIntervalSince(started) / Double(iterations) * 1000
    print(String(format: "route lookup + interface scan: %.3f ms per evaluation", each))

case "unblock":
    requireRoot("unblock")
    PacketFilter.clearBlock()
    print("Block cleared.")

case "config":
    let data = try JSONEncoder().encode(Config.load())
    print(String(decoding: data, as: UTF8.self))

case "set":
    requireRoot("set")
    guard arguments.count >= 3 else { usage() }
    var config = Config.load()
    let key = arguments[1], value = arguments[2]
    let boolValue = ["1", "true", "yes", "on"].contains(value.lowercased())
    switch key {
    case "mode":                 config.mode = value.uppercased() == "LIST" ? "LIST" : "ALL"
    case "alwaysArmed":          config.alwaysArmed = boolValue
    case "autostart":            config.autostart = boolValue
    case "allowLAN":             config.allowLAN = boolValue
    case "blockDNS":             config.blockDNS = boolValue
    case "allowVPNReconnect":    config.allowVPNReconnect = boolValue
    case "requireDefaultRoute":  config.requireDefaultRoute = boolValue
    case "probeEnabled":         config.probeEnabled = boolValue
    case "probeHost":            config.probeHost = value; config.probeHostHeader = value
    case "probeIntervalSeconds": config.probeIntervalSeconds = Double(value) ?? 1
    case "probeFailThreshold":   config.probeFailThreshold = Int(value) ?? 1
    case "vpnInterface":         config.vpnInterface = value
    default:
        FileHandle.standardError.write(Data("unknown key: \(key)\n".utf8))
        exit(1)
    }
    try config.save()

    // Autostart is pure file placement — put the plist in (or take it out
    // of) /Library/LaunchDaemons. Deliberately does NOT restart anything,
    // so flipping it never interrupts protection that is already running.
    if key == "autostart" {
        Installer.applyAutostart(config)
    }
    print("\(key) = \(value)")

case "install":
    requireRoot("install")
    var config = Config.load()
    if arguments.contains("--autostart")    { config.autostart = true }
    if arguments.contains("--no-autostart") { config.autostart = false }
    try config.save()
    try Installer.install(config: config)

case "uninstall":
    requireRoot("uninstall")
    Installer.uninstall()

default:
    usage()
}
