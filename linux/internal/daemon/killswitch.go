package daemon

import (
	"fmt"
	"math"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"

	"vpnks/internal/core"
)

type evaluation struct {
	up               bool
	reason           string
	tunnel           *Tunnel
	defaultInterface string
}

func (e evaluation) state() string {
	if e.up {
		return "up"
	}
	return "down"
}

type probeResult struct {
	ok         bool
	generation int
}

// unverified is the probe failure count before any probe has passed.
const unverified = math.MaxInt

// KillSwitch is the state machine. Everything below runs on one goroutine
// (Run's loop); the probe runs on its own and only reports back, so a
// network timeout can never stall a structural check behind it.
type KillSwitch struct {
	cfg core.Config

	trigger chan struct{}
	probes  chan probeResult

	probeInFlight bool
	lastState     string // "", "up", "down"
	// Fail closed on startup: the tunnel is dead until a probe proves
	// otherwise. Block first, unblock on evidence — never the reverse.
	probeFailures int
	lastProbe     time.Time
	lastProbeOK   bool
	// The tunnel the current probe verdict is about, and a generation bumped
	// on every reset so a probe in flight across a reset cannot deliver a
	// verdict about a tunnel that has since changed.
	probedInterface string
	probeGeneration int

	appliedTunnelSignature string
	appliedAllowList       []string
	allowListChanged       bool
	endpointsStamp         int64
	configStamp            int64

	lastEndpointScan     time.Time
	lastIdleAudit        time.Time
	lastHeartbeat        time.Time
	lastSessionSample    time.Time
	lastBlockedRouteScan time.Time
	lastEnforcementCheck time.Time
	lastAppScan          time.Time
	evaluations          int
	forceReassert        bool

	sessions *SessionTracker
	vpnApp   VPNApp
	appFor   string // tunnel the vpnApp verdict is about

	// Whether this daemon has the block loaded, as it last set it. Tracked
	// rather than asked of nft, which costs a process launch.
	blockLoaded        bool
	observedInterfaces []string
	blockedSince       *time.Time
	lastTunnel         string
	lastVPNAppName     string
	lastLoggedReason   string

	// Reconnect assist. With Block DNS on, a VPN client that must look up
	// its server's name before connecting can never reconnect through the
	// block: the lookup is dropped and it retries forever. So when a tunnel
	// exists but has not carried traffic for a few seconds, DNS may leave
	// the physical interfaces. While a tunnel is up the system resolver
	// points into it, so what leaves directly is essentially the VPN
	// client's own lookup. With no tunnel at all, DNS stays blocked.
	dnsAssist          bool
	tunnelWaitingSince *time.Time

	lastPublished *core.DaemonStatus
	snap          Snapshot
}

const dnsAssistDelay = 6 * time.Second

func New(cfg core.Config) *KillSwitch {
	return &KillSwitch{
		cfg:           cfg,
		trigger:       make(chan struct{}, 1),
		probes:        make(chan probeResult, 1),
		probeFailures: unverified,
		lastHeartbeat: time.Now(),
		sessions:      NewSessionTracker(),
	}
}

// Notify asks for a reconcile pass. Never blocks; bursts coalesce.
func (k *KillSwitch) Notify() {
	select {
	case k.trigger <- struct{}{}:
	default:
	}
}

// MARK: Detection

