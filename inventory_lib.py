"""Homelab mesh inventory: dual-read v1→v2 nodes, save v2 only (OmarPlugs-5oy.1)."""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from plugin_paths import atomic_write_json

SCHEMA_VERSION = 2
NODE_TYPES = frozenset({"machine", "host", "proxy"})
PROXY_CHECKS = frozenset({"http", "tcp"})

HERE = Path(__file__).resolve().parent
DEFAULT_INVENTORY = HERE / "inventory.json"  # seed with plugin_paths.ensure_user_inventory()


def slugify(label: str) -> str:
    """Stable id slug from display label (create only; never reshuffle on rename)."""
    s = (label or "").strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = s.strip("-")
    return s or "node"


def _as_str(v: Any) -> str | None:
    if v is None:
        return None
    s = str(v).strip()
    return s or None


def _project_v1_row(entry: dict, node_type: str) -> dict:
    """Project a v1 machines/lan/proxies row onto a v2 node."""
    eid = _as_str(entry.get("id")) or slugify(str(entry.get("label") or entry.get("host") or "node"))
    label = _as_str(entry.get("label")) or eid
    node: dict[str, Any] = {
        "id": eid,
        "type": node_type,
        "label": label,
    }
    if node_type in ("machine", "host"):
        # v1 used `host`; v2 prefers dns and/or ip
        host = _as_str(entry.get("host")) or _as_str(entry.get("dns"))
        ip = _as_str(entry.get("ip"))
        if host:
            node["dns"] = host
        if ip:
            node["ip"] = ip
        elif "ip" not in entry:
            node["ip"] = None
        return node

    # proxy
    check = str(entry.get("check") or "tcp").lower()
    if check not in PROXY_CHECKS:
        check = "tcp"
    node["check"] = check
    if check == "http":
        url = _as_str(entry.get("url"))
        if url:
            node["url"] = url
    else:
        dns = _as_str(entry.get("dns")) or _as_str(entry.get("host"))
        ip = _as_str(entry.get("ip"))
        port = entry.get("port")
        if dns:
            node["dns"] = dns
        if ip:
            node["ip"] = ip
        elif "ip" in entry:
            node["ip"] = None
        if port is not None:
            try:
                node["port"] = int(port)
            except (TypeError, ValueError):
                pass
    return node


def v1_to_nodes(data: dict) -> list[dict]:
    nodes: list[dict] = []
    for row in data.get("machines") or []:
        if isinstance(row, dict):
            nodes.append(_project_v1_row(row, "machine"))
    for row in data.get("lan") or []:
        if isinstance(row, dict):
            nodes.append(_project_v1_row(row, "host"))
    for row in data.get("proxies") or []:
        if isinstance(row, dict):
            nodes.append(_project_v1_row(row, "proxy"))
    return nodes


def normalize_node(raw: dict) -> dict:
    """Normalize one node dict; raises ValueError on hard violations."""
    if not isinstance(raw, dict):
        raise ValueError("node must be an object")
    ntype = str(raw.get("type") or "").strip().lower()
    if ntype not in NODE_TYPES:
        raise ValueError(f"type must be one of {sorted(NODE_TYPES)}")
    label = _as_str(raw.get("label"))
    if not label:
        raise ValueError("label is required")
    nid = _as_str(raw.get("id")) or slugify(label)
    node: dict[str, Any] = {"id": nid, "type": ntype, "label": label}
    if raw.get("notify") is False:
        node["notify"] = False
    order = raw.get("mapOrder")
    if order is not None:
        try:
            node["mapOrder"] = int(order)
        except (TypeError, ValueError):
            pass
    band = _as_str(raw.get("mapBand"))
    if band:
        node["mapBand"] = band
    zone = _as_str(raw.get("zone"))
    if zone:
        node["zone"] = zone.lower()
    if raw.get("httpReachable") is True:
        node["httpReachable"] = True
    group = _as_str(raw.get("group"))
    if group:
        node["group"] = slugify(group)
    if raw.get("hidden") is True:
        node["hidden"] = True
    if raw.get("mapHidden") is True:
        node["mapHidden"] = True

    dns = _as_str(raw.get("dns")) or _as_str(raw.get("host"))
    ip = _as_str(raw.get("ip"))

    if ntype in ("machine", "host"):
        if not dns and not ip:
            raise ValueError(f"{ntype} needs dns and/or ip")
        if dns:
            node["dns"] = dns
        node["ip"] = ip  # may be None
        _preserve_extras(raw, node)
        return node

    check = str(raw.get("check") or "tcp").lower()
    if check not in PROXY_CHECKS:
        raise ValueError("proxy check must be http or tcp")
    node["check"] = check
    if check == "http":
        url = _as_str(raw.get("url"))
        if not url:
            raise ValueError("http proxy needs url")
        node["url"] = url
    else:
        if not dns and not ip:
            raise ValueError("tcp proxy needs dns and/or ip")
        if dns:
            node["dns"] = dns
        if ip is not None or "ip" in raw:
            node["ip"] = ip
        port = raw.get("port")
        if port is None:
            raise ValueError("tcp proxy needs port")
        node["port"] = int(port)
    _preserve_extras(raw, node)
    return node


