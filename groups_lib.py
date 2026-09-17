"""Collapse noisy host+proxy twins into service groups (OmarPlugs-5oy.12)."""
from __future__ import annotations

import re
from typing import Any

from inventory_lib import slugify

# Pretty names when the group key would otherwise be a slug.
GROUP_LABELS = {
    "ha": "Home Assistant",
    "bernie": "Bernie",
    "pihole": "Pi-hole",
    "caddy": "Caddy",
    "cameras": "Cameras",
    "git": "Git",
    "files": "Files",
    "dockge": "Dockge",
    "search": "Search",
    "omotenashi": "Omotenashi",
    "xmcp": "xMCP",
    "modal": "Modal",
}

# Merge leftover numeric siblings (pihole1 + pihole2 → pihole).
_TRAILING_DIGIT = re.compile(r"^(.*?)(\d+)$")
_SUFFIX = re.compile(r"-(api|ui|web|app|health)$")


def _as_str(v: Any) -> str | None:
    if v is None:
        return None
    s = str(v).strip()
    return s or None


def node_group_key(node: dict) -> str:
    explicit = _as_str(node.get("group"))
    if explicit:
        return slugify(explicit)
    raw = (_as_str(node.get("id")) or _as_str(node.get("dns")) or _as_str(node.get("label")) or "")
    raw = raw.lower()
    raw = re.sub(r"\.lan$", "", raw)
    raw = _SUFFIX.sub("", raw)
    return slugify(raw)


def member_role(node: dict) -> str:
    ntype = str(node.get("type") or "")
    if ntype == "machine":
        return "machine"
    if ntype == "host":
        return "host"
    if str(node.get("check") or "").lower() == "http":
        return "http"
    port = node.get("port")
    if port is not None:
        return str(port)
    return "tcp"


def _collapse_numeric_keys(keys: list[str]) -> dict[str, str]:
    """Map pihole1/pihole2 → pihole when two or more share a stem."""
    buckets: dict[str, list[str]] = {}
    for key in keys:
        m = _TRAILING_DIGIT.match(key)
        if m and m.group(1):
            buckets.setdefault(m.group(1), []).append(key)
    remap = {k: k for k in keys}
    for stem, sibs in buckets.items():
        if len(sibs) >= 2:
            for k in sibs:
                remap[k] = stem
    return remap


def _pretty_label(key: str, members: list[dict]) -> str:
    if key in GROUP_LABELS:
        return GROUP_LABELS[key]
    for n in members:
        label = _as_str(n.get("label")) or ""
        if label and not label.endswith(".lan") and n.get("type") == "host":
            return label
    return key.replace("-", " ").title()


def _is_service(members: list[dict]) -> bool:
    types = {str(n.get("type") or "") for n in members}
    if any(_as_str(n.get("group")) for n in members):
        return True
    if "machine" in types and types <= {"machine"}:
        return False
    if len(members) >= 2:
        return True
    # Lone interesting proxy (Caddy health) stays on the dash.
    return types == {"proxy"}


def group_nodes(nodes: list[dict]) -> dict[str, list]:
    """Partition inventory into machines, services, leftover lan/proxies."""
    raw: dict[str, list[dict]] = {}
    for n in nodes or []:
        if not isinstance(n, dict):
            continue
        raw.setdefault(node_group_key(n), []).append(n)
    remap = _collapse_numeric_keys(list(raw))
    buckets: dict[str, list[dict]] = {}
    for key, members in raw.items():
        buckets.setdefault(remap[key], []).extend(members)

    machines: list[dict] = []
    services: list[dict] = []
    leftover_lan: list[dict] = []
    leftover_proxies: list[dict] = []
    grouped_ids: set[str] = set()

    for key, members in buckets.items():
        if not _is_service(members):
            for n in members:
                t = str(n.get("type") or "")
                if t == "machine":
                    machines.append(n)
                elif t == "host":
                    leftover_lan.append(n)
                elif t == "proxy":
                    leftover_proxies.append(n)
            continue
        # A machine is never absorbed into a service card. Grouping exists to
        # collapse host+proxy twins (`ha.lan` and the `ha` health URL) into one
        # service, but a real box must keep its own row: absorbed ids are
        # excluded from `machines` AND from `leftover_rows` (which only emits
        # hosts and proxies), so the machine would appear nowhere at all. A
        # colliding group key is enough to trigger it, for instance a machine
        # `caddy` beside the proxy `caddy-health`, whose `-health` suffix is
        # stripped to the same key.
        for n in members:
            if str(n.get("type") or "") == "machine":
                machines.append(n)
        grouped_ids.update(
            str(n.get("id") or "")
            for n in members
            if n.get("id") and str(n.get("type") or "") != "machine"
        )
        zones = {
            str(n.get("zone") or "").strip().lower()
            for n in members
            if str(n.get("zone") or "").strip()
        }
        svc: dict[str, Any] = {
            "id": f"svc-{key}",
            "key": key,
            "label": _pretty_label(key, members),
            "kind": "service",
            "member_ids": [str(n.get("id") or "") for n in members if n.get("id")],
            "roles": [member_role(n) for n in members],
        }
        if "external" in zones:
            svc["zone"] = "external"
        services.append(svc)

    services.sort(key=lambda s: (0 if s["key"] == "ha" else 1, s["label"].lower()))
    return {
        "machines": machines,
        "services": services,
        "lan": leftover_lan,
        "proxies": leftover_proxies,
        "grouped_ids": grouped_ids,
    }


def attach_status(dash: dict, by_id: dict[str, dict]) -> list[dict]:
    """Fill live status onto service groups from glance rows."""
    out: list[dict] = []
    for svc in dash.get("services") or []:
        members = []
        up = 0
        down = 0
        metric = None
        for nid, role in zip(svc.get("member_ids") or [], svc.get("roles") or []):
            row = by_id.get(nid) or {}
            status = str(row.get("status") or "unknown")
            if status == "up":
                up += 1
            elif status == "down":
                down += 1
            member = {"id": nid, "role": role, "status": status, "label": str(row.get("label") or nid)}
            for k in ("rtt_ms", "ttfb_ms", "connect_ms", "http_code"):
                if row.get(k) is not None:
                    member[k] = row[k]
            if metric is None and row.get("ttfb_ms") is not None:
                metric = row["ttfb_ms"]
            elif metric is None and row.get("rtt_ms") is not None:
                metric = row["rtt_ms"]
            members.append(member)
        if down and not up and down == len(members):
            status = "down"
        elif down:
            # Yellow only when something is actually down (mixed or partial).
            # up + unknown must not paint the map yellow.
            status = "degraded"
        elif up:
            status = "up"
        else:
            status = "unknown"
        out.append(
            {
                **svc,
                "status": status,
                "up": up,
                "down": down,
                "total": len(members),
                "rtt_ms": metric,
                "members": members,
            }
        )
    return out


def leftover_rows(nodes: list[dict], by_id: dict[str, dict], grouped_ids: set[str]) -> tuple[list[dict], list[dict]]:
    lan, proxies = [], []
    for n in nodes or []:
        nid = str(n.get("id") or "")
        if not nid or nid in grouped_ids:
            continue
        if n.get("hidden") is True:
            continue
        row = dict(by_id.get(nid) or {"id": nid, "label": n.get("label") or nid, "status": "unknown"})
        t = str(n.get("type") or "")
        if t == "host":
            lan.append(row)
        elif t == "proxy":
            proxies.append(row)
    return lan, proxies
