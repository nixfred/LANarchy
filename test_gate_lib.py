#!/usr/bin/env python3
"""Probe gate decisions: panel state, battery, and which network we are on."""
from __future__ import annotations

import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

import gate_lib

HOME = "02:00:5e:10:00:01"
AWAY = "aa:bb:cc:dd:ee:ff"


def decide(settings=None, *, panel=False, battery=None, gw=None):
    return gate_lib.decide(
        settings, is_panel_open=panel, battery=battery, current_gateway_mac=gw
    )


def test_desktop_defaults_unchanged():
    """No battery, no home gateway configured → old always-on 15s behaviour."""
    d = decide({})
    assert d["probe"] is True
    assert d["sleep_s"] == 15.0
    assert d["reason"] == "mains"


def test_panel_open_always_full_pace():
    d = decide({"probeIntervalSec": 20}, panel=True, battery=True)
    assert d["probe"] is True and d["sleep_s"] == 20.0


def test_battery_with_panel_closed_backs_off():
    d = decide({}, panel=False, battery=True)
    assert d["probe"] is True
    assert d["sleep_s"] == gate_lib.DEFAULT_BATTERY_INTERVAL_S
    assert d["reason"] == "battery panel-closed"


def test_battery_backoff_can_be_disabled():
    d = decide({"batteryBackoff": False}, panel=False, battery=True)
    assert d["sleep_s"] == 15.0 and d["reason"] == "mains"


def test_battery_interval_is_configurable_and_clamped():
    assert decide({"batteryIntervalSec": 90}, battery=True)["sleep_s"] == 90.0
    # below the base interval is nonsense for a backoff → fall back to the default
    assert decide({"batteryIntervalSec": 2}, battery=True)["sleep_s"] == 300.0


def test_away_network_pauses_probing():
    d = decide({"homeGatewayMac": HOME}, gw=AWAY)
    assert d["probe"] is False
    assert d["sleep_s"] == gate_lib.AWAY_POLL_S
    assert d["reason"] == "away-network"


def test_away_network_still_probes_when_user_opens_panel():
    """Explicit user intent beats the privacy gate: they asked to see the lab."""
    d = decide({"homeGatewayMac": HOME}, panel=True, gw=AWAY)
    assert d["probe"] is True and d["reason"] == "away-network panel-open"


def test_home_network_match_is_case_insensitive():
    d = decide({"homeGatewayMac": HOME.upper()}, gw=HOME)
    assert d["probe"] is True and d["reason"] == "mains"


def test_unknown_gateway_does_not_pause():
    """Cannot read the gateway (no route yet) → never silently stop probing."""
    d = decide({"homeGatewayMac": HOME}, gw=None)
    assert d["probe"] is True


def test_closed_interval_opt_in():
    d = decide({"closedIntervalSec": 60}, panel=False, battery=False)
    assert d["sleep_s"] == 60.0 and d["reason"] == "panel-closed"


def test_bad_interval_values_fall_back():
    assert decide({"probeIntervalSec": "banana"})["sleep_s"] == 15.0
    assert decide({"probeIntervalSec": 99999})["sleep_s"] == 15.0


def test_on_battery_reads_sysfs() -> None:
    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / "power_supply"
        (root / "AC").mkdir(parents=True)
        (root / "AC" / "type").write_text("Mains\n")
        bat = root / "BAT0"
        bat.mkdir()
        (bat / "type").write_text("Battery\n")

        (bat / "status").write_text("Discharging\n")
        assert gate_lib.on_battery(root) is True
        (bat / "status").write_text("Charging\n")
        assert gate_lib.on_battery(root) is False


def test_on_battery_none_without_a_battery() -> None:
    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / "power_supply"
        (root / "AC").mkdir(parents=True)
        (root / "AC" / "type").write_text("Mains\n")
        assert gate_lib.on_battery(root) is None
        assert gate_lib.on_battery(Path(td) / "missing") is None


def test_panel_open_reads_heartbeat_age() -> None:
    with tempfile.TemporaryDirectory() as td:
        hb = Path(td) / ".panel-heartbeat"
        original = gate_lib.panel_heartbeat_path
        gate_lib.panel_heartbeat_path = lambda: hb
        try:
            assert gate_lib.panel_open() is False  # missing
            hb.write_text("")
            assert gate_lib.panel_open() is True
            assert gate_lib.panel_open(max_age_s=20, now=time.time() + 600) is False
        finally:
            gate_lib.panel_heartbeat_path = original


def test_gateway_mac_parses_route_then_neigh() -> None:
    calls = []

    def fake_run(cmd, **kw):
        calls.append(cmd)
        if "route" in cmd:
            out = "default via 192.168.1.1 dev eno1 proto dhcp metric 100\n"
        else:
            out = f"192.168.1.1 dev eno1 lladdr {HOME} REACHABLE\n"
        return SimpleNamespace(stdout=out, stderr="", returncode=0)

    assert gate_lib.gateway_mac(run=fake_run) == HOME
    assert calls[1][-1] == "192.168.1.1"


def test_gateway_mac_none_without_default_route() -> None:
    def fake_run(cmd, **kw):
        return SimpleNamespace(stdout="", stderr="", returncode=0)

    assert gate_lib.gateway_mac(run=fake_run) is None


if __name__ == "__main__":
    for _name, _fn in sorted(list(globals().items())):
        if _name.startswith("test_") and callable(_fn):
            _fn()
    print("ok")