# Keys owned by normalize_node or mapped aliases. Everything else passes through.
_NORMALIZED_KEYS = frozenset(
    {
        "id",
        "type",
        "label",
        "notify",
        "mapOrder",
        "mapBand",
        "zone",
        "httpReachable",
        "group",
        "hidden",
        "mapHidden",
        "dns",
        "host",
        "ip",
        "check",
        "url",
        "port",
    }
)


def _preserve_extras(raw: dict, node: dict[str, Any]) -> None:
    for key, value in raw.items():
        if key in _NORMALIZED_KEYS or key in node:
            continue
        node[key] = value


def normalize_inventory(data: dict) -> dict:
    """Return canonical v2 inventory {schemaVersion, nodes} plus optional settings/edges."""
    if not isinstance(data, dict):
        raise ValueError("inventory must be an object")
    nodes_in = data.get("nodes")
    if isinstance(nodes_in, list):
        nodes = [normalize_node(n) for n in nodes_in if isinstance(n, dict)]
    else:
        # v1 three-arrays
        nodes = [normalize_node(n) for n in v1_to_nodes(data)]
    out: dict[str, Any] = {"schemaVersion": SCHEMA_VERSION, "nodes": nodes}
    settings = data.get("settings")
    if isinstance(settings, dict) and settings:
        out["settings"] = dict(settings)
    edges = data.get("edges")
    if isinstance(edges, list) and edges:
        out["edges"] = [e for e in edges if isinstance(e, dict)]
    return out


def load_inventory(path: Path | None = None) -> dict:
    """Load inventory file; dual-read v1 or v2. Adds migratedFromV1 when projected."""
    p = Path(path) if path else DEFAULT_INVENTORY
    with p.open(encoding="utf-8") as f:
        raw = json.load(f)
    if not isinstance(raw, dict):
        raise ValueError("inventory root must be an object")

    has_nodes = isinstance(raw.get("nodes"), list)
    has_v1 = any(isinstance(raw.get(k), list) for k in ("machines", "lan", "proxies"))
    migrated_from_v1 = False

    if has_nodes:
        inv = normalize_inventory(raw)
        # still v1 keys present → treat as already on v2 shape if schema says so
        ver = raw.get("schemaVersion") or raw.get("schema_version")
        if ver is None and has_v1:
            migrated_from_v1 = True
    elif has_v1:
        inv = normalize_inventory(raw)
        migrated_from_v1 = True
    else:
        inv = {"schemaVersion": SCHEMA_VERSION, "nodes": []}

    out = dict(inv)
    out["migratedFromV1"] = migrated_from_v1
    out["path"] = str(p)
    return out


def save_inventory(inv: dict, path: Path | None = None) -> Path:
    """Write v2-only inventory (no v1 arrays)."""
    p = Path(path) if path else DEFAULT_INVENTORY
    nodes = inv.get("nodes") if isinstance(inv, dict) else None
    if not isinstance(nodes, list):
        raise ValueError("save requires nodes[]")
    base: dict[str, Any] = {"schemaVersion": SCHEMA_VERSION, "nodes": nodes}
    if isinstance(inv, dict):
        if isinstance(inv.get("settings"), dict):
            base["settings"] = inv["settings"]
        if isinstance(inv.get("edges"), list):
            base["edges"] = inv["edges"]
    normalized = normalize_inventory(base)
    payload: dict[str, Any] = {"schemaVersion": SCHEMA_VERSION, "nodes": normalized["nodes"]}
    if normalized.get("settings"):
        payload["settings"] = normalized["settings"]
    if normalized.get("edges"):
        payload["edges"] = normalized["edges"]
    return atomic_write_json(p, payload)


def nodes_by_type(nodes: list[dict]) -> dict[str, list[dict]]:
    """Group nodes for glance: machine→machines, host→lan, proxy→proxies."""
    machines: list[dict] = []
    lan: list[dict] = []
    proxies: list[dict] = []
    for n in nodes or []:
        t = str(n.get("type") or "")
        if t == "machine":
            machines.append(n)
        elif t == "host":
            lan.append(n)
        elif t == "proxy":
            proxies.append(n)
    return {"machines": machines, "lan": lan, "proxies": proxies}


def probe_target(node: dict) -> tuple[str | None, int | None, str | None]:
    """Return (host_or_dns, port, url) preferred for probing. Prefer dns over ip."""
    ntype = str(node.get("type") or "")
    if ntype == "proxy":
        check = str(node.get("check") or "tcp").lower()
        if check == "http":
            return None, None, _as_str(node.get("url"))
        host = _as_str(node.get("dns")) or _as_str(node.get("ip"))
        port = node.get("port")
        try:
            port_i = int(port) if port is not None else None
        except (TypeError, ValueError):
            port_i = None
        return host, port_i, None
    host = _as_str(node.get("dns")) or _as_str(node.get("ip"))
    return host, None, None


def node_display_target(node: dict) -> str:
    """Muted right-side text for setup list."""
    ntype = str(node.get("type") or "")
    if ntype == "proxy":
        check = str(node.get("check") or "")
        if check == "http":
            return _as_str(node.get("url")) or ""
        host = _as_str(node.get("dns")) or _as_str(node.get("ip")) or ""
        port = node.get("port")
        if host and port is not None:
            return f"{host}:{port}"
        return host
    parts = []
    dns = _as_str(node.get("dns"))
    ip = _as_str(node.get("ip"))
    if dns:
        parts.append(dns)
    if ip:
        parts.append(ip)
    return " · ".join(parts)
