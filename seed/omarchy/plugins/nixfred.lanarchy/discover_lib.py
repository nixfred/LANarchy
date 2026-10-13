"""Slow discover job: mDNS + ARP neigh candidates for Setup. Reads only; probe puts the list in snapshot.discover[].

Candidate: {source: mdns|neigh|unifi, type: machine|host, label, host, ip, mac, services[]}
"""
from __future__ import annotations

import re
import socket
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any

from history_lib import node_meta
from naming_lib import friendly_name
from telemetry_lib import neighbors
from unifi_lib import fmt_mac, known_from

AVAHI_CMD = ["avahi-browse", "-a", "-t", "-r", "-p", "-k"]
AVAHI_TIMEOUT_S = 20.0
MIN_INTERVAL_S = 60.0
MAX_CANDIDATES = 48

# mDNS service type → what it says about the box. machine: something you ssh into. host: a service endpoint.
# noise: pairing chatter from phones/TVs/laptops whose instance names are opaque ids, never a label.
SERVICE_ROLE = {
    "_workstation._tcp": "machine",
    "_ssh._tcp": "machine",
    "_sftp-ssh._tcp": "machine",
    "_http._tcp": "host",
    "_https._tcp": "host",
    "_home-assistant._tcp": "host",
    "_esphomelib._tcp": "host",
    "_printer._tcp": "host",
    "_ipp._tcp": "host",
    "_smb._tcp": "host",
    "_androidtvremote2._tcp": "host",
    "_companion-link._tcp": "noise",
    "_airplay._tcp": "noise",
    "_raop._tcp": "noise",
    "_googlecast._tcp": "noise",
    "_googcrossdevice._tcp": "noise",
    "_ghp._tcp": "noise",
    "_meshcop._udp": "noise",
}
LABEL_ORDER = ("machine", "host", None)

# An mDNS instance name that is a bare opaque id (Chromecast / AirPlay / Matter
# pairing ids) is never a useful label, so such a candidate is dropped.
_OPAQUE_LABEL = re.compile(
    r"""^(?:
        [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}  # uuid
      | [0-9a-f]{12,}                                                  # long hex blob
      | [0-9a-f]{8}(?:-[0-9a-f]{4,})+                                  # dashed hex id
    )$""",
    re.I | re.X,
)
REVERSE_DNS_WORKERS = 16
REVERSE_DNS_TIMEOUT_S = 1.0

# A "machine" is something you log into. mDNS cannot tell you that: plenty of
# real boxes never publish _ssh (Arch and Omarchy do not by default), while a
# Sonos speaker happily publishes _smb-adjacent services. Asking the port
# directly is one socket and answers the actual question.
LOGIN_PORTS = (22, 3389)          # ssh, rdp
LOGIN_PROBE_TIMEOUT_S = 0.6
LOGIN_PROBE_WORKERS = 24

# Asking a box its own name is the most reliable name there is, and it is free
# for any host whose key we already hold. Discovery must not write to
# known_hosts while scanning a whole LAN, hence the throwaway known-hosts file.
SSH_NAME_TIMEOUT_S = 3.0
SSH_NAME_OPTS = (
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=2",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
)

_ESCAPE = re.compile(r"\\(\d{3})")
_BRACKET_MAC = re.compile(r"\s*\[([0-9a-fA-F:]{17})\]\s*$")

_cache: dict[str, Any] = {"ts": float("-inf"), "rows": []}

# Port verdicts and SSH names are properties of a box, not of a scan, so they are
# remembered for much longer than the candidate list itself. Without this, a
# whole-LAN login probe plus SSH naming re-runs every discover and adds seconds
# to a probe cycle.
ENRICH_TTL_S = 900.0
_login_cache: dict[str, tuple[float, bool]] = {}
_name_cache: dict[str, tuple[float, str | None]] = {}


def _fresh(entry: tuple[float, Any] | None, now: float) -> bool:
    return entry is not None and (now - entry[0]) < ENRICH_TTL_S


def reset_enrich_cache() -> None:
    _login_cache.clear()
    _name_cache.clear()


def unescape(name: str) -> str:
    return _ESCAPE.sub(lambda m: chr(int(m.group(1))), name).replace("\\.", ".").replace("\\\\", "\\")