func (k *KillSwitch) evaluate() evaluation {
	tunnels := k.snap.Tunnels()
	defaultIF := DefaultInterface(k.snap)

	var chosen *Tunnel
	pick := func(name string) {
		for i := range tunnels {
			if chosen == nil && tunnels[i].Name == name {
				chosen = &tunnels[i]
			}
		}
	}
	if k.cfg.VPNInterface != "" {
		pick(k.cfg.VPNInterface)
	}
	if chosen == nil && defaultIF != "" {
		pick(defaultIF)
	}
	if chosen == nil && len(tunnels) > 0 {
		chosen = &tunnels[0]
	}

	if chosen == nil {
		k.resetProbe()
		return evaluation{reason: "no-tunnel-interface", defaultInterface: defaultIF}
	}

	// Structural: for a full-tunnel VPN, ordinary traffic must route into
	// the tunnel. If it snapped back to the physical link, traffic is
	// already leaving in the clear — block now, no grace period.
	if k.cfg.RequireDefaultRoute && (defaultIF == "" || !k.snap.IsTunnel(defaultIF)) {
		k.resetProbe()
		d := defaultIF
		if d == "" {
			d = "none"
		}
		return evaluation{reason: fmt.Sprintf("default-route-not-tunnel(%s)", d), tunnel: chosen, defaultInterface: defaultIF}
	}

	// Liveness: only a probe tells a live tunnel from the corpse a crashed
	// VPN client leaves behind, still holding a valid address.
	if k.cfg.ProbeEnabled {
		if chosen.Name != k.probedInterface {
			// A different tunnel inherits nothing from the previous one.
			k.resetProbe()
			k.probedInterface = chosen.Name
		}
		k.startProbeIfDue(*chosen)
		if k.probeFailures >= k.cfg.ProbeFailThreshold {
			label := "awaiting-first-probe"
			if k.probeFailures != unverified {
				label = fmt.Sprintf("probe-failed-%dx", k.probeFailures)
			}
			return evaluation{reason: label + "-on-" + chosen.Name, tunnel: chosen, defaultInterface: defaultIF}
		}
	}
	route := defaultIF
	if route == "" {
		route = "none"
	}
	return evaluation{up: true, reason: fmt.Sprintf("up(iface=%s,route=%s)", chosen.Name, route), tunnel: chosen, defaultInterface: defaultIF}
}

// resetProbe goes back to "unverified". Up must always be earned by a
// probe on this tunnel; treating a new tunnel as healthy lifted the block
// the moment a connecting client created its interface.
func (k *KillSwitch) resetProbe() {
	k.probeFailures = unverified
	k.lastProbe = time.Time{}
	k.lastProbeOK = false
	k.probedInterface = ""
	k.probeGeneration++
}

// startProbeIfDue dispatches at most one probe at a time. A failing tunnel
// is re-probed faster than a healthy one, but never more than twice a
// second, so an event storm cannot pile up network I/O.
func (k *KillSwitch) startProbeIfDue(t Tunnel) {
	if k.probeInFlight {
		return
	}
	interval := time.Duration(k.cfg.ProbeIntervalSeconds * float64(time.Second))
	if !k.lastProbeOK && interval > 500*time.Millisecond {
		interval = 500 * time.Millisecond
	}
	if time.Since(k.lastProbe) < interval {
		return
	}
	k.probeInFlight = true
	cfg, gen := k.cfg, k.probeGeneration
	go func() {
		timeout := time.Duration(cfg.ProbeTimeoutSeconds * float64(time.Second))
		ok := Probe(t.Name, cfg.ProbeHost, cfg.ProbePort, cfg.ProbeHostHeader, cfg.ProbePath, timeout)
		k.probes <- probeResult{ok: ok, generation: gen}
	}()
}

func (k *KillSwitch) handleProbe(r probeResult) {
	k.probeInFlight = false
	// Stale: the tunnel was lost or replaced mid-probe.
	if r.generation != k.probeGeneration {
		return
	}
	k.lastProbe = time.Now()
	k.lastProbeOK = r.ok
	switch {
	case r.ok:
		k.probeFailures = 0
	case k.probeFailures == unverified:
		k.probeFailures = 1
	default:
		k.probeFailures++
	}
}

// MARK: Reconcile

