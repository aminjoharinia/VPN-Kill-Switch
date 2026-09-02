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
      vpnks sessions            session history with traffic totals
      vpnks endpoints           list VPN server exceptions
      vpnks pin add <ip>        pin an exception so it is never dropped
      vpnks pin remove <ip>     delete an exception
      vpnks --version           print the build version

    Emergency unblock without this tool:
      sudo /sbin/pfctl -a \(Paths.anchorName) -F rules
    """)
    exit(0)
}

/// Column padding done with Swift strings.
///
/// `String(format: "%-16s", swiftString)` segfaults: %s expects a C string
/// pointer and gets a Swift String struct. That crashed `vpnks endpoints`
/// outright, and would have taken `vpnks sessions` down as soon as there
/// was a row to print.
func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func padLeft(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
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

case "--version", "-v", "version":
    print("\(Build.version) (build \(Build.number))")

case "status":
    let config = Config.load()
    let tunnels = Interfaces.tunnels()
    print("version:      \(Build.version) (build \(Build.number))")
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
    print("endpoints:    \(EndpointStore.allowList().joined(separator: " "))")

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

case "sessions":
    let sessions = SessionStore.load()
    if sessions.isEmpty { print("No sessions recorded yet."); break }
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd HH:mm"
    func human(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
    func spell(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600 ? "\(total/3600)h \((total%3600)/60)m"
             : total >= 60   ? "\(total/60)m \(total%60)s"
             : "\(total)s"
    }
    print(pad("STARTED", 18) + pad("DURATION", 10)
          + padLeft("DOWN", 11) + padLeft("UP", 11) + "  TUNNEL")
    for session in sessions.prefix(30) {
        let tunnel = session.interfaceName + (session.isActive ? "  (active)" : "")
        print(pad(stamp.string(from: session.startedAt), 18)
              + pad(spell(session.duration), 10)
              + padLeft(human(session.bytesIn), 11)
              + padLeft(human(session.bytesOut), 11)
              + "  " + tunnel)
    }

case "endpoints", "pin":
    // vpnks endpoints                 list
    // vpnks pin add    1.2.3.4        add and pin (never aged out)
    // vpnks pin remove 1.2.3.4        delete entirely
    // vpnks pin keep   1.2.3.4        pin one that was already learned
    // vpnks pin unkeep 1.2.3.4        let it age normally again
    let sub = arguments.count > 1 ? arguments[1] : "list"
    let target = arguments.count > 2 ? arguments[2] : ""

    switch sub {
    case "add":
        requireRoot("pin add")
        guard EndpointStore.add(target, pinned: true) else {
            FileHandle.standardError.write(Data("not a valid IPv4 address: \(target)\n".utf8))
            exit(1)
        }
        print("pinned \(target)")
    case "remove", "rm", "delete":
        requireRoot("pin remove")
        EndpointStore.remove(target)
        print("removed \(target)")
    case "keep":
        requireRoot("pin keep")
        EndpointStore.setPinned(target, true)
        print("pinned \(target)")
    case "unkeep", "unpin":
        requireRoot("pin unpin")
        EndpointStore.setPinned(target, false)
        print("unpinned \(target)")
    default:
        let all = EndpointStore.load()
        if all.isEmpty { print("No exceptions recorded yet."); break }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let allowed = Set(EndpointStore.allowList())
        print(pad("ADDRESS", 17) + pad("PINNED", 8) + pad("HITS", 7)
              + pad("LAST SEEN", 18) + "IN RULES")
        let ordered = all.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.hits > b.hits
        }
        for e in ordered {
            print(pad(e.ip, 17)
                  + pad(e.pinned ? "yes" : "no", 8)
                  + pad(String(e.hits), 7)
                  + pad(stamp.string(from: e.lastSeen), 18)
                  + (allowed.contains(e.ip) ? "yes" : "no"))
        }
    }

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
