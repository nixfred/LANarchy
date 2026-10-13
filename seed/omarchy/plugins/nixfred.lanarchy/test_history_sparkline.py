#!/usr/bin/env python3
"""sparkline_payload reads rtt_ms and rx_bps; it does not invent rate."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from history_lib import empty_history, sparkline_payload, sparkline_values


def test_payload_rtt_and_rate() -> None:
    hist = empty_history()
    hist["series"]["aka"] = {
        "samples": [
            {"ts": "2026-09-16T20:00:00-03:00", "status": "up", "rtt_ms": 1.2, "rx_bps": 8000},
            {"ts": "2026-09-16T20:00:15-03:00", "status": "unknown"},
            {"ts": "2026-09-16T20:00:30-03:00", "status": "up", "rtt_ms": "2.5"},
            {"ts": "2026-09-16T20:00:45-03:00", "status": "up", "rtt_ms": 3.1, "rx_bps": 12000.5},
        ]
    }
    payload = sparkline_payload(hist, "aka", 4)
    assert payload == {
        "id": "aka",
        "values": [1.2, None, 2.5, 3.1],
        "rx_bps": [8000.0, None, None, 12000.5],
    }
    assert sparkline_values(hist, "aka", 4) == [1.2, None, 2.5, 3.1]


def test_payload_missing_node_is_empty() -> None:
    assert sparkline_payload(empty_history(), "nope", 8) == {
        "id": "nope",
        "values": [],
        "rx_bps": [],
    }


def test_payload_caps_at_n() -> None:
    hist = empty_history()
    hist["series"]["aka"] = {
        "samples": [{"ts": f"t{i}", "status": "up", "rtt_ms": i} for i in range(10)]
    }
    payload = sparkline_payload(hist, "aka", 3)
    assert payload["values"] == [7.0, 8.0, 9.0]
    assert payload["rx_bps"] == [None, None, None]


def test_cli_sparkline_id() -> None:
    here = Path(__file__).resolve().parent
    out = subprocess.check_output(
        [sys.executable, str(here / "history_cli.py"), "sparkline", "--id", "deba", "--n", "4"],
        cwd=str(here),
        text=True,
    )
    data = json.loads(out)
    assert data["id"] == "deba"
    assert isinstance(data["values"], list)
    assert isinstance(data["rx_bps"], list)
    assert len(data["values"]) == len(data["rx_bps"])
    for rtt, rx in zip(data["values"], data["rx_bps"]):
        assert rtt is None or isinstance(rtt, (int, float))
        assert rx is None or isinstance(rx, (int, float))


if __name__ == "__main__":
    test_payload_rtt_and_rate()
    test_payload_missing_node_is_empty()
    test_payload_caps_at_n()
    test_cli_sparkline_id()
    print("ok")
