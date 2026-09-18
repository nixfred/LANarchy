#!/usr/bin/env python3
"""Live homelab mesh projection. Glance JSON unchanged: {as_of, machines, lan, proxies}."""
from __future__ import annotations

import json
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from discover_lib import collect_discover, known_targets, merge_discover
from history_lib import (
    flap_counts,
    recent_events,
    sparkline_batch,
    append_probe_sample,
    last_counters,
    load_history,
    node_meta,
    save_history,
    set_last_counters,
    set_node_meta,
)
from groups_lib import attach_status, group_nodes, leftover_rows
from inventory_lib import (
    ignore_key,
    ignored_keys,
    load_inventory,
    name_overrides,
    probe_fallback_host,
    probe_target,
)
from naming_lib import apply_name, name_key
from notify_lib import process_probe_glance
from os_lib import identify
from seen_lib import load_ledger, observe, prune, recent_arrivals, save_ledger
from plugin_paths import (
    atomic_write_json,
    ensure_user_inventory,
    load_json_or,
    probe_lock,
    snapshot_path,
)
from unifi_lib import collect_unifi, fmt_mac
from speedtest_lib import resolve_speedtest_url, run_speedtest
from telemetry_lib import (
    local_addresses,
    local_macs,
    neighbors,
    collect_machine,
    dns_time_ms,
    http_timing,
    link_grade,
    local_addresses,
    local_macs,
    neighbors,
    default_gateway,
    primary_link,
    rates_from,
    resolve_ipv4,
    send_wol,
    tcp_timing,
)

HERE = Path(__file__).resolve().parent
PING_TIMEOUT_S = 1.5
HTTP_TIMEOUT_S = 2.0
# A stable, unauthenticated anycast address: "is the internet reachable".
WAN_PROBE_HOST = "1.1.1.1"


def inventory_file() -> Path:
    return ensure_user_inventory()


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def ping_host(host: str) -> tuple[str, float | None, int | None]:
    """ICMP ping → (status, rtt_ms, ttl). unknown if probe can't run or DNS misses.

    The TTL is free here (it is in the reply line we already parse) and is the
    cheapest OS family hint there is: 64 unix, 128 windows, 255 appliance.
    """
    if not host:
        return "unknown", None, None
    try:
        proc = subprocess.run(
            ["ping", "-c", "1", "-W", "1", host],
            capture_output=True,
            text=True,
            timeout=PING_TIMEOUT_S + 1.0,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return "unknown", None, None
    out = (proc.stdout or "") + (proc.stderr or "")
    low = out.lower()
    if any(s in low for s in ("name or service not known", "temporary failure", "unknown host", "cannot resolve")):
        return "unknown", None, None
    if proc.returncode != 0:
        return "down", None, None
    ttl = None
    mt = re.search(r"\bttl[=\s]*(\d{1,3})", out, re.I)
    if mt:
        try:
            ttl = int(mt.group(1))
        except ValueError:
            ttl = None
    m = re.search(r"time[=<]([0-9.]+)\s*ms", out, re.I)
    if not m:
        return "up", None, ttl
    try:
        return "up", float(m.group(1)), ttl
    except ValueError:
        return "up", None, ttl


def check_tcp(host: str, port: int) -> str:
    if not host or not port:
        return "down"
    try:
        with socket.create_connection((host, int(port)), timeout=HTTP_TIMEOUT_S):
            return "up"
    except OSError:
        return "down"


def check_http(url: str) -> str:
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            return "up" if 200 <= int(resp.status) < 400 else "down"
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError, ValueError):
        return "down"


def probe_rtt_node(node: dict) -> dict:
    host, _port, _url = probe_target(node)
    host = host or ""
    status, rtt, ttl = ping_host(host)
    if status == "unknown":
        # The dns name did not resolve. We stored an address for exactly this
        # case, so use it rather than reporting a box we can reach as unknown.
        fallback = probe_fallback_host(node)
        if fallback:
            alt_status, alt_rtt, alt_ttl = ping_host(fallback)
            if alt_status != "unknown":
                host, status, rtt, ttl = fallback, alt_status, alt_rtt, alt_ttl
    row = {
        "id": str(node.get("id") or host),
        "label": str(node.get("label") or node.get("id") or host),
        "host": host,
        "status": status,
        "rtt_ms": rtt,
    }
    if ttl is not None:
        row["ttl"] = ttl
    return row


