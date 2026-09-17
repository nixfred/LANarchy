"""Probe gate: decide whether the collector should probe right now, and how often.

The collector used to probe every 15s from login to logout, panel open or not,
on mains or on battery, on the home LAN or on hotel wifi. On a laptop that is
a needless battery and radio cost, and probing your lab's hostnames on a
foreign network leaks the shape of your homelab.

This module is pure decision logic over injected readers so it can be tested
without a battery, a router, or a panel.
"""
from __future__ import annotations

import re
import subprocess
import time
from pathlib import Path

from plugin_paths import panel_heartbeat_path

DEFAULT_INTERVAL_S = 15.0
DEFAULT_BATTERY_INTERVAL_S = 300.0
AWAY_POLL_S = 60.0
HEARTBEAT_MAX_AGE_S = 20.0

_MAC_RE = re.compile(r"\b([0-9a-f]{2}(?::[0-9a-f]{2}){5})\b", re.I)


def _clamp_interval(raw: object, fallback: float, lo: float = 5.0, hi: float = 3600.0) -> float:
    try:
        n = float(raw)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return fallback
    if not lo <= n <= hi:
        return fallback
    return n


def on_battery(root: Path = Path("/sys/class/power_supply")) -> bool | None:
    """True on battery, False on mains, None when the box has no battery."""
    try:
        supplies = sorted(root.iterdir())
    except OSError:
        return None
    seen_battery = False
    for supply in supplies:
        try:
            kind = (supply / "type").read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if kind != "Battery":
            continue
        seen_battery = True
        try:
            status = (supply / "status").read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if status in ("Charging", "Full"):
            return False
        if status == "Discharging":
            return True
    return None if not seen_battery else False


def panel_open(max_age_s: float = HEARTBEAT_MAX_AGE_S, now: float | None = None) -> bool:
    """The panel touches a heartbeat file while open. Stale or missing = closed."""
    path = panel_heartbeat_path()
    try:
        age = (time.time() if now is None else now) - path.stat().st_mtime
    except OSError:
        return False
    return age <= max_age_s


def gateway_mac(run=subprocess.run) -> str | None:
    """MAC of the current default gateway: a cheap, stable "which network am I on"."""
    try:
        route = run(
            ["ip", "-4", "route", "show", "default"],
            capture_output=True, text=True, timeout=3, check=False,
        )
        fields = (route.stdout or "").split()
        try:
            gw = fields[fields.index("via") + 1]
        except (ValueError, IndexError):
            return None
        neigh = run(
            ["ip", "-4", "neigh", "show", gw],
            capture_output=True, text=True, timeout=3, check=False,
        )
        m = _MAC_RE.search(neigh.stdout or "")
        return m.group(1).lower() if m else None
    except (OSError, subprocess.SubprocessError):
        return None


def decide(
    settings: dict | None,
    *,
    is_panel_open: bool,
    battery: bool | None,
    current_gateway_mac: str | None,
) -> dict:
    """Return {"probe": bool, "sleep_s": float, "reason": str}.

    Defaults preserve the old always-on behaviour on a desktop (no battery,
    no configured home gateway). Only a laptop away from home, or a laptop on
    battery with the panel closed, gets throttled.
    """
    s = settings if isinstance(settings, dict) else {}
    base = _clamp_interval(s.get("probeIntervalSec"), DEFAULT_INTERVAL_S, 5.0, 120.0)

    home = s.get("homeGatewayMac")
    home_mac = str(home).strip().lower() if isinstance(home, str) and home.strip() else None
    if home_mac and current_gateway_mac and current_gateway_mac != home_mac:
        if is_panel_open:
            return {"probe": True, "sleep_s": base, "reason": "away-network panel-open"}
        return {"probe": False, "sleep_s": AWAY_POLL_S, "reason": "away-network"}

    if is_panel_open:
        return {"probe": True, "sleep_s": base, "reason": "panel-open"}

    if battery and s.get("batteryBackoff") is not False:
        idle = _clamp_interval(
            s.get("batteryIntervalSec"), DEFAULT_BATTERY_INTERVAL_S, base, 3600.0
        )
        return {"probe": True, "sleep_s": idle, "reason": "battery panel-closed"}

    closed = s.get("closedIntervalSec")
    if closed is not None:
        return {
            "probe": True,
            "sleep_s": _clamp_interval(closed, base, base, 3600.0),
            "reason": "panel-closed",
        }

    return {"probe": True, "sleep_s": base, "reason": "mains"}


GATEWAY_TTL_S = 30.0
BATTERY_TTL_S = 10.0

_cache: dict[str, tuple[float, object]] = {}


def _cached(key: str, ttl_s: float, produce, now: float | None = None):
    """The collector re-reads the gate every couple of seconds so it notices the
    panel opening promptly. Battery sysfs is cheap; shelling out to `ip` is not,
    so those answers are cached, since they change on the scale of minutes, not ticks.
    """
    t = time.monotonic() if now is None else now
    hit = _cache.get(key)
    if hit is not None and t - hit[0] < ttl_s:
        return hit[1]
    value = produce()
    _cache[key] = (t, value)
    return value


def reset_cache() -> None:
    _cache.clear()


def current_decision(settings: dict | None) -> dict:
    """Live gate read for the collector loop. Cheap enough to call every tick."""
    return decide(
        settings,
        is_panel_open=panel_open(),
        battery=_cached("battery", BATTERY_TTL_S, on_battery),
        current_gateway_mac=_cached("gateway", GATEWAY_TTL_S, gateway_mac),
    )
