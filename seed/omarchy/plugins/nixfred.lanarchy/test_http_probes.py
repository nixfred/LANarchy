#!/usr/bin/env python3
"""HTTP probes verify TLS, refuse non-HTTP(S), and never slurp an unbounded body."""
from __future__ import annotations

from unittest.mock import patch

from probe import HTTP_PROBE_MAX_BYTES, check_http
from telemetry_lib import http_timing


def test_http_timing_verifies_tls() -> None:
    seen = []

    def fake_run(args, timeout):
        seen.append(args)
        return "200 0.01 0.02"

    with patch("telemetry_lib._run", fake_run):
        got = http_timing("https://ha.lan/health")
    assert got["http_code"] == 200
    args = seen[0]
    assert "-k" not in args
    assert "-s" in args
    assert args[args.index("--proto") + 1] == "=http,https"


def test_check_http_refuses_non_http() -> None:
    assert check_http("file:///etc/passwd") == "down"
    assert check_http("ftp://files.lan/x") == "down"
    assert check_http("not-a-url") == "down"


class _CappedResp:
    def __init__(self, status: int, body: bytes):
        self.status = status
        self._body = body
        self._off = 0

    def read(self, n: int = -1) -> bytes:
        if n is None or n < 0:
            raise AssertionError("uncapped read")
        if n > HTTP_PROBE_MAX_BYTES:
            raise AssertionError(f"read too large: {n}")
        data = self._body[self._off : self._off + n]
        self._off += len(data)
        return data

    def __enter__(self) -> _CappedResp:
        return self

    def __exit__(self, *args) -> bool:
        return False


def test_check_http_caps_body() -> None:
    huge = b"x" * (HTTP_PROBE_MAX_BYTES * 4)
    with patch("urllib.request.urlopen", return_value=_CappedResp(200, huge)):
        assert check_http("https://ha.lan/health") == "up"


if __name__ == "__main__":
    test_http_timing_verifies_tls()
    test_check_http_refuses_non_http()
    test_check_http_caps_body()
    print("ok")
