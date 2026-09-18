"""Fail-streak notifications (OmarPlugs-5oy.2)."""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path
from typing import Any

from inventory_lib import load_inventory
from plugin_paths import atomic_write_json, inventory_path, load_json_or, notify_state_path

NOTIFY_SCHEMA = 1
DEFAULT_THRESHOLD = 3


def empty_notify_state() -> dict:
    return {"schemaVersion": NOTIFY_SCHEMA, "nodes": {}}


def load_notify_state(path: Path | None = None) -> dict:
    raw = load_json_or(path or notify_state_path(), None)
    if not isinstance(raw, dict):
        return empty_notify_state()
    raw.setdefault("schemaVersion", NOTIFY_SCHEMA)
    raw.setdefault("nodes", {})
    return raw


def save_notify_state(state: dict, path: Path | None = None) -> Path:
    return atomic_write_json(path or notify_state_path(), state)


def fail_streak_threshold(inv: dict) -> int:
    settings = inv.get("settings")
    if isinstance(settings, dict):
        n = settings.get("failStreakThreshold")
        try:
            v = int(n)
            if v >= 1:
                return v
        except (TypeError, ValueError):
            pass
    return DEFAULT_THRESHOLD


def node_notify_enabled(inv: dict, node_id: str) -> bool:
    for n in inv.get("nodes") or []:
        if str(n.get("id") or "") == str(node_id):
            if n.get("notify") is False:
                return False
            return True
    return True


