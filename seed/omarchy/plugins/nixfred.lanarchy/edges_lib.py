"""Curated edge list for letterbox map (OmarPlugs-5oy.9)."""
from __future__ import annotations

from typing import Any


def _first_caddy_proxy(nodes: list[dict]) -> str | None:
    for n in nodes:
        if str(n.get("type") or "") != "proxy":
            continue
        if str(n.get("check") or "").lower() == "http":
            label = str(n.get("label") or "").lower()
            if "caddy" in label:
                return str(n.get("id") or "")
    for n in nodes:
        if str(n.get("type") or "") == "proxy":
            return str(n.get("id") or "")
    return None


def _first_machine_id(nodes: list[dict]) -> str | None:
    for n in nodes:
        if str(n.get("type") or "") == "machine":
            return str(n.get("id") or "")
    return None


def pick_hub_id(nodes: list[dict]) -> str | None:
    return _first_caddy_proxy(nodes) or _first_machine_id(nodes)


def derive_default_edges(nodes: list[dict], *, max_lan: int = 24, services: list[dict] | None = None) -> list[dict]:
    hub = pick_hub_id(nodes)
    if not hub:
        return []
    edges: list[dict] = []
    for n in nodes:
        if str(n.get("type") or "") == "machine":
            nid = str(n.get("id") or "")
            if nid:
                edges.append({"from": nid, "to": hub, "kind": "hub"})
    if services:
        for svc in services:
            sid = str(svc.get("id") or "")
            if sid and sid != hub and hub not in (svc.get("member_ids") or []):
                edges.append({"from": hub, "to": sid, "kind": "service"})
        return edges
    lan_count = 0
    for n in nodes:
        if str(n.get("type") or "") != "host":
            continue
        if lan_count >= max_lan:
            break
        hid = str(n.get("id") or "")
        if hid:
            edges.append({"from": hub, "to": hid, "kind": "lan"})
            lan_count += 1
    return edges


def resolve_edges(inv: dict, services: list[dict] | None = None) -> list[dict]:
    raw = inv.get("edges")
    nodes = inv.get("nodes") if isinstance(inv.get("nodes"), list) else []
    if isinstance(raw, list) and raw:
        out: list[dict] = []
        for e in raw:
            if not isinstance(e, dict):
                continue
            fr = str(e.get("from") or "")
            to = str(e.get("to") or "")
            if fr and to:
                out.append({"from": fr, "to": to, "kind": str(e.get("kind") or "custom")})
        return out
    return derive_default_edges(nodes, services=services)


def edge_rtt_ms(edge: dict, status_by_id: dict[str, dict]) -> float | None:
    a = status_by_id.get(str(edge.get("from") or "")) or {}
    b = status_by_id.get(str(edge.get("to") or "")) or {}
    vals: list[float] = []
    for row in (a, b):
        rtt = row.get("rtt_ms")
        if rtt is None:
            continue
        try:
            vals.append(float(rtt))
        except (TypeError, ValueError):
            pass
    if not vals:
        return None
    return max(vals)
