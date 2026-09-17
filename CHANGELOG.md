# Changelog

All notable changes to Lanarchy (`donnie.homelab-mesh`) are documented here.
The version in `manifest.json` is the single source of truth.

## 0.3.12 — 2026-09-17

- Resolve plugin dir from install location (marketplace `donnie.homelab-mesh`), not a hardcoded `homelab-mesh` path
- Ship a localhost starter `inventory.json` (lab mesh moved out of the default)
- Refresh marketplace preview and README screenshots

## 0.3.11 — 2026-09-17

- Visio-style orthogonal edges attach to card borders (not through centers)
- **FLOW** / **STATIC** toggle (`a`) for animated traffic; animation actually moves again

## 0.3.10 — 2026-09-17

- Calm traffic: one shared slow pulse, modest width from real link rates only (no aggregate bleed / yellow overlays)

## 0.3.9 — 2026-09-17

- Drop LAN / PROXIES / ALL (ISSUES) toggles — leftovers and demoted cards always show in List; map shows everything except Move-to-LAN demotions

## 0.3.8 — 2026-09-17

- Map traffic as a slow Minard-style march: width from volume, soft under-glow, long pulse (not frantic dashes)

## 0.3.7 — 2026-09-17

- **Move to LAN** demotes a map card into the LAN bucket (cluster + List → LAN); **Show** brings it back
- Removed the separate HIDDEN drawer — LAN is the only hide/show bucket

## 0.3.6 — 2026-09-17

- Map edges hub on the **reverse proxy** (Caddy), not the UniFi router; WAN lines still cross the router bar
- Card colour = status only (fill + rim match) — drop orange “hot RTT” wash that fought green borders
- Hub card labelled `reverse proxy`; no extra dns role needed for overlays

## 0.3.5 — 2026-09-17

- ISSUES off always persists: inventory writes send `settings` even when empty (no stale `mapQuietUp` merge)
- Map hub placement: redUltra on the router bar without also drawing Caddy as a left gateway

## 0.3.4 — 2026-09-17

- **HIDDEN** drawer: restore cards one-by-one or Show all (replaces unhide-all chip)
- Stronger map card fill vs border (status wash vs hard rim)
- Zone labels coloured (INTERNAL green / EXTERNAL accent)
- Degraded (yellow) only when a member is actually **down** — up+unknown stays green

## 0.3.3 — 2026-09-17

- Map proportions: ~2⁄3 INTERNAL · router bar · ~1⁄3 EXTERNAL
- Per-service **Hide on map** (`mapHidden`, still probed)
- **ISSUES** quiet mode: auto-hide healthy LAN services on the map while tracking continues (`q`)

## 0.3.2 — 2026-09-17

- Map: three columns — INTERNAL | ROUTER bar | EXTERNAL
- Router bar (redUltra) shows live aggregate LAN ↓/↑ traffic; edges bend through it
- External/cloud boxes with `httpReachable` for 401/404 edges
- Packaging: plugin root is the git repo root (marketplace `omarchy plugin add` layout)

## 0.3.1 — 2026-09-17

- Stop grey↔LIVE flicker: keep applying snapshot while the panel is closed (bar chip)
- Don't flash PROBING on refresh when glance data already exists
- Wider STALE window; boot daemon without opening the panel; ignore flock exit-0 restarts

## 0.3.0 — 2026-09-16

- Theme-aware map/list status colours from Omarchy `colors.toml`
- Stronger borders on map cards, pills, and setup rows
- Scrollable Setup / form
- **Search network** (Find hosts): UniFi wired machines + mDNS + ARP
- UniFi OS `macAddress` / `ipAddress` projection; machine vs IoT noise filter
- Reverse-proxy hosts no longer steal the Caddy box MAC in history
- README rewritten to match Omarchy plugin develop guide + Pulse-style docs
- Panel-only screenshots under `docs/screenshots/`

## 0.2.0 — 2026-09-16

- P0–P3 stack: inventory write safety, discover, sparklines, speedtest, talkers, bar health ramp, unknown-neighbor notify
- UniFi collector + castle-socket bar mark

## 0.1.0

- Initial Homelab Mesh / Lanarchy glance panel
