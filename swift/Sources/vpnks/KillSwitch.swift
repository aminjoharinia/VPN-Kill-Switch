import Foundation

enum VPNState: String { case up, down }

struct Evaluation {
    let state: VPNState
    let reason: String
    let tunnel: TunnelInterface?
    let defaultInterface: String?
}

final class KillSwitch {
    private var config: Config
    private let queue = DispatchQueue(label: "vpnks.state")
    private let pathWatcher = PathWatcher()
    private let powerWatcher = PowerWatcher()

    private let probeQueue = DispatchQueue(label: "vpnks.probe")
    private var probeInFlight = false

    private var lastState: VPNState?
    // Fail closed on startup: assume the tunnel is dead until a probe
    // proves otherwise. A kill switch should block first and unblock on
    // evidence, never the reverse.
    private var probeFailures = Int.max
    private var lastProbe = Date.distantPast
    private var lastProbeOK = false
    // The tunnel the current probe verdict is about, and a generation
    // bumped on every reset so a probe that was in flight across a reset
    // cannot deliver a verdict about a tunnel that has since changed.
    private var probedInterface = ""
    private var probeGeneration = 0
    private var appliedTunnelSignature = ""
    private var lastEndpointScan = Date.distantPast
    private var lastIdleAudit = Date.distantPast
    private var lastHeartbeat = Date()
    private var evaluations = 0
    private var forceReassert = false

    init(config: Config) { self.config = config }

    // MARK: - Detection

    private func evaluate() -> Evaluation {
        let tunnels = Interfaces.tunnels()
        let defaultIF = RouteTable.defaultInterfaceName()

        var chosen: TunnelInterface?
        if !config.vpnInterface.isEmpty {
            chosen = tunnels.first { $0.name == config.vpnInterface }
        }
        if chosen == nil, let d = defaultIF {
            chosen = tunnels.first { $0.name == d }
        }
        if chosen == nil { chosen = tunnels.first }

        // A tunnel that owns the default route but carries no IPv4 is
        // still the tunnel. utun devices can be IPv6-only, or briefly
        // address-less while the VPN client is bringing them up; treating
        // that as "no tunnel at all" reported the VPN as down while it was
        // plainly routing. The probe binds by interface index, not by
        // address, so it works regardless.
        if chosen == nil, let d = defaultIF, Interfaces.isTunnelName(d) {
            chosen = TunnelInterface(name: d, ipv4: "")
        }

        guard let tunnel = chosen else {
            resetProbe()
            return Evaluation(state: .down, reason: "no-tunnel-interface",
                              tunnel: nil, defaultInterface: defaultIF)
        }

        // Structural: for a full-tunnel VPN the default route must be in
        // the tunnel. If it snapped back to the physical link, traffic is
        // already leaving in the clear — block now, no grace period.
        if config.requireDefaultRoute {
            guard let d = defaultIF, Interfaces.isTunnelName(d) else {
                resetProbe()
                return Evaluation(state: .down,
                                  reason: "default-route-not-tunnel(\(defaultIF ?? "none"))",
                                  tunnel: tunnel, defaultInterface: defaultIF)
            }
        }

        // Liveness: only a probe can tell a live tunnel from the corpse a
        // crashed VPN client leaves behind, still holding a valid IP.
        //
        // The probe runs OFF this queue and only its cached result is read
        // here. Running it inline would have meant a 3s network timeout
        // stalling every structural check behind it — so a tunnel dying
        // while a probe hung would go unnoticed for the whole timeout,
        // which is the opposite of what this rewrite is for.
        if config.probeEnabled {
            // A different tunnel inherits nothing from the previous one.
            if tunnel.name != probedInterface {
                resetProbe()
                probedInterface = tunnel.name
            }
            startProbeIfDue(tunnel: tunnel)
            if probeFailures >= config.probeFailThreshold {
                let label = probeFailures == Int.max ? "awaiting-first-probe" : "probe-failed-\(probeFailures)x"
                return Evaluation(state: .down,
                                  reason: "\(label)-on-\(tunnel.name)",
                                  tunnel: tunnel, defaultInterface: defaultIF)
            }
        }

        return Evaluation(state: .up,
                          reason: "up(iface=\(tunnel.name),route=\(defaultIF ?? "none"))",
                          tunnel: tunnel, defaultInterface: defaultIF)
    }

