<div align="center">

<img src="docs/screenshots/map.png" width="900" alt="Lanarchy map: machines to Caddy hub to services, leftover LAN cluster, theme-coloured borders">

# Lanarchy

**Homelab status in the Omarchy bar — who is up, what sits behind Caddy, and what just appeared on the LAN.**

No typing IPs. Search the network, add boxes from UniFi / mDNS, keep `.lan` names as reverse-proxy hosts.

[![Omarchy](https://img.shields.io/badge/Omarchy-plugin-00d3f2?style=flat-square)](https://omarchy.org)
[![Quickshell](https://img.shields.io/badge/Quickshell-QML-5e81ac?style=flat-square)](https://quickshell.org)
[![Version](https://img.shields.io/badge/version-0.3.7-4fc9d6?style=flat-square)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-MIT-a3be8c?style=flat-square)](LICENSE)

Plugin id: `donnie.homelab-mesh` · Config: `~/.config/omarchy/plugins/homelab-mesh/`  
Repo: [DonnieFi/OmarPlugs](https://github.com/DonnieFi/OmarPlugs) · Architecture: [`docs/architecture.md`](docs/architecture.md)

</div>

---

## The idea

A lab is not a flat list of IPs. You have real boxes (and VMs), a Caddy (or Traefik) front door, and a pile of `*.lan` names that all resolve to the same proxy.

Lanarchy keeps that straight:

| Kind | Example | Role |
|------|---------|------|
| **machine** | `yanagiba` @ `.92`, `homeassistant` @ `.178` | SSH / ICMP / telemetry |
| **host** | `ha.lan`, `git.lan` | Service names, often via reverse proxy |
| **proxy** | Caddy health URL | HTTP 2xx/3xx or TCP check |

<div align="center">
<img src="docs/screenshots/list.png" width="520" alt="Lanarchy list dash: machines, UniFi, grouped services with colour lights">
</div>

List is the default dash (Pulse-style colour lights). Map is the letterbox of the same mesh. Setup is where you **Search network** instead of hand-entering addresses.

<div align="center">
<img src="docs/screenshots/setup.png" width="520" alt="Lanarchy Setup: Find hosts Search network button and inventory with machine/host pills">
</div>

---

## Install

Plugins run **unsandboxed** inside your long-lived `omarchy-shell` process. Only add repos you trust; read them before enabling ([Omarchy shell plugins](https://omarchy.org)).

```bash
omarchy plugin add https://github.com/DonnieFi/OmarPlugs.git --enable
omarchy bar move donnie.homelab-mesh --section right
```

Dev symlink (this checkout is the plugin root):

```bash
ln -sfn /path/to/OmarPlugs ~/.config/omarchy/plugins/homelab-mesh
omarchy-shell shell rescanPlugins
omarchy plugin enable donnie.homelab-mesh
```

Validate:

```bash
omarchy plugin validate .
# or
omarchy plugin validate ~/.config/omarchy/plugins/homelab-mesh
```

Open:

```bash
omarchy-shell shell summon donnie.homelab-mesh
```

### Optional UniFi

```bash
cp unifi-secrets.json.example ~/.config/omarchy/plugins/homelab-mesh/unifi-secrets.json
# UNIFI_KEY=...   or JSON {"apiKey":"..."}
```

`unifi-secrets.json` is gitignored. Never put keys in `inventory.json`. Lanarchy never auto-writes inventory from UniFi — Find hosts only proposes candidates you click to add.

---

## Usage

| Action | How |
|--------|-----|
| Open / close | Click the castle-socket bar icon · Esc closes |
| List / Map | Tabs or `l` / `m` |
| Leftover LAN / proxies | `LAN N` / `PROXIES` or `n` / `p` |
| Map quiet (hide healthy services) | `ISSUES` chip or `q` — still probes everything |
| Hide / demote selected card | Detail **Move to LAN** or `h` — card joins the LAN bucket (still probed) |
| Restore to main map | List → **LAN** → **Show** (or **Show all on map**) |
| Refresh | `r` |
| Setup | `⚙ Setup` or `s` |
| Map select / notify | Arrows · Enter toggles ALERT/MUTE |
| Find hosts | Setup → **Search network** → **+ add** |

### What **Search network** does

Rebuilds `snapshot.discover[]` from three sources and merges them:

| Source | Meaning | Classification |
|--------|---------|----------------|
| **UniFi** | Wired clients from your Cloud Gateway / UDM | Prefer **`machine`**. Strips `name ab:cd` MAC tails. Drops phones / cams / TVs / Chromecast-class noise. |
| **mDNS** | `avahi-browse` (`_ssh`, `_home-assistant`, …) | `machine` or `host` from service type |
| **ARP** | `ip neigh` with a MAC | `host` fallback |

Known inventory (ids, dns, labels, static ip/mac) is filtered out. History MAC/IP counts only for **`machine`** nodes so reverse-proxied hosts do not hide the real Caddy box. UniFi machines win over mDNS/neigh for the same device; machines list first.

Adding a UniFi machine prefers a `.lan` DNS guess plus IP/MAC — lab DNS, not raw typing.

Without UniFi secrets, Search still runs mDNS + ARP with weaker names.

---

## Configure

Bar widget setting (also in `shell.json` under the widget entry):

| Key | Default | Notes |
|-----|---------|-------|
| `refreshIntervalSec` | `15` | 5–120 |

Inventory and sidecars (all under `~/.config/omarchy/plugins/homelab-mesh/`):

| File | Purpose |
|------|---------|
| `inventory.json` | v2 nodes + optional `settings` / `edges` |
| `history.json` | RTT sparklines / events |
| `notify-state.json` | Fail streaks + unknown-neighbor mute |
| `snapshot.json` | Last glance (daemon / probe) |
| `unifi-secrets.json` | API key (optional) |

Useful `inventory.json` settings:

```json
{
  "schemaVersion": 2,
  "settings": {
    "failStreakThreshold": 3,
    "unknownNeighborNotify": true,
    "unifi": { "url": "https://192.168.1.1", "site": "default" },
    "speedtestUrl": "https://files.lan/"
  },
  "nodes": []
}
```

Empty inventory writes are refused. Setup/form saves go through `inventory_cli.py` only when you act — nothing silent.

---

## Remove

```bash
omarchy plugin remove donnie.homelab-mesh
```

That disables and removes the plugin checkout/symlink. Your state files under `~/.config/omarchy/plugins/homelab-mesh/` may remain if the folder was not a pure git checkout — delete that directory if you want a clean slate (`inventory.json`, history, secrets, snapshot).

---

## Dependencies

| Need | Required? | Notes |
|------|-----------|-------|
| Omarchy + Quickshell | yes | Bar widget host |
| Python 3 | yes | `probe.py`, `daemon.py`, CLIs |
| `ping`, `curl`, `ip` | yes | Probes / neigh |
| `avahi-browse` | optional | Richer mDNS discover |
| UniFi OS API key | optional | Named wired machines for Search |
| `iperf3` | optional | Speedtest fallback only if already installed |
| SSH | optional | Machine telemetry / talkers / remote speedtest |

---

## IPC

```bash
omarchy-shell shell summon donnie.homelab-mesh
omarchy-shell shell hide donnie.homelab-mesh
omarchy-shell shell rescanPlugins
```

One-shot collector (debug):

```bash
cd ~/.config/omarchy/plugins/homelab-mesh
python3 probe.py                 # glance JSON on stdout + snapshot
python3 probe.py wol <id|mac>
python3 probe.py speedtest --id <machine>
python3 inventory_cli.py dump
python3 history_cli.py sparkline --id <node>
```

---

## Icons & chrome

<div align="center">
<img src="docs/screenshots/bar-icon-preview.png" width="360" alt="Castle-socket Lanarchy bar mark preview">
</div>

| Affordance | Meaning |
|------------|---------|
| **Castle-socket** | Bar + header mark; alarms when glance has downs |
| **● / ○** | Filled = up/down known; hollow = unknown / probing |
| **Green / yellow / red** | Theme status on **both** fill and border (up / degraded / down) — no separate “hot RTT” wash |
| **reverse proxy** subline | Caddy (or first proxy group) — LAN service edges hub here |
| **router** subline | `role: router` / `mapBand: router` machine (e.g. redUltra) — WAN bar + rates |
| **LIVE · …** pill | Aggregate health + `as_of` |
| **Map / List** | View tabs |
| **LAN N / PROXIES** | Leftover bands |
| **ALERT / MUTE** | Per-node notify on map cards |
| **Sparklines** | Recent RTT from history |
| **machine / host / proxy** chips | Setup inventory type |
| **unifi · box / mdns / arp** | Discover source on Found rows |

---

## How it works

```text
inventory.json  ──►  daemon.py (~15s)  ──►  probe.py
                                              │
                    ┌─────────────────────────┼─────────────────────────┐
                    ▼                         ▼                         ▼
              ICMP / SSH               UniFi OS API              mDNS + ARP
                    │                         │                         │
                    └────────────► snapshot.json ◄──────────────────────┘
                                         │
                              Panel.qml + notify-state
```

Deeper sidecar formats: [`docs/architecture.md`](docs/architecture.md).

---

## Versions

Version lives in **`manifest.json`** only. Releases bump it, add a [CHANGELOG.md](CHANGELOG.md) entry, and should be tagged `vX.Y.Z`.

---

## Credits

Built for [Omarchy](https://omarchy.org) / Quickshell. List density and panel patterns follow [Pulse](https://github.com/nixfred/pulse) by Fred Nix. Discover and glance UX are Lanarchy’s own.

MIT — see [LICENSE](LICENSE).

Listed via the [Omarchy plugin marketplace](https://omarchyplugins.com) submit form once this repo is public.
