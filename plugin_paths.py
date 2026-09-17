"""User plugin config dir + atomic JSON IO (OmarPlugs-5oy.9)."""
from __future__ import annotations

import fcntl
import json
import os
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator


def atomic_write_json(path: Path, value: Any, *, indent: int | None = 2) -> Path:
    """Write via a per-call temp file in the same dir, then rename. Safe under concurrent writers."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(value, indent=indent, ensure_ascii=False) + "\n")
        tmp.replace(path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    return path


def load_json_or(path: Path, fallback: Any) -> Any:
    """Read JSON; on corruption move the file aside and return fallback."""
    if not path.is_file():
        return fallback
    try:
        with path.open(encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        try:
            path.replace(path.with_suffix(path.suffix + ".corrupt"))
        except OSError:
            pass
        return fallback


@contextmanager
def probe_lock(timeout_s: float = 20.0) -> Iterator[bool]:
    """Serialize probe runs: shell timer and manual runs share history/notify files."""
    import time

    lock_path = plugin_config_dir() / ".probe.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w") as fh:
        deadline = time.monotonic() + timeout_s
        acquired = False
        while True:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.2)
        try:
            yield acquired
        finally:
            if acquired:
                fcntl.flock(fh, fcntl.LOCK_UN)


def plugin_config_dir() -> Path:
    """Plugin install directory (marketplace: ~/.config/omarchy/plugins/<manifest.id>/).

    Resolved from this file's location so marketplace checkouts and local
    symlinks both work without hardcoding the directory name.
    """
    return Path(__file__).resolve().parent


def inventory_path() -> Path:
    return plugin_config_dir() / "inventory.json"


def history_path() -> Path:
    return plugin_config_dir() / "history.json"


def notify_state_path() -> Path:
    return plugin_config_dir() / "notify-state.json"


def snapshot_path() -> Path:
    return plugin_config_dir() / "snapshot.json"


def unifi_secrets_path() -> Path:
    """Sidecar credentials. Never commit; never copy into inventory.json."""
    return plugin_config_dir() / "unifi-secrets.json"
