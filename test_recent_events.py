"""One flapping device must not fill the "what just changed" strip.

A sleeping phone transitions every few minutes, so a raw newest-first ring is
entirely that phone and every other change on the network is invisible.
"""
import sys

from history_lib import recent_events


def _ev(ts, nid, frm, to):
    return {"ts": ts, "id": nid, "from": frm, "to": to}


def test_one_row_per_node_newest_kept():
    hist = {"events": [
        _ev("2026-09-17T23:00:00", "phone", "up", "down"),
        _ev("2026-09-17T23:05:00", "phone", "down", "up"),
        _ev("2026-09-17T23:10:00", "phone", "up", "down"),
        _ev("2026-09-17T23:02:00", "nas", "up", "down"),
    ]}
    rows = recent_events(hist, 6)
    ids = [r["id"] for r in rows]
    assert ids == ["phone", "nas"], ids
    assert rows[0]["ts"] == "2026-09-17T23:10:00"
    assert rows[0]["to"] == "down"
    assert rows[0]["changes"] == 3
    assert rows[1]["changes"] == 1


def test_limit_counts_nodes_not_transitions():
    events = []
    for n in range(4):
        for k in range(5):
            events.append(_ev("2026-09-17T23:%02d:00" % (n * 5 + k), "n%d" % n, "up", "down"))
    rows = recent_events({"events": events}, 2)
    assert len(rows) == 2, rows
    assert len({r["id"] for r in rows}) == 2


def test_known_filters_nodes_that_no_longer_exist():
    """The ring retains 24h, so it outlives a deleted node.

    A node removed from the inventory kept appearing in "what just changed"
    under its raw id, because nothing was left that could give it a name.
    """
    hist = {"events": [
        _ev("2026-09-17T23:10:00", "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9", "up", "down"),
        _ev("2026-09-17T23:09:00", "nas", "up", "down"),
    ]}
    rows = recent_events(hist, 6, known={"nas"})
    assert [r["id"] for r in rows] == ["nas"], rows
    # No filter given means no filtering: the caller opts in.
    assert len(recent_events(hist, 6)) == 2


def test_flap_counts_respects_known():
    from history_lib import flap_counts
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).isoformat()
    hist = {"events": [
        _ev(now, "ghost", "up", "down"),
        _ev(now, "nas", "up", "down"),
    ]}
    assert flap_counts(hist, 1.0, known={"nas"}) == {"nas": 1}


def test_junk_and_empty():
    assert recent_events({}, 6) == []
    assert recent_events({"events": "nope"}, 6) == []
    assert recent_events({"events": [None, {"id": "a"}, {"to": "up"}]}, 6) == []


if __name__ == "__main__":
    for name, fn in sorted(list(globals().items())):
        if name.startswith("test_"):
            fn()
            print("ok", name)
    sys.exit(0)
