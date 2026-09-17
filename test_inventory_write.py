#!/usr/bin/env python3
"""inventory_cli write must refuse empty nodes (OmarPlugs-5oy.15.1)."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CLI = HERE / "inventory_cli.py"


def _write(inv_path: Path, payload: dict) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(payload, fh)
        tmp = Path(fh.name)
    try:
        return subprocess.run(
            [sys.executable, str(CLI), str(inv_path), "write", str(tmp)],
            capture_output=True,
            text=True,
        )
    finally:
        tmp.unlink(missing_ok=True)


def test_refuse_empty_write() -> None:
    with tempfile.TemporaryDirectory() as td:
        inv = Path(td) / "inventory.json"
        inv.write_text(
            json.dumps(
                {
                    "schemaVersion": 2,
                    "nodes": [
                        {"id": "deba", "type": "machine", "label": "deba", "dns": "deba.lan", "ip": None}
                    ],
                }
            ),
            encoding="utf-8",
        )
        before = inv.read_text(encoding="utf-8")
        proc = _write(inv, {"schemaVersion": 2, "nodes": []})
        assert proc.returncode != 0, proc.stdout + proc.stderr
        assert "refusing empty" in proc.stderr.lower()
        assert inv.read_text(encoding="utf-8") == before


def test_write_keeps_one_node() -> None:
    with tempfile.TemporaryDirectory() as td:
        inv = Path(td) / "inventory.json"
        payload = {
            "schemaVersion": 2,
            "nodes": [
                {"id": "aka", "type": "machine", "label": "aka", "dns": "aka.lan", "ip": None}
            ],
        }
        proc = _write(inv, payload)
        assert proc.returncode == 0, proc.stderr
        saved = json.loads(inv.read_text(encoding="utf-8"))
        assert [n["id"] for n in saved["nodes"]] == ["aka"]


def test_write_keeps_group_and_map_extras() -> None:
    with tempfile.TemporaryDirectory() as td:
        inv = Path(td) / "inventory.json"
        payload = {
            "schemaVersion": 2,
            "nodes": [
                {
                    "id": "frigate.lan",
                    "type": "host",
                    "label": "Frigate",
                    "group": "cameras",
                    "hidden": True,
                    "mapHidden": True,
                    "mapOrder": 3,
                    "mapBand": "host",
                    "dns": "frigate.lan",
                    "ip": None,
                }
            ],
        }
        proc = _write(inv, payload)
        assert proc.returncode == 0, proc.stderr
        node = json.loads(inv.read_text(encoding="utf-8"))["nodes"][0]
        assert node["group"] == "cameras"
        assert node["hidden"] is True
        assert node["mapHidden"] is True
        assert node["mapOrder"] == 3
        assert node["mapBand"] == "host"


def test_empty_settings_clears_stale_keys() -> None:
    """Panel always sends settings (even {}); omit must not revive stale keys from disk."""
    with tempfile.TemporaryDirectory() as td:
        inv = Path(td) / "inventory.json"
        inv.write_text(
            json.dumps(
                {
                    "schemaVersion": 2,
                    "settings": {"retiredFlag": True, "failStreakThreshold": 3},
                    "nodes": [
                        {"id": "aka", "type": "machine", "label": "aka", "dns": "aka.lan", "ip": None}
                    ],
                }
            ),
            encoding="utf-8",
        )
        # Omitting settings merges on-disk values.
        proc_omit = _write(
            inv,
            {
                "schemaVersion": 2,
                "nodes": [
                    {"id": "aka", "type": "machine", "label": "aka", "dns": "aka.lan", "ip": None}
                ],
            },
        )
        assert proc_omit.returncode == 0, proc_omit.stderr
        merged = json.loads(inv.read_text(encoding="utf-8"))
        assert merged.get("settings", {}).get("retiredFlag") is True

        # Explicit empty settings clears keys.
        proc_clear = _write(
            inv,
            {
                "schemaVersion": 2,
                "settings": {},
                "nodes": [
                    {"id": "aka", "type": "machine", "label": "aka", "dns": "aka.lan", "ip": None}
                ],
            },
        )
        assert proc_clear.returncode == 0, proc_clear.stderr
        cleared = json.loads(inv.read_text(encoding="utf-8"))
        assert "retiredFlag" not in (cleared.get("settings") or {})


def test_write_keeps_partial_settings() -> None:
    with tempfile.TemporaryDirectory() as td:
        inv = Path(td) / "inventory.json"
        inv.write_text(
            json.dumps(
                {
                    "schemaVersion": 2,
                    "settings": {"retiredFlag": True, "failStreakThreshold": 3},
                    "nodes": [
                        {"id": "aka", "type": "machine", "label": "aka", "dns": "aka.lan", "ip": None}
                    ],
                }
            ),
            encoding="utf-8",
        )
        proc = _write(
            inv,
            {
                "schemaVersion": 2,
                "settings": {"failStreakThreshold": 3},
                "nodes": [
                    {"id": "aka", "type": "machine", "label": "aka", "dns": "aka.lan", "ip": None}
                ],
            },
        )
        assert proc.returncode == 0, proc.stderr
        saved = json.loads(inv.read_text(encoding="utf-8"))["settings"]
        assert saved == {"failStreakThreshold": 3}


if __name__ == "__main__":
    test_refuse_empty_write()
    test_write_keeps_one_node()
    test_write_keeps_group_and_map_extras()
    test_empty_settings_clears_stale_keys()
    test_write_keeps_partial_settings()
    print("ok")
