"use strict";
// The window. Every view mirrors its SwiftUI counterpart in gui/VPNKillSwitch;
// the Go side (app.go) is the Controller and pushes a snapshot whenever
// anything changes.

// ---------------------------------------------------------------------------
// Bridge — the Go app, or a mock when the page is opened in a plain browser
// (for working on the design without a Linux machine: ?state=protected,
// blocked, verifying, armed, off, starting; &os=windows for Windows wording).
// ---------------------------------------------------------------------------

const backend = window.go && window.go.main && window.go.main.App;
const api = backend || makeMock();

const S = {
  snap: null,
  live: null,
  panel: "overview",
  filter: "",
  addError: "",
  regions: {},
};

try { S.panel = localStorage.getItem("panel") || "overview"; } catch (_) {}

// ---------------------------------------------------------------------------
// Vocabulary — one colour language for every indicator (Indicators.swift).
//   good: protected · warning: held or changing · danger: unprotected
//   armed: always-armed
// ---------------------------------------------------------------------------

const POWER = {
  off:      { label: "OFF",      tone: "danger",  symbol: "power",       action: "Turn ON"   },
  starting: { label: "STARTING", tone: "warning", symbol: "powerDotted", action: "Starting…" },
  on:       { label: "ON",       tone: "good",    symbol: "power",       action: "Turn OFF"  },
  stopping: { label: "STOPPING", tone: "warning", symbol: "powerDotted", action: "Stopping…" },
};
const busyPower = (p) => p === "starting" || p === "stopping";

const PROTECTION = {
  off:       { title: "Not Protected",   tone: "danger",  symbol: "shieldSlash" },
  protected: { title: "Protected",       tone: "good",    symbol: "shieldCheck" },
  blocked:   { title: "Traffic Blocked", tone: "warning", symbol: "hand" },
  armed:     { title: "Always Armed",    tone: "armed",   symbol: "lockShield" },
};

const PANELS = [
  { id: "overview",   title: "Overview",   symbol: "shieldHalf" },
  { id: "settings",   title: "Settings",   symbol: "sliders" },
  { id: "exceptions", title: "Exceptions", symbol: "pin" },
  { id: "history",    title: "History",    symbol: "history" },
  { id: "activity",   title: "Activity",   symbol: "list" },
];

// ---------------------------------------------------------------------------
// Formatting (Format in History.swift)
// ---------------------------------------------------------------------------

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// Like ByteCountFormatter's binary style.
function fmtBytes(n) {
  n = Number(n || 0);
  if (n === 0) return "Zero KB";
  if (n < 1024) return `${n} bytes`;
  const units = ["KB", "MB", "GB", "TB", "PB"];
  let v = n / 1024, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  const digits = i === 0 ? 0 : i === 1 ? 1 : 2;
  // No zero padding: "20 MB", not "20.0 MB".
  return `${parseFloat(v.toFixed(digits))} ${units[i]}`;
}

