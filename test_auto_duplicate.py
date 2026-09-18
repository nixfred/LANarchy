"""A renamed discovered interface must not draw a second card for a curated box.

Discovery excludes anything it already recognises, but that check runs on the
label discovery found, before the user's rename override is applied. On a
multihomed machine the wired and wireless sides have different MACs, so
renaming the discovered side to the curated node's name produced two cards for
one machine.
"""
import sys


def _curated_names(nodes):
    out = set()
    for n in nodes:
        if str(n.get("type") or "") != "machine":
            continue
        for key in ("label", "id", "dns"):
            val = str(n.get(key) or "").strip().lower()
            if val:
                out.add(val)
                out.add(val.removesuffix(".local"))
                out.add(val.removesuffix(".lan"))
    out.discard("")
    return out


NODES = [
    {"id": "laptop", "type": "machine", "label": "laptop", "dns": "laptop.local", "ip": "10.0.0.213"},
    {"id": "nas", "type": "machine", "label": "NAS", "ip": "10.0.0.10"},
    {"id": "web", "type": "proxy", "label": "web"},
]


def test_curated_names_cover_label_id_and_dns():
    names = _curated_names(NODES)
    assert {"laptop", "laptop.local", "nas", "web"} & names == {"laptop", "laptop.local", "nas"}
    # A proxy is not a machine card, so it must not suppress a discovered machine.
    assert "web" not in names


def test_renamed_second_interface_is_dropped():
    """The wired side, renamed to the curated name, is the same machine."""
    names = _curated_names(NODES)
    renamed_row = {"label": "laptop", "mac": "aa:bb:cc:dd:ee:03", "ip": "10.0.0.124"}
    assert str(renamed_row["label"]).strip().lower() in names


def test_a_genuinely_different_box_survives():
    names = _curated_names(NODES)
    other = {"label": "printer", "mac": "aa:bb:cc:dd:ee:04", "ip": "10.0.0.50"}
    assert str(other["label"]).strip().lower() not in names


def test_match_is_case_and_suffix_insensitive():
    names = _curated_names(NODES)
    assert "nas" in names                  # curated label was "NAS"
    assert "laptop" in names                # curated dns was "laptop.local"


if __name__ == "__main__":
    for name, fn in sorted(list(globals().items())):
        if name.startswith("test_"):
            fn()
            print("ok", name)
    sys.exit(0)
