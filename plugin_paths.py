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

    lock_path = state_dir() / ".probe.lock"
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
    symlinks both work without hardcoding the directory name. READ ONLY at
    runtime: see state_dir().
    """
    return Path(__file__).resolve().parent


def state_dir() -> Path:
    """Where everything this plugin writes actually lives.

    Runtime state must NOT sit in the plugin directory. The shell watches a
    local plugin tree for changes and hot-reloads the plugin when anything in it
    is touched, so writing snapshot.json every probe (and a panel heartbeat
    every 8 seconds) reloaded the plugin about once a second: measured at 296
    reloads in five minutes, which makes the panel unusable while it is open.
    """
    base = os.environ.get("XDG_STATE_HOME") or ""
    root = Path(base) if base else Path.home() / ".local" / "state"
    out = root / "lanarchy"
    out.mkdir(parents=True, exist_ok=True)
    return out


# Files that used to live beside the code and are now migrated out of it.
_STATE_FILES = (
    "inventory.json",
    "history.json",
    "notify-state.json",
    "snapshot.json",
    "unifi-secrets.json",
)


def migrate_state_out_of_plugin_dir() -> list[str]:
    """Move pre-0.9 state out of the plugin tree, once. Never overwrites."""
    moved: list[str] = []
    src_dir = plugin_config_dir()
    dst_dir = state_dir()
    for name in _STATE_FILES:
        src = src_dir / name
        dst = dst_dir / name
        if not src.is_file() or dst.exists():
            continue
        try:
            src.replace(dst)
            moved.append(name)
        except OSError:
            try:
                dst.write_bytes(src.read_bytes())
                src.unlink(missing_ok=True)
                moved.append(name)
            except OSError:
                pass
    # Stale locks and heartbeats in the plugin dir keep triggering reloads.
    for name in (".daemon.lock", ".probe.lock", ".panel-heartbeat"):
        try:
            (src_dir / name).unlink(missing_ok=True)
        except OSError:
            pass
    return moved


def inventory_path() -> Path:
    return state_dir() / "inventory.json"


def default_inventory_path() -> Path:
    """Repo-shipped starter. Tracked in git; never written to at runtime."""
    return plugin_config_dir() / "inventory.default.json"


def ensure_user_inventory() -> Path:
    """Seed the user's inventory.json from the shipped default on first run.

    inventory.json is user state and stays untracked, so `omarchy plugin update`
    (a git pull) can never conflict with an edited lab or clobber it.
    """
    migrate_state_out_of_plugin_dir()
    live = inventory_path()
    if live.is_file():
        return live
    seed = default_inventory_path()
    if not seed.is_file():
        return live
    try:
        live.write_text(seed.read_text(encoding="utf-8"), encoding="utf-8")
    except OSError:
        pass
    return live


def panel_heartbeat_path() -> Path:
    """Touched by the panel while it is open; read by the collector's probe gate."""
    return state_dir() / ".panel-heartbeat"


def history_path() -> Path:
    return state_dir() / "history.json"


def notify_state_path() -> Path:
    return state_dir() / "notify-state.json"


def snapshot_path() -> Path:
    return state_dir() / "snapshot.json"


def unifi_secrets_path() -> Path:
    """Sidecar credentials. Never commit; never copy into inventory.json."""
    return state_dir() / "unifi-secrets.json"