def _send_notification(title: str, body: str) -> None:
    try:
        subprocess.run(
            ["omarchy-notification-send", title, body],
            check=False,
            capture_output=True,
            timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass


_MEANINGLESS = re.compile(
    r"""^(?:
        [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}   # uuid
      | [0-9a-f]{12,}                                                   # hex blob
      | [0-9a-f]{8}(?:-[0-9a-f]{4,})+                                   # dashed hex id
      | (?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}                               # mac
      | \d{1,3}(?:\.\d{1,3}){3}                                        # bare ipv4
      | (?:sonos)?RINCON_[0-9A-F]+.*                                    # sonos device id
    )$""",
    re.I | re.X,
)


def is_meaningless_name(text: str) -> bool:
    """True when a string identifies a device but tells a person nothing."""
    return bool(_MEANINGLESS.match(str(text or "").strip()))


def notify_name(inv: dict, node_id: str, label: str) -> str:
    """A name a human can act on.

    A label that is a bare pairing id, a MAC, or an address tells you nothing at
    2am, so fall back to the node's dns name, then its address, then the id.
    """
    text = str(label or "").strip()
    node = None
    for n in (inv.get("nodes") or []) if isinstance(inv, dict) else []:
        if str(n.get("id") or "") == str(node_id):
            node = n
            break
    if text and not is_meaningless_name(text):
        return text
    if node:
        for key in ("dns", "ip", "mac"):
            alt = str(node.get(key) or "").strip()
            if alt and not is_meaningless_name(alt):
                return alt
        for key in ("dns", "ip"):
            alt = str(node.get(key) or "").strip()
            if alt:
                return alt
    return text or str(node_id)


def notify_where(inv: dict, node_id: str) -> str:
    """The address line, so an alert says where as well as what."""
    for n in (inv.get("nodes") or []) if isinstance(inv, dict) else []:
        if str(n.get("id") or "") == str(node_id):
            parts = [str(n.get(k) or "").strip() for k in ("dns", "ip")]
            return " · ".join(p for p in parts if p)
    return ""


def apply_status_updates(
    state: dict,
    inv: dict,
    updates: list[tuple[str, str, str]],
) -> list[dict[str, Any]]:
    """Apply (node_id, label, status) rows; return notifications emitted."""
    threshold = fail_streak_threshold(inv)
    nodes = state.setdefault("nodes", {})
    sent: list[dict[str, Any]] = []
    for nid, label, status in updates:
        if not nid:
            continue
        entry = nodes.setdefault(nid, {"downStreak": 0, "alerted": False, "lastStatus": status})
        entry["lastStatus"] = status
        if status == "down":
            entry["downStreak"] = int(entry.get("downStreak") or 0) + 1
            if (
                node_notify_enabled(inv, nid)
                and int(entry["downStreak"]) >= threshold
                and not entry.get("alerted")
            ):
                name = notify_name(inv, nid, label)
                where = notify_where(inv, nid)
                title = f"Lanarchy: {name} down"
                body = f"{threshold} consecutive probe failures"
                if where and where != name:
                    body += f" · {where}"
                _send_notification(title, body)
                entry["alerted"] = True
                sent.append({"id": nid, "title": title, "body": body})
        elif status == "up":
            entry["downStreak"] = 0
            entry["alerted"] = False
        # unknown / other: leave streak and alerted alone
    return sent


def process_probe_glance(
    glance: dict,
    *,
    inv_path: Path | None = None,
    state_path: Path | None = None,
) -> dict:
    inv = load_inventory(inv_path or inventory_path())
    state = load_notify_state(state_path)
    updates: list[tuple[str, str, str]] = []
    for band in ("machines", "lan", "proxies"):
        for row in glance.get(band) or []:
            if not isinstance(row, dict):
                continue
            updates.append(
                (
                    str(row.get("id") or ""),
                    str(row.get("label") or row.get("id") or ""),
                    str(row.get("status") or "unknown"),
                )
            )
    sent = apply_status_updates(state, inv, updates)
    sent.extend(apply_arrival_alerts(inv, glance))
    sent.extend(apply_unknown_neighbor_alerts(state, inv, glance))
    save_notify_state(state, state_path)
    return {"notified": sent}


def apply_arrival_alerts(inv: dict, glance: dict) -> list[dict[str, Any]]:
    """Announce hardware that has never been on this network before.

    The ledger has already decided what counts as an arrival: seen more than
    once, after the baseline pass, and not something the user has dealt with. So
    this only has to say it well.
    """
    settings = inv.get("settings") if isinstance(inv.get("settings"), dict) else {}
    if settings.get("newDeviceNotify") is False:
        return []
    arrivals = glance.get("new_devices")
    if not isinstance(arrivals, list) or not arrivals:
        return []

    sent: list[dict[str, Any]] = []
    for row in arrivals:
        if not isinstance(row, dict):
            continue
        name = str(row.get("label") or row.get("mac") or "device")
        where = " · ".join(p for p in (str(row.get("ip") or ""), str(row.get("mac") or "")) if p)
        kind = str(row.get("kind") or "")
        title = f"Lanarchy: new on your network · {name}"
        body = where if not kind else f"{kind} · {where}"
        if row.get("randomized"):
            body += " · randomized MAC"
        _send_notification(title, body)
        sent.append({"id": str(row.get("mac") or ""), "title": title, "body": body,
                     "kind": "new_device"})
    return sent


def apply_unknown_neighbor_alerts(state: dict, inv: dict, glance: dict) -> list[dict[str, Any]]:
    """Fing-like: one notify per new lladdr in lan_meta.unknown_hosts until muted."""
    settings = inv.get("settings") if isinstance(inv.get("settings"), dict) else {}
    if settings.get("unknownNeighborNotify") is False:
        return []
    meta = glance.get("lan_meta") if isinstance(glance.get("lan_meta"), dict) else {}
    unknowns = meta.get("unknown_hosts") if isinstance(meta.get("unknown_hosts"), list) else []
    seen = state.setdefault("unknownNeighbors", {})
    if not isinstance(seen, dict):
        seen = {}
        state["unknownNeighbors"] = seen
    sent: list[dict[str, Any]] = []
    for row in unknowns:
        if not isinstance(row, dict):
            continue
        mac = str(row.get("mac") or "").strip().lower()
        ip = str(row.get("ip") or "").strip()
        key = mac or ip
        if not key:
            continue
        entry = seen.setdefault(key, {"alerted": False, "muted": False, "ip": ip, "mac": mac})
        if entry.get("muted") or entry.get("alerted"):
            continue
        label = ip or mac
        title = f"Lanarchy: new neighbor {label}"
        body = " · ".join(p for p in (ip, mac) if p)
        _send_notification(title, body)
        entry["alerted"] = True
        entry["ip"] = ip or entry.get("ip")
        entry["mac"] = mac or entry.get("mac")
        sent.append({"id": key, "title": title, "body": body, "kind": "unknown_neighbor"})
    return sent
