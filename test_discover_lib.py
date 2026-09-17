#!/usr/bin/env python3
"""discover_lib: literal candidates from fixture avahi/neigh text, no live daemon (OmarPlugs-5oy.18)."""
from __future__ import annotations

from discover_lib import (
    collect_discover,
    is_known,
    known_targets,
    mdns_candidates,
    merge_discover,
    neigh_candidates,
    parse_avahi,
)
from telemetry_lib import parse_neigh

AVAHI = "\n".join(
    [
        "+;wlp2s0;IPv4;Home;_home-assistant._tcp;local",
        "=;wlp2s0;IPv6;aka\\032\\091dc\\058a6\\05832\\05815\\058ee\\058ae\\093;_workstation._tcp;local;aka.local;fe80::1;9;",
        "=;wlp2s0;IPv4;aka\\032\\091dc\\058a6\\05832\\05815\\058ee\\058ae\\093;_workstation._tcp;local;aka.local;192.168.1.11;9;",
        "=;wlp2s0;IPv4;aka\\032\\091dc\\058a6\\05832\\05815\\058ee\\058af\\093;_workstation._tcp;local;aka.local;192.168.1.11;9;",
        "=;wlp2s0;IPv4;Home;_home-assistant._tcp;local;6629267f.local;192.168.1.178;8123;\"location_name=Home\"",
        "=;wlp2s0;IPv4;MacBookPro-L52X9HTGV2;_companion-link._tcp;local;MacBookPro-L52X9HTGV2.local;192.168.1.108;63367;\"rpBA=8E:F0\"",
        "=;wlp2s0;IPv4;FEC9D0B9F4BE\\064MacBookPro-L52X9HTGV2;_raop._tcp;local;MacBookPro-L52X9HTGV2.local;192.168.1.108;7000;",
        "=;wlp2s0;IPv4;MacBookPro-L52X9HTGV2;_airplay._tcp;local;MacBookPro-L52X9HTGV2.local;192.168.1.108;7000;",
        "=;wlp2s0;IPv4;MacBookPro-L52X9HTGV2;_ssh._tcp;local;MacBookPro-L52X9HTGV2.local;192.168.1.108;22;",
        "=;wlp2s0;IPv4;esp-master;_esphomelib._tcp;local;esp-master.local;192.168.1.209;6053;\"mac=04830858e1d0\"",
        "=;wlp2s0;IPv4;onn-4K-Pro-b7eb562d;_googlecast._tcp;local;b7eb562d-8672.local;192.168.1.112;8009;\"fn=Living Room TV\"",
        "=;wlp2s0;IPv4;Living\\032Room\\032TV;_androidtvremote2._tcp;local;Android_YHKOAT02.local;192.168.1.112;6466;\"bt=88:42\"",
        "=;wlp2s0;IPv4;ddc8c6250309563a;_ghp._tcp;local;Android_YHKOAT02.local;192.168.1.112;45147;\"p=ATV\"",
    ]
)

NEIGH = (
    '[{"dst":"192.168.1.209","dev":"wlp2s0","lladdr":"04:83:08:58:e1:d0","state":["REACHABLE"]},'
    '{"dst":"192.168.1.55","dev":"wlp2s0","lladdr":"aa:bb:cc:dd:ee:55","state":["STALE"]},'
    '{"dst":"192.168.1.11","dev":"wlp2s0","lladdr":"dc:a6:32:15:ee:ae","state":["REACHABLE"]},'
    '{"dst":"192.168.1.66","dev":"wlp2s0","state":["FAILED"]}]'
)

NODES = [
    {"id": "aka", "type": "machine", "label": "aka", "dns": "aka.lan", "ip": None},
    {"id": "ha.lan", "type": "host", "label": "Home Assistant", "dns": "ha.lan", "ip": None},
]
HIST = {
    "series": {
        "aka": {"samples": [], "meta": {"mac": "dc:a6:32:15:ee:ae", "ip": "192.168.1.11"}},
        "ha.lan": {"samples": [], "meta": {"mac": "dc:a6:32:27:be:b6", "ip": "192.168.1.178"}},
    }
}
MACBOOK = {
    "source": "mdns",
    "type": "machine",
    "label": "MacBookPro-L52X9HTGV2",
    "host": "MacBookPro-L52X9HTGV2",
    "ip": "192.168.1.108",
    "mac": None,
    "services": ["_companion-link._tcp", "_raop._tcp", "_airplay._tcp", "_ssh._tcp"],
}
ESP = {
    "source": "mdns",
    "type": "host",
    "label": "esp-master",
    "host": "esp-master",
    "ip": "192.168.1.209",
    "mac": "04:83:08:58:e1:d0",
    "services": ["_esphomelib._tcp"],
}
TV = {
    "source": "mdns",
    "type": "host",
    "label": "Living Room TV",
    "host": "Android_YHKOAT02",
    "ip": "192.168.1.112",
    "mac": None,
    "services": ["_googlecast._tcp", "_androidtvremote2._tcp", "_ghp._tcp"],
}
STRAY = {"source": "neigh", "type": "host", "label": "192.168.1.55", "host": None, "ip": "192.168.1.55", "mac": "aa:bb:cc:dd:ee:55", "services": []}


