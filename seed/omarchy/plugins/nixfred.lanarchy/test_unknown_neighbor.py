#!/usr/bin/env python3
"""unknown neighbor notify fires once per new lladdr (OmarPlugs-5oy.21)."""
from unittest.mock import patch

from notify_lib import apply_unknown_neighbor_alerts, empty_notify_state
from probe import lan_meta


def test_unknown_neighbor_once() -> None:
    inv = {"schemaVersion": 2, "nodes": [], "settings": {}}
    state = empty_notify_state()
    glance = {
        "lan_meta": {
            "unknown_hosts": [
                {"ip": "192.168.1.77", "mac": "aa:bb:cc:dd:ee:77"},
            ]
        }
    }
    sent = apply_unknown_neighbor_alerts(state, inv, glance)
    assert len(sent) == 1
    assert sent[0]["kind"] == "unknown_neighbor"
    again = apply_unknown_neighbor_alerts(state, inv, glance)
    assert again == []


def test_unknown_neighbor_mute_setting() -> None:
    inv = {"schemaVersion": 2, "nodes": [], "settings": {"unknownNeighborNotify": False}}
    state = empty_notify_state()
    glance = {"lan_meta": {"unknown_hosts": [{"ip": "192.168.1.9", "mac": "11:22:33:44:55:66"}]}}
    assert apply_unknown_neighbor_alerts(state, inv, glance) == []


def test_lan_meta_uses_history_not_live_dns() -> None:
    """DNS-only inventory host remembered in history must not become unknown on DNS miss."""
    nodes = [{"id": "aka", "type": "machine", "label": "aka", "dns": "aka.lan", "ip": None}]
    hist = {"series": {"aka": {"samples": [], "meta": {"ip": "192.168.1.11", "mac": "aa:bb:cc:dd:ee:11"}}}}
    neigh = [{"ip": "192.168.1.11", "mac": "aa:bb:cc:dd:ee:11"}, {"ip": "192.168.1.99", "mac": "ff:ee:dd:cc:bb:aa"}]
    with patch("probe.neighbors", return_value=neigh), patch("probe.dns_time_ms", return_value=None):
        meta = lan_meta(nodes, hist, 0.0)
    assert meta["neighbors"] == 2
    assert meta["unknown"] == 1
    assert meta["unknown_hosts"][0]["ip"] == "192.168.1.99"


if __name__ == "__main__":
    test_unknown_neighbor_once()
    test_unknown_neighbor_mute_setting()
    test_lan_meta_uses_history_not_live_dns()
    print("ok")