function fmtDuration(seconds) {
  const t = Math.max(0, Math.floor(seconds));
  if (t >= 3600) return `${Math.floor(t / 3600)}h ${Math.floor((t % 3600) / 60)}m`;
  if (t >= 60) return `${Math.floor(t / 60)}m ${t % 60}s`;
  return `${t}s`;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
function fmtStarted(iso) {
  const d = new Date(iso);
  const p = (x) => String(x).padStart(2, "0");
  return `${d.getDate()} ${MONTHS[d.getMonth()]}, ${p(d.getHours())}:${p(d.getMinutes())}`;
}

const since = (iso) => (Date.now() - new Date(iso).getTime()) / 1000;

// ---------------------------------------------------------------------------
// Daftar pieces (Daftar.swift)
// ---------------------------------------------------------------------------

const tile = (symbol, tone, size = "") => `<div class="tile ${size} t-${tone}">${icon(symbol)}</div>`;

function header(symbol, title, subtitle, trailing = "", tone = "accent") {
  return `<div class="header">${tile(symbol, tone)}
    <div class="titles"><h1>${esc(title)}</h1>${subtitle ? `<div class="sub">${esc(subtitle)}</div>` : ""}</div>
    ${trailing}</div>`;
}

const pill = (label, value, tone) =>
  `<div class="pill t-${tone}"><div class="label">${esc(label)}</div><div class="value">${esc(value)}</div></div>`;

const stat = (label, value, symbol, tone, detail) => `<div class="stat t-${tone}">${tile(symbol, tone, "chip-size")}
  <div class="body"><div class="label">${esc(label)}</div><div class="value">${esc(value)}</div><div class="detail">${esc(detail)}</div></div></div>`;

const badge = (label, tone, symbol = "") =>
  `<span class="badge t-${tone}" title="${esc(label)}">${symbol ? icon(symbol) : ""}<span class="selectable">${esc(label)}</span></span>`;

function hint(symbol, title, message, { tone = "warning", code = "", trailing = "" } = {}) {
  return `<div class="hint t-${tone}">${tile(symbol, tone, "chip-size")}
    <div class="body"><div class="title">${esc(title)}</div><div class="message">${esc(message)}</div>
    ${code ? `<div class="code selectable">${esc(code)}</div>` : ""}</div>${trailing}</div>`;
}

function rows(list) {
  return list.map((r, i) => r.replace(/^<div class="row/, `<div class="row${i % 2 ? " z" : ""}`)).join("");
}

function table(title, rowList, { footer = "", aside = "" } = {}) {
  return `<div class="table-wrap"><div class="table">
    <div class="table-head"><span>${esc(title)}</span>${aside ? `<span class="aside">${esc(aside)}</span>` : ""}</div>
    ${rows(rowList)}</div>${footer ? `<div class="footer">${esc(footer)}</div>` : ""}</div>`;
}

function detailRow(label, value, { mono = false, tone = "" } = {}) {
  const v = value === "" || value == null ? "—" : value;
  return `<div class="row"><div class="detail-row" style="flex:1;min-width:0">
    <span class="k">${esc(label)}</span>
    <span class="v selectable ${mono ? "mono" : ""} ${tone ? `toned t-${tone}` : ""}" title="${esc(v)}">${esc(v)}</span></div></div>`;
}

function empty(symbol, title, detail) {
  return `<div class="empty">${icon(symbol)}<div class="title">${esc(title)}</div><div class="detail">${esc(detail)}</div></div>`;
}

const traffic = (down, up) =>
  `<span class="traffic"><span class="down">${icon("arrowDown")}${fmtBytes(down)}</span><span class="up">${icon("arrowUp")}${fmtBytes(up)}</span></span>`;

// ---------------------------------------------------------------------------
// Derived state
// ---------------------------------------------------------------------------

const snap = () => S.snap || {};
const liveStatus = () => (snap().daemonRunning ? snap().status : null);
const verifying = (s) => !!s && s.vpnState !== "up" && (s.reason || "").startsWith("awaiting-first-probe");

function liveTotals() {
  const s = liveStatus();
  if (!s || !s.sessionStartedAt) return null;
  return S.live || { down: s.sessionBytesIn, up: s.sessionBytesOut };
}

// ---------------------------------------------------------------------------
// Toolbar (ContentView.swift: PowerStateChip, PowerButton)
// ---------------------------------------------------------------------------

function toolbarHTML() {
  const sn = snap();
  const p = POWER[sn.power || "off"];
  const busy = busyPower(sn.power);
  const kind = busy ? "busy" : sn.power === "on" ? "on" : "off";
  const disabled = busy || sn.busy || (!sn.installed && sn.power === "off");
  return `<span class="chip t-${p.tone}"><span class="dot"></span><span class="label">${p.label}</span></span>
    <button class="power ${kind}" data-action="power" ${disabled ? "disabled" : ""}>
      ${busy ? `<span class="spinner"></span>` : icon(p.symbol)}<span>${p.action}</span></button>`;
}

// ---------------------------------------------------------------------------
// Overview (ContentView.swift OverviewView, StatusCard.swift, Indicators.swift)
// ---------------------------------------------------------------------------

function statusCardHTML() {
  const sn = snap();
  const power = sn.power || "off";
  const busy = busyPower(power);
  const prot = PROTECTION[sn.protection || "off"];
  const status = liveStatus();
  // While turning on or off the card follows the toolbar chip.
  const tone = busy ? POWER[power].tone : prot.tone;

  let title = prot.title;
  if (power === "starting") title = "Starting…";
  else if (power === "stopping") title = "Stopping…";
  else if (sn.protection === "blocked" && verifying(status)) title = "Verifying Tunnel";

  const symbol = busy ? "shieldHalf" : prot.symbol;

  let subtitle;
  if (power === "starting") subtitle = "Waiting for the kill switch to report in.";
  else if (power === "stopping") subtitle = "Removing the firewall rules and stopping the daemon.";
  else if (!status) subtitle = "The kill switch is not running. Traffic is unprotected.";
  else if (sn.protection === "blocked" && status.reconnectWindow)
    subtitle = "Your VPN is connecting to a server. Its tunnel already holds the route, so the link is open for a few seconds while it reaches the server.";
  else if (sn.protection === "blocked" && status.reconnectAssist)
    subtitle = "Your VPN is reconnecting. DNS is briefly allowed so it can look up its server; all other traffic stays cut.";
  else if (sn.protection === "blocked" && verifying(status))
    subtitle = "Tunnel found. Holding traffic until a test request confirms it works.";
  else if (sn.protection === "blocked")
    subtitle = "The tunnel stopped carrying traffic. Everything except your LAN is cut.";
  else if (sn.protection === "armed")
    subtitle = status.vpnState === "up"
      ? "Traffic leaves only through the tunnel. No detection delay."
      : "Tunnel is down. Traffic stays cut until it returns.";
  else if (sn.protection === "protected")
    subtitle = "Tunnel is carrying traffic. Traffic will be cut the moment it stops.";
  else subtitle = "The kill switch is not running.";

  // The one headline figure: how long the tunnel has been up, how long
  // traffic has been cut, or the switch's own state.
  let headline = "";
  if (!busy && status && status.sessionStartedAt && status.vpnState === "up") {
    headline = pill("Connected for", fmtDuration(since(status.sessionStartedAt)), tone);
  } else if (!busy && status && status.blocked) {
    const label = verifying(status) ? "Holding for" : "Blocked for";
    headline = status.blockedSince
      ? pill(label, fmtDuration(since(status.blockedSince)), tone)
      : pill("Traffic", "HELD", tone);
  } else if (!busy) {
    headline = pill("Kill switch", POWER[power].label, POWER[power].tone);
  }

  const reason = status && sn.protection === "blocked" && !busy
    ? badge(status.reason, tone, "info") : "";

  return `<div class="card t-${tone}">${tile(symbol, tone, "hero-size")}
    <div class="titles"><h2>${esc(title)}</h2><div class="sub">${esc(subtitle)}</div>${reason}</div>
    ${headline}</div>`;
}

function indicatorsHTML() {
  const sn = snap();
  const power = sn.power || "off";
  const status = liveStatus();
  const live = !!status;
  const changing = busyPower(power);
  const vpnUp = live && status.vpnState === "up";
  const isVerifying = live && verifying(status);
  const blocked = live && status.blocked;

  const vpnTone = changing ? "warning" : !live ? "muted" : vpnUp ? "good" : "warning";
  const vpnValue = changing ? "Waiting" : !live ? "Unknown" : vpnUp ? "Connected" : isVerifying ? "Checking" : "Down";

  let vpnDetail = "no daemon";
  if (live) {
    const name = status.vpnAppName || "";
    const iface = status.tunnelInterface || "";
    if (!iface && status.lastTunnelInterface) {
      const last = name || status.lastVPNAppName || "";
      vpnDetail = last ? `${last} · ${status.lastTunnelInterface} down` : `${status.lastTunnelInterface} down`;
    } else if (!name && !iface) vpnDetail = "no tunnel";
    else if (!name) vpnDetail = iface;
    else if (!iface) vpnDetail = name;
    else vpnDetail = `${name} · ${iface}`;
  }

  const trafficTone = changing ? "warning" : !live ? "danger" : blocked ? "warning" : "good";
  const trafficValue = changing ? "Waiting" : !live ? "Unprotected" : blocked ? (isVerifying ? "Held" : "Blocked") : "Flowing";
  const trafficDetail = changing ? "for the kill switch" : !live ? "kill switch is off"
    : blocked ? (isVerifying ? "until the tunnel is verified" : "cut by the kill switch") : "over the tunnel";

  const switchDetail = { on: "watching", off: "not running", starting: "starting up", stopping: "shutting down" }[power];
  const totals = live && status.sessionStartedAt ? liveTotals() : null;

  return `<div class="stats">
    ${stat("Kill switch", POWER[power].label[0] + POWER[power].label.slice(1).toLowerCase(), "power", POWER[power].tone, switchDetail)}
    ${stat("VPN", vpnValue, "network", vpnTone, vpnDetail)}
    ${stat("Traffic", trafficValue, blocked ? "hand" : "arrowsUpDown", trafficTone, trafficDetail)}
    ${stat("This session", totals ? fmtBytes(totals.down) : "—", "arrowDownCircle", "armed",
           totals ? `↑ ${fmtBytes(totals.up)} uploaded` : "no active session")}
  </div>`;
}

function tunnelHTML() {
  const status = liveStatus();
  if (!status) {
    return table("Tunnel", [`<div class="row"><span class="detail">Waiting for the daemon…</span></div>`]);
  }
  const tunnelGone = !status.tunnelInterface && !!status.lastTunnelInterface;
  const appText = status.vpnAppName || (status.lastVPNAppName ? `${status.lastVPNAppName} · disconnected` : "not detected");
  const list = [
    detailRow("VPN app", appText, { tone: !status.vpnAppName && status.lastVPNAppName ? "warning" : "" }),
  ];
  if (status.vpnBundleID) list.push(detailRow("Process", status.vpnBundleID, { mono: true }));
  list.push(detailRow("Interface",
    status.tunnelInterface ? `${status.tunnelInterface}  ${status.tunnelAddress || ""}`.trim()
      : tunnelGone ? `${status.lastTunnelInterface} · down` : "none",
    { mono: true, tone: tunnelGone ? "warning" : "" }));
  // Leaving the tunnel is the one fact here that means traffic is
  // escaping, so it is the one that gets a colour.
  const tunnel = status.tunnelInterface || status.lastTunnelInterface;
  const routeLeft = status.defaultInterface && status.defaultInterface !== tunnel;
  list.push(detailRow("Default route",
    tunnelGone && status.defaultInterface ? `${status.lastTunnelInterface} → ${status.defaultInterface}` : status.defaultInterface,
    { mono: true, tone: routeLeft ? "warning" : "" }));
  list.push(detailRow("Liveness probe", status.probeEnabled ? status.probeTarget : "disabled", { mono: true }));
  list.push(detailRow("Mode", status.mode));
  return table("Tunnel", list);
}

function overviewHTML() {
  const sn = snap();
  const status = liveStatus();
  const pf = platform();
  let out = statusCardHTML() + indicatorsHTML();
  if (!sn.installed) {
    out += hint("alert", "Daemon not found", pf.buildLead, { code: pf.buildCommand });
  }
  if (sn.outOfDate) {
    out += hint("refresh", "Daemon is out of date",
      `Running ${sn.daemonVersionText || "an older build"}, this app is ${sn.appVersion}. Some values may display incorrectly until it is updated.`,
      { trailing: `<button class="btn prominent" data-action="update" ${sn.busy ? "disabled" : ""}>Update</button>` });
  }
  // While traffic is cut, the escape hatch must be visible.
  if (sn.protection === "blocked" && !verifying(status)) {
    out += hint("lifebuoy", "Stuck offline?", pf.unblockLead, { code: pf.unblockCommand });
  }
  return out + tunnelHTML();
}

// What differs per platform (PlatformText in platform.go), with the Linux
// wording as the fallback for an older app build.
function platform() {
  return Object.assign({
    os: "linux",
    buildLead: "Build the daemon first, then press Turn On:",
    buildCommand: "./linux/build.sh",
    unblockLead: "Turning the kill switch off restores traffic. From any terminal:",
    unblockCommand: `sudo nft delete table inet ${snap().tableName || "vpn_kill_switch"}`,
    autostartTitle: "Start at boot",
    autostartDetail: "Requires your password — it enables a system service, so protection is up before the network.",
    trayTitle: "Tray icon",
    trayDetail: "Shows the state on an amber-and-black plate, like the app icon, so it stands out in a busy top bar.",
  }, snap().platform || {});
}

// ---------------------------------------------------------------------------
// Settings (SettingsPanel.swift)
// ---------------------------------------------------------------------------

function settingRow(title, detail, symbol, key, on, { tone = "accent", disabled = false } = {}) {
  return `<div class="row">${tile(symbol, tone, "row-size")}
    <div class="grow"><div class="title">${esc(title)}</div><div class="detail">${esc(detail)}</div></div>
    <button class="switch ${on ? "on" : ""}" role="switch" aria-checked="${on}" aria-label="${esc(title)}"
      data-action="set" data-key="${key}" data-value="${on ? "0" : "1"}" ${disabled ? "disabled" : ""}></button></div>`;
}

function actionRow(title, detail, symbol, tone, label, action, { disabled = false, destructive = false } = {}) {
  return `<div class="row">${tile(symbol, tone, "row-size")}
    <div class="grow"><div class="title">${esc(title)}</div><div class="detail">${esc(detail)}</div></div>
    <button class="btn ${destructive ? "destructive" : ""}" data-action="${action}" ${disabled ? "disabled" : ""}>${esc(label)}</button></div>`;
}

function settingsHTML() {
  const sn = snap();
  const status = sn.status;
  const live = !!sn.daemonRunning;
  const armed = !!(status && status.alwaysArmed);
  const v = (k, d) => (status && status[k] !== undefined ? !!status[k] : d);

  let out = header("sliders", "Settings", "How the kill switch behaves, and what it lets through",
    pill("Protection", !live ? "Off" : armed ? "Armed" : "On drop", !live ? "danger" : armed ? "armed" : "good"));

  if (!live) out += hint("power", "The kill switch is off", "Turn it on to change these settings.");

  out += table("Protection", [
    settingRow("Always armed",
      armed ? "Traffic can leave only through the tunnel, right now and always."
            : "Traffic is cut only after a drop is detected — under two seconds, never instant.",
      "lockShield", "alwaysArmed", armed, { tone: "armed", disabled: !live }),
  ], {
    footer: armed
      ? "On: the rule stays loaded permanently and only the tunnel is ever allowed out, so there is nothing to detect and no gap. If the VPN will not connect, you will have no internet until you turn the kill switch off."
      : "Off: the firewall rule is loaded only once the tunnel is found to be dead. Detection takes about a second, and traffic can escape during it.",
  });

  out += table("While traffic is blocked", [
    settingRow("Allow local network", "Printers, file shares and other machines at home stay reachable.",
      "house", "allowLAN", v("allowLAN", true), { disabled: !live }),
    settingRow("Block DNS", "Stops name lookups leaking to your router and on to your ISP. If a VPN tunnel is up but not connecting for 6 seconds, DNS is allowed briefly so the VPN can look up its server.",
      "textSearch", "blockDNS", v("blockDNS", true), { disabled: !live }),
    settingRow("Let the VPN reconnect", "Keeps a hole open to your VPN server only. Turn off for a strict block — you would then have to clear it by hand.",
      "refresh", "allowVPNReconnect", v("allowVPNReconnect", true), { disabled: !live }),
  ], { footer: "These apply within a second — no password needed." });

  const pf = platform();
  out += table("Startup", [
    settingRow(pf.autostartTitle, pf.autostartDetail,
      "sunrise", "autostart", v("autostart", false), { disabled: !live }),
  ]);

  // A display preference kept by this app, so it works while the switch is off.
  const stripes = !!(sn.prefs && sn.prefs.trayStripes);
  out += table(pf.trayTitle, [
    `<div class="row"><div class="hazard"></div>
      <div class="grow"><div class="title">Hazard-stripe background</div>
      <div class="detail">${esc(pf.trayDetail)}</div></div>
      <button class="switch ${stripes ? "on" : ""}" role="switch" aria-checked="${stripes}" data-action="stripes" data-value="${stripes ? "0" : "1"}"></button></div>`,
  ]);

  out += table("Recovery", [
    actionRow("Clear block now", "Restores traffic immediately; the switch keeps watching.",
      "lockOpen", "warning", "Clear", "unblock", { disabled: !(status && status.blocked && live) }),
    actionRow("Remove kill switch", "Stops the daemon and removes its firewall rules.",
      "trash", "danger", "Remove…", "turnOff", { disabled: !live, destructive: true }),
  ], { footer: "Removing stops the daemon, clears any block and deletes its firewall table. It never leaves traffic cut." });

  return out;
}

// ---------------------------------------------------------------------------
// Exceptions (Exceptions.swift)
// ---------------------------------------------------------------------------

function sortedEndpoints() {
  return [...(snap().endpoints || [])].sort((a, b) => {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
    const t = new Date(b.lastSeen) - new Date(a.lastSeen);
    return t !== 0 ? t : b.hits - a.hits;
  });
}

function exceptionsHeadHTML() {
  const sn = snap();
  const list = sortedEndpoints();
  const active = sn.daemonRunning && sn.status ? new Set(sn.status.endpoints || []) : null;
  return header("pin", "Exceptions", "VPN servers allowed through the block so your VPN can reconnect",
    active ? pill("Allowed", `${active.size} of ${list.length}`, "accent") : pill("Stored", String(list.length), "accent"));
}

function exceptionsHintHTML() {
  return hint("pinFill", "Pin your VPN server if reconnecting has ever failed",
    "Addresses marked Allowed stay reachable while traffic is blocked: every pinned one, plus the 16 your VPN used most recently. The rest wait on standby. New servers your VPN switches to are picked up automatically, even during a block; unused ones are forgotten after two weeks.",
    { tone: "accent" });
}

function exceptionsTableHTML() {
  const sn = snap();
  const list = sortedEndpoints();
  const active = sn.daemonRunning && sn.status ? new Set(sn.status.endpoints || []) : null;
  const pinned = list.filter((e) => e.pinned).length;
  if (!list.length) {
    return table("Addresses", [`<div class="row"><span class="detail">Nothing learned yet. Addresses appear here while the tunnel is up.</span></div>`],
      { aside: `${pinned} pinned` });
  }
  const rowList = list.map((e) => {
    const tone = e.pinned ? "accent" : "muted";
    let badges = e.pinned ? badge("Pinned", "accent") : "";
    if (active) {
      const allowed = active.has(e.ip);
      badges += `<span title="${allowed ? "In the firewall now: reachable while traffic is blocked."
        : "Stored but not in the firewall — only pinned and the 16 most recently used are. Pin it to always allow it."}">${
        badge(allowed ? "Allowed" : "Standby", allowed ? "good" : "muted", allowed ? "check" : "zzz")}</span>`;
    }
    return `<div class="row">${tile(e.pinned ? "pinFill" : "arrowUpRight", tone, "row-size")}
      <div class="grow"><div class="title"><span class="selectable" style="font-family:var(--mono)">${esc(e.ip)}</span>${badges}</div>
      <div class="meta">${e.hits} sighting${e.hits === 1 ? "" : "s"} · last seen ${fmtStarted(e.lastSeen)}</div></div>
      <button class="icon-btn" data-action="pin" data-ip="${esc(e.ip)}" data-value="${e.pinned ? "0" : "1"}"
        title="${e.pinned ? "Unpin — allow automatic cleanup" : "Pin — never remove automatically"}">${icon(e.pinned ? "pinSlash" : "pin")}</button>
      <button class="icon-btn danger" data-action="remove" data-ip="${esc(e.ip)}" title="Remove this exception">${icon("trash")}</button></div>`;
  });
  return table("Addresses", rowList, { aside: `${pinned} pinned` });
}

// ---------------------------------------------------------------------------
// History (History.swift)
// ---------------------------------------------------------------------------

function historySessions() {
  const list = snap().sessions || [];
  const live = S.live;
  if (!live) return list;
  return list.map((s) => (s.endedAt ? s : { ...s, bytesIn: live.down, bytesOut: live.up }));
}

const sessionSeconds = (s) => ((s.endedAt ? new Date(s.endedAt) : new Date()) - new Date(s.startedAt)) / 1000;

function historyHTML() {
  const list = historySessions();
  let out = header("history", "History", "One session each time the tunnel comes up while the kill switch runs",
    pill("Sessions", String(list.length), "accent"));
  if (!list.length) {
    return out + empty("history", "No sessions yet", "A session is recorded each time the tunnel comes up while the kill switch is running.");
  }
  const sum = (f) => list.reduce((a, s) => a + f(s), 0);
  out += `<div class="stats">
    ${stat("Downloaded", fmtBytes(sum((s) => s.bytesIn)), "arrowDown", "armed", "all sessions")}
    ${stat("Uploaded", fmtBytes(sum((s) => s.bytesOut)), "arrowUp", "accent", "all sessions")}
    ${stat("Connected", fmtDuration(sum(sessionSeconds)), "timer", "good", "total tunnel time")}
    ${stat("Blocks", String(sum((s) => s.blockCount || 0)), "hand", "warning", "times traffic was cut")}
  </div>`;
  const rowList = list.map((s) => {
    const active = !s.endedAt;
    const parts = [];
    if (s.vpnAppName) parts.push(s.vpnAppName);
    if (s.interfaceName) parts.push(s.interfaceName);
    if (s.blockCount > 0) parts.push(`${s.blockCount} block${s.blockCount === 1 ? "" : "s"}`);
    return `<div class="row">${tile(active ? "radio" : "check", active ? "good" : "muted", "row-size")}
      <div class="grow"><div class="title">${esc(fmtStarted(s.startedAt))}${active ? badge("LIVE", "good") : ""}</div>
      <div class="detail">${esc(parts.join(" · "))}</div></div>
      <div class="right">${traffic(s.bytesIn, s.bytesOut)}<span class="meta">${fmtDuration(sessionSeconds(s))}</span></div></div>`;
  });
  return out + table("Sessions", rowList, { aside: "newest first" });
}

// ---------------------------------------------------------------------------
// Activity (ActivityView.swift)
// ---------------------------------------------------------------------------

function logTone(line) {
  if (line.includes("ERROR") || line.includes("FATAL")) return "danger";
  if (line.includes("WARN") || line.includes("WAKE:")) return "warning";
  if (line.includes("-> down") || line.includes("block applied")) return "warning";
  if (line.includes("-> up") || line.includes("block cleared")) return "good";
  return "";
}

function filteredLogs() {
  const all = snap().logs || [];
  const f = S.filter.trim().toLowerCase();
  return f ? all.filter((l) => l.toLowerCase().includes(f)) : all;
}

function activityHeadHTML() {
  return header("list", "Activity", "The daemon's log, newest first",
    pill(S.filter ? "Matching" : "Events", String(filteredLogs().length), "accent"));
}

function activityListHTML() {
  const all = snap().logs || [];
  if (!all.length) return empty("list", "No activity yet", "Events appear here once the kill switch is running.");
  const lines = filteredLogs().map((line, i) => {
    // "2026-10-15 13:28:47 message" → only the time earns a column.
    const m = /^\S+ (\d\d:\d\d:\d\d) (.*)$/.exec(line);
    const time = m ? m[1] : "", msg = m ? m[2] : line;
    const tone = logTone(line);
    return `<div class="log-row${i % 2 ? " z" : ""}"><span class="dot ${tone ? `t-${tone}` : "faint"}"></span>
      <span class="time">${esc(time)}</span><span class="msg selectable">${esc(msg)}</span></div>`;
  });
  return `<div class="table"><div class="table-head"><span>Events</span><span class="aside">last ${all.length} lines</span></div>${lines.join("")}</div>`;
}

// ---------------------------------------------------------------------------
// Pages: a fixed skeleton per panel (so text fields keep focus) with regions
// that are re-rendered — and only touched when their HTML changed.
// ---------------------------------------------------------------------------

const PAGES = {
  overview:   { skeleton: `<div data-r="main" class="stack"></div>`, regions: () => ({ main: overviewHTML() }) },
  settings:   { skeleton: `<div data-r="main" class="stack"></div>`, regions: () => ({ main: settingsHTML() }) },
  history:    { skeleton: `<div data-r="main" class="stack"></div>`, regions: () => ({ main: historyHTML() }) },
  exceptions: {
    skeleton: `<div data-r="head"></div><div data-r="hint"></div>
      <div class="table-wrap"><div class="addbar">
        <input class="field" id="newAddress" placeholder="Add an address, e.g. 185.143.233.238" spellcheck="false" autocomplete="off">
        <button class="btn prominent" data-action="add" id="addButton" disabled>${icon("pin")}Add &amp; Pin</button></div>
        <div data-r="error"></div></div>
      <div data-r="table"></div>`,
    regions: () => ({
      head: exceptionsHeadHTML(),
      hint: exceptionsHintHTML(),
      error: S.addError ? `<div class="error-text">${esc(S.addError)}</div>` : "",
      table: exceptionsTableHTML(),
    }),
  },
  activity: {
    skeleton: `<div data-r="head"></div>
      <label class="search">${icon("search")}<input id="filter" placeholder="Filter events" spellcheck="false" autocomplete="off"></label>
      <div data-r="list"></div>`,
    regions: () => ({ head: activityHeadHTML(), list: activityListHTML() }),
  },
};

let builtPanel = null;

function renderPage() {
  const page = document.getElementById("page");
  const def = PAGES[S.panel] || PAGES.overview;
  if (builtPanel !== S.panel) {
    page.innerHTML = def.skeleton;
    builtPanel = S.panel;
    S.regions = {};
    document.getElementById("scroll").scrollTop = 0;
    const filter = document.getElementById("filter");
    if (filter) filter.value = S.filter;
  }
  const html = def.regions();
  for (const [name, content] of Object.entries(html)) {
    if (S.regions[name] === content) continue;
    S.regions[name] = content;
    const el = page.querySelector(`[data-r="${name}"]`);
    if (el) el.innerHTML = content;
  }
}

function renderNav() {
  const nav = document.getElementById("nav");
  const html = PANELS.map((p) => `<button class="nav-item ${p.id === S.panel ? "selected" : ""}" data-action="panel" data-panel="${p.id}">
    ${icon(p.symbol)}<span>${p.title}</span></button>`).join("");
  if (nav.innerHTML !== html) nav.innerHTML = html;
}

let lastToolbar = "";
function renderChrome() {
  const sn = snap();
  const appearance = (sn.prefs && sn.prefs.appearance) || "auto";
  const dark = appearance === "dark" || (appearance === "auto" && (sn.systemDark ||
    (!backend && window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches)));
  document.documentElement.dataset.theme = dark ? "dark" : "light";

  const seg = document.getElementById("appearance");
  const segHTML = [["auto", "circleHalf", "Auto"], ["light", "sun", "Light"], ["dark", "moonFill", "Dark"]]
    .map(([id, sym, label]) => `<button class="${id === appearance ? "on" : ""}" data-action="appearance" data-value="${id}" title="${label}">${icon(sym)}</button>`)
    .join("");
  if (seg.innerHTML !== segHTML) seg.innerHTML = segHTML;
  document.getElementById("version").textContent = sn.version ? `v${sn.version}` : "";

  const tb = toolbarHTML();
  if (tb !== lastToolbar) {
    document.getElementById("toolbar").innerHTML = tb;
    lastToolbar = tb;
  }

  const modal = document.getElementById("modal");
  if (sn.lastError) {
    const html = `<div class="modal t-warning" role="alertdialog"><div class="head">${tile("alert", "warning", "chip-size")}<h3>Something went wrong</h3></div>
      <pre class="selectable">${esc(sn.lastError)}</pre><div class="actions"><button class="btn prominent" data-action="dismiss">OK</button></div></div>`;
    if (modal.innerHTML !== html) modal.innerHTML = html;
    modal.hidden = false;
  } else {
    modal.hidden = true;
    modal.innerHTML = "";
  }
}

function render() {
  if (!S.snap) return;
  renderChrome();
  renderNav();
  renderPage();
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

function addException() {
  const input = document.getElementById("newAddress");
  const ip = input.value.trim();
  if (!isIPv4(ip)) { S.addError = "Not a valid IPv4 address."; render(); return; }
  Promise.resolve(api.AddException(ip)).then((err) => {
    S.addError = err || "";
    if (!err) { input.value = ""; document.getElementById("addButton").disabled = true; }
    render();
  });
}

function isIPv4(s) {
  const parts = s.split(".");
  return parts.length === 4 && parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255 && String(Number(p)) === p);
}

document.addEventListener("click", (event) => {
  const el = event.target.closest("[data-action]");
  if (!el || el.disabled) return;
  const d = el.dataset;
  switch (d.action) {
    case "panel":
      S.panel = d.panel;
      try { localStorage.setItem("panel", S.panel); } catch (_) {}
      render();
      break;
    case "power":
      if (snap().power === "on") api.TurnOff(); else api.TurnOn();
      break;
    case "update": api.UpdateDaemon(); break;
    case "unblock": api.UnblockNow(); break;
    case "turnOff": api.TurnOff(); break;
    case "set": api.Set(d.key, d.value); break;
    case "stripes": api.SetTrayStripes(d.value === "1"); break;
    case "appearance": api.SetAppearance(d.value); break;
    case "dismiss": api.DismissError(); break;
    case "add": addException(); break;
    case "pin": api.SetPinned(d.ip, d.value === "1"); break;
    case "remove": api.RemoveException(d.ip); break;
  }
});

document.addEventListener("input", (event) => {
  if (event.target.id === "filter") {
    S.filter = event.target.value;
    render();
  } else if (event.target.id === "newAddress") {
    document.getElementById("addButton").disabled = !isIPv4(event.target.value.trim());
    if (S.addError) { S.addError = ""; render(); }
  }
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && event.target.id === "newAddress") addException();
  if (event.key === "Escape" && snap().lastError) api.DismissError();
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

async function start() {
  const first = await api.State();
  S.snap = first.snapshot;
  S.live = first.live;
  render();
  if (backend && window.runtime) {
    window.runtime.EventsOn("snapshot", (s) => { S.snap = s; render(); });
    window.runtime.EventsOn("live", (l) => { S.live = l; render(); });
  }
  // Clocks ("Connected for", "Blocked for") tick on their own.
  setInterval(render, 1000);
}
start();

// ---------------------------------------------------------------------------
// Mock backend for browser previews
// ---------------------------------------------------------------------------

function makeMock() {
  const params = new URLSearchParams(location.search);
  const state = params.get("state") || "protected";
  const ago = (s) => new Date(Date.now() - s * 1000).toISOString();
  const up = state === "protected" || state === "armed";
  const status = {
    running: true, vpnState: up ? "up" : "down",
    reason: { protected: "up(iface=tun0,route=tun0)", armed: "up(iface=tun0,route=tun0)", blocked: "probe-failed-3x-on-tun0", verifying: "awaiting-first-probe-on-tun0" }[state] || "",
    vpnAppName: up || state === "verifying" ? "sing-box" : "", vpnBundleID: up ? "/usr/bin/sing-box (pid 2214)" : "",
    blocked: state !== "protected", alwaysArmed: state === "armed", allowLAN: true, blockDNS: true, allowVPNReconnect: true,
    autostart: false, mode: "ALL", tunnelInterface: state === "blocked" ? "" : "tun0", tunnelAddress: "172.19.0.1",
    defaultInterface: state === "blocked" ? "wlp2s0" : "tun0", probeEnabled: true, probeTarget: "1.1.1.1:80",
    endpoints: ["185.143.233.238", "91.107.130.4"], pid: 4242, daemonVersion: "26.10.15+120000",
    sessionStartedAt: up ? ago(4210) : undefined, sessionBytesIn: 1532000000, sessionBytesOut: 84200000,
    blockedSince: state === "protected" ? undefined : ago(37), reconnectAssist: false,
    lastTunnelInterface: "tun0", lastVPNAppName: "sing-box",
  };
  const running = state !== "off" && state !== "starting";
  const snapshot = {
    status: running ? status : null, daemonRunning: running,
    power: state === "off" ? "off" : state === "starting" ? "starting" : "on",
    protection: !running ? "off" : state === "armed" ? "armed" : state === "protected" ? "protected" : "blocked",
    installed: true, outOfDate: params.has("outdated"), daemonVersionText: "26.09.24+101010",
    appVersion: "26.10.15+120000", version: "26.10.15", busy: false, lastError: params.get("error") || "",
    logs: [
      "2026-10-15 17:15:47 block cleared",
      "2026-10-15 17:15:47 event: vpn -> up (reason=up(iface=tun0,route=tun0), default_if=tun0)",
      "2026-10-15 17:15:46 still blocked: awaiting-first-probe-on-tun0 (default_if=tun0)",
      "2026-10-15 17:15:44 block applied",
      "2026-10-15 17:15:44 event: vpn -> down (reason=default-route-not-tunnel(wlp2s0), default_if=wlp2s0)",
      "2026-10-15 17:15:29 interface tracking: none -> tun0",
      "2026-10-15 17:15:28 WARN: could not load observing rules; clearing instead",
      "2026-10-15 17:15:28 === vpnks daemon starting (pid 4242, uid 0, v26.10.15+120000) ===",
    ],
    sessions: [
      { id: "a", startedAt: ago(4210), interfaceName: "tun0", vpnAppName: "sing-box", bytesIn: 1532000000, bytesOut: 84200000, blockCount: 0 },
      { id: "b", startedAt: ago(90000), endedAt: ago(80000), interfaceName: "wg0", vpnAppName: "WireGuard", bytesIn: 734003200, bytesOut: 21000000, blockCount: 2 },
      { id: "c", startedAt: ago(190000), endedAt: ago(186000), interfaceName: "tun0", vpnAppName: "Work VPN", bytesIn: 51200000, bytesOut: 3100000, blockCount: 1 },
    ],
    endpoints: [
      { ip: "185.143.233.238", lastSeen: ago(300), hits: 42, pinned: true },
      { ip: "91.107.130.4", lastSeen: ago(7200), hits: 9, pinned: false },
      { ip: "203.0.113.77", lastSeen: ago(900000), hits: 2, pinned: false },
    ],
    prefs: { appearance: params.get("appearance") || "auto", trayStripes: true }, systemDark: false,
    cliPath: "/usr/lib/vpn-kill-switch/vpnks", tableName: "vpn_kill_switch",
    platform: params.get("os") === "windows" ? {
      os: "windows",
      buildLead: "Reinstall VPN Kill Switch, or build it on a Mac or PC:",
      buildCommand: "./windows/build.sh",
      unblockLead: "Turning the kill switch off restores traffic. From a terminal opened as administrator:",
      unblockCommand: '& "C:\\Program Files\\VPN Kill Switch\\Daemon\\vpnks.exe" unblock',
      autostartTitle: "Start with Windows",
      autostartDetail: "Asks for permission — the service then starts with Windows, and the block stays in force across restarts.",
      trayTitle: "Notification area icon",
      trayDetail: "Shows the state on an amber-and-black plate, like the app icon, so it stands out among the other icons.",
    } : undefined,
  };
  const update = (f) => { f(snapshot); S.snap = { ...snapshot }; render(); };
  return {
    State: async () => ({ snapshot, live: up ? { down: 1532000000, up: 84200000 } : null }),
    TurnOn: () => update((s) => { s.power = "starting"; }),
    TurnOff: () => update((s) => { s.power = "stopping"; }),
    UpdateDaemon: () => {}, UnblockNow: () => {},
    Set: (k, v) => update((s) => { if (s.status) s.status[k] = v === "1"; }),
    SetTrayStripes: (on) => update((s) => { s.prefs.trayStripes = on; }),
    SetAppearance: (m) => update((s) => { s.prefs.appearance = m; }),
    DismissError: () => update((s) => { s.lastError = ""; }),
    AddException: async (ip) => { update((s) => { s.endpoints.push({ ip, lastSeen: new Date().toISOString(), hits: 1, pinned: true }); }); return ""; },
    SetPinned: (ip, p) => update((s) => { s.endpoints.find((e) => e.ip === ip).pinned = p; }),
    RemoveException: (ip) => update((s) => { s.endpoints = s.endpoints.filter((e) => e.ip !== ip); }),
  };
}
