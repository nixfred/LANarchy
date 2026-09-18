# Lanarchy architecture

Product name **Lanarchy**. Plugin id: `nixfred.lanarchy`.

This document defines the sidecar formats the panel, probe, and daemon share. The bar **glance probe JSON stays unchanged** (`as_of`, `machines`, `lan`, `proxies`).

## Config paths

All user-writable state lives under:

`~/.config/omarchy/plugins/<manifest.id>/` (e.g. `nixfred.lanarchy`)

| File | Purpose |
|------|---------|
| `inventory.json` | v2 node list (source of truth for probes + UI). Untracked; seeded from `inventory.default.json` |
| `history.json` | Ring buffer of RTT samples and status events |
| `notify-state.json` | Ephemeral fail-streak counters (rebuilt from history on miss) |
| `unifi-secrets.json` | Optional UniFi API key or user/pass. Never committed; never copied into inventory |

Repo-shipped `inventory.default.json` is a localhost starter that lives in the plugin install directory (same tree as `Panel.qml`). It is copied to `inventory.json` on first run and never written to again. Sidecars (`snapshot.json`, `history.json`, …) are written next to it.

## Inventory v2 extension

Root shape stays `{ "schemaVersion": 2, "nodes": [...] }`.

Optional **root** fields (v2.1, ignored by readers that only know v2):

```json
{
  "schemaVersion": 2,
  "settings": {
    "failStreakThreshold": 3,
    "unifi": {
      "url": "https://192.168.1.1",
      "site": "default"
    },
    "speedtestUrl": "https://files.lan/"
  },
  "edges": [
    { "from": "deba", "to": "git.lan", "kind": "hub" }
  ],
  "nodes": []
}
```

Per-node optional fields:

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `notify` | boolean | `true` | When `false`, no fail-streak alerts for this id |
| `group` | string | derived from id/dns stem | Collapse host+proxy twins (`bernie`, `ha`) into one service |
| `hidden` | boolean | `false` | Drop from leftover LAN even when the LAN toggle is on |
| `mapBand` | string | derived from `type` | Override band key for letterbox layout (`machine`, `host`, `proxy`, `router`) |
| `mapOrder` | integer | list order | Stable sort within band |
| `mapHidden` | boolean | `false` | Demote from the main map into the LAN bucket (still probed; List → LAN can **Show** it back) |
| `zone` | string | internal | Set `external` to place the service on the map's right-hand WAN rail |
| `httpReachable` | boolean | `false` | HTTP proxy: any response code (incl. 401/404) counts as up — for workers without a public health path |

Normalization rules:

- Missing `notify` → treat as `true`.
- Unknown keys on nodes are preserved through load/save when present in file (forward-compatible).
- `edges[]` is **curated**, not auto N². Empty or missing → derive default hub edges (see below).
- `inventory_cli write`: if the payload omits `settings` / `edges`, existing on-disk values are kept. Send `"settings": {}` (or a partial object) to clear or replace. Empty settings are not written back to disk.
- `settings.mapAnimate`: when `false`, map edges are static Visio elbows; default `true` pulses a dash along those routes.

## Edge graph (v1)

**Purpose:** Letterbox map draws lines between ids. Pulse period uses **RTT at endpoints**, not throughput (link rates when present).

Default derivation when `edges` is absent:

1. Pick **hub** = first `type: proxy` with `check: http` and label containing `caddy`, else first proxy, else first machine id. (Panel map always prefers the Caddy **service group** as the L7 reverse-proxy hub.)
2. For each `machine`, add `{ from: machine.id, to: hub, kind: "hub" }`.
3. For each `host`, add `{ from: hub, to: host.id, kind: "lan" }` (cap at 24 hosts in UI; rest in LAN super-node clip).
4. Optional `edges` in inventory **replace** defaults when non-empty.

Map roles (no extra `dns` designation — DNS is a LAN metric, not a hop):

| Affordance | How |
|------------|-----|
| Reverse proxy hub | Caddy group (`key: caddy`) — service edges terminate here |
| Router | machine with `role: router` / `mapBand: router` (or id/label redUltra) — WAN bar + rates |
| External | node/group `zone: external` |

Edge record:

```json
{ "from": "kiritsuke", "to": "caddy-health", "kind": "hub" }
```

`kind` is cosmetic for stroke style only in v1.

## History ring (`history.json`)

Single JSON file, append-friendly structure, rewritten atomically (`.tmp` + rename) like inventory.

```json
{
  "schemaVersion": 1,
  "retentionHours": 24,
  "probeIntervalSec": 15,
  "series": {
    "deba": {
      "samples": [
        { "ts": "2026-09-16T19:00:00-03:00", "status": "up", "rtt_ms": 1.2 }
      ]
    }
  },
  "events": [
    {
      "ts": "2026-09-16T18:55:00-03:00",
      "id": "deba",
      "from": "up",
      "to": "down"
    }
  ]
}
```

**Retention:** Target ~24h wall clock at the configured probe interval.

- Cap **samples per node** at `max(96, retentionHours * 3600 / probeIntervalSec)` (96 ≈ 24h @ 15s).
- On save, drop oldest samples and events older than `retentionHours`.
- Optional future compaction: merge samples older than 6h into 5-minute buckets (not required for v1 proof).

