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
from inventory_lib import load_inventory
from plugin_paths import ensure_user_inventory, inventory_path, plugin_config_dir
from probe import run_probe

DEFAULT_INTERVAL_S = gate_lib.DEFAULT_INTERVAL_S
TICK_S = 2.0


def inventory_settings() -> dict:
    try:
        inv = load_inventory(inventory_path())
    except (OSError, ValueError):
        return {}
    settings = inv.get("settings") if isinstance(inv, dict) else None
    return settings if isinstance(settings, dict) else {}


def loop() -> int:
    ensure_user_inventory()
    lock_path = plugin_config_dir() / ".daemon.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w") as fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        fh.write(str(os.getpid()))
        fh.flush()
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
                    run_probe(write_stdout=False)
                except Exception as e:
                    print(f"lanarchy daemon: {type(e).__name__}: {e}", flush=True)
                last_probe = time.monotonic()
            # Tick faster than the probe interval so opening the panel takes effect
            # at once instead of waiting out a 5-minute battery backoff.
            time.sleep(min(TICK_S, gate["sleep_s"]))


if __name__ == "__main__":
    raise SystemExit(loop())