def probe_machine_node(node: dict, hist: dict, ts_now: float) -> dict:
    """Ping plus SSH/local telemetry: link speed, throughput delta, uptime."""
    row = probe_rtt_node(node)
    if row["status"] != "up" or node.get("telemetry") is False:
        # No telemetry hop, so TTL (when the host answered at all) is all there is.
        row["os"] = identify(
            ttl=row.get("ttl"), services=node.get("services"), role=node.get("role")
        )
        return row
    report = collect_machine(row["host"], node.get("sshUser"))
    if not report:
        row["os"] = identify(
            ttl=row.get("ttl"), services=node.get("services"), role=node.get("role")
        )
        return row
    link = primary_link(report)
    if link:
        row["link"] = {
            "iface": link["iface"],
            "speed_mbit": link["speed_mbit"],
            "duplex": link["duplex"],
            "kind": link["kind"],
            "grade": link_grade(link),
        }
    if report.get("uptime_s") is not None:
        row["uptime_s"] = report["uptime_s"]
    if report.get("talkers"):
        row["talkers"] = report["talkers"]
    prev = last_counters(hist, row["id"])
    rates = rates_from(prev, prev.get("ts_epoch") if prev else None, report, ts_now)
    if rates:
        row["rates"] = rates
    row["_counters"] = {"rx_bytes": report.get("rx_bytes"), "tx_bytes": report.get("tx_bytes"), "ts_epoch": ts_now}
    row["os"] = identify(
        uname=report.get("uname_s"),
        ttl=row.get("ttl"),
        services=node.get("services"),
        role=node.get("role"),
    )
    if report.get("uname_r"):
        row["os"]["release"] = report["uname_r"]
    return row


def probe_proxy_node(node: dict) -> dict:
    check = str(node.get("check") or "tcp").lower()
    label = str(node.get("label") or node.get("id") or "proxy")
    pid = str(node.get("id") or label)
    host, port, url = probe_target(node)
    row = {"id": pid, "label": label, "check": check if check in ("http", "tcp") else "tcp"}
    zone = str(node.get("zone") or "").strip().lower()
    if zone:
        row["zone"] = zone
    if check == "http":
        if not url:
            row["status"] = "unknown"
            return row
        # Prefer explicit host; else parse from URL for DNS health.
        if not host:
            try:
                from urllib.parse import urlparse

                host = urlparse(url).hostname
            except Exception:
                host = None
        if host and resolve_ipv4(host) is None:
            row["status"] = "unknown"
            return row
        timing = http_timing(url or "")
        code = timing.get("http_code")
        # Cloud edges often answer 401/404 without a public health path — treat
        # any HTTP response as up when httpReachable is set on the inventory node.
        if node.get("httpReachable") is True:
            row["status"] = "up" if code is not None else "down"
        else:
            row["status"] = "up" if code and 200 <= int(code) < 400 else "down"
        if timing:
            row["connect_ms"] = timing["connect_ms"]
            row["ttfb_ms"] = timing["ttfb_ms"]
            row["http_code"] = code
        return row
    if not host:
        row["status"] = "unknown"
        return row
    # DNS miss → unknown (same as ICMP); do not advance fail-streak.
    if resolve_ipv4(host) is None:
        row["status"] = "unknown"
        return row
    ms = tcp_timing(host or "", int(port or 0))
    row["status"] = "up" if ms is not None else "down"
    if ms is not None:
        row["connect_ms"] = ms
    return row


def lan_meta(nodes: list[dict], hist: dict, ts_now: float) -> dict:
    """Neighbor discovery + DNS health for the LAN cluster card.

    Known set matches discover: inventory ip/mac plus history remembered while up.
    Do not require live DNS resolve — a blip must not mark inventory hosts unknown.
    """
    neigh = neighbors()
    known = known_targets(nodes, hist)
    unknown = []
    for r in neigh:
        ip = str(r.get("ip") or "")
        mac = fmt_mac(str(r.get("mac") or "")) or ""
        if ip and ip in known["ips"]:
            continue
        if mac and mac in known["macs"]:
            continue
        unknown.append(r)
    dns_ms = None
    sample = next((str(n.get("dns")) for n in nodes if n.get("type") == "host" and n.get("dns")), None)
    if sample:
        dns_ms = dns_time_ms(sample)
    return {
        "neighbors": len(neigh),
        "unknown": len(unknown),
        "unknown_hosts": unknown[:8],
        "dns_ms": dns_ms,
        "dns_probe": sample,
    }