def scan() -> list[dict]:
    neigh = parse_neigh(NEIGH)
    mdns = mdns_candidates(parse_avahi(AVAHI), {n["ip"]: n["mac"] for n in neigh})
    return mdns + neigh_candidates(neigh, {c["ip"] for c in mdns})


def test_parse_avahi_unescapes_and_keeps_resolved_ipv4_only() -> None:
    rows = parse_avahi(AVAHI)
    assert len(rows) == 11
    assert rows[0] == {"name": "aka [dc:a6:32:15:ee:ae]", "type": "_workstation._tcp", "host": "aka", "ip": "192.168.1.11"}
    assert rows[4]["name"] == "FEC9D0B9F4BE@MacBookPro-L52X9HTGV2"


def test_parse_neigh_drops_failed() -> None:
    assert parse_neigh(NEIGH)[1] == {"ip": "192.168.1.55", "mac": "aa:bb:cc:dd:ee:55", "state": "STALE"}
    assert len(parse_neigh(NEIGH)) == 3


def test_mdns_groups_by_ip_and_suggests_type() -> None:
    rows = scan()
    aka = rows[0]
    assert aka["label"] == "aka" and aka["mac"] == "dc:a6:32:15:ee:ae" and aka["type"] == "machine"
    assert rows[1]["label"] == "Home" and rows[1]["type"] == "host"
    assert rows[2:] == [MACBOOK, ESP, TV, STRAY]


def test_bracket_mac_fills_when_neigh_missing() -> None:
    rows = mdns_candidates(parse_avahi(AVAHI), {})
    assert rows[0]["mac"] == "dc:a6:32:15:ee:ae"


def test_known_targets_includes_history_meta() -> None:
    known = known_targets(NODES, HIST)
    # machine history counts; host (reverse-proxy) history does not
    assert "192.168.1.11" in known["ips"]
    assert "dc:a6:32:15:ee:ae" in known["macs"]
    assert "192.168.1.178" not in known["ips"]
    assert is_known({"label": "aka ee:af", "ip": "192.168.1.12"}, known) is True
    assert is_known(MACBOOK, known) is False


def test_merge_filters_known_and_dedups_with_unifi() -> None:
    unifi = [
        {"source": "unifi", "kind": "client", "type": "host", "label": "esp-master e1:d0", "host": None, "ip": "192.168.1.209", "mac": None},
        {"source": "unifi", "kind": "client", "type": "host", "label": "aka ee:af", "host": None, "ip": "192.168.1.12", "mac": None},
        {"source": "unifi", "kind": "client", "type": "host", "label": "Mac 65:6e", "host": None, "ip": "192.168.1.91", "mac": None},
        {"source": "unifi", "kind": "client", "type": "host", "label": "Laptop", "host": "macbookpro-l52x9htgv2", "ip": "192.168.1.108", "mac": "fe:c9:d0:b9:f4:be"},
    ]
    merged = merge_discover(scan(), unifi, known=known_targets(NODES, HIST))
    labels = [x["label"] for x in merged]
    # aka filtered by machine history IP/MAC; HA reverse-proxy host does not hide the Pi
    assert "aka" not in labels
    assert "Home" in labels
    assert "Laptop" in labels  # unifi label wins on same device as MacBook mDNS
    assert "Mac 65:6e" in labels
    assert "esp-master e1:d0" in labels
    assert "192.168.1.55" in labels
    assert labels == sorted(labels, key=str.lower)


def test_collect_soft_fails_without_avahi(monkeypatch=None) -> None:
    import discover_lib

    saved = (discover_lib.AVAHI_CMD, dict(discover_lib._cache))
    discover_lib.AVAHI_CMD = ["/nonexistent/avahi-browse"]
    discover_lib._cache.update(ts=float("-inf"), rows=[])
    try:
        rows = collect_discover()
        assert isinstance(rows, list)
        assert all(r.get("source") == "neigh" for r in rows)
        # Soft-fail still returns neigh rows when the ARP table has lladdrs; empty is also fine.
        assert rows == [] or all("ip" in r and "mac" in r for r in rows)
    finally:
        discover_lib.AVAHI_CMD = saved[0]
        discover_lib._cache.update(saved[1])