def parse_avahi(text: str) -> list[dict]:
    """Resolved IPv4 lines of `avahi-browse -a -t -r -p -k` → [{name, type, host, ip}]."""
    rows: list[dict] = []
    for line in text.splitlines():
        parts = line.split(";", 9)
        if len(parts) < 8 or parts[0] != "=" or parts[2] != "IPv4":
            continue
        rows.append(
            {
                "name": unescape(parts[3]),
                "type": parts[4],
                "host": unescape(parts[6]).removesuffix(".local") or None,
                "ip": parts[7] or None,
            }
        )
    return rows


def mdns_candidates(records: list[dict], mac_by_ip: dict[str, str]) -> list[dict]:
    groups: dict[str, list[dict]] = {}
    for r in records:
        if r.get("ip"):
            groups.setdefault(r["ip"], []).append(r)
    out: list[dict] = []
    for ip, recs in groups.items():
        services = list(dict.fromkeys(r["type"] for r in recs))
        roles = {SERVICE_ROLE.get(s) for s in services}
        mapped = {SERVICE_ROLE[s] for s in services if s in SERVICE_ROLE}
        if mapped and mapped <= {"noise"}:
            continue
        pick = next((r for role in LABEL_ORDER for r in recs if SERVICE_ROLE.get(r["type"]) == role), None)
        label = pick["name"] if pick else None
        host = (pick or {}).get("host") or next((r["host"] for r in recs if r.get("host")), None)
        mac = mac_by_ip.get(ip)
        for r in recs:
            m = _BRACKET_MAC.search(r["name"])
            if m and not mac:
                mac = fmt_mac(m.group(1))
        clean_label = _BRACKET_MAC.sub("", label) if label else (host or ip)
        if is_opaque_label(clean_label):
            # A pairing id is never a label. Fall back to the resolved host name,
            # and drop the candidate only when there is nothing else to call it.
            if not host:
                continue
            clean_label = host
        out.append(
            {
                "source": "mdns",
                "type": "machine" if "machine" in roles else "host",
                "label": clean_label,
                "host": host,
                "ip": ip,
                "mac": mac,
                "services": services,
            }
        )
    return out


_BARE_IPV4 = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")


def is_meaningless_label(label: str | None) -> bool:
    """An opaque pairing id or a bare address: identifies, but does not inform."""
    s = str(label or "").strip()
    return bool(s) and (is_opaque_label(s) or bool(_BARE_IPV4.match(s)))


def is_opaque_label(label: str | None) -> bool:
    """True for pairing ids that should never become a node label."""
    s = str(label or "").strip()
    return bool(s) and bool(_OPAQUE_LABEL.match(s))


# systemd-resolved answers some addresses with synthetic names that are not hosts.
SYNTHETIC_PTR = frozenset({"_gateway", "localhost", "localhost.localdomain", "_outbound"})


def reverse_dns(ip: str, resolver=socket.gethostbyaddr) -> str | None:
    """PTR lookup for one address. Short name only, no trailing dot.

    Synthetic answers (`_gateway`, `localhost`) are rejected: they are stub names
    from the local resolver, not something you would put in an inventory.
    """
    try:
        name = resolver(str(ip))[0]
    except (OSError, UnicodeError, IndexError):
        return None
    name = str(name or "").strip().rstrip(".")
    if not name or name.lower() in SYNTHETIC_PTR or name.startswith("_"):
        return None
    if name == str(ip):
        return None
    return name


def reverse_dns_map(ips: list[str], resolver=socket.gethostbyaddr) -> dict[str, str]:
    """PTR lookups in parallel. An address that does not resolve is simply absent."""
    if not ips:
        return {}
    original = socket.getdefaulttimeout()
    socket.setdefaulttimeout(REVERSE_DNS_TIMEOUT_S)
    try:
        with ThreadPoolExecutor(max_workers=min(REVERSE_DNS_WORKERS, len(ips))) as pool:
            names = list(pool.map(lambda ip: reverse_dns(ip, resolver), ips))
    finally:
        socket.setdefaulttimeout(original)
    return {ip: name for ip, name in zip(ips, names) if name}


