#!/usr/bin/env python3
"""ss -tunH talkers: ESTAB remotes only, omit when ss is missing."""
from __future__ import annotations

import subprocess

from telemetry_lib import REMOTE_SCRIPT, parse_machine_report, parse_ss_talkers, ss_peer_host

SS = "\n".join(
    [
        "tcp   TIME-WAIT 0 0 192.168.1.10:22     192.168.1.5:1",
        "tcp   ESTAB     0 0 192.168.1.10:22     192.168.1.5:52341",
        "tcp   ESTAB     0 0 192.168.1.10:22     192.168.1.5:52342",
        "tcp   ESTAB     0 0 192.168.1.10:443    8.8.8.8:443",
        "tcp   ESTAB     0 0 192.168.1.10:443    8.8.8.8:444",
        "tcp   ESTAB     0 0 192.168.1.10:443    1.1.1.1:443",
        "tcp   ESTAB     0 0 192.168.1.10:443    9.9.9.9:443",
        "tcp   ESTAB     0 0 [::1]:22            [::1]:9",
        "tcp   LISTEN    0 128 0.0.0.0:22        0.0.0.0:*",
        "udp   ESTAB     0 0 192.168.1.10:53     192.168.1.5:53",
        "udp   UNCONN    0 0 0.0.0.0:68          0.0.0.0:*",
    ]
)

T_PREFIXED = "\n".join("T " + line for line in SS.splitlines())

EXPECTED = {
    "total": 8,
    "top": [
        {"host": "192.168.1.5", "count": 3},
        {"host": "8.8.8.8", "count": 2},
        {"host": "1.1.1.1", "count": 1},
        {"host": "9.9.9.9", "count": 1},
    ],
}


def test_peer_host_v4_and_v6() -> None:
    assert ss_peer_host("192.168.1.5:52341") == "192.168.1.5"
    assert ss_peer_host("[2001:db8::1]:443") == "2001:db8::1"
    assert ss_peer_host("[fe80::1%eth0]:22") == "fe80::1"


def test_parse_ranks_remotes_and_skips_listen() -> None:
    assert parse_ss_talkers(SS) == EXPECTED
    assert parse_ss_talkers(T_PREFIXED) == EXPECTED


def test_parse_soft_fails_empty() -> None:
    assert parse_ss_talkers("") is None
    assert parse_ss_talkers("not ss output") is None
    assert parse_ss_talkers("tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*") is None


def test_report_attaches_talkers_from_t_lines() -> None:
    text = "\n".join(
        [
            "L eth0 1000 full eth",
            "D eth0: 10 0 0 0 0 0 0 0 20 0 0 0 0 0 0 0",
            "U 12.5 0.0",
            T_PREFIXED,
        ]
    )
    got = parse_machine_report(text)
    assert got["talkers"] == EXPECTED
    assert got["uptime_s"] == 12.5
    assert got["rx_bytes"] == 10


def test_report_omits_talkers_when_ss_missing() -> None:
    got = parse_machine_report("L eth0 1000 full eth\nU 1.0 0.0")
    assert "talkers" not in got


def test_local_script_emits_talkers() -> None:
    proc = subprocess.run(["bash", "-c", REMOTE_SCRIPT], capture_output=True, text=True, timeout=5)
    assert proc.returncode == 0
    t_lines = [line for line in proc.stdout.splitlines() if line.startswith("T ")]
    assert t_lines
    got = parse_machine_report(proc.stdout)
    assert got.get("talkers") == parse_ss_talkers("\n".join(t_lines))


if __name__ == "__main__":
    test_peer_host_v4_and_v6()
    test_parse_ranks_remotes_and_skips_listen()
    test_parse_soft_fails_empty()
    test_report_attaches_talkers_from_t_lines()
    test_report_omits_talkers_when_ss_missing()
    test_local_script_emits_talkers()
    print("ok")
