#!/usr/bin/env python3
"""The first-seen ledger: what has been here, and what just arrived."""
from __future__ import annotations

from seen_lib import empty_ledger, normalize_mac, observe, prune, recent_arrivals

STRANGER = [{"mac": "24:6f:28:ab:cd:ef", "label": "Espressif", "ip": "10.0.0.207", "kind": "IoT"}]
RESIDENT = [{"mac": "6c:6e:07:1e:75:3c", "label": "fnix", "ip": "10.0.0.213"}]


def test_first_pass_is_a_baseline_not_an_alarm() -> None:
    """Everything is new the first time you look. Announcing all of it is how a
    tripwire becomes noise that gets muted on day one."""
    led = empty_ledger()
    arrivals = observe(led, RESIDENT + STRANGER)
    assert arrivals == []
    assert led["baselined_at"]
    assert recent_arrivals(led) == [], "the baseline is not news"


def test_an_arrival_after_the_baseline_is_announced() -> None:
    led = empty_ledger()
    observe(led, RESIDENT)                 # baseline: fnix is furniture
    assert observe(led, RESIDENT + STRANGER) == [], "one sighting is not an arrival"
    got = observe(led, RESIDENT + STRANGER)
    assert [a["mac"] for a in got] == ["24:6f:28:ab:cd:ef"]


def test_an_arrival_is_announced_once() -> None:
    led = empty_ledger()
    observe(led, RESIDENT)
    observe(led, STRANGER)
    observe(led, STRANGER)
    for _ in range(5):
        assert observe(led, STRANGER) == [], "must not re-announce forever"


def test_a_single_blip_does_not_alarm() -> None:
    """An ARP entry that appears once and never again is not an arrival."""
    led = empty_ledger()
    observe(led, RESIDENT)
    assert observe(led, STRANGER) == []
    assert recent_arrivals(led) == []


def test_acknowledged_devices_drop_out_of_the_tray() -> None:
    led = empty_ledger()
    observe(led, RESIDENT)
    observe(led, STRANGER)
    observe(led, STRANGER)
    assert len(recent_arrivals(led)) == 1
    assert recent_arrivals(led, exclude={"24:6F:28:AB:CD:EF"}) == [], "case must not matter"


def test_rows_without_a_mac_are_ignored() -> None:
    """There is nothing stable to remember them by, and guessing from an address
    would announce a stranger every time DHCP shuffles."""
    led = empty_ledger()
    observe(led, RESIDENT)
    assert observe(led, [{"label": "mystery", "ip": "10.0.0.9"}]) == []
    assert observe(led, [{"label": "mystery", "ip": "10.0.0.9"}]) == []


def test_mac_normalisation() -> None:
    assert normalize_mac("24-6F-28-AB-CD-EF") == "24:6f:28:ab:cd:ef"
    assert normalize_mac("24:6f:28:ab:cd:ef") == "24:6f:28:ab:cd:ef"
    assert normalize_mac("nope") is None
    assert normalize_mac(None) is None


def test_prune_forgets_long_gone_hardware() -> None:
    led = empty_ledger()
    observe(led, RESIDENT)
    led["devices"]["6c:6e:07:1e:75:3c"]["last_seen"] = "2020-01-01T00:00:00+00:00"
    prune(led, keep_days=30)
    assert led["devices"] == {}


def test_randomized_mac_is_carried_through() -> None:
    led = empty_ledger()
    observe(led, RESIDENT)
    phone = [{"mac": "0e:9e:a5:11:22:33", "label": "phone", "randomizedMac": True}]
    observe(led, phone)
    observe(led, phone)
    assert recent_arrivals(led)[0]["randomized"] is True


def test_the_tray_is_not_the_alert_list() -> None:
    """The tray is everything from the last day and is rebuilt every probe. The
    alert is only what arrived on this pass.

    Notifying on the tray re-announced every device in it on every cycle, which
    on a 15s probe meant the same box alerting four times a minute, forever.
    """
    led = empty_ledger()
    observe(led, RESIDENT)

    alerts = 0
    for _ in range(10):
        alerts += len(observe(led, STRANGER))

    assert alerts == 1, "an arrival is announced once"
    assert len(recent_arrivals(led)) == 1, "but it stays in the tray"


if __name__ == "__main__":
    for _name, _fn in sorted(list(globals().items())):
        if _name.startswith("test_") and callable(_fn):
            _fn()
    print("ok")
