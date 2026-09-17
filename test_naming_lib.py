#!/usr/bin/env python3
"""A card leads with a name; the identifier goes in the detail."""
from __future__ import annotations

from naming_lib import friendly_name, is_identifier, is_randomized_mac, is_serialish


def test_sonos_room_is_the_name() -> None:
    """The owner already named it. That name was hiding after the '@'."""
    got = friendly_name(label="RINCON_5CAAFD26F5E201400@Living Room",
                        ip="10.0.0.127", mac="5c:aa:fd:26:f5:e2", services=["_sonos._tcp"])
    assert got["name"] == "Living Room"
    assert got["kind"] == "Sonos"
    assert got["raw"] == "RINCON_5CAAFD26F5E201400@Living Room"


def test_sonos_without_a_room_falls_back_to_the_kind() -> None:
    got = friendly_name(label="sonosRINCON_5CAAFD15955901400", ip="10.0.0.127",
                        mac="5c:aa:fd:15:95:59", services=["_sonos._tcp"])
    assert got["name"] == "Sonos" and got["raw"].startswith("sonosRINCON_")


def test_a_real_hostname_wins() -> None:
    got = friendly_name(label="VIC", host="vic", ip="10.0.0.239",
                        services=["_smb._tcp", "_kdeconnect._udp"])
    assert got["name"] == "vic"
    assert got["kind"] == "Linux desktop"
    assert got["raw"] == "", "a real name has no identifier to hide"


def test_uuid_label_never_leads() -> None:
    got = friendly_name(label="83DEE99F-B526-470F-9D1B-16EC01196A2C", ip="10.0.0.153",
                        services=["_apple-mobdev2._tcp"])
    # class-only name, so it carries the octet to stay distinguishable
    assert got["name"] == "iPhone / iPad .153"
    assert got["kind"] == "iPhone / iPad"
    assert got["raw"] == "83DEE99F-B526-470F-9D1B-16EC01196A2C"


def test_serial_tail_is_stripped() -> None:
    assert is_serialish("X02500VWG236")
    assert not is_serialish("vic")
    assert not is_serialish("Living Room")
    got = friendly_name(label="Android_R5UE8DLF", ip="10.0.0.139",
                        services=["_androidtvremote2._tcp"])
    assert got["name"] == "Android"
    assert got["kind"] == "Android TV"
    assert got["raw"] == "Android_R5UE8DLF"


def test_class_only_names_carry_the_octet() -> None:
    """Two things both called "Ubiquiti" are not distinguishable."""
    a = friendly_name(label="10.0.0.1", ip="10.0.0.1", mac="d8:b3:70:99:ce:bf")
    b = friendly_name(label="10.0.0.10", ip="10.0.0.10", mac="d8:b3:70:11:22:33")
    assert a["name"] == "Ubiquiti .1"
    assert b["name"] == "Ubiquiti .10"
    assert a["name"] != b["name"]


def test_vm_mac_prefixes() -> None:
    assert friendly_name(label="192.168.124.137", ip="192.168.124.137",
                         mac="52:54:00:aa:bb:cc")["kind"] == "VM"
    assert friendly_name(label="10.0.0.5", ip="10.0.0.5",
                         mac="bc:24:11:aa:bb:cc")["kind"] == "VM"


def test_unknown_stays_honest() -> None:
    got = friendly_name(label="10.0.0.122", ip="10.0.0.122", mac="98:f4:ab:11:22:33")
    assert got["name"] == "10.0.0.122"
    assert got["kind"] == ""


def test_randomized_mac_is_flagged() -> None:
    """A privacy MAC is why a phone keeps reappearing as a new device."""
    assert is_randomized_mac("0e:9e:a5:11:22:33")
    assert is_randomized_mac("02:6b:9c:11:22:33")
    assert not is_randomized_mac("d8:b3:70:99:ce:bf")
    assert friendly_name(label="x", ip="10.0.0.9", mac="0e:9e:a5:11:22:33")["randomized"]


def test_is_identifier() -> None:
    assert is_identifier("10.0.0.5")
    assert is_identifier("d8:b3:70:99:ce:bf")
    assert is_identifier("83DEE99F-B526-470F-9D1B-16EC01196A2C")
    assert not is_identifier("vic")
    assert not is_identifier("Living Room")


if __name__ == "__main__":
    for _name, _fn in sorted(list(globals().items())):
        if _name.startswith("test_") and callable(_fn):
            _fn()
    print("ok")