**Writers:** `probe.py` (or a small `history_cli.py append` invoked from probe after each run) appends one sample per probed machine/host with RTT; proxies append status-only samples (`rtt_ms` omitted).

**Readers:** QML via `python3 history_cli.py sparkline --id deba --n 32` → JSON array of numbers for sparkline; map/detail strip uses last sample status + RTT.

## Notify

**Policy:**

- Fail-streak threshold **N** = `settings.failStreakThreshold` or **3**.
- Consecutive probe results with `status === "down"` for a node id increment streak in `notify-state.json`.
- When streak reaches N and `notify !== false` on that node, emit **one** notification via `omarchy-notification-send`, then set `alerted: true` on that node entry until status returns to `up`.
- Recovery to `up` clears streak and `alerted`.

`notify-state.json`:

```json
{
  "schemaVersion": 1,
  "nodes": {
    "deba": { "downStreak": 2, "alerted": false, "lastStatus": "down" }
  }
}
```

Inventory `notify: false` skips increment and send for that id.

## Glance vs sidecars

| Surface | Contract |
|---------|----------|
| `probe.py` stdout | Three-band glance plus optional `groups`, `quiet_lan`, `quiet_proxies`, `lan_meta`, `unifi` |
| Inventory | Nodes + optional edges/settings/notify/group/hidden |
| History | RTT + transitions |
| Notify state | Streaks only |

Panel merges glance rows with inventory `notify` for toggles in map and Setup.

## Collector daemon

`daemon.py` is the single writer. `fcntl` flock on `.daemon.lock`; loop every 15s calls `run_probe(write_stdout=False)` and atomically replaces `snapshot.json`.

The panel **starts** the daemon on open (idempotent via flock) and **only reads** `snapshot.json` (`FileView` + 2s reload). It does not spawn `probe.py` on a timer. `probe.py` remains the one-shot / `wol` / `speedtest` CLI.

### Probe gate (`gate_lib.py`)

The loop ticks every 2s but only probes when the gate allows it, so opening the
panel takes effect at once instead of waiting out a long backoff:

| Condition | Probe | Discover |
|-----------|-------|----------|
| Panel open, on the home network | `probeIntervalSec` | yes |
| Away from the home gateway | yes, panel open only | **never** |
| Home gateway unknown or unreadable | yes | **never** (fails closed) |
| On battery, panel closed | `batteryIntervalSec` (300s) | no |
| Mains, panel closed | `closedIntervalSec` if set, else `probeIntervalSec` | no |

**Probe and discover are separate decisions.** Probing touches only the addresses
already in the inventory. Discovery sweeps the attached subnet: mDNS, ARP, a TCP
connect to 22 and 3389 on every neighbour, and an SSH attempt on whatever
answers. That is the feature at home and is port-scanning strangers anywhere
else, so it **fails closed**: no known home network means no sweep.

`homeGatewayMac` is adopted on first run (trust on first use), because a gate
that requires the user to look up a MAC before discovery works is a gate nobody
switches on. Every later network is measured against it.

Gateway MAC is cached 30s and battery state 10s so the 2s tick stays cheap.
Unknown gateway (no default route yet) never pauses probing.

### Seeding user state

`inventory.json` is user state and stays untracked. The repo ships
`inventory.default.json`; `plugin_paths.ensure_user_inventory()` copies it on
first run only, and never over an existing file. This keeps `omarchy plugin
update` (a `git pull`) from conflicting with an edited lab.

Edge pulse uses `rx_bps` when present, else endpoint RTT.

## Telemetry

No extra packages. SSH sysfs + `/proc/net/dev` for machines that accept BatchMode; local sysfs for this box; `curl -w` for HTTP proxies; `ip -4 neigh` + DNS timing for the LAN cluster; WoL is a raw UDP magic packet (`probe.py wol <id|mac>`). A machine-row Speedtest runs `probe.py speedtest --id <machine>`. That command measures curl throughput from `settings.speedtestUrl` or `https://files.lan/`, then tries iperf3 via SSH only if that binary is already present. iperf3 is not a dependency. `ss -tunH` socket counts ride the same BatchMode hop. Missing `ss` or SSH omits `talkers` on the machine row.

Ethernet negotiated below 1000 Mbit is `link.grade: degraded` (amber on the dash).

## UniFi

Optional. The collector always tries `GET {settings.unifi.url}/api/system` (no auth) so a Cloud Gateway / UDM shows name + model on the dash. Clients, APs, and switches require credentials in `unifi-secrets.json`:

Dotenv (`UNIFI_KEY=...`) or JSON (`{"apiKey":"..."}`). Cookie login: `UNIFI_USER` / `UNIFI_PASS`. Env fallbacks: `UNIFI_KEY`, `UNIFI_API_KEY`, `UNIFI_USER`, `UNIFI_PASS`, `UNIFI_URL`.

`snapshot.unifi` is `{ok, auth, name, model, mac, devices, clients, discover}`. `discover[]` is candidates only — the collector never writes them into `inventory.json`.