func (k *KillSwitch) applyBlock() {
	tunnels := TunnelNames(k.snap.Tunnels())
	allow := core.AllowList()
	var assist []string
	if k.dnsAssist {
		assist = k.snap.PhysicalNames()
	}
	err := Load(BuildBlock(k.cfg, tunnels, allow, assist))
	if err != nil {
		core.Logf("ERROR: nft failed to load the block: %v", err)
	}
	wasLoaded := k.blockLoaded
	k.blockLoaded = err == nil
	if k.blockLoaded && !wasLoaded {
		now := time.Now()
		k.blockedSince = &now
	}
	k.lastEnforcementCheck = time.Now()
	k.appliedTunnelSignature = strings.Join(tunnels, ",")
	k.appliedAllowList = allow
	k.allowListChanged = false
}

// liftBlock swaps the block for the pass-only observing rules.
func (k *KillSwitch) liftBlock() {
	k.observedInterfaces = k.snap.PhysicalNames()
	if err := Load(BuildObserve(k.observedInterfaces)); err != nil {
		// Never leave a failed load standing in for "no block".
		core.Logf("WARN: could not load observing rules (%v); clearing instead", err)
		Clear()
	}
	k.blockLoaded = false
}

var failureCount = regexp.MustCompile(`-\d+x-`)

func (k *KillSwitch) reconcile() {
	k.evaluations++
	k.reloadConfigIfChanged()
	k.snap = TakeSnapshot()

	// Rebuild the rules when the exceptions change, judged by the addresses
	// that end up in the rules — the daemon's own learning pass rewrites
	// the file, so its timestamp alone would rebuild for nothing.
	if stamp := core.ModTime(core.EndpointsFile); stamp != k.endpointsStamp {
		k.endpointsStamp = stamp
		k.allowListChanged = !equalStrings(core.AllowList(), k.appliedAllowList)
	}

	ev := k.evaluate()
	now := time.Now()
	k.updateVPNApp(ev, now)

	if ev.up && ev.tunnel != nil {
		k.lastTunnel = ev.tunnel.Name
		if k.vpnApp.Name != "" {
			k.lastVPNAppName = k.vpnApp.Name
		}
	}
	k.logBlockedReasonIfChanged(ev)
	assistChanged := k.updateDNSAssist(ev, now)

	if ev.up && ev.tunnel != nil && ev.tunnel.Name != k.cfg.VPNInterface {
		from := k.cfg.VPNInterface
		if from == "" {
			from = "none"
		}
		core.Logf("interface tracking: %s -> %s", from, ev.tunnel.Name)
		k.cfg.VPNInterface = ev.tunnel.Name
		_ = k.cfg.Save()
		k.configStamp = core.ModTime(core.ConfigFile)
	}

	wantBlock := k.cfg.AlwaysArmed || !ev.up

	if ev.state() != k.lastState {
		core.Logf("event: vpn -> %s (reason=%s, default_if=%s)", ev.state(), ev.reason, orNone(ev.defaultInterface))
		k.lastState = ev.state()
		if ev.up && ev.tunnel != nil {
			k.sessions.Begin(ev.tunnel.Name, k.vpnApp.Name)
		} else if !ev.up {
			k.sessions.NoteBlock()
			k.sessions.End()
		}
		if wantBlock {
			// A last look at what the VPN client was talking to before the
			// observe table (and its tally) is replaced: if it moved to a
			// new server moments ago, that server must be allowed or the
			// tunnel can never come back.
			if !k.blockLoaded && k.cfg.AllowVPNReconnect {
				Learn(k.snap)
			}
			k.applyBlock()
			if k.blockLoaded {
				core.Logf("block applied")
			}
		} else {
			k.dnsAssist = false
			k.tunnelWaitingSince = nil
			k.liftBlock()
			core.Logf("block cleared")
		}
		k.publish(ev, true)
		k.forceReassert = false
		return
	}

	// Re-assert against reality every pass, not only on transitions: this
	// survives sleep/wake and other software reloading the firewall.
	if wantBlock {
		switch {
		case assistChanged:
			k.applyBlock()
		case k.allowListChanged:
			core.Logf("exception list changed — rebuilding rules")
			k.applyBlock()
		case k.forceReassert || k.blockWentMissing(now):
			core.Logf("re-asserting block (missing or forced; reason=%s)", ev.reason)
			k.applyBlock()
		case k.cfg.Mode == "ALL" && strings.Join(TunnelNames(k.snap.Tunnels()), ",") != k.appliedTunnelSignature:
			// The rules name tunnels explicitly; without a rebuild the probe
			// on a new tunnel stays blocked and recovery is never observed.
			core.Logf("tunnel set changed — rebuilding rules")
			k.applyBlock()
		}
	} else {
		// Nothing leaks while the VPN is up, so this only catches a
		// leftover block cutting the user off — a minute is plenty.
		if k.forceReassert || now.Sub(k.lastIdleAudit) >= time.Minute {
			k.lastIdleAudit = now
			if BlockLoaded() {
				core.Logf("WARN: block active while VPN is up — clearing")
				k.liftBlock()
			}
			k.blockLoaded = false
		}
		// Wi-Fi ↔ Ethernet: the observing rules name the interfaces.
		if !equalStrings(k.snap.PhysicalNames(), k.observedInterfaces) {
			k.liftBlock()
		}
	}

	// Byte counters for the running session. A sample is a few sysfs reads.
	if ev.up && now.Sub(k.lastSessionSample) >= 5*time.Second {
		k.lastSessionSample = now
		k.sessions.Sample()
	}

	// Learn the VPN server while the tunnel is healthy; reconnecting
	// through a block depends on it.
	if ev.up && now.Sub(k.lastEndpointScan) >= 30*time.Second {
		k.lastEndpointScan = now
		Learn(k.snap)
	}

	// While blocked, keep watching for a server a reconnecting client
	// starts using, and let it through at once. The store's change is
	// picked up at the top of the next pass, which rebuilds the rules.
	if wantBlock && k.cfg.AllowVPNReconnect && now.Sub(k.lastBlockedRouteScan) >= 2*time.Second {
		k.lastBlockedRouteScan = now
		if LearnWhileBlocked(k.snap) {
			core.Logf("learned a new VPN server while blocked — allowing it")
			k.Notify()
		}
	}

	k.publish(ev, false)

	if now.Sub(k.lastHeartbeat) >= time.Hour {
		k.lastHeartbeat = now
		core.Logf("heartbeat: state=%s iface=%s blocked=%v evals=%d", k.lastState, k.cfg.VPNInterface, k.blockLoaded, k.evaluations)
		k.evaluations = 0
	}
	k.forceReassert = false
}

