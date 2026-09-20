"""LAN telemetry with no extra packages: SSH sysfs, curl timing, neigh table, DNS, WoL."""
from __future__ import annotations

import os
import re
import socket
import subprocess
import time
from pathlib import Path
from typing import Any

SSH_TIMEOUT_S = 4.0
HTTP_TIMEOUT_S = 4.0
C_LOCALE = dict(os.environ, LC_ALL="C", LANG="C")

# One remote shell prints link lines (L), /proc/net/dev rows (D), uptime (U),
# and ss -tunHn sockets (T). Counts only; no -p, so no extra privilege.
# -n matters: without it ss reverse-resolves every peer, which on a busy box
# outruns SSH_TIMEOUT_S and costs us the entire report, not just the counts.
REMOTE_SCRIPT = r"""
for i in /sys/class/net/*; do
  n=$(basename "$i")
  [ -e "$i/device" ] || continue
  [ "$(cat "$i/carrier" 2>/dev/null)" = 1 ] || continue
  if [ -d "$i/wireless" ]; then
    br=$(iw dev "$n" link 2>/dev/null | sed -n 's/.*tx bitrate: \([0-9.]*\).*/\1/p' | head -1)
    echo "L $n ${br:-0} full wifi"
  else
    echo "L $n $(cat "$i/speed" 2>/dev/null) $(cat "$i/duplex" 2>/dev/null) eth"
  fi
done
tail -n +3 /proc/net/dev | sed 's/^/D /'
sed 's/^/U /' /proc/uptime
echo "O $(uname -s 2>/dev/null) $(uname -r 2>/dev/null)"
if command -v ss >/dev/null 2>&1; then
  ss -tunHn 2>/dev/null | sed 's/^/T /'
fi
true
"""


def _run(args: list[str], timeout: float, stdin: str | None = None) -> str:
    try:
        p = subprocess.run(
            args, capture_output=True, text=True, timeout=timeout, check=False, env=C_LOCALE, input=stdin
        )
        return p.stdout if p.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def default_gateway() -> dict | None:
    """The real next hop for this machine: {ip, mac, iface}.

    Every box on a LAN reaches the internet through this address. Drawing a
    topology without it means inventing one, which is what happens when the hub
    falls back to "the first machine in the list".
    """
    out = _run(["ip", "-4", "route", "show", "default"], 2)
    fields = (out or "").split()
    try:
        ip = fields[fields.index("via") + 1]
    except (ValueError, IndexError):
        return None
    iface = ""
    if "dev" in fields:
        try:
            iface = fields[fields.index("dev") + 1]
        except IndexError:
            iface = ""
    mac = None
    neigh = _run(["ip", "-4", "neigh", "show", ip], 2)
    m = re.search(r"lladdr\s+((?:[0-9a-f]{2}:){5}[0-9a-f]{2})", neigh or "", re.I)
    if m:
        mac = m.group(1).lower()
    return {"ip": ip, "mac": mac, "iface": iface}


def local_addresses() -> set[str]:
    out: set[str] = set()
    try:
        import json

        for entry in json.loads(_run(["ip", "-j", "addr"], 2) or "[]"):
            for a in entry.get("addr_info", []):
                if a.get("local"):
                    out.add(str(a["local"]))
    except (ValueError, TypeError):
        pass
    return out


def local_macs() -> set[str]:
    """Every MAC on this machine, including the interfaces it is not using.

    A laptop with wifi and ethernet is two entries in its own ARP-adjacent view,
    and announcing yourself as a new device on your own network is absurd.
    """
    out: set[str] = set()
    try:
        import json

        for entry in json.loads(_run(["ip", "-j", "link"], 2) or "[]"):
            mac = str(entry.get("address") or "").strip().lower()
            if len(mac) == 17 and mac != "00:00:00:00:00:00":
                out.add(mac)
    except (ValueError, TypeError):
        pass
    return out


def is_local_host(host: str) -> bool:
    if not host:
        return False
    short = host.split(".")[0].lower()
    if short in (socket.gethostname().lower(), "localhost"):
        return True
    try:
        infos = socket.getaddrinfo(host, None)
    except OSError:
        return False
    addrs = {str(i[4][0]) for i in infos}
    return bool(addrs & local_addresses())


def ss_peer_host(peer: str) -> str:
    """Local/peer column from ss: host:port, [v6]:port, or v6:port."""
    peer = (peer or "").strip()
    if peer.startswith("["):
        end = peer.find("]")
        host = peer[1:end] if end > 0 else peer
    else:
        host = peer.rsplit(":", 1)[0] if peer.count(":") == 1 else peer
    return host.split("%")[0]


