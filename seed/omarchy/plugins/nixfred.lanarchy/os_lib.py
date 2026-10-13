"""Best-effort OS identification for a node, from evidence already collected.

Nothing here adds a probe. The ping we already run carries a TTL, the SSH
telemetry hop can answer `uname` in the same round trip, and mDNS service types
we already browse are a strong Apple tell.

Every answer carries its source and confidence, and "unknown" is a real answer:
a wrong OS badge on a card is worse than no badge.
"""
from __future__ import annotations

import re

# Initial TTL by stack. Routers and embedded gear answer 255, Windows 128,
# Linux / macOS / BSD 64. The observed TTL is the initial value minus hops, so
# each is matched as a band below its origin.
TTL_BANDS = (
    (255, 128, "appliance"),   # 129..255: network gear, printers, IoT
    (128, 64, "windows"),      #  65..128: Windows
    (64, 0, "unix"),           #   1..64 : Linux / macOS / BSD
)

# Services that mean "an Apple computer", not merely "an Apple device".
# _airplay and _raop are published by iPhones, HomePods and Apple TVs, so
# treating them as macOS labelled phones as Macs with full confidence, which is
# worse than the vaguer TTL guess they replaced.
APPLE_COMPUTER_SERVICES = frozenset({
    "_companion-link._tcp",
    "_rdlink._tcp",
    "_sleep-proxy._udp",
    "_smbserver._tcp",
})
# Apple, but not a computer: useful for saying "Apple device" and nothing more.
APPLE_DEVICE_SERVICES = frozenset({
    "_airplay._tcp",
    "_raop._tcp",
    "_apple-mobdev2._tcp",
    "_touch-able._tcp",
})
# Avahi publishes this on Linux desktops; Apple does not.
LINUX_SERVICES = frozenset({"_workstation._tcp"})

FAMILY_LABELS = {
    "linux": "LINUX",
    "macos": "MACOS",
    "windows": "WINDOWS",
    "bsd": "BSD",
    "unix": "UNIX",
    "apple": "APPLE",
    "appliance": "APPLIANCE",
    "router": "ROUTER",
    # Deliberately empty: "MACHINE" on a card of machines is not a fact, and
    # the panel shows the link kind instead when the OS is unknown.
    "unknown": "",
}


def family_from_ttl(ttl: object) -> str | None:
    """Coarse family from an observed ICMP TTL. None when unusable."""
    try:
        v = int(ttl)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    if not 1 <= v <= 255:
        return None
    for origin, floor, family in TTL_BANDS:
        if floor < v <= origin:
            return family
    return None


def family_from_uname(uname: object) -> str | None:
    """`uname -s` output to a family."""
    s = str(uname or "").strip().lower()
    if not s:
        return None
    if s.startswith("linux"):
        return "linux"
    if s.startswith("darwin"):
        return "macos"
    if "bsd" in s:
        return "bsd"
    if any(k in s for k in ("mingw", "msys", "cygwin", "windows")):
        return "windows"
    return None


def family_from_services(services: object) -> str | None:
    """Apple and Linux mDNS tells. Apple wins: its services are distinctive."""
    if not isinstance(services, (list, tuple, set, frozenset)):
        return None
    names = {str(s).strip().lower() for s in services}
    if names & APPLE_COMPUTER_SERVICES:
        return "macos"
    if names & LINUX_SERVICES:
        return "linux"
    if names & APPLE_DEVICE_SERVICES:
        # An Apple something. Claiming macOS here is how iPhones and HomePods
        # ended up badged as Macs.
        return "apple"
    return None


def family_from_unifi(entry: object) -> str | None:
    """UniFi sometimes names the client OS outright."""
    if not isinstance(entry, dict):
        return None
    for key in ("os_name", "osName", "os"):
        got = family_from_uname(entry.get(key))
        if got:
            return got
    return None


def identify(
    *,
    uname: object = None,
    ttl: object = None,
    services: object = None,
    unifi: object = None,
    role: object = None,
) -> dict:
    """Merge the evidence into {family, label, confidence, source}.

    Order is by trustworthiness: an explicit `role: router` in the inventory,
    then uname (the machine said so), then mDNS, then UniFi, then TTL. TTL alone
    cannot separate Linux from macOS, so it yields the honest "unix".
    """
    if str(role or "").strip().lower() == "router":
        return {"family": "router", "label": FAMILY_LABELS["router"],
                "confidence": "certain", "source": "inventory"}

    got = family_from_uname(uname)
    if got:
        return {"family": got, "label": FAMILY_LABELS[got],
                "confidence": "certain", "source": "uname"}

    got = family_from_services(services)
    if got:
        return {"family": got, "label": FAMILY_LABELS[got],
                "confidence": "likely", "source": "mdns"}

    got = family_from_unifi(unifi)
    if got:
        return {"family": got, "label": FAMILY_LABELS[got],
                "confidence": "likely", "source": "unifi"}

    got = family_from_ttl(ttl)
    if got:
        # "unix" is deliberately not narrowed to linux: TTL cannot tell them apart.
        return {"family": got, "label": FAMILY_LABELS[got],
                "confidence": "guess", "source": "ttl"}

    return {"family": "unknown", "label": FAMILY_LABELS["unknown"],
            "confidence": "unknown", "source": "none"}