// reloadConfigIfChanged re-reads config.json when it changes on disk, so
// the app's toggles take effect within a second.
func (k *KillSwitch) reloadConfigIfChanged() {
	stamp := core.ModTime(core.ConfigFile)
	if stamp == 0 {
		return
	}
	if k.configStamp == 0 {
		k.configStamp = stamp
		return
	}
	if stamp == k.configStamp {
		return
	}
	reloaded, ok := core.LoadConfigIfValid()
	if !ok {
		// Mid-write, most likely: retry next pass rather than skip it.
		k.configStamp = 0
		return
	}
	k.configStamp = stamp
	prev := k.cfg
	k.cfg = reloaded
	core.Logf("config reloaded: alwaysArmed=%v mode=%s allowLAN=%v blockDNS=%v", k.cfg.AlwaysArmed, k.cfg.Mode, k.cfg.AllowLAN, k.cfg.BlockDNS)

	// Anything that changes the shape of the ruleset makes the loaded rules
	// stale: rebuild now rather than at the next transition.
	if prev.AlwaysArmed != k.cfg.AlwaysArmed || prev.Mode != k.cfg.Mode || prev.AllowLAN != k.cfg.AllowLAN ||
		prev.BlockDNS != k.cfg.BlockDNS || prev.AllowVPNReconnect != k.cfg.AllowVPNReconnect {
		k.forceReassert = true
		if prev.AlwaysArmed && !k.cfg.AlwaysArmed {
			// Leaving always-armed: drop the standing block at once if the
			// tunnel is healthy, instead of stranding the user.
			k.lastState = ""
		}
	}
}

