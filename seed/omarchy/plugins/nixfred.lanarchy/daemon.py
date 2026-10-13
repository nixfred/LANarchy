#!/usr/bin/env python3
"""Single-owner collector. Writes snapshot.json; the panel only reads it.

Probing is gated (see gate_lib): full pace while the panel is open or on mains,
throttled on battery with the panel closed, and paused entirely when a
configured home gateway is not the one we are behind.
"""
from __future__ import annotations

import fcntl
import os
import time

import gate_lib
from inventory_lib import load_inventory, save_inventory
from plugin_paths import (
    plugin_config_dir,
    ensure_user_inventory,
    inventory_path,
    migrate_state_out_of_plugin_dir,
    state_dir,
)
from probe import run_probe

DEFAULT_INTERVAL_S = gate_lib.DEFAULT_INTERVAL_S
TICK_S = 2.0


def _source_mtime() -> float:
    """Newest mtime across the collector's own python sources."""
    newest = 0.0
    for path in sorted(plugin_config_dir().glob("*.py")):
        try:
            newest = max(newest, path.stat().st_mtime)
        except OSError:
            continue
    return newest


def inventory_settings() -> dict:
    try:
        inv = load_inventory(inventory_path())
    except (OSError, ValueError):
        return {}
    settings = inv.get("settings") if isinstance(inv, dict) else None
    return settings if isinstance(settings, dict) else {}


def adopt_home_if_unset() -> None:
    """Record the network we start on as home, once, so the gate can fail closed
    everywhere else without discovery being off by default."""
    settings = inventory_settings()
    mac = gate_lib.adopt_home_network(settings, gate_lib.gateway_mac())
    if not mac:
        return
    try:
        inv = load_inventory(inventory_path())
    except (OSError, ValueError):
        return
    merged = dict(inv.get("settings") or {})
    merged["homeGatewayMac"] = mac
    inv["settings"] = merged
    try:
        save_inventory(inv, inventory_path())
        print(f"lanarchy daemon: adopted home network {mac}", flush=True)
    except (OSError, ValueError):
        pass


def loop() -> int:
    migrate_state_out_of_plugin_dir()
    ensure_user_inventory()
    adopt_home_if_unset()
    lock_path = state_dir() / ".daemon.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w") as fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        fh.write(str(os.getpid()))
        fh.flush()
        # The daemon holds the flock across a shell restart, so after a plugin
        # update the panel's new code talks to a collector still running the old
        # one. Exit when our own source changes and let the panel start a fresh
        # instance.
        source_stamp = _source_mtime()
        last_reason = ""
        last_probe = 0.0
        while True:
            gate = gate_lib.current_decision(inventory_settings())
            if gate["reason"] != last_reason:
                print(f"lanarchy daemon: {gate['reason']} · {gate['sleep_s']:.0f}s", flush=True)
                last_reason = gate["reason"]
            now = time.monotonic()
            if gate["probe"] and (last_probe == 0.0 or now - last_probe >= gate["sleep_s"]):
                try:
                    run_probe(write_stdout=False, discover=bool(gate.get("discover", True)))
                except Exception as e:
                    print(f"lanarchy daemon: {type(e).__name__}: {e}", flush=True)
                last_probe = time.monotonic()
            # Tick faster than the probe interval so opening the panel takes effect
            # at once instead of waiting out a 5-minute battery backoff.
            if _source_mtime() != source_stamp:
                print("lanarchy daemon: source changed, exiting for a reload", flush=True)
                return 0
            time.sleep(min(TICK_S, gate["sleep_s"]))


if __name__ == "__main__":
    raise SystemExit(loop())
