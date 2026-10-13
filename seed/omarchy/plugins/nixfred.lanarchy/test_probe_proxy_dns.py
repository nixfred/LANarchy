#!/usr/bin/env python3
"""Proxy DNS miss must be unknown, not down (fail-streak safety)."""
from unittest.mock import patch

from probe import probe_proxy_node


def test_proxy_dns_miss_is_unknown() -> None:
    node = {"id": "svc", "type": "proxy", "label": "svc", "check": "tcp", "dns": "missing.lan", "port": 443}
    with (
        patch("probe.probe_target", return_value=("missing.lan", 443, None)),
        patch("probe.resolve_ipv4", return_value=None),
    ):
        row = probe_proxy_node(node)
    assert row["status"] == "unknown"


def test_proxy_http_dns_miss_is_unknown() -> None:
    node = {"id": "web", "type": "proxy", "label": "web", "check": "http", "url": "https://gone.lan/"}
    with (
        patch("probe.probe_target", return_value=("gone.lan", 443, "https://gone.lan/")),
        patch("probe.resolve_ipv4", return_value=None),
    ):
        row = probe_proxy_node(node)
    assert row["status"] == "unknown"


if __name__ == "__main__":
    test_proxy_dns_miss_is_unknown()
    test_proxy_http_dns_miss_is_unknown()
    print("ok")
