"""First-seen ledger: what has ever been on this network, and what just arrived.

Keyed by MAC, because that is the only thing about a device that does not move.
An address is a DHCP lease and a hostname is whatever the device felt like
announcing; hardware is hardware.

The point is a single, answerable question: **has this thing been here before?**
Everything the plugin already knows about a device is recorded the first time it
is observed, so an arrival is a fact with a timestamp rather than a guess.
"""
from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from plugin_paths import atomic_write_json, load_json_or, state_dir

SCHEMA_VERSION = 1
# How long an arrival stays "new" before it is simply part of the furniture.
NEW_FOR_HOURS = 24.0
# A device must be observed this many separate probes before it is announced.
# A single ARP blip is not an arrival, and announcing one is how a tripwire
# becomes noise that gets muted.
CONFIRM_SIGHTINGS = 2


def seen_path() -> Path:
    return state_dir() / "seen-devices.json"


def empty_ledger() -> dict:
    return {"schemaVersion": SCHEMA_VERSION, "devices": {}, "baselined_at": None}


def load_ledger(path: Path | None = None) -> dict:
    data = load_json_or(path or seen_path(), empty_ledger())
    if not isinstance(data, dict) or not isinstance(data.get("devices"), dict):
        return empty_ledger()
    data.setdefault("schemaVersion", SCHEMA_VERSION)
    return data


def save_ledger(ledger: dict, path: Path | None = None) -> Path:
    return atomic_write_json(path or seen_path(), ledger)


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def normalize_mac(mac: object) -> str | None:
    m = str(mac or "").strip().lower().replace("-", ":")
    return m if len(m) == 17 else None


def observe(ledger: dict, devices: list[dict], now: str | None = None) -> list[dict]:
    """Record every device observed this pass; return the ones that are new.

    `devices` is any list of rows carrying at least a MAC. A row without one
    cannot be tracked: there is nothing stable to remember it by, and guessing
    from an address would announce a stranger every time DHCP shuffles.
    """
    stamp = now or _now_iso()
    book = ledger.setdefault("devices", {})
    arrivals: list[dict] = []

    # The first pass writes down what is already here. Everything on a network
    # is "new" the first time you look at it, and announcing all of it is how a
    # tripwire turns into noise that gets muted on day one. Only what arrives
    # AFTER the baseline is news.
    baselining = not ledger.get("baselined_at")

    for row in devices or []:
        if not isinstance(row, dict):
            continue
        mac = normalize_mac(row.get("mac"))
        if not mac:
            continue

        entry = book.get(mac)
        if entry is None:
            entry = {
                "first_seen": stamp,
                "sightings": 0,
                "announced": False,
            }
            book[mac] = entry

        entry["last_seen"] = stamp
        entry["sightings"] = int(entry.get("sightings") or 0) + 1
        # Keep the most recent description; a device renames itself over time.
        for key, field in (("label", "label"), ("ip", "ip"), ("kind", "kind")):
            val = row.get(field)
            if val:
                entry[key] = str(val)
        if row.get("randomizedMac"):
            entry["randomized"] = True

        if baselining:
            entry["announced"] = True
            entry["baseline"] = True
            continue

        if not entry.get("announced") and entry["sightings"] >= CONFIRM_SIGHTINGS:
            entry["announced"] = True
            arrivals.append(dict(entry, mac=mac))

    if baselining:
        ledger["baselined_at"] = stamp

    return arrivals


def _parse(ts: object) -> datetime | None:
    try:
        return datetime.fromisoformat(str(ts))
    except (TypeError, ValueError):
        return None


def recent_arrivals(ledger: dict, within_hours: float = NEW_FOR_HOURS,
                    exclude: set[str] | None = None) -> list[dict]:
    """Devices first seen inside the window, newest first.

    `exclude` carries the MACs the user has already dealt with, whether by
    adding the device to the inventory or by dismissing it. A device you have
    acknowledged is not news.
    """
    skip = {normalize_mac(m) for m in (exclude or set())}
    skip.discard(None)
    cutoff = datetime.now(timezone.utc) - timedelta(hours=float(within_hours))
    out: list[dict] = []
    for mac, entry in (ledger.get("devices") or {}).items():
        if mac in skip or entry.get("baseline"):
            continue
        if int(entry.get("sightings") or 0) < CONFIRM_SIGHTINGS:
            continue
        first = _parse(entry.get("first_seen"))
        if first is None or first < cutoff:
            continue
        out.append({
            "mac": mac,
            "first_seen": entry.get("first_seen"),
            "last_seen": entry.get("last_seen"),
            "label": entry.get("label") or mac,
            "ip": entry.get("ip"),
            "kind": entry.get("kind") or "",
            "randomized": bool(entry.get("randomized")),
        })
    out.sort(key=lambda r: str(r.get("first_seen") or ""), reverse=True)
    return out


def prune(ledger: dict, keep_days: float = 90.0) -> dict:
    """Forget hardware that has not been seen for a long time."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=float(keep_days))
    book = ledger.get("devices") or {}
    for mac in [m for m, e in book.items()
                if (_parse(e.get("last_seen")) or datetime.now(timezone.utc)) < cutoff]:
        book.pop(mac, None)
    return ledger
