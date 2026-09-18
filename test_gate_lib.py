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
    """No battery → 15s probing, as before. Discovery is a separate decision."""
    d = decide({"homeGatewayMac": HOME}, gw=HOME)
    assert d["probe"] is True
    assert d["sleep_s"] == 15.0
    assert d["reason"] == "mains"


def test_panel_open_always_full_pace():
    d = decide({"probeIntervalSec": 20, "homeGatewayMac": HOME},
               panel=True, battery=True, gw=HOME)
    assert d["probe"] is True and d["sleep_s"] == 20.0


def test_battery_with_panel_closed_backs_off():
    d = decide({"homeGatewayMac": HOME}, panel=False, battery=True, gw=HOME)
    assert d["probe"] is True
    assert d["sleep_s"] == gate_lib.DEFAULT_BATTERY_INTERVAL_S
    assert d["reason"] == "battery panel-closed"


def test_battery_backoff_can_be_disabled():
    d = decide({"homeGatewayMac": HOME, "batteryBackoff": False},
               panel=False, battery=True, gw=HOME)
    assert d["sleep_s"] == 15.0 and d["reason"] == "mains"


def test_failing_closed_does_not_cost_the_battery_backoff():
    """Discovery and cadence are separate decisions.

    Refusing to sweep an unrecognised network must not also drop the laptop back
    to a 15s probe on battery with nobody looking.
    """
    d = decide({}, panel=False, battery=True, gw=None)
    assert d["discover"] is False
    assert d["sleep_s"] == gate_lib.DEFAULT_BATTERY_INTERVAL_S
    assert d["reason"] == "battery panel-closed"


def test_unknown_network_never_sweeps():
    """An unset home network used to disable the rule entirely, so the scan ran
    on whatever network the laptop had joined."""
    assert decide({}, panel=True, gw="ff:ff:ff:ff:ff:ff")["discover"] is False
    assert decide({"homeGatewayMac": HOME}, panel=True, gw=None)["discover"] is False
    # and a recognised home network is the one place it is allowed
    assert decide({"homeGatewayMac": HOME}, panel=True, gw=HOME)["discover"] is True


def test_home_adoption_is_first_use_only():
    from gate_lib import adopt_home_network

    assert adopt_home_network({}, "AA:BB:CC:DD:EE:01") == "aa:bb:cc:dd:ee:01"
    assert adopt_home_network({}, "aa-bb-cc-dd-ee-01") == "aa:bb:cc:dd:ee:01"
    assert adopt_home_network({"homeGatewayMac": HOME}, "ff:ff:ff:ff:ff:ff") is None
    assert adopt_home_network({}, None) is None
    assert adopt_home_network({}, "nonsense") is None


def test_battery_interval_is_configurable_and_clamped():
    assert decide({"batteryIntervalSec": 90, "homeGatewayMac": HOME},
                  battery=True, gw=HOME)["sleep_s"] == 90.0
    # below the base interval is nonsense for a backoff → fall back to the default
    assert decide({"batteryIntervalSec": 2, "homeGatewayMac": HOME},
                  battery=True, gw=HOME)["sleep_s"] == 300.0


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
    # and hyphen-separated MACs are the same network
    assert decide({"homeGatewayMac": HOME.replace(":", "-")}, gw=HOME)["discover"] is False


def test_unknown_gateway_does_not_pause_probing():
    """Cannot read the gateway → still probe your own inventory, just never sweep."""
    d = decide({"homeGatewayMac": HOME}, gw=None)
    assert d["probe"] is True and d["discover"] is False


def test_closed_interval_opt_in():
    d = decide({"closedIntervalSec": 60, "homeGatewayMac": HOME},
               panel=False, battery=False, gw=HOME)
    assert d["sleep_s"] == 60.0 and d["reason"] == "panel-closed"


def test_bad_interval_values_fall_back():
    assert decide({"probeIntervalSec": "banana", "homeGatewayMac": HOME}, gw=HOME)["sleep_s"] == 15.0
    assert decide({"probeIntervalSec": 99999, "homeGatewayMac": HOME}, gw=HOME)["sleep_s"] == 15.0


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


def test_discovery_is_refused_on_a_foreign_network() -> None:
    """Probing touches your own inventory; discovery sweeps the whole subnet.

    A TCP connect to 22 and 3389 on every neighbour plus an SSH attempt is fine
    at home and is port-scanning on someone else's network, so an open panel
    must not authorise it away from the known gateway.
    """
    away = decide({"homeGatewayMac": HOME}, panel=True, gw=AWAY)
    assert away["probe"] is True, "the user should still see their own nodes"
    assert away["discover"] is False, "must never sweep a foreign LAN"

    closed = decide({"homeGatewayMac": HOME}, panel=False, gw=AWAY)
    assert closed["probe"] is False and closed["discover"] is False


def test_discovery_only_runs_when_someone_is_looking() -> None:
    assert decide({"homeGatewayMac": HOME}, panel=True, gw=HOME)["discover"] is True
    assert decide({"homeGatewayMac": HOME}, panel=False, battery=True, gw=HOME)["discover"] is False
    assert decide({"homeGatewayMac": HOME, "closedIntervalSec": 60},
                  panel=False, gw=HOME)["discover"] is False


def test_home_network_permits_discovery() -> None:
    got = decide({"homeGatewayMac": HOME}, panel=True, gw=HOME)
    assert got["probe"] is True and got["discover"] is True



if __name__ == "__main__":
    for _name, _fn in sorted(list(globals().items())):
        if _name.startswith("test_") and callable(_fn):
            _fn()
    print("ok")
