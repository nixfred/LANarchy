"""A name a person would use, plus the identifier underneath it.

A card leads with a name you recognise. The raw identifier is kept, because it
is what you need when two things look alike, but it belongs in the detail, not
in the headline. `sonosRINCON_5CAAFD26F5E201400` is not a name; "Living Room"
is, and it was inside that string the whole time.
"""
from __future__ import annotations

import re

# `RINCON_<id>@Living Room` and `sonosRINCON_<id>` (Sonos), where the part after
# `@` is the room the owner chose.
_SONOS = re.compile(r"^(?:sonos)?RINCON_[0-9A-F]+(?:@(?P<room>.+))?$", re.I)
_UUID_ISH = re.compile(
    r"^(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{12,})$",
    re.I,
)
_BARE_IPV4 = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")
_MAC_TAIL = re.compile(r"[\s_-]*(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\s*$", re.I)
# Vendor-ish trailing hex that devices append to a friendly name, e.g.
# "Android_Z9K22SNZ" or "Sonos-5CAAFD26F5E2".
_HEX_TAIL = re.compile(r"[\s_-]+[0-9A-F]{8,}$")
# A model/serial chunk appended to a real word: "Android_R5UE8DLF" -> "Android".
_SERIAL_TAIL = re.compile(r"[_-](?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{5,}$")

# Hardware prefixes worth naming outright. Deliberately tiny: these are the ones
# that otherwise show up as a bare address on a home LAN.
MAC_VENDORS = {
    "5c:aa:fd": "Sonos",
    "b8:e9:37": "Sonos",
    "52:54:00": "VM",        # QEMU / KVM
    "bc:24:11": "VM",        # Proxmox
    "00:15:5d": "VM",        # Hyper-V
    "00:50:56": "VM",        # VMware
    "08:00:27": "VM",        # VirtualBox
    "d8:b3:70": "Ubiquiti",
    "74:ac:b9": "Ubiquiti",
    "e0:63:da": "Ubiquiti",
    "18:e8:29": "Ubiquiti",
}

# What a device is, from what it advertises. First match wins, so the most
# specific services come first.
SERVICE_KINDS = (
    ("_sonos._tcp", "Sonos"),
    ("_apple-mobdev2._tcp", "iPhone / iPad"),
    ("_androidtvremote2._tcp", "Android TV"),
    ("_googlecast._tcp", "Chromecast"),
    ("_ghp._tcp", "Google TV"),
    ("_airplay._tcp", "AirPlay"),
    ("_raop._tcp", "AirPlay"),
    ("_spotify-connect._tcp", "Speaker"),
    ("_display._tcp", "Display"),
    ("_kdeconnect._udp", "Linux desktop"),
    ("_home-assistant._tcp", "Home Assistant"),
    ("_esphomelib._tcp", "ESPHome"),
    ("_printer._tcp", "Printer"),
    ("_ipp._tcp", "Printer"),
    ("_nvstream._tcp", "GeForce"),
    ("_workstation._tcp", "Workstation"),
    ("_smb._tcp", "File share"),
    ("_nfs._tcp", "File share"),
    ("_rfb._tcp", "Screen share"),
    ("_ssh._tcp", "Server"),
)


# A model or serial string: no spaces, and a mix of capitals and digits that no
# person would choose, e.g. "X02500VWG236" or "Android_R5UE8DLF".
_SERIALISH = re.compile(r"^[A-Za-z]*[_-]?(?=[A-Z0-9_-]*\d)(?=[A-Z0-9_-]*[A-Z])[A-Z0-9_-]{6,}$")


def is_serialish(text: str | None) -> bool:
    s = str(text or "").strip()
    if not s or " " in s:
        return False
    if not _SERIALISH.match(s):
        return False
    digits = sum(c.isdigit() for c in s)
    uppers = sum(c.isupper() for c in s)
    return digits >= 3 and uppers >= 3


def is_identifier(text: str | None) -> bool:
    """True when a string names a device to a machine but not to a person."""
    s = str(text or "").strip()
    if not s:
        return False
    return bool(
        _UUID_ISH.match(s)
        or _BARE_IPV4.match(s)
        or _SONOS.match(s)
        or re.match(r"^(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}$", s, re.I)
        or is_serialish(s)
    )


def mac_vendor(mac: str | None) -> str | None:
    m = str(mac or "").strip().lower()
    if len(m) < 8:
        return None
    return MAC_VENDORS.get(m[:8])


def is_randomized_mac(mac: str | None) -> bool:
    """Locally-administered address: a privacy MAC, so it will change.

    Worth surfacing, because it is why a phone keeps appearing as a new device.
    """
    m = str(mac or "").strip().lower().replace("-", ":")
    if len(m) < 2:
        return False
    try:
        first = int(m[:2], 16)
    except ValueError:
        return False
    return bool(first & 0x02)


def device_kind(services: object, mac: str | None = None) -> str | None:
    """A short noun for what this is."""
    names = set()
    if isinstance(services, (list, tuple, set, frozenset)):
        names = {str(s).strip().lower() for s in services}
    for service, kind in SERVICE_KINDS:
        if service in names:
            return kind
    return mac_vendor(mac)


def _clean(text: str) -> str:
    s = _MAC_TAIL.sub("", str(text or "").strip())
    s = _HEX_TAIL.sub("", s)
    s = _SERIAL_TAIL.sub("", s)
    return re.sub(r"\s+", " ", s).strip()


def friendly_name(
    *,
    label: object = None,
    host: object = None,
    ip: object = None,
    mac: object = None,
    services: object = None,
) -> dict:
    """Return {name, kind, raw, randomized}.

    `name` is what a card leads with. `raw` is the identifier it came from, for
    the detail view, and is empty when the label was already a real name.
    """
    raw_label = str(label or "").strip()
    kind = device_kind(services, mac)
    randomized = is_randomized_mac(mac)

    # A Sonos carries its room after the '@'. That room is the name the owner
    # chose, so it wins over everything else.
    sonos = _SONOS.match(raw_label)
    if sonos:
        room = (sonos.group("room") or "").strip()
        return {
            "name": room or (kind or "Sonos"),
            "kind": kind or "Sonos",
            "raw": raw_label,
            "randomized": randomized,
        }

    host_s = _clean(str(host or ""))
    if host_s and not is_identifier(host_s):
        return {"name": host_s.split(".")[0], "kind": kind or "", "raw": "",
                "randomized": randomized}

    cleaned = _clean(raw_label)
    if cleaned and not is_identifier(cleaned):
        return {"name": cleaned, "kind": kind or "", "raw": raw_label if cleaned != raw_label else "",
                "randomized": randomized}

    # Nothing human anywhere: lead with what it is, and keep the address as the
    # identifier rather than the title.
    addr = str(ip or "").strip()
    octet = addr.rsplit(".", 1)[-1] if "." in addr else ""
    suffix = (" ." + octet) if octet else ""
    if kind:
        # Two speakers both called "Sonos" are not distinguishable, so a
        # class-only name carries the host octet.
        return {"name": kind + suffix, "kind": kind, "raw": raw_label or addr,
                "randomized": randomized}
    vendor = mac_vendor(mac)
    if vendor:
        return {"name": vendor + suffix, "kind": vendor, "raw": raw_label or addr,
                "randomized": randomized}
    return {"name": addr or "unknown device", "kind": "", "raw": raw_label,
            "randomized": randomized}
