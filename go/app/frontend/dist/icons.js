// Line icons standing in for the SF Symbols the macOS app uses. 24×24,
// drawn in currentColor so they take the tone of whatever holds them.
const SHIELD = "M12 3l7.5 3v5.5c0 4.6-3.2 8.3-7.5 9.8-4.3-1.5-7.5-5.2-7.5-9.8V6z";

const ICON_PATHS = {
  shieldHalf:   `<path d="${SHIELD}"/><path d="M12 3v18.3c-4.3-1.5-7.5-5.2-7.5-9.8V6z" fill="currentColor" stroke="none"/>`,
  shieldCheck:  `<path d="${SHIELD}" fill="currentColor" fill-opacity=".18"/><path d="M8.6 12.2l2.4 2.4 4.6-4.8"/>`,
  shieldSlash:  `<path d="${SHIELD}"/><path d="M4 4l16 16"/>`,
  lockShield:   `<path d="${SHIELD}" fill="currentColor" fill-opacity=".18"/><rect x="9.2" y="11" width="5.6" height="4.6" rx="1"/><path d="M10.4 11V9.6a1.6 1.6 0 013.2 0V11"/>`,
  hand:         `<path d="M8 13V6.5a1.5 1.5 0 013 0V11M11 10.5V4.5a1.5 1.5 0 013 0v6M14 10.5V6a1.5 1.5 0 013 0v4.5M17 10.5V9a1.5 1.5 0 013 0v5c0 4.2-3 7.5-7.2 7.5h-.6c-2.4 0-4-1-5.4-2.9L4 14.8a1.6 1.6 0 012.5-2L8 14.4" fill="currentColor" fill-opacity=".14"/>`,
  power:        `<path d="M12 3v8"/><path d="M6.4 6.6a8 8 0 1011.2 0"/>`,
  powerDotted:  `<path d="M12 3v8"/><path d="M6.4 6.6a8 8 0 1011.2 0" stroke-dasharray="2 3"/>`,
  network:      `<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.6 2.6 3.8 5.6 3.8 9s-1.2 6.4-3.8 9c-2.6-2.6-3.8-5.6-3.8-9S9.4 5.6 12 3z"/>`,
  arrowsUpDown: `<path d="M8 20V4M4 8l4-4 4 4M16 4v16M12 16l4 4 4-4"/>`,
  arrowDownCircle: `<circle cx="12" cy="12" r="9"/><path d="M12 7.5v9M8 12.5l4 4 4-4"/>`,
  sliders:      `<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>`,
  pin:          `<path d="M9 3h6M10 3v6.2l-3 3.8h10l-3-3.8V3M12 13v8"/>`,
  pinFill:      `<path d="M9 3h6M10 3v6.2l-3 3.8h10l-3-3.8V3z" fill="currentColor"/><path d="M12 13v8"/>`,
  pinSlash:     `<path d="M9 3h6M10 3v6.2l-3 3.8h10l-3-3.8V3M12 13v8M3.5 3.5l17 17"/>`,
  history:      `<path d="M3.5 12a8.5 8.5 0 102.6-6.1L3.5 8.5"/><path d="M3.5 4v4.5H8M12 7.5V12l3 2"/>`,
  list:         `<rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><path d="M7.5 9h9M7.5 12h9M7.5 15h5"/>`,
  alert:        `<path d="M10.3 4.3L2.6 18a2 2 0 001.7 3h15.4a2 2 0 001.7-3L13.7 4.3a2 2 0 00-3.4 0z"/><path d="M12 9.5v4M12 17v.01"/>`,
  refresh:      `<path d="M20 11a8 8 0 00-14.6-4.5M4 4v4h4M4 13a8 8 0 0014.6 4.5M20 20v-4h-4"/>`,
  lifebuoy:     `<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3.8"/><path d="M5.6 5.6l3.7 3.7M14.7 14.7l3.7 3.7M18.4 5.6l-3.7 3.7M9.3 14.7l-3.7 3.7"/>`,
  info:         `<circle cx="12" cy="12" r="9"/><path d="M12 11v5.5M12 7.6v.01"/>`,
  lockOpen:     `<rect x="4.5" y="11" width="15" height="10" rx="2"/><path d="M8 11V7.5a4 4 0 017.7-1.5"/>`,
  trash:        `<path d="M4 7h16M10 11v6M14 11v6M5.8 7l.9 12.2A2 2 0 008.7 21h6.6a2 2 0 002-1.8L18.2 7M9 7V4.5h6V7"/>`,
  house:        `<path d="M3.5 11L12 4l8.5 7M5.5 9.5V20h13V9.5M10 20v-5.5h4V20"/>`,
  search:       `<circle cx="10.5" cy="10.5" r="6"/><path d="M15 15l5 5"/>`,
  textSearch:   `<path d="M3 6h9M3 11h6M3 16h5"/><circle cx="15.5" cy="13.5" r="4"/><path d="M18.5 16.5l2.5 2.5"/>`,
  sunrise:      `<path d="M12 3v5M9.5 5.5L12 3l2.5 2.5M4.9 10.9l1.4 1.4M19.1 10.9l-1.4 1.4M2.5 18.5h19M7 18.5a5 5 0 0110 0M6 21.5h12"/>`,
  tray:         `<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M3 9h18"/>`,
  check:        `<path d="M5 12.5l4.5 4.5L19 7.5"/>`,
  moon:         `<path d="M20 14.5A8.2 8.2 0 019.5 4 8.5 8.5 0 1020 14.5z"/>`,
  moonFill:     `<path d="M20 14.5A8.2 8.2 0 019.5 4 8.5 8.5 0 1020 14.5z" fill="currentColor"/>`,
  zzz:          `<path d="M14 4h6l-6 6h6M4 12h7l-7 8h7"/>`,
  arrowUpRight: `<path d="M7 17L17 7M9 7h8v8"/>`,
  radio:        `<circle cx="12" cy="12" r="1.8" fill="currentColor"/><path d="M8.6 8.6a4.8 4.8 0 000 6.8M15.4 8.6a4.8 4.8 0 010 6.8M5.6 5.6a9 9 0 000 12.8M18.4 5.6a9 9 0 010 12.8"/>`,
  timer:        `<circle cx="12" cy="13.5" r="7.5"/><path d="M12 9.5v4l2.5 2M10 2.5h4"/>`,
  arrowDown:    `<path d="M12 4.5v15M6 13.5l6 6 6-6"/>`,
  arrowUp:      `<path d="M12 19.5v-15M6 10.5l6-6 6 6"/>`,
  sun:          `<circle cx="12" cy="12" r="4" fill="currentColor"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/>`,
  circleHalf:   `<circle cx="12" cy="12" r="8.5"/><path d="M12 3.5a8.5 8.5 0 010 17z" fill="currentColor"/>`,
};

function icon(name, extra = "") {
  return `<svg class="i ${extra}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON_PATHS[name] || ""}</svg>`;
}