    /// Back to "unverified". These paths used to set probeFailures = 0,
    /// which reads as healthy: the moment a connecting VPN client created
    /// its interface, the tunnel was declared up and the block lifted with
    /// no probe ever passing — then the first real probe failed and it
    /// blocked again. Up must always be earned by a probe on this tunnel.
    private func resetProbe() {
        probeFailures = Int.max
        lastProbe = .distantPast
        lastProbeOK = false
        probedInterface = ""
        probeGeneration &+= 1
    }

    /// Dispatches a probe without blocking the state queue. At most one
    /// is ever in flight; a failing probe retries faster than a healthy
    /// one, but never faster than twice a second, so a path-change storm
    /// cannot pile up network I/O.
    private func startProbeIfDue(tunnel: TunnelInterface) {
        guard !probeInFlight else { return }
        let interval = lastProbeOK
            ? config.probeIntervalSeconds
            : min(config.probeIntervalSeconds, 0.5)
        guard Date().timeIntervalSince(lastProbe) >= interval else { return }

        probeInFlight = true
        let snapshot = config
        let generation = probeGeneration
        probeQueue.async { [weak self] in
            let ok = Probe.run(interface: tunnel.name,
                               host: snapshot.probeHost,
                               port: snapshot.probePort,
                               hostHeader: snapshot.probeHostHeader,
                               path: snapshot.probePath,
                               timeout: snapshot.probeTimeoutSeconds)
            self?.queue.async {
                guard let self else { return }
                self.probeInFlight = false
                // Stale: the tunnel was lost or replaced mid-probe.
                guard generation == self.probeGeneration else {
                    self.reconcileLocked()
                    return
                }
                self.lastProbe = Date()
                self.lastProbeOK = ok
                self.probeFailures = ok ? 0 : (self.probeFailures == Int.max ? 1 : self.probeFailures + 1)
                self.reconcileLocked()
            }
        }
    }

    // MARK: - Reconcile

    private func signature(_ tunnels: [TunnelInterface]) -> String {
        tunnels.map(\.name).joined(separator: ",")
    }

    private func applyBlock(flushStates: Bool) {
        let tunnels = Interfaces.tunnels()
        let allowList = EndpointStore.allowList()
        let rules = PacketFilter.buildRules(config: config,
                                            tunnels: tunnels,
                                            endpoints: allowList,
                                            dnsAssist: dnsAssist ? Interfaces.physicalNames() : [],
                                            vpnUDPPorts: config.allowVPNReconnect ? vpnUDPPorts : [])
        let wasLoaded = blockLoaded
        blockLoaded = PacketFilter.applyBlock(rules: rules, flushStates: flushStates)
        if blockLoaded, !wasLoaded { blockedSince = Date() }
        lastEnforcementCheck = Date()
        appliedTunnelSignature = signature(tunnels)
        appliedAllowList = allowList
        appliedVPNUDPPorts = vpnUDPPorts
        allowListChanged = false
    }

    func reconcile() {
        queue.async { self.reconcileLocked() }
    }

