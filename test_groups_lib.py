#!/usr/bin/env python3
"""groups_lib: Bernie collapses, HA is first-class, leftovers stay quiet."""
from __future__ import annotations

import json
from pathlib import Path

from groups_lib import attach_status, group_nodes, leftover_rows, node_group_key
from inventory_lib import load_inventory, normalize_node


def test_inventory_groups() -> None:
    inv = load_inventory(Path(__file__).resolve().parent / "fixtures" / "groups-inventory.json")
    dash = group_nodes(inv["nodes"])
    labels = [s["label"] for s in dash["services"]]
    keys = [s["key"] for s in dash["services"]]
    assert "ha" in keys, keys
    assert labels[0] == "Home Assistant", labels
    bernie = next(s for s in dash["services"] if s["key"] == "bernie")
    assert set(bernie["member_ids"]) == {"bernie.lan", "bernie", "bernie-api"}
    leftover_ids = {n["id"] for n in dash["lan"]}
    assert "ha.lan" not in leftover_ids
    assert "bernie.lan" not in leftover_ids
    assert "cockpit.lan" in leftover_ids
    assert "print.lan" in leftover_ids
    machine_ids = {n["id"] for n in dash["machines"]}
    assert machine_ids == {"deba", "kiritsuke", "aka", "suji", "redultra"}


def test_attach_status_degraded() -> None:
    dash = {
        "services": [
            {
                "id": "svc-bernie",
                "key": "bernie",
                "label": "Bernie",
                "member_ids": ["bernie.lan", "bernie-api"],
                "roles": ["host", "http"],
            }
        ]
    }
    by_id = {
        "bernie.lan": {"id": "bernie.lan", "status": "up", "rtt_ms": 1.2},
        "bernie-api": {"id": "bernie-api", "status": "down"},
    }
    out = attach_status(dash, by_id)
    assert out[0]["status"] == "degraded"
    assert out[0]["up"] == 1 and out[0]["down"] == 1
    partial = attach_status(
        {"services": [{**dash["services"][0], "member_ids": ["a", "b"], "roles": ["host", "443"]}]},
        {"a": {"status": "up"}, "b": {"status": "unknown"}},
    )
    assert partial[0]["status"] == "up"


def test_attach_status_all_unknown_not_down() -> None:
    out = attach_status(
        {"services": [{"id": "svc-x", "key": "x", "label": "X", "member_ids": ["a", "b"], "roles": ["host", "443"]}]},
        {"a": {"status": "unknown"}, "b": {"status": "down"}},
    )
    assert out[0]["status"] == "degraded"
    all_down = attach_status(
        {"services": [{"id": "svc-x", "key": "x", "label": "X", "member_ids": ["a", "b"], "roles": ["host", "443"]}]},
        {"a": {"status": "down"}, "b": {"status": "down"}},
    )
    assert all_down[0]["status"] == "down"


def test_normalize_keeps_group() -> None:
    n = normalize_node(
        {"id": "ha.lan", "type": "host", "label": "Home Assistant", "dns": "ha.lan", "group": "ha"}
    )
    assert n["group"] == "ha"
    assert node_group_key(n) == "ha"


def test_normalize_keeps_ssh_user_and_telemetry() -> None:
    n = normalize_node(
        {
            "id": "aka",
            "type": "machine",
            "label": "aka",
            "dns": "aka.lan",
            "ip": None,
            "sshUser": "red",
            "telemetry": False,
        }
    )
    assert n["sshUser"] == "red"
    assert n["telemetry"] is False


def test_leftover_skips_grouped() -> None:
    nodes = [
        {"id": "ha.lan", "type": "host", "label": "HA", "dns": "ha.lan", "group": "ha"},
        {"id": "notes.lan", "type": "host", "label": "notes.lan", "dns": "notes.lan"},
    ]
    dash = group_nodes(nodes)
    lan, proxies = leftover_rows(nodes, {}, dash["grouped_ids"])
    assert [n["id"] for n in lan] == ["notes.lan"]
    assert proxies == []


def test_normalize_keeps_map_hidden_and_zone() -> None:
    n = normalize_node(
        {
            "id": "xmcp",
            "type": "proxy",
            "label": "xMCP",
            "check": "http",
            "url": "https://xmcp-write.dfiander.workers.dev/mcp",
            "zone": "external",
            "httpReachable": True,
            "mapHidden": True,
        }
    )
    assert n["zone"] == "external"
    assert n["httpReachable"] is True
    assert n["mapHidden"] is True
    clear = normalize_node(
        {
            "id": "xmcp",
            "type": "proxy",
            "label": "xMCP",
            "check": "http",
            "url": "https://example.test/",
        }
    )
    assert "mapHidden" not in clear


if __name__ == "__main__":
    test_inventory_groups()
    test_attach_status_degraded()
    test_attach_status_all_unknown_not_down()
    test_normalize_keeps_group()
    test_normalize_keeps_ssh_user_and_telemetry()
    test_normalize_keeps_map_hidden_and_zone()
    test_leftover_skips_grouped()
    print("ok")
