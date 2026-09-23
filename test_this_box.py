"""The box running the panel must never be offered as a discovered device.

It already has a node. Discovery sees it once per interface and once per
source, so it arrives several times over with a different address and MAC each
time. Dismissing one of those removed one face and the next scan handed the
machine back under another, which looked like a device that could not be
removed.
"""
import sys

from probe import is_this_box

MY_IPS = {"10.0.0.2", "10.0.0.3", "127.0.0.1"}
MY_MACS = {"aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"}
MY_NAMES = {"box"}


def _is(cand):
    return is_this_box(cand, MY_IPS, MY_MACS, MY_NAMES)


def test_matches_a_current_address():
    assert _is({"ip": "10.0.0.2"})
    assert _is({"ip": "10.0.0.3"})


def test_matches_any_owned_mac_including_an_idle_interface():
    """A laptop's wifi and ethernet are both its own, even when one is unused."""
    assert _is({"mac": "aa:bb:cc:dd:ee:02", "ip": "10.0.0.8"})
    assert _is({"mac": "AA:BB:CC:DD:EE:01"})


def test_matches_its_own_hostname():
    """A stale ARP entry still names the host after the lease it held expired.

    This is the case an address check alone misses: the address is no longer
    ours, but the record is still us.
    """
    assert _is({"label": "box", "ip": "10.0.0.9", "mac": "99:99:99:99:99:99"})
    assert _is({"host": "box.local", "ip": "10.0.0.9"})
    assert _is({"host": "BOX.lan"})


def test_a_real_neighbour_is_left_alone():
    assert not _is({"label": "nas", "ip": "10.0.0.20", "mac": "11:22:33:44:55:66"})
    assert not _is({"label": "boxer", "ip": "10.0.0.21"})
    assert not _is({})


def test_empty_fields_never_match():
    """Blank must not collide with a blank name and swallow a real device."""
    assert not is_this_box({"label": "", "host": "", "ip": "", "mac": ""},
                           MY_IPS, MY_MACS, MY_NAMES | {""})


if __name__ == "__main__":
    for name, fn in sorted(list(globals().items())):
        if name.startswith("test_"):
            fn()
            print("ok", name)
    sys.exit(0)
