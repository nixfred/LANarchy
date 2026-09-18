#!/usr/bin/env python3
"""OS identification: what the evidence supports, and nothing more."""
from __future__ import annotations

from os_lib import (
    family_from_services,
    family_from_ttl,
    family_from_uname,
    family_from_unifi,
    identify,
)


def test_ttl_bands() -> None:
    assert family_from_ttl(64) == "unix"
    assert family_from_ttl(52) == "unix"      # 64 minus hops
    assert family_from_ttl(128) == "windows"
    assert family_from_ttl(119) == "windows"
    assert family_from_ttl(255) == "appliance"
    assert family_from_ttl(0) is None
    assert family_from_ttl(300) is None
    assert family_from_ttl(None) is None
    assert family_from_ttl("banana") is None


def test_uname_families() -> None:
    assert family_from_uname("Linux") == "linux"
    assert family_from_uname("Darwin") == "macos"
    assert family_from_uname("FreeBSD") == "bsd"
    assert family_from_uname("MINGW64_NT-10.0") == "windows"
    assert family_from_uname("") is None
    assert family_from_uname(None) is None


def test_mdns_apple_and_linux_tells() -> None:
    assert family_from_services(["_companion-link._tcp"]) == "macos"
    assert family_from_services(["_workstation._tcp"]) == "linux"
    assert family_from_services(["_http._tcp"]) is None
    assert family_from_services(None) is None


def test_airplay_is_an_apple_device_not_a_mac() -> None:
    """iPhones, HomePods and Apple TVs all publish _airplay and _raop.

    Calling those macOS badged a phone as a Mac with "likely" confidence, which
    is worse than the vaguer TTL guess it replaced: a confident wrong answer.
    """
    assert family_from_services(["_airplay._tcp"]) == "apple"
    assert family_from_services(["_raop._tcp"]) == "apple"
    assert family_from_services(["_apple-mobdev2._tcp"]) == "apple"
    assert identify(ttl=64, services=["_airplay._tcp"])["label"] == "APPLE"

    # a real Mac says so through services only a computer publishes
    assert family_from_services(["_companion-link._tcp", "_airplay._tcp"]) == "macos"
    # and uname still beats every guess
    assert identify(uname="Darwin", services=["_airplay._tcp"])["family"] == "macos"


def test_unifi_os_name() -> None:
    assert family_from_unifi({"os_name": "Darwin"}) == "macos"
    assert family_from_unifi({"os": "Linux"}) == "linux"
    assert family_from_unifi({}) is None
    assert family_from_unifi("nope") is None


def test_uname_beats_ttl() -> None:
    """A box that said Darwin is macOS, even though its TTL only says unix."""
    got = identify(uname="Darwin", ttl=64)
    assert got["family"] == "macos"
    assert got["confidence"] == "certain"
    assert got["source"] == "uname"


def test_ttl_alone_does_not_claim_linux() -> None:
    """TTL 64 cannot separate Linux from macOS, so it must not guess either."""
    got = identify(ttl=64)
    assert got["family"] == "unix"
    assert got["label"] == "UNIX"
    assert got["confidence"] == "guess"


def test_inventory_role_router_wins() -> None:
    got = identify(uname="Linux", ttl=64, role="router")
    assert got["family"] == "router" and got["confidence"] == "certain"


def test_no_evidence_is_unknown_not_a_guess() -> None:
    got = identify()
    assert got["family"] == "unknown"
    assert got["label"] == "MACHINE"
    assert got["confidence"] == "unknown"
    assert got["source"] == "none"


def test_mdns_outranks_ttl() -> None:
    got = identify(ttl=64, services=["_companion-link._tcp"])
    assert got["family"] == "macos" and got["source"] == "mdns"


if __name__ == "__main__":
    for _name, _fn in sorted(list(globals().items())):
        if _name.startswith("test_") and callable(_fn):
            _fn()
    print("ok")