def neigh_candidates(
    neigh: list[dict], taken_ips: set[str], names: dict[str, str] | None = None
) -> list[dict]:
    """ARP neighbours as candidates. A PTR name, when the LAN has one, beats a bare IP
    as both the label and the dns field, so Setup offers a name instead of an address.
    """
    names = names or {}
    rows = []
    for n in neigh:
        if n["ip"] in taken_ips:
            continue
        fqdn = names.get(n["ip"])
        short = fqdn.split(".")[0] if fqdn else None
        rows.append(
            {
                "source": "neigh",
                "type": "host",
                "label": short or n["ip"],
                "host": fqdn,
                "ip": n["ip"],
                "mac": n["mac"],
                "services": [],
            }
        )
    return rows


def port_open(ip: str, port: int, timeout_s: float = LOGIN_PROBE_TIMEOUT_S) -> bool:
    try:
        with socket.create_connection((str(ip), int(port)), timeout=timeout_s):
            return True
    except (OSError, ValueError, OverflowError):
        return False


def has_login_port(ip: str) -> bool:
    """True when the address accepts ssh or rdp: a box someone logs into."""
    for port in LOGIN_PORTS:
        if port_open(ip, port):
            return True
    return False


def ssh_hostname(ip: str) -> str | None:
    """`hostname -s` over SSH, for a box we already have a key for.

    BatchMode means no prompt and a fast failure when we do not, so this costs a
    refused connection for strangers and yields a real name for our own fleet.
    """
    try:
        proc = subprocess.run(
            ["ssh", *SSH_NAME_OPTS, str(ip), "hostname -s"],
            capture_output=True, text=True, timeout=SSH_NAME_TIMEOUT_S, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    name = (proc.stdout or "").strip().splitlines()
    if not name:
        return None
    short = name[0].strip()
    if not short or " " in short or is_opaque_label(short):
        return None
    return short


def name_by_ssh(rows: list[dict]) -> list[dict]:
    """Fill in host names for login-capable candidates that still have none."""
    now = time.monotonic()
    candidates = [
        r for r in rows
        if r.get("login") and r.get("ip") and not str(r.get("host") or "").strip()
    ]

    targets: list[dict] = []
    resolved: list[tuple[dict, str | None]] = []
    for row in candidates:
        hit = _name_cache.get(str(row["ip"]))
        if _fresh(hit, now):
            resolved.append((row, hit[1]))
        else:
            targets.append(row)

    if targets:
        with ThreadPoolExecutor(max_workers=min(LOGIN_PROBE_WORKERS, len(targets))) as pool:
            names = list(pool.map(lambda r: ssh_hostname(str(r["ip"])), targets))
        for row, name in zip(targets, names):
            _name_cache[str(row["ip"])] = (now, name)
            resolved.append((row, name))

    for row, name in resolved:
        if not name:
            continue
        row["host"] = name
        # A bare address is not a label once the box has told us its name.
        if is_meaningless_label(str(row.get("label") or "")):
            row["label"] = name
    return rows


def promote_logins(rows: list[dict]) -> list[dict]:
    """Reclassify candidates as `machine` when they answer on a login port.

    Runs once per Search, in parallel, only for rows not already machines and
    only for rows that have an address. Leaves everything else untouched, so a
    speaker that answers nothing stays a host.
    """
    now = time.monotonic()
    candidates = [r for r in rows if str(r.get("type") or "") != "machine" and r.get("ip")]

    # Serve what we already know, probe only the rest.
    fresh: list[dict] = []
    for row in candidates:
        hit = _login_cache.get(str(row["ip"]))
        if _fresh(hit, now):
            if hit[1]:
                row["type"] = "machine"
                row["login"] = True
        else:
            fresh.append(row)

    if fresh:
        with ThreadPoolExecutor(max_workers=min(LOGIN_PROBE_WORKERS, len(fresh))) as pool:
            verdicts = list(pool.map(lambda r: has_login_port(str(r["ip"])), fresh))
        for row, is_login in zip(fresh, verdicts):
            _login_cache[str(row["ip"])] = (now, is_login)
            if is_login:
                row["type"] = "machine"
                row["login"] = True
    return rows


def known_targets(nodes: list[dict], hist: dict) -> dict[str, set[str]]:
    """Inventory dns/ip/mac plus history remembered on machines (not reverse-proxied hosts)."""
    known = known_from(nodes)
    for n in nodes:
        if str(n.get("type") or "") != "machine":
            continue
        meta = node_meta(hist, str(n.get("id") or ""))
        if meta.get("ip"):
            known["ips"].add(str(meta["ip"]))
        if meta.get("mac"):
            known["macs"].add(fmt_mac(str(meta["mac"])) or "")
    known["macs"].discard("")
    return known


def is_known(c: dict, known: dict[str, set[str]]) -> bool:
    if c.get("ip") and c["ip"] in known["ips"]:
        return True
    if c.get("mac") and c["mac"] in known["macs"]:
        return True
    for name in (c.get("host"), c.get("label")):
        n = str(name or "").strip().lower().removesuffix(".local")
        if n and (n in known["hosts"] or n.split()[0] in known["hosts"]):
            return True
    return False


def same_device(a: dict, b: dict) -> bool:
    # A multi-homed box (wifi + ethernet) answers on two IPs with two MACs but one
    # host name, so the name is checked before the MACs. Otherwise it is offered
    # twice and lands in the inventory twice.
    ah, bh = str(a.get("host") or "").lower(), str(b.get("host") or "").lower()
    if ah and bh:
        return ah == bh
    if a.get("mac") and b.get("mac"):
        return a["mac"] == b["mac"]
    return bool(a.get("ip")) and a.get("ip") == b.get("ip")


def merge_discover(*lists: list[dict], known: dict[str, set[str]]) -> list[dict]:
    """Union of candidate lists minus inventory, deduped by mac/host/ip.

    UniFi wired machines win over mDNS/neigh for the same device; machines list before hosts.
    """
    out: list[dict] = []
    for c in (x for lst in lists for x in lst):
        if is_known(c, known):
            continue
        dup = next((o for o in out if same_device(o, c)), None)
        if dup is None:
            out.append(dict(c))
            continue
        # Prefer machine over host; prefer unifi source for label/mac.
        if str(c.get("type") or "") == "machine" and str(dup.get("type") or "") != "machine":
            for key, val in c.items():
                if val is not None and val != "":
                    dup[key] = val
            continue
        if str(c.get("source") or "") == "unifi" and str(dup.get("source") or "") != "unifi":
            for key in ("label", "mac", "ip", "host", "kind", "wireless"):
                if c.get(key) is not None and c.get(key) != "":
                    dup[key] = c[key]
            if c.get("type"):
                dup["type"] = c["type"]
            continue
        for key in ("host", "ip", "mac", "label"):
            if not dup.get(key) and c.get(key):
                dup[key] = c[key]
    out.sort(key=lambda r: (0 if str(r.get("type") or "") == "machine" else 1, str(r.get("label") or "").lower()))
    return out[:MAX_CANDIDATES]


def collect_discover() -> list[dict]:
    """mDNS + neigh candidates, re-scanned at most every MIN_INTERVAL_S. Soft-fails to neigh-only without avahi."""
    now = time.monotonic()
    if now - _cache["ts"] < MIN_INTERVAL_S:
        return _cache["rows"]
    text = ""
    try:
        text = subprocess.run(AVAHI_CMD, capture_output=True, text=True, timeout=AVAHI_TIMEOUT_S).stdout
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass
    neigh = neighbors()
    mdns = mdns_candidates(parse_avahi(text), {n["ip"]: n["mac"] for n in neigh})
    taken = {c["ip"] for c in mdns}
    names = reverse_dns_map([n["ip"] for n in neigh if n["ip"] not in taken])
    rows = name_by_ssh(promote_logins(mdns + neigh_candidates(neigh, taken, names)))
    # Give every candidate a name a person would use, keeping the identifier it
    # came from for the detail view.
    for row in rows:
        pretty = friendly_name(
            label=row.get("label"), host=row.get("host"), ip=row.get("ip"),
            mac=row.get("mac"), services=row.get("services"),
        )
        row["label"] = pretty["name"]
        if pretty["kind"]:
            row["deviceKind"] = pretty["kind"]
        if pretty["raw"]:
            row["identifier"] = pretty["raw"]
        if pretty["randomized"]:
            row["randomizedMac"] = True
    _cache.update(ts=now, rows=rows)
    return rows