    private func reconcileLocked() {
        evaluations += 1
        reloadConfigIfChanged()
        // The exception list is user-editable; rebuild the ruleset when it
        // changes so a newly pinned address takes effect immediately
        // rather than at the next state transition.
        //
        // Judged by the addresses that end up in the rules, not by the
        // file's timestamp. The daemon's own 30-second learning pass
        // rewrites the file with fresh hit counts, so the timestamp moved
        // every time and the whole pf.conf was reloaded twice a minute for
        // nothing. The stamp is only a cheap "worth looking" check.
        if let stamp = EndpointStore.modifiedAt(), stamp != endpointsStamp {
            endpointsStamp = stamp
            allowListChanged = EndpointStore.allowList() != appliedAllowList
        }

        if Date().timeIntervalSince(lastServiceScan) >= 5 {
            lastServiceScan = Date()
            vpnService = VPNService.current()
        }
        let evaluation = evaluate()
        let now = Date()

        if evaluation.state == .up, let tunnel = evaluation.tunnel {
            lastTunnelInterface = tunnel.name
            if let name = vpnService?.appName, !name.isEmpty { lastVPNAppName = name }
        }
        logBlockedReasonIfChanged(evaluation)
        let assistChanged = updateDNSAssist(evaluation, now: now)

        if let tunnel = evaluation.tunnel,
           evaluation.state == .up,
           tunnel.name != config.vpnInterface {
            log("interface tracking: \(config.vpnInterface.isEmpty ? "none" : config.vpnInterface) -> \(tunnel.name)")
            config.vpnInterface = tunnel.name
            try? config.save()
        }

        let wantBlock = config.alwaysArmed || evaluation.state == .down

        if evaluation.state != lastState {
            log("event: vpn -> \(evaluation.state.rawValue) (reason=\(evaluation.reason), default_if=\(evaluation.defaultInterface ?? "none"))")
            lastState = evaluation.state
            if evaluation.state == .up, let tunnel = evaluation.tunnel {
                sessions.begin(interface: tunnel.name,
                               appName: vpnService?.appName ?? "")
            } else if evaluation.state == .down {
                sessions.noteBlock()
                sessions.end()
            }
            if wantBlock {
                // Last look at what the VPN client was talking to before the
                // flush below erases pf's connection records: if it moved
                // to a new server moments ago, that server must be in the
                // allow-list or the tunnel can never come back.
                if !blockLoaded, config.allowVPNReconnect {
                    Endpoints.learn()
                    Endpoints.learnWhileBlocked(vpnPID: tunnelOwnerPID(evaluation.tunnel))
                    vpnUDPPorts = tunnelOwnerPID(evaluation.tunnel).map(Sockets.udpPorts) ?? []
                }
                // Flush states only when newly blocking, so healthy
                // connections are not torn down on every transition.
                applyBlock(flushStates: !blockLoaded)
            } else {
                dnsAssist = false
                tunnelWaitingSince = nil
                liftBlock()
                log("block cleared")
            }
            publishStatus(evaluation, force: true)
            forceReassert = false
            return
        }

        // Re-assert against reality every pass, not only on transitions.
        // This is what survives sleep/wake and other software reloading pf.
        if wantBlock {
            if assistChanged {
                applyBlock(flushStates: false)
            } else if allowListChanged {
                // Only a loaded block contains the list, so only then is
                // there anything to rebuild; otherwise the next block
                // picks up the current list when it is applied.
                log("exception list changed — rebuilding rules")
                applyBlock(flushStates: false)
            } else if forceReassert || blockWentMissing(now) {
                log("re-asserting block (missing or forced; reason=\(evaluation.reason))")
                applyBlock(flushStates: false)
            } else if config.mode == "ALL",
                      signature(Interfaces.tunnels()) != appliedTunnelSignature {
                // A tunnel appeared or vanished. Rules name tunnels
                // explicitly, so rebuild — otherwise the probe on the new
                // tunnel stays blocked and recovery is never observed.
                log("tunnel set changed — rebuilding rules")
                applyBlock(flushStates: false)
            }
        } else {
            if forceReassert { PacketFilter.ensureAnchorRegistered() }
            // Nothing leaks while the VPN is up, so this only catches a
            // leftover block cutting the user off — a minute is plenty.
            if forceReassert || now.timeIntervalSince(lastIdleAudit) >= 60 {
                lastIdleAudit = now
                if PacketFilter.blockRuleCount > 0 {
                    log("WARN: block active while VPN is up — clearing")
                    liftBlock()
                }
                blockLoaded = false
            }
            // Wi-Fi ↔ Ethernet: the observing rules name the interfaces.
            if Interfaces.physicalNames() != observedInterfaces { liftBlock() }
        }

        // Byte counters for the running session. Deliberately unhurried:
        // a sample costs ~0.4 ms, and there is nothing to gain from finer
        // granularity than this.
        if evaluation.state == .up, now.timeIntervalSince(lastSessionSample) >= 5 {
            lastSessionSample = now
            sessions.sample()
        }

        // Learn the VPN server endpoints whenever the tunnel is healthy.
        // Required for reconnection once the block is on.
        if evaluation.state == .up, now.timeIntervalSince(lastEndpointScan) >= 30 {
            lastEndpointScan = now
            Endpoints.learn()
        }

        // While blocked, keep watching for the server a reconnecting VPN
        // client turns to — its host route, or its own socket's connection
        // attempt — and let it through at once. The store's change is
        // picked up by the allow-list check at the top of the next pass,
        // which rebuilds the rules.
        if wantBlock, config.allowVPNReconnect,
           now.timeIntervalSince(lastBlockedRouteScan) >= 1 {
            lastBlockedRouteScan = now
            let owner = tunnelOwnerPID(evaluation.tunnel)
            vpnUDPPorts = owner.map(Sockets.udpPorts) ?? []
            if blockLoaded, vpnUDPPorts != appliedVPNUDPPorts {
                log("VPN client's UDP ports now \(vpnUDPPorts.isEmpty ? "none" : vpnUDPPorts.map(String.init).joined(separator: ", ")) — rebuilding rules")
                applyBlock(flushStates: false)
            }
            let added = Endpoints.learnWhileBlocked(vpnPID: owner)
            if !added.isEmpty {
                log("learned a new VPN server while blocked — allowing \(added.joined(separator: ", "))")
                // Pick it up now rather than on the next pass.
                endpointsStamp = nil
                reconcile()
            }
        }

        publishStatus(evaluation)

        // Hourly: it only shows the daemon was alive, which the app now
        // checks directly. Every 5 minutes it was most of the log.
        if now.timeIntervalSince(lastHeartbeat) >= 3600 {
            lastHeartbeat = now
            log("heartbeat: state=\(lastState?.rawValue ?? "unknown") iface=\(config.vpnInterface) blocked=\(blockLoaded) evals=\(evaluations)")
            evaluations = 0
        }
        forceReassert = false
    }