def parse_ss_talkers(text: str) -> dict[str, Any] | None:
    """ESTAB sockets ranked by remote. None when ss is missing or nothing counts."""
    counts: dict[str, int] = {}
    total = 0
    for raw in (text or "").splitlines():
        line = raw.strip()
        if line.startswith("T "):
            line = line[2:].strip()
        fields = line.split()
        if len(fields) < 6:
            continue
        proto, state, peer = fields[0], fields[1], fields[5]
        if not proto.startswith(("tcp", "udp")):
            continue
        if proto.startswith("tcp") and state != "ESTAB":
            continue
        if peer.startswith("*") or peer.endswith(":*"):
            continue
        host = ss_peer_host(peer)
        if not host or host in ("*", "0.0.0.0", "::"):
            continue
        total += 1
        counts[host] = counts.get(host, 0) + 1
    if total == 0:
        return None
    top = [{"host": h, "count": c} for h, c in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:4]]
    return {"total": total, "top": top}


def parse_machine_report(text: str) -> dict[str, Any]:
    links: list[dict] = []
    counters: dict[str, dict] = {}
    talker_lines: list[str] = []
    uptime = None
    uname_s = ""
    uname_r = ""
    for raw in (text or "").splitlines():
        line = raw.strip()
        if line.startswith("L "):
            parts = line.split()
            if len(parts) >= 5:
                try:
                    speed = float(parts[2])
                except ValueError:
                    speed = 0.0
                links.append(
                    {"iface": parts[1], "speed_mbit": speed if speed > 0 else None, "duplex": parts[3], "kind": parts[4]}
                )
        elif line.startswith("D "):
            body = line[2:]
            name, _, rest = body.partition(":")
            v = rest.split()
            if len(v) >= 16:
                try:
                    counters[name.strip()] = {"rx": int(v[0]), "tx": int(v[8])}
                except ValueError:
                    pass
        elif line.startswith("U "):
            try:
                uptime = float(line.split()[1])
            except (IndexError, ValueError):
                uptime = None
        elif line.startswith("T "):
            talker_lines.append(line)
        elif line.startswith("O "):
            parts = line.split(None, 2)
            if len(parts) >= 2:
                uname_s = parts[1]
                uname_r = parts[2] if len(parts) > 2 else ""
    active = {l["iface"] for l in links}
    rx = sum(c["rx"] for n, c in counters.items() if n in active)
    tx = sum(c["tx"] for n, c in counters.items() if n in active)
    out: dict[str, Any] = {
        "links": links,
        "rx_bytes": rx if active else None,
        "tx_bytes": tx if active else None,
        "uptime_s": uptime,
    }
    if uname_s:
        out["uname_s"] = uname_s
        if uname_r:
            out["uname_r"] = uname_r
    talkers = parse_ss_talkers("\n".join(talker_lines))
    if talkers:
        out["talkers"] = talkers
    return out


def collect_machine(host: str, ssh_user: str | None = None) -> dict[str, Any] | None:
    """Link + counter report for a machine; local sysfs for this box, SSH otherwise."""
    if is_local_host(host):
        text = _run(["bash", "-c", REMOTE_SCRIPT], SSH_TIMEOUT_S)
    else:
        target = f"{ssh_user}@{host}" if ssh_user else host
        text = _run(
            [
                "ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={int(SSH_TIMEOUT_S) - 1}",
                "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR", target, "bash", "-s",
            ],
            SSH_TIMEOUT_S + 1.0,
            stdin=REMOTE_SCRIPT,
        )
    if not text.strip():
        return None
    return parse_machine_report(text)


def primary_link(report: dict | None) -> dict | None:
    if not report:
        return None
    links = report.get("links") or []
    eth = [l for l in links if l.get("kind") == "eth" and l.get("speed_mbit")]
    if eth:
        return max(eth, key=lambda l: l["speed_mbit"])
    return links[0] if links else None


def link_grade(link: dict | None) -> str:
    """ok | degraded | unknown. Ethernet under 1000 Mbit reads as a bad cable or port."""
    if not link or not link.get("speed_mbit"):
        return "unknown"
    if link.get("kind") == "eth" and float(link["speed_mbit"]) < 1000:
        return "degraded"
    return "ok"


