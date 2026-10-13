#!/usr/bin/env python3
"""speedtest_lib prefers curl and degrades when iperf3 is missing."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from speedtest_lib import (
    DEFAULT_SPEEDTEST_URL,
    RunResult,
    curl_throughput,
    iperf3_oneshot,
    parse_curl_writeout,
    parse_iperf3_json,
    resolve_speedtest_url,
    run_speedtest,
)

IPERF_OK = json.dumps({"end": {"sum_received": {"bits_per_second": 934_000_000, "seconds": 3.0}}})


class DummyProc:
    def poll(self):
        return 0

    def terminate(self):
        return None

    def wait(self, timeout=None):
        return 0

    def kill(self):
        return None


def test_url_from_settings() -> None:
    inv = {"settings": {"speedtestUrl": "https://files.lan/big.bin"}, "nodes": []}
    assert resolve_speedtest_url(inv) == "https://files.lan/big.bin"


def test_url_files_lan_default() -> None:
    inv = {"nodes": [{"id": "files.lan", "type": "host", "dns": "files.lan"}]}
    assert resolve_speedtest_url(inv) == DEFAULT_SPEEDTEST_URL
    assert resolve_speedtest_url({}) == DEFAULT_SPEEDTEST_URL
    assert resolve_speedtest_url(None) == DEFAULT_SPEEDTEST_URL


def test_parse_curl_writeout() -> None:
    assert parse_curl_writeout("200 10485760 0.8 13107200") == {
        "http_code": 200,
        "bytes": 10485760,
        "seconds": 0.8,
        "mbps": 13107200 * 8 / 1_000_000,
    }
    assert parse_curl_writeout("nope") is None


def test_curl_ok_and_http_error() -> None:
    seen = {}

    def run_ok(args, timeout, stdin=None):
        seen["args"] = args
        return RunResult(0, "200 1000 0.5 2000", "")

    got = curl_throughput("https://files.lan/", run=run_ok)
    assert "-k" not in seen["args"]
    assert "-s" in seen["args"]
    assert seen["args"][seen["args"].index("--proto") + 1] == "=http,https"
    assert got == {
        "ok": True,
        "method": "curl",
        "mbps": 2000 * 8 / 1_000_000,
        "bytes": 1000,
        "seconds": 0.5,
        "url": "https://files.lan/",
        "host": None,
        "error": None,
        "tried": ["curl"],
    }

    def run_404(args, timeout, stdin=None):
        return RunResult(0, "404 12 0.1 120", "")

    bad = curl_throughput("https://files.lan/missing", run=run_404)
    assert bad["ok"] is False
    assert bad["error"] == "HTTP 404"
    assert bad["method"] == "curl"


def test_parse_iperf3_json() -> None:
    assert parse_iperf3_json(IPERF_OK) == {"mbps": 934.0, "seconds": 3.0, "bytes": None}
    assert parse_iperf3_json("{") is None


def test_iperf3_missing_local() -> None:
    def run(args, timeout, stdin=None):
        if args[:2] == ["iperf3", "--version"]:
            return RunResult(127, "", "not found")
        raise AssertionError(f"unexpected {args}")

    got = iperf3_oneshot("remote-box.test", run=run, spawn=lambda args: DummyProc(), wait_s=0)
    assert got["ok"] is False
    assert got["error"] == "iperf3 not local"
    assert got["method"] == "iperf3"


def test_iperf3_missing_on_host() -> None:
    def run(args, timeout, stdin=None):
        if args[:2] == ["iperf3", "--version"]:
            return RunResult(0, "iperf 3.16", "")
        if args[0] == "ssh" and args[-1] == "command -v iperf3":
            return RunResult(1, "", "")
        raise AssertionError(f"unexpected {args}")

    got = iperf3_oneshot("remote-box.test", run=run, spawn=lambda args: DummyProc(), wait_s=0)
    assert got["ok"] is False
    assert got["error"] == "iperf3 not on host"


def test_run_prefers_curl() -> None:
    seen = []

    def run(args, timeout, stdin=None):
        seen.append(args[0])
        if args[0] == "curl":
            return RunResult(0, "200 5000 0.25 20000", "")
        raise AssertionError("iperf3 must not run when curl works")

    got = run_speedtest(url="https://files.lan/", host="remote-box.test", run=run, spawn=lambda args: DummyProc())
    assert got["ok"] is True
    assert got["method"] == "curl"
    assert got["tried"] == ["curl"]
    assert seen == ["curl"]


def test_run_falls_back_to_iperf3() -> None:
    def run(args, timeout, stdin=None):
        if args[0] == "curl":
            return RunResult(0, "503 0 0.1 0", "")
        if args[:2] == ["iperf3", "--version"]:
            return RunResult(0, "iperf 3.16", "")
        if args[0] == "ssh" and args[-1] == "command -v iperf3":
            return RunResult(0, "/usr/bin/iperf3\n", "")
        if args[0] == "iperf3" and "-c" in args:
            return RunResult(0, IPERF_OK, "")
        raise AssertionError(f"unexpected {args}")

    got = run_speedtest(url="https://files.lan/", host="remote-box.test", run=run, spawn=lambda args: DummyProc())
    assert got["ok"] is True
    assert got["method"] == "iperf3"
    assert got["mbps"] == 934.0
    assert got["tried"] == ["curl", "iperf3"]


def test_run_degrades_when_both_fail() -> None:
    def run(args, timeout, stdin=None):
        if args[0] == "curl":
            return RunResult(7, "", "connection refused")
        if args[:2] == ["iperf3", "--version"]:
            return RunResult(127, "", "not found")
        raise AssertionError(f"unexpected {args}")

    got = run_speedtest(url="https://files.lan/", host="remote-box.test", run=run, spawn=lambda args: DummyProc())
    assert got["ok"] is False
    assert got["method"] is None
    assert got["tried"] == ["curl", "iperf3"]
    assert got["error"] == "connection refused · iperf3 not local"


def test_cli_speedtest_json() -> None:
    here = Path(__file__).resolve().parent
    proc = subprocess.run(
        [sys.executable, str(here / "probe.py"), "speedtest"],
        cwd=str(here),
        capture_output=True,
        text=True,
        timeout=25,
    )
    data = json.loads(proc.stdout)
    assert "ok" in data
    assert data.get("method") in (None, "curl", "iperf3")
    if data["ok"]:
        assert isinstance(data["mbps"], (int, float))
        assert data["mbps"] >= 0
        assert proc.returncode == 0
    else:
        assert data.get("error")
        assert proc.returncode == 1


if __name__ == "__main__":
    test_url_from_settings()
    test_url_files_lan_default()
    test_parse_curl_writeout()
    test_curl_ok_and_http_error()
    test_parse_iperf3_json()
    test_iperf3_missing_local()
    test_iperf3_missing_on_host()
    test_run_prefers_curl()
    test_run_falls_back_to_iperf3()
    test_run_degrades_when_both_fail()
    test_cli_speedtest_json()
    print("ok")