    /// The process that owns the tunnel, cached (an lsof over every process
    /// is a fraction of a second, too slow for each pass). Looked up again
    /// when the tunnel changes, or when the cached process has died — Happ
    /// relaunches its tunnel process on a reconnect and the new one comes
    /// back on the same utun, so keying the cache on the name alone kept
    /// watching a dead pid and never saw the new process's connections.
    /// With no tunnel at all, the last live owner is kept.
    private var tunnelOwner: (interface: String, pid: pid_t?) = ("", nil)
    /// The tunnel owner's unconnected UDP ports, passed while blocked so a
    /// QUIC client can reach a server never seen before. See Sockets.udpPorts.
    private var vpnUDPPorts: [Int] = []
    private var appliedVPNUDPPorts: [Int] = []
    private var lastOwnerLookup = Date.distantPast
    private func tunnelOwnerPID(_ tunnel: TunnelInterface?) -> pid_t? {
        let alive = tunnelOwner.pid.map(Sockets.isAlive) == true
        if let tunnel,
           tunnel.name != tunnelOwner.interface
            || (!alive && Date().timeIntervalSince(lastOwnerLookup) >= 2) {
            lastOwnerLookup = Date()
            let pid = Sockets.tunnelOwner(interface: tunnel.name)
            if pid != nil || !alive { tunnelOwner = (tunnel.name, pid) }
            else { tunnelOwner.interface = tunnel.name }
        }
        guard let pid = tunnelOwner.pid, Sockets.isAlive(pid) else { return nil }
        return pid
    }