def rates_from(prev: dict | None, ts_prev: float | None, report: dict | None, ts_now: float) -> dict | None:
    if not report or not prev or ts_prev is None:
        return None
    dt = ts_now - ts_prev
    if dt <= 0 or report.get("rx_bytes") is None or prev.get("rx_bytes") is None:
        return None
    rx = max(0, report["rx_bytes"] - prev["rx_bytes"]) / dt
    tx = max(0, report["tx_bytes"] - prev["tx_bytes"]) / dt
    return {"rx_bps": rx, "tx_bps": tx}


# Health timing discards the body; still cap so a hostile URL cannot stream forever.
HTTP_TIMING_MAX_BYTES = 1 * 1024 * 1024


def http_timing(url: str) -> dict[str, Any]:
    out = _run(
        [
            "curl",
            "-s",
            "--proto",
            "=http,https",
            "-o",
            "/dev/null",
            "--max-filesize",
            str(HTTP_TIMING_MAX_BYTES),
            "--max-time",
            str(HTTP_TIMEOUT_S),
            "-w",
            "%{http_code} %{time_connect} %{time_starttransfer}",
            url,
        ],
        HTTP_TIMEOUT_S + 1.0,
    )
    parts = out.split()
    if len(parts) != 3:
        return {}
    try:
        code = int(parts[0])
        return {"http_code": code, "connect_ms": float(parts[1]) * 1000, "ttfb_ms": float(parts[2]) * 1000}
    except ValueError:
        return {}


def tcp_timing(host: str, port: int) -> float | None:
    if not host or not port:
        return None
    t = time.perf_counter()
    try:
        with socket.create_connection((host, int(port)), timeout=HTTP_TIMEOUT_S):
            return (time.perf_counter() - t) * 1000
    except OSError:
        return None


def dns_time_ms(name: str) -> float | None:
    t = time.perf_counter()
    try:
        socket.getaddrinfo(name, None, socket.AF_INET)
    except OSError:
        return None
    return (time.perf_counter() - t) * 1000


# Interfaces that are not the network the user means. A container bridge and a
# libvirt bridge each have their own subnet full of neighbours, and treating
# them as "the lab" fills the map with things that are not on the LAN at all.
VIRTUAL_IFACE_PREFIXES = ("docker", "br-", "virbr", "veth", "lxc", "lxd", "podman",
                          "cni", "flannel", "tailscale", "zt", "wg", "tun", "tap")


def is_virtual_iface(name: object) -> bool:
    n = str(name or "").strip().lower()
    return bool(n) and n.startswith(VIRTUAL_IFACE_PREFIXES)


def neighbors(include_virtual: bool = False) -> list[dict]:
    """ARP neighbours on real interfaces.

    Container and hypervisor bridges are excluded: their neighbours are not on
    the network being mapped, and promoting them produced map cards for docker
    and libvirt addresses.
    """
    rows = parse_neigh(_run(["ip", "-j", "-4", "neigh"], 2))
    if include_virtual:
        return rows
    return [r for r in rows if not is_virtual_iface(r.get("iface"))]


def parse_neigh(text: str) -> list[dict]:
    """`ip -j -4 neigh` JSON → [{ip, mac, state}] for entries with a resolved lladdr."""
    import json

    rows: list[dict] = []
    try:
        for r in json.loads(text or "[]"):
            if not r.get("lladdr"):
                continue
            state = r.get("state") or []
            if "FAILED" in state or "INCOMPLETE" in state:
                continue
            rows.append({
                "ip": str(r.get("dst")),
                "mac": str(r["lladdr"]).lower(),
                "state": state[0] if state else "",
                "iface": str(r.get("dev") or ""),
            })
    except (ValueError, TypeError):
        pass
    return rows


def resolve_ipv4(host: str) -> str | None:
    try:
        return socket.getaddrinfo(host, None, socket.AF_INET)[0][4][0]
    except (OSError, IndexError):
        return None


def send_wol(mac: str, broadcast: str = "255.255.255.255", port: int = 9) -> bool:
    hexmac = re.sub(r"[^0-9a-fA-F]", "", mac or "")
    if len(hexmac) != 12:
        return False
    payload = b"\xff" * 6 + bytes.fromhex(hexmac) * 16
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            s.sendto(payload, (broadcast, port))
        return True
    except OSError:
        return False


def fmt_rate(bps: float | None) -> str:
    if bps is None:
        return "—"
    v = float(bps)
    for unit in ("B/s", "kB/s", "MB/s", "GB/s"):
        if v < 1000:
            return f"{v:.0f} {unit}" if unit == "B/s" else f"{v:.1f} {unit}"
        v /= 1000
    return f"{v:.1f} TB/s"
