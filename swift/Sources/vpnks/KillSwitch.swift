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
            probeFailures = 0
            return Evaluation(state: .down, reason: "no-tunnel-interface",
                              tunnel: nil, defaultInterface: defaultIF)
        }

        // Structural: for a full-tunnel VPN the default route must be in
        // the tunnel. If it snapped back to the physical link, traffic is
        // already leaving in the clear — block now, no grace period.
        if config.requireDefaultRoute {
            guard let d = defaultIF, Interfaces.isTunnelName(d) else {
                probeFailures = 0
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
        let rules = PacketFilter.buildRules(config: config,
                                            tunnels: tunnels,
                                            endpoints: EndpointStore.allowList())
        PacketFilter.applyBlock(rules: rules, flushStates: flushStates)
        appliedTunnelSignature = signature(tunnels)
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
        let endpointsChanged: Bool = {
            guard let stamp = EndpointStore.modifiedAt() else { return false }
            defer { endpointsStamp = stamp }
            guard let previous = endpointsStamp else { return false }
            return stamp != previous
        }()
        if endpointsChanged {
            log("exception list changed — rebuilding rules")
            forceReassert = true
        }

        if Date().timeIntervalSince(lastServiceScan) >= 5 {
            lastServiceScan = Date()
            vpnService = VPNService.current()
        }
        let evaluation = evaluate()
        let now = Date()

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
                // Flush states only when newly blocking, so healthy
                // connections are not torn down on every transition.
                applyBlock(flushStates: !PacketFilter.isEnforced)
            } else {
                PacketFilter.clearBlock()
                log("block cleared")
            }
            publishStatus(evaluation, force: true)
            forceReassert = false
            return
        }

        // Re-assert against reality every pass, not only on transitions.
        // This is what survives sleep/wake and other software reloading pf.
        if wantBlock {
            if forceReassert || !PacketFilter.isEnforced {
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
            if now.timeIntervalSince(lastIdleAudit) >= 15 {
                lastIdleAudit = now
                if PacketFilter.isEnforced {
                    log("WARN: block active while VPN is up — clearing")
                    PacketFilter.clearBlock()
                }
            }
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

        publishStatus(evaluation)

        if now.timeIntervalSince(lastHeartbeat) >= 300 {
            lastHeartbeat = now
            log("heartbeat: state=\(lastState?.rawValue ?? "unknown") iface=\(config.vpnInterface) blocked=\(PacketFilter.isEnforced) evals=\(evaluations)")
            evaluations = 0
        }
        forceReassert = false
    }

    private let sessions = SessionTracker()
    private var lastSessionSample = Date.distantPast
    private var lastPublished = Date.distantPast
    private var vpnService: VPNService?
    private var lastServiceScan = Date.distantPast
    private var configStamp: Date?
    private var endpointsStamp: Date?

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

    /// Publish at most once a second while idle, but always immediately
    /// after a state change, so the UI never lags a transition.
    private func publishStatus(_ evaluation: Evaluation, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublished) >= 1 else { return }
        lastPublished = now
        DaemonStatus(
            updatedAt: now,
            running: true,
            vpnState: evaluation.state.rawValue,
            reason: evaluation.reason,
            vpnAppName: vpnService?.appName ?? "",
            vpnBundleID: vpnService?.bundleID ?? "",
            blocked: PacketFilter.isEnforced,
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
            endpoints: EndpointStore.allowList(),
            pid: getpid(),
            daemonVersion: "\(Build.version)+\(Build.number)",
            sessionStartedAt: sessions.active?.startedAt,
            sessionBytesIn: sessions.active?.bytesIn ?? 0,
            sessionBytesOut: sessions.active?.bytesOut ?? 0
        ).write()
    }

    // MARK: - Run

    func run() {
        log("=== vpnks daemon starting (pid \(getpid()), uid \(getuid())) ===")
        log("mode=\(config.mode) alwaysArmed=\(config.alwaysArmed) probe=\(config.probeHost):\(config.probePort) interval=\(config.probeIntervalSeconds)s threshold=\(config.probeFailThreshold)")

        PacketFilter.ensureAnchorRegistered()

        // Fail closed: evaluate before anything else can happen.
        reconcileLocked()

        pathWatcher.onChange = { [weak self] in
            // Structural evaluation is pure syscalls here, so unlike the
            // shell version there is no need to ration these.
            self?.reconcile()
        }
        pathWatcher.start()

        powerWatcher.onSleep = { log("system going to sleep") }
        powerWatcher.onWake = { [weak self] in
            guard let self else { return }
            log("WAKE: system powered on — forcing full re-assert")
            self.queue.async {
                self.forceReassert = true
                // Re-verify from scratch; nothing learned before sleep
                // can be trusted about the tunnel after waking.
                self.probeFailures = Int.max
                self.lastProbe = .distantPast
                self.lastProbeOK = false
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
