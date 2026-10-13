#!/usr/bin/env python3
"""History sidecar CLI for QML Process (OmarPlugs-5oy.6)."""
from __future__ import annotations

import json
import sys

from history_lib import load_history, sparkline_payload


def cmd_sparkline(node_id: str, n: int) -> int:
    json.dump(sparkline_payload(load_history(), node_id, n), sys.stdout)
    sys.stdout.write("\n")
    return 0


def main(argv: list[str]) -> int:
    args = argv[1:]
    if len(args) >= 3 and args[0] == "sparkline" and args[1] == "--id":
        n = 32
        if len(args) >= 5 and args[3] == "--n":
            try:
                n = int(args[4])
            except ValueError:
                n = 32
            return cmd_sparkline(args[2], n)
        return cmd_sparkline(args[2], n)
    print("usage: history_cli.py sparkline --id <node-id> [--n 32]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