// updateDNSAssist reports whether the assist switched on or off.
func (k *KillSwitch) updateDNSAssist(ev evaluation, now time.Time) bool {
	waiting := k.cfg.BlockDNS && k.cfg.AllowVPNReconnect && !ev.up && ev.tunnel != nil
	if waiting {
		if k.tunnelWaitingSince == nil {
			k.tunnelWaitingSince = &now
		}
	} else {
		k.tunnelWaitingSince = nil
	}
	want := waiting && now.Sub(*k.tunnelWaitingSince) >= dnsAssistDelay
	if want == k.dnsAssist {
		return false
	}
	k.dnsAssist = want
	if want {
		core.Logf("reconnect assist on: tunnel %s not carrying traffic for %ds — allowing DNS so the VPN client can look up its server",
			ev.tunnel.Name, int(dnsAssistDelay.Seconds()))
	} else {
		core.Logf("reconnect assist off: DNS blocked again")
	}
	return true
}

// logBlockedReasonIfChanged logs each change in WHY traffic is blocked,
// so a lockout can be diagnosed afterwards. The failure count is dropped
// from the comparison, or every failed probe would be a new line.
func (k *KillSwitch) logBlockedReasonIfChanged(ev evaluation) {
	if ev.up {
		k.lastLoggedReason = ""
		return
	}
	kind := failureCount.ReplaceAllString(ev.reason, "-")
	if kind == k.lastLoggedReason {
		return
	}
	if k.lastLoggedReason != "" {
		core.Logf("still blocked: %s (default_if=%s)", kind, orNone(ev.defaultInterface))
	}
	k.lastLoggedReason = kind
}

// blockWentMissing checks every 5 seconds while blocked that the rules
// are still in force. nftables has no "rules changed" notification, and
// other software (a firewall reload, `nft flush ruleset`) can remove them
// while the status still says blocked.
func (k *KillSwitch) blockWentMissing(now time.Time) bool {
	if now.Sub(k.lastEnforcementCheck) < 5*time.Second {
		return false
	}
	k.lastEnforcementCheck = now
	return !BlockLoaded()
}

// updateVPNApp re-identifies the VPN app when the tunnel changes, and
// every 15 seconds otherwise (a /proc walk; cheap, but not free).
func (k *KillSwitch) updateVPNApp(ev evaluation, now time.Time) {
	name := ""
	if ev.tunnel != nil {
		name = ev.tunnel.Name
	}
	if name == k.appFor && now.Sub(k.lastAppScan) < 15*time.Second {
		return
	}
	k.appFor, k.lastAppScan = name, now
	app, _ := DetectVPNApp(name, k.snap)
	k.vpnApp = app
}

