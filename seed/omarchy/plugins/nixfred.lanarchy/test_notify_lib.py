#!/usr/bin/env python3
"""notify_lib: unknown must not reset a fail streak (OmarPlugs-5oy.15.7)."""
from notify_lib import apply_status_updates, empty_notify_state


def test_unknown_preserves_streak() -> None:
    inv = {"schemaVersion": 2, "settings": {"failStreakThreshold": 3}, "nodes": [{"id": "aka", "type": "machine", "label": "aka", "dns": "aka.lan"}]}
    state = empty_notify_state()
    apply_status_updates(state, inv, [("aka", "aka", "down")])
    apply_status_updates(state, inv, [("aka", "aka", "down")])
    assert state["nodes"]["aka"]["downStreak"] == 2
    apply_status_updates(state, inv, [("aka", "aka", "unknown")])
    assert state["nodes"]["aka"]["downStreak"] == 2
    apply_status_updates(state, inv, [("aka", "aka", "down")])
    assert state["nodes"]["aka"]["downStreak"] == 3
    assert len(apply_status_updates(state, inv, [("aka", "aka", "down")])) == 0  # already alerted after threshold


def test_up_clears_streak() -> None:
    inv = {"schemaVersion": 2, "nodes": [{"id": "aka", "type": "machine", "label": "aka", "dns": "aka.lan"}]}
    state = empty_notify_state()
    apply_status_updates(state, inv, [("aka", "aka", "down")])
    apply_status_updates(state, inv, [("aka", "aka", "up")])
    assert state["nodes"]["aka"]["downStreak"] == 0
    assert state["nodes"]["aka"]["alerted"] is False


if __name__ == "__main__":
    test_unknown_preserves_streak()
    test_up_clears_streak()
    print("ok")