def remember_macs(hist: dict, rows: list[dict]) -> None:
    """Capture MAC per node while it is up so Wake-on-LAN can target it later."""
    by_ip = {r["ip"]: r["mac"] for r in neighbors()}
    for row in rows:
        ip = resolve_ipv4(str(row.get("host") or ""))
        mac = by_ip.get(ip or "")
        if mac:
            set_node_meta(hist, row["id"], {"mac": mac, "ip": ip})


def cmd_wol(target: str) -> int:
    """Wake a machine by inventory id or MAC."""
    mac = str(target or "").strip()
    if ":" not in mac and "-" not in mac:
        mac = str(node_meta(load_history(), mac).get("mac") or "")
        snap = load_json_or(snapshot_path(), {}) or {}
        for row in snap.get("machines") or []:
            if str(row.get("id") or "") == str(target or "") and row.get("mac"):
                mac = str(row["mac"])
                break
    ok = send_wol(mac)
    print(json.dumps({"ok": ok, "mac": mac}))
    return 0 if ok else 1


def cmd_speedtest(target: str) -> int:
    """One-shot curl throughput, then iperf3 if that binary is already on the host."""
    try:
        inv = load_inventory(inventory_file())
    except Exception as e:
        print(json.dumps({"ok": False, "error": f"inventory: {e}", "method": None}))
        return 1
    url = resolve_speedtest_url(inv)
    host = None
    ssh_user = None
    node_id = str(target or "").strip()
    if node_id:
        for n in inv.get("nodes") or []:
            if str(n.get("id") or "") == node_id:
                host, _port, _url = probe_target(n)
                raw_user = n.get("sshUser")
                ssh_user = str(raw_user) if raw_user else None
                break
        if not host:
            snap = load_json_or(snapshot_path(), {}) or {}
            for row in snap.get("machines") or []:
                if str(row.get("id") or "") == node_id and row.get("host"):
                    host = str(row["host"])
                    break
    result = run_speedtest(url=url, host=host, ssh_user=ssh_user)
    if node_id:
        result["id"] = node_id
    print(json.dumps(result))
    return 0 if result.get("ok") else 1


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "wol":
        return cmd_wol(sys.argv[2] if len(sys.argv) > 2 else "")
    if len(sys.argv) > 1 and sys.argv[1] == "speedtest":
        args = sys.argv[2:]
        target = args[1] if len(args) >= 2 and args[0] == "--id" else (args[0] if args else "")
        return cmd_speedtest(target)
    payload = run_probe(write_stdout=True)
    return 1 if payload.get("error") else 0


def run_probe(*, write_stdout: bool = True, discover: bool = True) -> dict:
    with probe_lock() as acquired:
        if not acquired:
            err = {"error": "another probe is still running"}
            if write_stdout:
                print(json.dumps(err, indent=2))
            return err
        return _run_probe_locked(write_stdout=write_stdout, discover=discover)


