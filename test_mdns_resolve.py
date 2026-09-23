"""A .local name must be resolved by the mDNS resolver, not the system one.

`ping fnix.local` only works if nss-mdns is installed and healthy. When it is
not, it does not fail fast -- it hangs past the probe's whole budget, so the
node reports "unknown" and falls back to the address stored when it was added.
On a laptop using a private, rotating wifi MAC that address is stale within
days, so a machine sitting right there reads as down.
"""
import subprocess
import sys

import probe
from probe import resolve_mdns


class _Proc:
    def __init__(self, rc=0, out=""):
        self.returncode = rc
        self.stdout = out
        self.stderr = ""


def _patch(fn):
    real = subprocess.run
    probe.subprocess.run = fn
    return real


def _restore(real):
    probe.subprocess.run = real


def test_resolves_a_local_name():
    real = _patch(lambda *a, **k: _Proc(0, "fnix.local\t10.0.0.128\n"))
    try:
        assert resolve_mdns("fnix.local") == "10.0.0.128"
    finally:
        _restore(real)


def test_non_local_names_are_left_alone():
    """Only .local is mDNS. Everything else belongs to the system resolver."""
    called = []
    real = _patch(lambda *a, **k: called.append(a) or _Proc(0, "x 1.2.3.4"))
    try:
        assert resolve_mdns("nas.lan") is None
        assert resolve_mdns("10.0.0.5") is None
        assert resolve_mdns("") is None
        assert called == [], "must not shell out for a non-mDNS name"
    finally:
        _restore(real)


def test_missing_avahi_is_not_an_error():
    """No avahi means fall through to the ordinary path, not a crash."""
    def boom(*a, **k):
        raise FileNotFoundError("avahi-resolve-host-name")
    real = _patch(boom)
    try:
        assert resolve_mdns("fnix.local") is None
    finally:
        _restore(real)


def test_timeout_and_failure_return_none():
    def slow(*a, **k):
        raise subprocess.TimeoutExpired("avahi-resolve-host-name", 1.0)
    real = _patch(slow)
    try:
        assert resolve_mdns("fnix.local") is None
    finally:
        _restore(real)
    real = _patch(lambda *a, **k: _Proc(1, ""))
    try:
        assert resolve_mdns("fnix.local") is None
    finally:
        _restore(real)


def test_unparseable_output_returns_none():
    real = _patch(lambda *a, **k: _Proc(0, "fnix.local\n"))
    try:
        assert resolve_mdns("fnix.local") is None
    finally:
        _restore(real)


if __name__ == "__main__":
    for name, fn in sorted(list(globals().items())):
        if name.startswith("test_"):
            fn()
            print("ok", name)
    sys.exit(0)