// publish writes status.json only when something the app shows changed —
// never on a timer.
func (k *KillSwitch) publish(ev evaluation, force bool) {
	baseIn, baseOut, carriedIn, carriedOut := k.sessions.CounterState()
	s := core.DaemonStatus{
		Running:             true,
		VPNState:            ev.state(),
		Reason:              ev.reason,
		VPNAppName:          k.vpnApp.Name,
		VPNBundleID:         k.vpnApp.Process,
		Blocked:             k.blockLoaded,
		AlwaysArmed:         k.cfg.AlwaysArmed,
		AllowLAN:            k.cfg.AllowLAN,
		BlockDNS:            k.cfg.BlockDNS,
		AllowVPNReconnect:   k.cfg.AllowVPNReconnect,
		Autostart:           k.cfg.Autostart,
		Mode:                k.cfg.Mode,
		DefaultInterface:    ev.defaultInterface,
		ProbeEnabled:        k.cfg.ProbeEnabled,
		ProbeTarget:         fmt.Sprintf("%s:%d", k.cfg.ProbeHost, k.cfg.ProbePort),
		Endpoints:           k.allowListForStatus(),
		PID:                 os.Getpid(),
		DaemonVersion:       core.FullVersion(),
		SessionBaseIn:       baseIn,
		SessionBaseOut:      baseOut,
		SessionCarriedIn:    carriedIn,
		SessionCarriedOut:   carriedOut,
		ReconnectAssist:     k.dnsAssist,
		LastTunnelInterface: k.lastTunnel,
		LastVPNAppName:      k.lastVPNAppName,
	}
	if ev.tunnel != nil {
		s.TunnelInterface, s.TunnelAddress = ev.tunnel.Name, ev.tunnel.IPv4
	}
	if a := k.sessions.Active(); a != nil {
		started := a.StartedAt
		s.SessionStartedAt = &started
		s.SessionBytesIn, s.SessionBytesOut = a.BytesIn, a.BytesOut
	}
	if k.blockLoaded {
		s.BlockedSince = k.blockedSince
	}
	if !force && k.lastPublished != nil && s.SameContent(*k.lastPublished) {
		return
	}
	s.UpdatedAt = time.Now()
	if err := s.Write(); err != nil {
		core.Logf("WARN: could not write status: %v", err)
	}
	k.lastPublished = &s
}

var cachedAllow struct {
	stamp int64
	list  []string
}

func (k *KillSwitch) allowListForStatus() []string {
	stamp := core.ModTime(core.EndpointsFile)
	if cachedAllow.list == nil || cachedAllow.stamp != stamp {
		cachedAllow.stamp, cachedAllow.list = stamp, core.AllowList()
		if cachedAllow.list == nil {
			cachedAllow.list = []string{}
		}
	}
	return cachedAllow.list
}

// MARK: Run

func (k *KillSwitch) Run() {
	core.Logf("=== vpnks daemon starting (pid %d, uid %d, v%s) ===", os.Getpid(), os.Getuid(), core.FullVersion())
	core.Logf("mode=%s alwaysArmed=%v probe=%s:%d interval=%gs threshold=%d",
		k.cfg.Mode, k.cfg.AlwaysArmed, k.cfg.ProbeHost, k.cfg.ProbePort, k.cfg.ProbeIntervalSeconds, k.cfg.ProbeFailThreshold)

	// The app edits the exception list in place, without a password; it
	// cannot create the file in the root-owned state directory itself.
	if _, err := os.Stat(core.EndpointsFile); err != nil {
		core.SaveEndpoints(nil)
	}

	// Learn from whatever the observe table tallied before a restart, so
	// the fail-closed block below does not cut the tunnel off its server.
	k.snap = TakeSnapshot()
	if k.cfg.AllowVPNReconnect {
		Learn(k.snap)
	}

	// Fail closed: evaluate before anything else can happen.
	k.reconcile()

	WatchNetwork(k.Notify)
	power := WatchPower()

	stop := make(chan os.Signal, 2)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)

	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			// Backstop for the one case no event reports: a VPN process
			// dying quietly while its interface and routes stay put.
			k.reconcile()
		case <-k.trigger:
			k.reconcile()
		case r := <-k.probes:
			k.handleProbe(r)
			k.reconcile()
		case sleeping := <-power.Events:
			if sleeping {
				core.Logf("system going to sleep")
				k.sessions.PersistNow()
				power.Release()
			} else {
				core.Logf("WAKE: system resumed — forcing full re-assert")
				// Nothing learned before sleep can be trusted after it.
				k.forceReassert = true
				k.resetProbe()
				k.reconcile()
			}
		case sig := <-stop:
			// systemctl stop (Turn Off) sends SIGTERM. Save the session's
			// totals, which are no longer written every few seconds, and
			// leave the firewall as it is: uninstall clears it, and a
			// crash-restart must not open a gap.
			k.sessions.PersistNow()
			core.Logf("stopping (%v)", sig)
			os.Exit(0)
		}
	}
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
