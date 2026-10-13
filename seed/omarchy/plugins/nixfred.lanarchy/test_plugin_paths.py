#!/usr/bin/env python3
"""plugin_paths: private state dir and secrets-file gate."""
from __future__ import annotations

import os
import stat
import tempfile
from pathlib import Path

import plugin_paths


def test_state_dir_is_private() -> None:
    with tempfile.TemporaryDirectory() as td:
        os.environ["XDG_STATE_HOME"] = td
        try:
            path = plugin_paths.state_dir()
            assert path == Path(td) / "lanarchy"
            mode = path.stat().st_mode & 0o777
            assert mode == 0o700, f"expected 0700, got {oct(mode)}"
        finally:
            os.environ.pop("XDG_STATE_HOME", None)


def test_assert_private_secrets_file() -> None:
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        good = base / "good.json"
        good.write_text("{}", encoding="utf-8")
        good.chmod(0o600)
        plugin_paths.assert_private_secrets_file(good)

        bad = base / "bad.json"
        bad.write_text("{}", encoding="utf-8")
        bad.chmod(0o644)
        try:
            plugin_paths.assert_private_secrets_file(bad)
            raise AssertionError("expected PermissionError for 0644")
        except PermissionError:
            pass

        link = base / "link.json"
        link.symlink_to(good)
        try:
            plugin_paths.assert_private_secrets_file(link)
            raise AssertionError("expected PermissionError for symlink")
        except PermissionError:
            pass


if __name__ == "__main__":
    test_state_dir_is_private()
    test_assert_private_secrets_file()
    print("ok")