    private let sessions = SessionTracker()
    private var lastSessionSample = Date.distantPast
    private var lastBlockedRouteScan = Date.distantPast
    private var termination: DispatchSourceSignal?
    private var vpnService: VPNService?
    private var lastServiceScan = Date.distantPast
    private var configStamp: Date?
    private var endpointsStamp: Date?
    /// The allow-list inside the currently loaded block rules.
    private var appliedAllowList: [String] = []
    private var allowListChanged = false

    /// Re-read the config when it changes on disk.
    ///
    /// Previously it was read once at startup and never again, so
    /// `vpnks set alwaysArmed 1` wrote the file, raised an authorisation
    /// prompt, and the running daemon carried on with the old value — the
    /// setting appeared to do nothing at all.
    private func reloadConfigIfChanged() {
        let stamp = Config.modifiedAt()
        guard let stamp else { return }
        if configStamp == nil { configStamp = stamp; return }
        guard stamp != configStamp else { return }
        guard let reloaded = Config.loadIfValid() else {
            // Mid-write, most likely. Leave the stamp cleared so the next
            // pass retries rather than skipping the change entirely.
            configStamp = nil
            return
        }
        configStamp = stamp

        let previous = config
        config = reloaded
        log("config reloaded: alwaysArmed=\(config.alwaysArmed) mode=\(config.mode) allowLAN=\(config.allowLAN) blockDNS=\(config.blockDNS)")

        // Anything that changes the shape of the ruleset means the loaded
        // rules are now stale, so force a rebuild rather than waiting for
        // the next transition.
        if previous.alwaysArmed != config.alwaysArmed
            || previous.mode != config.mode
            || previous.allowLAN != config.allowLAN
            || previous.blockDNS != config.blockDNS
            || previous.allowVPNReconnect != config.allowVPNReconnect {
            forceReassert = true
            if !config.alwaysArmed && previous.alwaysArmed {
                // Leaving always-armed: drop the standing block at once if
                // the tunnel is healthy, instead of stranding the user.
                lastState = nil
            }
        }
    }

    /// Whether this daemon has the block loaded, as it last set it.
    /// Tracked rather than asked of pf: asking costs three pfctl process
    /// launches, and it used to be asked every second just to fill in the
    /// status file.
    private var blockLoaded = false
    private var observedInterfaces: [String] = []
    private var blockedSince: Date?
    private var lastTunnelInterface = ""
    private var lastVPNAppName = ""
    private var lastLoggedBlockReason = ""

    /// Reconnect assist. With "Block DNS" on, a VPN client that has to look
    /// up its server's name before connecting (Happ does) can never
    /// reconnect through the block: the lookup is dropped, it never learns
    /// the address, and it restarts its tunnel forever — traffic stays cut
    /// until the switch is turned off.
    ///
    /// So when a tunnel exists but has not carried traffic for a few
    /// seconds, DNS is let out of the physical interface. The leak is small
    /// by design: while a tunnel is up, the system resolver points into the
    /// tunnel, so what leaves directly is essentially the VPN client's own
    /// lookup. With no tunnel at all, DNS stays blocked — any lookup then
    /// is an ordinary app's and would expose it.
    private var dnsAssist = false
    private var tunnelWaitingSince: Date?
    /// Long enough to ride out a single failed probe on a healthy tunnel,
    /// short enough not to dominate a reconnect. It was 6 s, which made
    /// every reconnect that needed a lookup take at least that long.
    private let dnsAssistDelay: TimeInterval = 3

