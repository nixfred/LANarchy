#!/usr/bin/env python3
"""A card leads with a name; the identifier goes in the detail."""
from __future__ import annotations

from naming_lib import friendly_name, is_identifier, is_randomized_mac, is_serialish


def test_sonos_room_is_the_name() -> None:
    """The owner already named it. That name was hiding after the '@'."""
    got = friendly_name(label="RINCON_AABBCCDDEE0101400@Kitchen",
                        ip="10.0.0.127", mac="aa:bb:cc:dd:ee:01", services=["_sonos._tcp"])
    assert got["name"] == "Kitchen"
    assert got["kind"] == "Sonos"
    assert got["raw"] == "RINCON_AABBCCDDEE0101400@Kitchen"


def test_sonos_without_a_room_falls_back_to_the_kind() -> None:
    got = friendly_name(label="sonosRINCON_AABBCCDDEE0201400", ip="10.0.0.127",
                        mac="aa:bb:cc:dd:ee:02", services=["_sonos._tcp"])
    assert got["name"] == "Sonos" and got["raw"].startswith("sonosRINCON_")


def test_a_real_hostname_wins() -> None:
    got = friendly_name(label="NAS", host="nas", ip="10.0.0.239",
                        services=["_smb._tcp", "_kdeconnect._udp"])
    assert got["name"] == "nas"
    assert got["kind"] == "Linux desktop"
    assert got["raw"] == "", "a real name has no identifier to hide"


def test_uuid_label_never_leads() -> None:
    got = friendly_name(label="0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", ip="10.0.0.153",
                        services=["_apple-mobdev2._tcp"])
    # class-only name, so it carries the octet to stay distinguishable
    assert got["name"] == "iPhone / iPad .153"
    assert got["kind"] == "iPhone / iPad"
    assert got["raw"] == "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"


def test_serial_tail_is_stripped() -> None:
    assert is_serialish("X02500VWG236")
    assert not is_serialish("nas")
    assert not is_serialish("Kitchen")
    got = friendly_name(label="Android_A1B2C3D4E", ip="10.0.0.139",
                        services=["_androidtvremote2._tcp"])
    assert got["name"] == "Android"
    assert got["kind"] == "Android TV"
    assert got["raw"] == "Android_A1B2C3D4E"


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
    assert is_identifier("0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")
    assert not is_identifier("nas")
    assert not is_identifier("Kitchen")


def test_name_key_prefers_mac_over_address() -> None:
    """An address is a lease. A name must follow the hardware, not the lease."""
    from naming_lib import name_key

    assert name_key("78:55:36:04:2F:01", "10.0.0.169") == "mac:78:55:36:04:2f:01"
    assert name_key("78-55-36-04-2f-01", None) == "mac:78:55:36:04:2f:01"
    # only when there is no MAC to anchor to
    assert name_key(None, "10.0.0.169") == "ip:10.0.0.169"
    assert name_key(None, None) is None
    assert name_key("nonsense", "10.0.0.1") == "ip:10.0.0.1"


def test_apply_name_overrides_and_keeps_what_was_discovered() -> None:
    from naming_lib import apply_name

    row = {"label": "10.0.0.169", "mac": "78:55:36:04:2f:01", "ip": "10.0.0.169"}
    apply_name(row, {"mac:78:55:36:04:2f:01": "hive"})
    assert row["label"] == "hive"
    assert row["discoveredLabel"] == "10.0.0.169"
    assert row["renamed"] is True


def test_apply_name_follows_the_box_to_a_new_address() -> None:
    from naming_lib import apply_name

    overrides = {"mac:78:55:36:04:2f:01": "hive"}
    moved = {"label": "10.0.0.240", "mac": "78:55:36:04:2f:01", "ip": "10.0.0.240"}
    apply_name(moved, overrides)
    assert moved["label"] == "hive", "a DHCP move must not lose the name"

    # and an unrelated box that inherits the old address is NOT renamed
    stranger = {"label": "10.0.0.169", "mac": "aa:bb:cc:dd:ee:ff", "ip": "10.0.0.169"}
    apply_name(stranger, overrides)
    assert stranger["label"] == "10.0.0.169"


def test_apply_name_is_a_noop_without_an_override() -> None:
    from naming_lib import apply_name

    row = {"label": "laptop", "mac": "aa:bb:cc:dd:ee:03"}
    apply_name(row, {})
    assert row["label"] == "laptop" and "renamed" not in row



if __name__ == "__main__":
    for _name, _fn in sorted(list(globals().items())):
        if _name.startswith("test_") and callable(_fn):
            _fn()
    print("ok")
