#!/usr/bin/env python3
"""CLI for QML Process: dump | migrate | write <json-file> (OmarPlugs-5oy.1)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

from edges_lib import resolve_edges
from groups_lib import group_nodes
from inventory_lib import (
    DEFAULT_INVENTORY,
    load_inventory,
    normalize_inventory,
    save_inventory,
)
from plugin_paths import inventory_path as user_inventory_path

MAX_WRITE_BYTES = 2 * 1024 * 1024


def _load_write_payload(json_file: Path):
    if str(json_file) == "-":
        # QML sends compact JSON plus a newline (one document). Cap so a
        # stalled pipe cannot fill the collector.
        raw_bytes = sys.stdin.buffer.readline(MAX_WRITE_BYTES + 1)
        if len(raw_bytes) > MAX_WRITE_BYTES:
            print(json.dumps({"error": "inventory write exceeds 2 MiB"}), file=sys.stderr)
            return None
        return json.loads(raw_bytes.decode())
    if json_file.stat().st_size > MAX_WRITE_BYTES:
        print(json.dumps({"error": "inventory write exceeds 2 MiB"}), file=sys.stderr)
        return None
    return json.loads(json_file.read_text(encoding="utf-8"))


def cmd_dump(path: Path) -> int:
    inv = load_inventory(path)
    # QML consumes nodes + migratedFromV1; strip path
    out = {
        "schemaVersion": inv["schemaVersion"],
        "nodes": inv["nodes"],
        "migratedFromV1": bool(inv.get("migratedFromV1")),
        "edges": resolve_edges(inv, services=group_nodes(inv.get("nodes") or []).get("services")),
        "groups": group_nodes(inv.get("nodes") or []).get("services"),
    }
    if isinstance(inv.get("settings"), dict):
        out["settings"] = inv["settings"]
    if isinstance(inv.get("ignored"), list):
        out["ignored"] = inv["ignored"]
    if isinstance(inv.get("names"), list):
        out["names"] = inv["names"]
    json.dump(out, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def cmd_migrate(path: Path) -> int:
    inv = load_inventory(path)
    if not inv.get("migratedFromV1") and path.exists():
        # already v2 on disk — still rewrite normalized v2
        raw = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(raw.get("nodes"), list) and (
            raw.get("schemaVersion") == 2 or raw.get("schema_version") == 2
        ):
            save_inventory(inv, path)
            print(json.dumps({"ok": True, "migrated": False, "nodes": len(inv["nodes"])}))
            return 0
    save_inventory(inv, path)
    print(
        json.dumps(
            {
                "ok": True,
                "migrated": bool(inv.get("migratedFromV1")),
                "nodes": len(inv["nodes"]),
                "path": str(path),
            }
        )
    )
    return 0


def cmd_write(path: Path, json_file: Path) -> int:
    raw = _load_write_payload(json_file)
    if raw is None:
        return 1
    if isinstance(raw, list):
        raw = {"schemaVersion": 2, "nodes": raw}
    nodes = raw.get("nodes") if isinstance(raw, dict) else None
    # A payload with no `nodes` key is an overrides-only write: keep whatever is
    # on disk. Every override write used to resend the panel's in-memory node
    # list, so a node added since that copy was taken was silently dropped.
    overrides_only = isinstance(raw, dict) and "nodes" not in raw
    if not overrides_only and (not isinstance(nodes, list) or len(nodes) == 0):
        print(json.dumps({"error": "refusing empty inventory write"}), file=sys.stderr)
        return 1
    if path.exists():
        current = load_inventory(path)
        if overrides_only:
            raw["nodes"] = current.get("nodes") or []
        # Overrides are preserved exactly like settings/edges. Omitting them
        # used to erase them, so dismissing a device or renaming a box was
        # silently undone by the next ordinary save.
        for key in ("settings", "edges", "ignored", "names"):
            if key not in raw and key in current:
                raw[key] = current[key]
    inv = normalize_inventory(raw)
    if not inv["nodes"]:
        print(json.dumps({"error": "refusing empty inventory write"}), file=sys.stderr)
        return 1
    save_inventory(inv, path)
    print(json.dumps({"ok": True, "nodes": len(inv["nodes"]), "path": str(path)}))
    return 0


def main(argv: list[str]) -> int:
    # inventory_cli.py [inventory-path] dump|migrate|write <file>
    args = list(argv[1:])
    inv_path = user_inventory_path() if user_inventory_path().is_file() else DEFAULT_INVENTORY
    if args and args[0] not in ("dump", "migrate", "write") and not args[0].startswith("-"):
        # optional leading path
        maybe = Path(args[0])
        if len(args) >= 2 and args[1] in ("dump", "migrate", "write"):
            inv_path = maybe
            args = args[1:]
    if not args:
        print("usage: inventory_cli.py [inventory.json] dump|migrate|write <json-file>", file=sys.stderr)
        return 2
    cmd = args[0]
    try:
        if cmd == "dump":
            return cmd_dump(inv_path)
        if cmd == "migrate":
            return cmd_migrate(inv_path)
        if cmd == "write":
            if len(args) < 2:
                print("write requires <json-file>", file=sys.stderr)
                return 2
            return cmd_write(inv_path, Path(args[1]))
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