def _run_probe_locked(*, write_stdout: bool = True, discover: bool = True) -> dict:
    try:
        inv = load_inventory(inventory_file())
    except Exception as e:
        err = {"error": f"inventory: {e}"}
        if write_stdout:
            print(json.dumps(err, indent=2))
        return err
    nodes = inv.get("nodes") or []
    dash = group_nodes(nodes)
    hist = load_history()
    ts_now = time.time()
    with ThreadPoolExecutor(max_workers=8) as pool:
        machines_f = [pool.submit(probe_machine_node, x, hist, ts_now) for x in dash["machines"]]
        # Hosts and proxies that are service members still need a probe for group lights.
        proxy_nodes = [n for n in nodes if str(n.get("type") or "") == "proxy"]
        host_nodes = [n for n in nodes if str(n.get("type") or "") == "host"]
        all_host_f = [pool.submit(probe_rtt_node, x) for x in host_nodes]
        proxies_f = [pool.submit(probe_proxy_node, x) for x in proxy_nodes]
        meta_f = pool.submit(lan_meta, nodes, hist, ts_now)
        unifi_f = pool.submit(collect_unifi, inv, nodes)
        discover_f = pool.submit(collect_discover) if discover else None
        machines = [f.result() for f in machines_f]
        host_rows = [f.result() for f in all_host_f]
        proxies = [f.result() for f in proxies_f]

        by_node_id = {str(n.get("id") or ""): n for n in nodes if isinstance(n, dict)}

        # A user's name is anchored to hardware, so every row needs its MAC.
        # Inventory nodes rarely carry one, so learn it: the node's own field,
        # then what history remembered, then the current ARP table.
        mac_by_ip = {}
        for entry in neighbors():
            if entry.get("ip") and entry.get("mac"):
                mac_by_ip.setdefault(entry["ip"], entry["mac"])
        for row in machines + host_rows + proxies:
            nid = str(row.get("id") or "")
            node = by_node_id.get(nid) or {}
            mac = node.get("mac") or node_meta(hist, nid).get("mac")
            if not mac:
                mac = mac_by_ip.get(str(node.get("ip") or "")) or mac_by_ip.get(str(row.get("host") or ""))
            if mac:
                row["mac"] = str(mac).lower()
                set_node_meta(hist, nid, {"mac": row["mac"]})
            if node.get("ip") and not row.get("ip"):
                row["ip"] = node["ip"]

        # One place where a user's chosen name is stamped on. Anything shown
        # anywhere passes through here, so a rename follows the device into the
        # map, the list, setup, the detail pane and the notifications.
        chosen_names = name_overrides(inv)
        for row in machines + host_rows + proxies:
            apply_name(row, chosen_names)
        meta = meta_f.result()
        try:
            unifi = unifi_f.result()
        except Exception as e:
            unifi = {"ok": False, "auth": "none", "error": str(e)[:160], "devices": [], "clients": [], "discover": []}
        try:
            found = discover_f.result() if discover_f is not None else []
        except Exception:
            found = []
    # The real next hop, and the internet beyond it. Without these the map has no
    # true structure to draw and invents one.
    gw = default_gateway()
    gateway = None
    wan = None
    if gw and gw.get("ip"):
        gw_status, gw_rtt, gw_ttl = ping_host(gw["ip"])
        gateway = {
            "id": "__gateway__",
            "label": "Gateway",
            "ip": gw["ip"],
            "mac": gw.get("mac"),
            "iface": gw.get("iface"),
            "status": gw_status,
            "rtt_ms": gw_rtt,
        }
        if unifi.get("name"):
            gateway["label"] = str(unifi["name"])
            gateway["model"] = str(unifi.get("model") or "")
        # ICMP alone is not reachability: plenty of networks filter it while
        # everything else works, and reporting that as an outage is a false
        # alarm. A TCP handshake on 443 is the fallback answer.
        wan_status, wan_rtt, _ = ping_host(WAN_PROBE_HOST)
        if wan_status != "up":
            tcp_ms = tcp_timing(WAN_PROBE_HOST, 443)
            if tcp_ms is not None:
                wan_status, wan_rtt = "up", tcp_ms
        wan = {
            "id": "__wan__",
            "label": "Internet",
            "status": wan_status,
            "rtt_ms": wan_rtt,
            "via": gw["ip"],
        }
        # The controller reports the gateway's WAN address. That is the real
        # public IP, unlike the LAN counters that used to be labelled "WAN".
        for dev in unifi.get("devices") or []:
            if str(dev.get("kind") or "") == "gateway" and dev.get("ip"):
                addr = str(dev["ip"])
                if not addr.startswith(("10.", "192.168.", "172.")):
                    wan["public_ip"] = addr
                break
        # NOT "WAN rates". This is the sum of the interface counters on the
        # hosts we can see, which is a different quantity: it counts traffic
        # that never leaves the LAN and misses everything from hosts without
        # telemetry. Nothing here can measure the gateway's WAN interface, so
        # the number is reported as what it actually is and the Internet edge
        # carries no flow at all rather than an invented one.
        monitored = {"rx_bps": 0.0, "tx_bps": 0.0, "measured": False, "hosts": 0}
        for row in machines:
            rates = row.get("rates")
            if not isinstance(rates, dict):
                continue
            monitored["rx_bps"] += float(rates.get("rx_bps") or 0)
            monitored["tx_bps"] += float(rates.get("tx_bps") or 0)
            monitored["hosts"] += 1
            monitored["measured"] = True
        wan["monitored_hosts"] = monitored

    # The gateway has its own node, so it must never also be a client card. A
    # router commonly answers on more than one address (a LAN address plus a
    # management or VLAN one) and discovery reads the extra as an unrelated
    # device, which is how the same box appeared twice.
    gateway_keys: set[str] = set()
    gateway_ips: set[str] = set()
    if gateway:
        if gateway.get("mac"):
            gateway_keys.add("mac:" + str(gateway["mac"]).lower())
        if gateway.get("ip"):
            gateway_ips.add(str(gateway["ip"]))
    for dev in unifi.get("devices") or []:
        if str(dev.get("kind") or "") == "gateway" and dev.get("mac"):
            gateway_keys.add("mac:" + str(dev["mac"]).lower())

    # The network populates the view; the inventory only records your overrides.
    # A discovered box you have not curated still shows up, and a device you
    # dismissed stays dismissed because the dismissal is keyed by hardware.
    candidates = merge_discover(found, unifi.get("discover") or [], known=known_targets(nodes, hist))

    # The controller names its own hardware and states its role. A candidate that
    # matches one by MAC is an access point or a switch, not an anonymous address.
    gear_by_mac = {}
    for dev in unifi.get("devices") or []:
        mac = str(dev.get("mac") or "").lower()
        if mac:
            gear_by_mac[mac] = dev
    ROLE_LABEL = {"ap": "Access Point", "switch": "Switch", "gateway": "Gateway"}
    for cand in candidates:
        dev = gear_by_mac.get(str(cand.get("mac") or "").lower())
        if not dev:
            continue
        if dev.get("name"):
            cand["label"] = str(dev["name"])
        role = ROLE_LABEL.get(str(dev.get("kind") or ""))
        if role:
            cand["deviceKind"] = role
        if dev.get("model"):
            cand["model"] = str(dev["model"])
        cand["type"] = "machine"
        cand["unifiGear"] = True
    dismissed = ignored_keys(inv)
    renamed = name_overrides(inv)
    chosen_names = renamed
    auto_rows: list[dict] = []
    device_rows: list[dict] = []
    for cand in candidates:
        key = ignore_key(cand.get("mac"), cand.get("ip"))
        if key and key in dismissed:
            continue
        # Never a client card for the box that IS the gateway.
        if (key and key in gateway_keys) or str(cand.get("ip") or "") in gateway_ips:
            continue
        row = {
            "id": "auto:" + (key or str(cand.get("ip") or cand.get("label") or "")),
            "label": str(cand.get("label") or cand.get("ip") or "device"),
            "host": str(cand.get("host") or cand.get("ip") or ""),
            "ip": cand.get("ip"),
            "mac": cand.get("mac"),
            "auto": True,
            "source": cand.get("source"),
            "kind": cand.get("deviceKind") or "",
            "identifier": cand.get("identifier") or "",
            "randomizedMac": bool(cand.get("randomizedMac")),
            "services": cand.get("services") or [],
        }
        # Same stamp as every other row, so a renamed box keeps the name
        # discovery found underneath it.
        apply_name(row, renamed)

        if str(cand.get("type") or "") == "machine":
            # A box you can log into earns a place on the map without being
            # curated first.
            status, rtt, ttl = ping_host(row["host"] or str(cand.get("ip") or ""))
            row.update(status=status, rtt_ms=rtt)
            if ttl is not None:
                row["ttl"] = ttl
            row["os"] = identify(ttl=ttl, services=row["services"])
            auto_rows.append(row)
        else:
            # Speakers, TVs and phones are real and are listed, but they do not
            # belong on a topology map, and probing 20 of them every cycle is
            # cost without insight.
            row["status"] = "seen"
            device_rows.append(row)

    # Has this hardware ever been on the network before? Everything observed
    # this pass goes in the ledger; anything whose first sighting is recent and
    # that the user has not already dealt with is an arrival.
    ledger = load_ledger()
    observed = list(candidates) + [r for r in machines + host_rows + proxies if r.get("mac")]
    # What arrived on THIS pass. observe() announces a device once and never
    # again; this is the only thing that may raise a notification.
    announced_now = observe(ledger, observed)
    prune(ledger)
    save_ledger(ledger)

    acknowledged = set(dismissed)
    # The gateway has its own node. A router commonly answers on more than one
    # address (a LAN address and a management or VLAN address), and discovery
    # sees the extra one as an unrelated client, so the same box appeared both as
    # the default gateway and as a machine card.
    acknowledged |= gateway_keys

    # This machine is not a stranger on its own network. A laptop has a MAC per
    # interface, so without this it announces itself every time it switches
    # between wifi and ethernet.
    for own in local_macs():
        acknowledged.add("mac:" + own)
    mine = local_addresses()
    for node in nodes:
        m = str(node.get("mac") or "")
        if m:
            acknowledged.add("mac:" + m.lower())

    def unacknowledged(rows):
        return [
            r for r in rows
            if ("mac:" + str(r.get("mac") or "")) not in acknowledged
            and str(r.get("ip") or "") not in mine
            and str(r.get("ip") or "") not in gateway_ips
        ]

    # Two different lists, which is where this went wrong: the tray is everything
    # that arrived in the last day and is redrawn every probe, while the alert is
    # only what arrived just now. Notifying on the tray meant every device in it
    # was announced again on every single cycle.
    arrivals_now = unacknowledged(recent_arrivals(ledger))
    announced_now = unacknowledged(announced_now)

    by_id: dict[str, dict] = {}
    for row in machines + host_rows + proxies:
        by_id[str(row.get("id") or "")] = row
    quiet_lan, quiet_proxies = leftover_rows(nodes, by_id, dash["grouped_ids"])
    payload = {
        "as_of": now_iso(),
        "machines": machines,
        "lan": quiet_lan,
        "proxies": quiet_proxies,
        "groups": attach_status(dash, by_id),
        "quiet_lan": quiet_lan,
        "quiet_proxies": quiet_proxies,
        "lan_meta": meta,
        "unifi": unifi,
        "discover": candidates,
        "auto": auto_rows,
        "devices": device_rows,
        "ignored_count": len(dismissed),
        "gateway": gateway,
        "wan": wan,
        "sparks": sparkline_batch(
            hist,
            [str(r.get("id") or "") for r in machines + host_rows + proxies]
            + [str(g.get("id") or "") for g in dash.get("services") or []],
        ),
        "new_devices": arrivals_now,
        "new_devices_announce": announced_now,
        "events": recent_events(hist, 6),
        "flaps": flap_counts(hist, 1.0),
    }
    ts = payload["as_of"]
    for row in machines:
        counters = row.pop("_counters", None)
        if counters:
            set_last_counters(hist, row["id"], counters)
    for row in machines + host_rows:
        append_probe_sample(
            hist,
            str(row.get("id") or ""),
            status=str(row.get("status") or "unknown"),
            rtt_ms=row.get("rtt_ms"),
            ts=ts,
            extra={k: row[k] for k in ("rates",) if k in row},
        )
    for row in proxies:
        append_probe_sample(
            hist,
            str(row.get("id") or ""),
            status=str(row.get("status") or "unknown"),
            rtt_ms=row.get("ttfb_ms", row.get("connect_ms")),
            ts=ts,
        )
    remember_macs(hist, [r for r in machines if r.get("status") == "up"])
    # Host rows often resolve through a reverse proxy (Caddy on yanagiba) — do not
    # stamp that box's MAC onto every *.lan service name.
    for row in machines + host_rows:
        meta_row = node_meta(hist, row["id"])
        if meta_row.get("mac"):
            row["mac"] = meta_row["mac"]
    try:
        save_history(hist)
    except OSError:
        pass
    try:
        process_probe_glance(payload)
    except Exception:
        pass
    try:
        atomic_write_json(snapshot_path(), payload, indent=None)
    except OSError:
        pass
    if write_stdout:
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    return payload


if __name__ == "__main__":
    raise SystemExit(main())