def test_reverse_dns_rejects_synthetic_and_self_answers() -> None:
    from discover_lib import reverse_dns

    assert reverse_dns("10.0.0.5", resolver=lambda ip: ("deba.lan", [], [ip])) == "deba.lan"
    assert reverse_dns("10.0.0.1", resolver=lambda ip: ("_gateway", [], [ip])) is None
    assert reverse_dns("127.0.0.1", resolver=lambda ip: ("localhost", [], [ip])) is None
    assert reverse_dns("10.0.0.9", resolver=lambda ip: ("10.0.0.9", [], [ip])) is None

    def boom(ip):
        raise OSError("no PTR")

    assert reverse_dns("10.0.0.7", resolver=boom) is None


def test_reverse_dns_map_skips_unresolved() -> None:
    from discover_lib import reverse_dns_map

    names = {"10.0.0.5": "deba.lan"}

    def resolver(ip):
        if ip in names:
            return (names[ip], [], [ip])
        raise OSError("no PTR")

    out = reverse_dns_map(["10.0.0.5", "10.0.0.6"], resolver=resolver)
    assert out == {"10.0.0.5": "deba.lan"}
    assert reverse_dns_map([], resolver=resolver) == {}


def test_neigh_candidates_prefer_ptr_name_over_bare_ip() -> None:
    from discover_lib import neigh_candidates

    neigh = [{"ip": "10.0.0.5", "mac": "aa:bb:cc:dd:ee:01"},
             {"ip": "10.0.0.6", "mac": "aa:bb:cc:dd:ee:02"}]
    rows = neigh_candidates(neigh, set(), {"10.0.0.5": "deba.lan"})
    named = next(r for r in rows if r["ip"] == "10.0.0.5")
    bare = next(r for r in rows if r["ip"] == "10.0.0.6")
    assert named["label"] == "deba" and named["host"] == "deba.lan"
    assert bare["label"] == "10.0.0.6" and bare["host"] is None


def test_opaque_pairing_id_falls_back_to_host() -> None:
    from discover_lib import is_opaque_label, mdns_candidates

    assert is_opaque_label("83DEE99F-B526-470F-9D1B-16EC01196A2C")
    assert not is_opaque_label("fnix")
    assert not is_opaque_label("Living Room TV")

    # a uuid instance name with a resolved host shows the host instead
    recs = [{"name": "83DEE99F-B526-470F-9D1B-16EC01196A2C", "type": "_http._tcp",
             "host": "spike-iphone", "ip": "10.0.0.153"}]
    rows = mdns_candidates(recs, {})
    assert len(rows) == 1 and rows[0]["label"] == "spike-iphone"

    # and is dropped entirely when there is nothing else to call it
    recs2 = [{"name": "83DEE99F-B526-470F-9D1B-16EC01196A2C", "type": "_http._tcp",
              "host": None, "ip": "10.0.0.154"}]
    assert mdns_candidates(recs2, {}) == []


def test_multihomed_host_is_one_device() -> None:
    """Same box on wifi and ethernet: two IPs, two MACs, one name."""
    from discover_lib import merge_discover

    wifi = {"source": "mdns", "type": "machine", "label": "fnix", "host": "fnix",
            "ip": "10.0.0.213", "mac": "aa:bb:cc:dd:ee:01"}
    wired = {"source": "mdns", "type": "machine", "label": "fnix", "host": "fnix",
             "ip": "10.0.0.124", "mac": "aa:bb:cc:dd:ee:02"}
    rows = merge_discover([wifi, wired], known={"ips": set(), "macs": set(), "hosts": set()})
    assert len(rows) == 1, rows



if __name__ == "__main__":
    test_parse_avahi_unescapes_and_keeps_resolved_ipv4_only()
    test_parse_neigh_drops_failed()
    test_mdns_groups_by_ip_and_suggests_type()
    test_bracket_mac_fills_when_neigh_missing()
    test_known_targets_includes_history_meta()
    test_merge_filters_known_and_dedups_with_unifi()
    test_collect_soft_fails_without_avahi()
    test_reverse_dns_rejects_synthetic_and_self_answers()
    test_reverse_dns_map_skips_unresolved()
    test_neigh_candidates_prefer_ptr_name_over_bare_ip()
    test_opaque_pairing_id_falls_back_to_host()
    test_multihomed_host_is_one_device()
    print("ok")
