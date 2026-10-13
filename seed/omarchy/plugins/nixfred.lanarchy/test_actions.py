#!/usr/bin/env python3
from plugin_paths import snapshot_path
from probe import cmd_wol, run_probe
from telemetry_lib import send_wol


def test_wol_rejects_junk() -> None:
    assert send_wol("not-a-mac") is False
    assert cmd_wol("") == 1


def test_snapshot_write() -> None:
    payload = run_probe(write_stdout=False)
    assert "machines" in payload
    assert "groups" in payload
    assert snapshot_path().is_file()


if __name__ == "__main__":
    test_wol_rejects_junk()
    print("wol ok")
