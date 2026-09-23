<div align="center">

<img src="docs/screenshots/map-1.0.0.png" width="900" alt="LANarchy map: eight machines in a row, each wired down into its row lane and out through the gateway to the internet">

# LANarchy

**Your homelab as a map in the Omarchy bar — who is up, what it runs, and how much traffic is actually moving.**

No typing IPs. Search the network, add boxes from UniFi / mDNS, and every name sticks to its hardware rather than its address.

[![Omarchy](https://img.shields.io/badge/Omarchy-plugin-00d3f2?style=flat-square)](https://omarchy.org)
[![Quickshell](https://img.shields.io/badge/Quickshell-QML-5e81ac?style=flat-square)](https://quickshell.org)
[![Version](https://img.shields.io/badge/version-1.2.0-4fc9d6?style=flat-square)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-MIT-a3be8c?style=flat-square)](LICENSE)

Plugin id: `nixfred.lanarchy` · Install: `~/.config/omarchy/plugins/nixfred.lanarchy/`  
Repo: [nixfred/LANarchy](https://github.com/nixfred/LANarchy) · Architecture: [`docs/architecture.md`](docs/architecture.md)

*A fork of [Lanarchy](https://github.com/DonnieFi/OmarPlugs) by [Donnie Fiander](https://github.com/DonnieFi), who wrote the original and merged our work upstream through 0.4.0.*

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
<img src="docs/screenshots/list-1.0.0.png" width="520" alt="Lanarchy list dash: machines, UniFi, grouped services with colour lights">
</div>

List is the default dash (Pulse-style colour lights). Map is the letterbox of the same mesh. Setup is where you **Search network** instead of hand-entering addresses.

<div align="center">
<img src="docs/screenshots/setup-1.0.0.png" width="520" alt="Lanarchy Setup: Find hosts Search network button and inventory with machine/host pills">
</div>

---

## Install

Plugins run **unsandboxed** inside your long-lived `omarchy-shell` process. Only add repos you trust; read them before enabling ([Omarchy shell plugins](https://omarchy.org)).

```bash
omarchy plugin add https://github.com/DonnieFi/OmarPlugs.git --enable
omarchy bar move nixfred.lanarchy --section right
```

Dev symlink (this checkout is the plugin root):

```bash
ln -sfn /path/to/OmarPlugs ~/.config/omarchy/plugins/nixfred.lanarchy
omarchy-shell shell rescanPlugins
omarchy plugin enable nixfred.lanarchy
```

Validate:

```bash
omarchy plugin validate .
# or
omarchy plugin validate ~/.config/omarchy/plugins/nixfred.lanarchy
```

Open:

```bash
omarchy-shell shell summon nixfred.lanarchy
```

### Optional UniFi

```bash
cp unifi-secrets.json.example ~/.config/omarchy/plugins/nixfred.lanarchy/unifi-secrets.json
# UNIFI_KEY=...   or JSON {"apiKey":"..."}
```

Shipped `inventory.json` is a tiny localhost starter. Use **Setup → Search network** to build your mesh.

`unifi-secrets.json` is gitignored. Never put keys in `inventory.json`. Lanarchy never auto-writes inventory from UniFi — Find hosts only proposes candidates you click to add.

---

## Usage

| Action | How |
|--------|-----|
| Open / close | Click the castle-socket bar icon · Esc closes |
| List / Map | Tabs or `l` / `m` |
| Hide / demote selected card | Detail **Move to LAN** or `h` — card joins the LAN bucket (still probed) |
| Restore to main map | List → **LAN** → **Show** (or **Show all on map**) |
| Animate map traffic | **Flow** tab (map) or `a` — persists as `settings.mapAnimate` |
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

**What makes something a `machine`:** it answers on a login port (22 or 3389), or
mDNS says so. mDNS alone is not enough, because plenty of real boxes never publish
`_ssh` while plenty of appliances publish service records that look host-like.

**+ Add all machines** adds every found `machine` in a single inventory write, which
is the fast way to bootstrap. **+ Add everything** also takes the `host` rows, which
on a busy LAN includes TVs and phones, so it is the deliberate option rather than
the recommended one.

## New device alarm

Lanarchy remembers every MAC it has seen. Hardware that shows up later is
announced once and listed in a **NEW ON YOUR NETWORK** tray with its name,
address, kind and arrival time, with **adopt** and **ignore**.

| Rule | Why |
|------|-----|
| The first run records a baseline silently | Everything is new the first time you look; announcing it all is how a tripwire gets muted on day one |
| A device must be seen twice | A one-off ARP entry is not an arrival |
| Announced exactly once | Repeating it is nagging, not alerting |
| Anything adopted or ignored is dropped | A device you have dealt with is not news |

State lives in `~/.local/state/lanarchy/seen-devices.json`. Disable with
`settings.newDeviceNotify: false`.

---

## Naming

Lanarchy works the name out for you first, from the mDNS host record, reverse DNS,
`hostname -s` over SSH, and UniFi client names when a key is configured. Sonos
rooms, model serials and pairing ids are unpicked into something readable.

When you disagree, rename it: select a card and press **Rename**, or edit **Label**
in Setup. **The name is stored against the MAC, not the address**, because an
address is a DHCP lease and will eventually belong to something else. It applies
everywhere at once: map, list, Setup, detail and notifications. The discovered
name is kept underneath as `discoveredLabel`.

A node with no learnable MAC (routed or off-LAN) anchors to its address instead,
which is the weaker option and the only one available for such a host.

---

## Knowing what a box is

The machine card's top line names the platform instead of repeating the word
"machine". Nothing extra is probed to work it out:

| Source | Gives | Confidence |
|--------|-------|------------|
| `uname -s` over the telemetry hop | exact family plus release | certain |
| Apple mDNS services (`_companion-link`, `_airplay`, ...) | macOS | likely |
| UniFi `os_name` | family | likely |
| ICMP TTL in the ping reply (64 / 128 / 255) | `UNIX` / `WINDOWS` / `APPLIANCE` | guess, shown with `?` |

A TTL of 64 cannot separate Linux from macOS, so it reports `UNIX?` rather than
picking one. With no evidence the card says `MACHINE`.

Set `"role": "router"` on a node to label it `ROUTER` outright.

---

## Configure

Bar widget setting (also in `shell.json` under the widget entry):

| Key | Default | Notes |
|-----|---------|-------|
| `refreshIntervalSec` | `15` | 5–120 |

Inventory and sidecars live under `$XDG_STATE_HOME/lanarchy` (usually
`~/.local/state/lanarchy/`), never inside the plugin directory — the shell watches
that tree and reloads on every write:

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

### Collector pace (laptops)

The collector is gated so a closed panel is not a permanent background scan:

| Setting | Default | Effect |
|---------|---------|--------|
| `homeGatewayMac` | unset | When set and the current default gateway's MAC does not match, probing **pauses**. Keeps your lab's hostnames off coffee-shop wifi. Opening the panel probes anyway |
| `batteryIntervalSec` | `300` | Probe interval on battery while the panel is closed |
| `batteryBackoff` | `true` | `false` restores the old always-on pace |
| `closedIntervalSec` | unset | Explicit panel-closed interval on mains |

Open the panel and you always get the full `probeIntervalSec` pace. A desktop with
no battery and no `homeGatewayMac` behaves exactly as before.

Empty inventory writes are refused. Setup/form saves go through `inventory_cli.py` only when you act — nothing silent.

---

## Remove

```bash
omarchy plugin remove nixfred.lanarchy
```

That disables and removes the plugin checkout/symlink. Your state files under `~/.config/omarchy/plugins/nixfred.lanarchy/` may remain if the folder was not a pure git checkout — delete that directory if you want a clean slate (`inventory.json`, history, secrets, snapshot).

---

## Dependencies

| Need | Required? | Notes |
|------|-----------|-------|
| Omarchy + Quickshell | yes | Bar widget host |
| Python 3 | yes | `probe.py`, `daemon.py`, CLIs |
| `ping`, `curl`, `ip` | yes | Probes / neigh |
| `avahi-browse` | optional | Richer mDNS discover |
| `avahi-resolve-host-name` | optional | Resolves `.local` node names. Without it a `.local` name is left to the system resolver, which only answers mDNS if `nss-mdns` is healthy |
| UniFi OS API key | optional | Named wired machines for Search |
| `iperf3` | optional | Speedtest fallback only if already installed |
| SSH | optional | Machine telemetry / talkers / remote speedtest |

---

## IPC

```bash
omarchy-shell shell summon nixfred.lanarchy
omarchy-shell shell hide nixfred.lanarchy
omarchy-shell shell rescanPlugins
```

One-shot collector (debug):

```bash
cd ~/.config/omarchy/plugins/nixfred.lanarchy
python3 probe.py                 # glance JSON on stdout + snapshot
python3 probe.py wol <id|mac>
python3 probe.py speedtest --id <machine>
python3 inventory_cli.py dump
python3 history_cli.py sparkline --id <node>
```

---

## What the map's motion means

**Flow is measured throughput, not decoration.** Every packet on the map comes from
`rates` (`rx_bps` / `tx_bps`) read off the interface counters:

| You see | It means |
|---------|----------|
| Packets streaming | Real measured bytes. Count and speed both scale with the rate |
| Two lanes, different shades | rx walks the route forwards, tx walks it back |
| A dashed line | **No telemetry for either endpoint.** Not measured, as opposed to idle |
| A solid line with no packets | Measured, and genuinely idle |
| One card selected | Only that host's packets move, so a shared lane can be read per host |
| A dim lane | An endpoint's health check is down. The bytes are still real |

Local telemetry (`/proc/net/dev`, sysfs) needs no SSH and no credentials, so the box
running the panel always has live rates. Other machines need SSH with `BatchMode`;
without it their edges stay still, which is the honest answer rather than a fake pace.

Set `"telemetry": false` on a node to opt it out.

---

## The bar readout

The castle mark carries a number, so the bar answers "is the lab fine?" without a click.
Right-click the icon to pick what it shows:

| Mode | Shows |
|------|-------|
| `downs` (default) | `3↓` when something is down, `2!` when degraded, `✓` when all is well |
| `upfrac` | `12/14` up over tracked |
| `worstrtt` | the slowest node's RTT |
| `hosts` | `↓ down ↑ up`, summed over hosts with telemetry |
| `none` | icon only |

The mark itself still colours green / amber / red and alarms when a node goes down.
The choice is stored in `inventory.json` under `settings.barDisplay`.

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

**LANarchy is a fork of [Lanarchy](https://github.com/DonnieFi/OmarPlugs) by
[Donnie Fiander](https://github.com/DonnieFi).** He wrote the original plugin — the
inventory model, the discover flow, the bar widget and the first topology map — and
everything here is built on it.

Between 0.3.13 and 0.4.0 he reviewed and merged five pull requests from this fork
(runtime state relocation and the probe gate, collector naming / OS identification /
arrivals, the panel map rewrite, the starter telemetry fix, and a release checklist),
then cut 0.4.0 himself. **`donnie-0.4.0` is tagged in this repository** as the exact
point the two trees share, so anything at or before it is his work as much as ours.

From 1.0.0 this fork goes its own way, under its own plugin id (`nixfred.lanarchy`),
so both can be installed side by side.

Built for [Omarchy](https://omarchy.org) / Quickshell. List density and panel patterns
follow [Pulse](https://github.com/nixfred/pulse) by Fred Nix.

MIT — see [LICENSE](LICENSE).