    /// Returns true when the assist switched on or off.
    private func updateDNSAssist(_ evaluation: Evaluation, now: Date) -> Bool {
        let waiting = config.blockDNS && config.allowVPNReconnect
            && evaluation.state == .down && evaluation.tunnel != nil
        if waiting {
            if tunnelWaitingSince == nil { tunnelWaitingSince = now }
        } else {
            tunnelWaitingSince = nil
        }
        let want = waiting && now.timeIntervalSince(tunnelWaitingSince ?? now) >= dnsAssistDelay
        guard want != dnsAssist else { return false }
        dnsAssist = want
        log(want
            ? "reconnect assist on: tunnel \(evaluation.tunnel?.name ?? "") not carrying traffic for \(Int(dnsAssistDelay))s — allowing DNS so the VPN client can look up its server"
            : "reconnect assist off: DNS blocked again")
        return true
    }

    /// While blocked, log each change in WHY — "no tunnel", "awaiting the
    /// first probe on utun7", "probe failing on utun7" — so a lockout can
    /// be diagnosed afterwards. Only the state was logged before, and a
    /// reconnect that never succeeded left nothing but "rebuilding rules".
    /// The failure count is dropped from the comparison, or every failed
    /// probe would be a new line.
    private func logBlockedReasonIfChanged(_ evaluation: Evaluation) {
        guard evaluation.state == .down else { lastLoggedBlockReason = ""; return }
        let kind = evaluation.reason.replacingOccurrences(
            of: #"-\d+x-"#, with: "-", options: .regularExpression)
        guard kind != lastLoggedBlockReason else { return }
        if !lastLoggedBlockReason.isEmpty {
            log("still blocked: \(kind) (default_if=\(evaluation.defaultInterface ?? "none"))")
        }
        lastLoggedBlockReason = kind
    }

    /// Replaces the block with the pass-only observing rules, which let
    /// the daemon learn the VPN server while traffic flows normally.
    private func liftBlock() {
        observedInterfaces = Interfaces.physicalNames()
        PacketFilter.loadObserve(physical: observedInterfaces)
        blockLoaded = false
    }
    private var lastEnforcementCheck = Date.distantPast

    /// While blocked, confirm every 5 seconds that the rules are still in
    /// force. pf has no "rules changed" notification, and other software
    /// (a firewall or VPN app quitting, a pf reload) can disable pf or
    /// flush the anchor — the block would vanish and traffic leak while
    /// the status still said blocked. Two pfctl calls; nothing on disk.
    private func blockWentMissing(_ now: Date) -> Bool {
        guard now.timeIntervalSince(lastEnforcementCheck) >= 5 else { return false }
        lastEnforcementCheck = now
        return !PacketFilter.isEnabled || PacketFilter.blockRuleCount == 0
    }

    private var lastPublishedStatus: DaemonStatus?

    /// Writes status.json only when something the app shows has changed —
    /// never on a timer. It used to be rewritten every second whether or
    /// not anything had changed: 86,400 file writes a day to the SSD. The
    /// app no longer needs a heartbeat: it checks the daemon's process is
    /// alive, and reads live byte counts from the interface itself.
    private func publishStatus(_ evaluation: Evaluation, force: Bool = false) {
        let session = sessions.active
        let counters = sessions.counterState
        var status = DaemonStatus(
            updatedAt: Date(),
            running: true,
            vpnState: evaluation.state.rawValue,
            reason: evaluation.reason,
            vpnAppName: vpnService?.appName ?? "",
            vpnBundleID: vpnService?.bundleID ?? "",
            blocked: blockLoaded,
            alwaysArmed: config.alwaysArmed,
            allowLAN: config.allowLAN,
            blockDNS: config.blockDNS,
            allowVPNReconnect: config.allowVPNReconnect,
            autostart: config.autostart,
            mode: config.mode,
            tunnelInterface: evaluation.tunnel?.name ?? "",
            tunnelAddress: evaluation.tunnel?.ipv4 ?? "",
            defaultInterface: evaluation.defaultInterface ?? "",
            probeEnabled: config.probeEnabled,
            probeTarget: "\(config.probeHost):\(config.probePort)",
            endpoints: appliedOrCurrentAllowList(),
            pid: getpid(),
            daemonVersion: "\(Build.version)+\(Build.number)",
            sessionStartedAt: session?.startedAt,
            sessionBytesIn: session?.bytesIn ?? 0,
            sessionBytesOut: session?.bytesOut ?? 0,
            sessionBaseIn: counters.baseIn,
            sessionBaseOut: counters.baseOut,
            sessionCarriedIn: counters.carriedIn,
            sessionCarriedOut: counters.carriedOut,
            blockedSince: blockLoaded ? blockedSince : nil,
            reconnectAssist: dnsAssist,
            lastTunnelInterface: lastTunnelInterface,
            lastVPNAppName: lastVPNAppName)

        if let previous = lastPublishedStatus, status.sameContent(as: previous) { return }
        status.updatedAt = Date()
        status.write()
        lastPublishedStatus = status
    }

    /// The allow-list for the status file, read from disk only when the
    /// store has changed (its stamp is already checked each pass).
    private var cachedAllowList: (stamp: Date?, list: [String])?
    private func appliedOrCurrentAllowList() -> [String] {
        let stamp = EndpointStore.modifiedAt()
        if let cached = cachedAllowList, cached.stamp == stamp { return cached.list }
        let list = EndpointStore.allowList()
        cachedAllowList = (stamp, list)
        return list
    }

    // MARK: - Run

    func run() {
        log("=== vpnks daemon starting (pid \(getpid()), uid \(getuid())) ===")
        log("mode=\(config.mode) alwaysArmed=\(config.alwaysArmed) probe=\(config.probeHost):\(config.probePort) interval=\(config.probeIntervalSeconds)s threshold=\(config.probeFailThreshold)")

        PacketFilter.ensureAnchorRegistered()

        // Learn from whatever pf is already tracking — after an Update or a
        // restart, that includes the VPN client's current server — so the
        // fail-closed block below does not cut the tunnel off from it.
        if config.allowVPNReconnect { Endpoints.learn() }

        // Fail closed: evaluate before anything else can happen.
        //
        // On the state queue, like every other pass. This used to run on
        // the main thread, so a fast first probe was processed on the
        // queue *concurrently* with this pass's slower pfctl calls: the
        // queue logged "up, block cleared", then this pass finished loading
        // the block — status said up while traffic stayed cut until the
        // idle audit noticed a second later.
        queue.sync { reconcileLocked() }

        pathWatcher.onChange = { [weak self] in
            // Structural evaluation is pure syscalls here, so unlike the
            // shell version there is no need to ration these.
            self?.reconcile()
        }
        pathWatcher.start()

        powerWatcher.onSleep = { [weak self] in
            log("system going to sleep")
            self?.queue.sync { self?.sessions.persistNow() }
        }

        // launchctl bootout (Turn Off) sends SIGTERM. Save the session's
        // totals before going, since they are no longer written every few
        // seconds.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termination.setEventHandler { [weak self] in
            self?.sessions.persistNow()
            log("stopping (SIGTERM)")
            exit(0)
        }
        termination.resume()
        self.termination = termination
        powerWatcher.onWake = { [weak self] in
            guard let self else { return }
            log("WAKE: system powered on — forcing full re-assert")
            self.queue.async {
                self.forceReassert = true
                // Re-verify from scratch; nothing learned before sleep
                // can be trusted about the tunnel after waking.
                self.resetProbe()
            }
            self.reconcile()
        }
        powerWatcher.start()

        // Backstop poll. Catches the case no event can report: a VPN
        // process dying quietly while its interface and routes stay put.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.reconcileLocked() }
        timer.resume()

        RunLoop.main.run()
    }
}
