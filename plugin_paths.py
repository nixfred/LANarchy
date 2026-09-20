"""User plugin config dir + atomic JSON IO (OmarPlugs-5oy.9)."""
from __future__ import annotations

import fcntl
import json
import os
import stat
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

STATE_DIR_MODE = 0o700
SECRETS_FILE_MODE = 0o600


def ensure_private_dir(path: Path) -> Path:
    """Create path as a user-only directory and tighten an existing one to 0700."""
    path.mkdir(parents=True, exist_ok=True, mode=STATE_DIR_MODE)
    try:
        os.chmod(path, STATE_DIR_MODE)
    except OSError:
        pass
    return path


def atomic_write_json(path: Path, value: Any, *, indent: int | None = 2) -> Path:
    """Write via a per-call temp file in the same dir, then rename. Safe under concurrent writers."""
    ensure_private_dir(path.parent)
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
    ensure_private_dir(lock_path.parent)
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
    return ensure_private_dir(root / "lanarchy")


def pycache_env() -> dict:
    """Environment that keeps CPython's bytecode cache out of the plugin tree.

    Importing any module here writes `__pycache__/` next to the code, which the
    shell's plugin watcher sees as a change and answers with a reload. Redirect
    it rather than disabling caching, so imports stay fast.
    """
    env = dict(os.environ)
    env["PYTHONPYCACHEPREFIX"] = str(state_dir() / "pycache")
    return env


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
        moved_this = False
        try:
            src.replace(dst)
            moved_this = True
            moved.append(name)
        except OSError:
            try:
                dst.write_bytes(src.read_bytes())
                src.unlink(missing_ok=True)
                moved_this = True
                moved.append(name)
            except OSError:
                pass
        if moved_this and name == "unifi-secrets.json":
            try:
                os.chmod(dst, SECRETS_FILE_MODE)
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


def unifi_tls_pin_path() -> Path:
    """TOFU / explicit SHA-256 pins for UniFi controller certificates."""
    return state_dir() / "unifi-tls.json"


def unifi_ca_path() -> Path:
    """Optional user-installed UniFi CA / controller certificate (PEM)."""
    return state_dir() / "unifi-ca.pem"


def assert_private_secrets_file(path: Path) -> None:
    """Refuse to read credentials that are not a private, owner-only regular file.

    Uses O_NOFOLLOW so a symlink cannot redirect the open. Rejects group/other
    access bits and any owner other than the current user.
    """
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as e:
        raise PermissionError(f"unifi secrets unavailable: {path}") from e
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise PermissionError(f"unifi secrets must be a regular file: {path}")
        if st.st_uid != os.getuid():
            raise PermissionError(f"unifi secrets must be owned by the current user: {path}")
        if st.st_mode & 0o077:
            raise PermissionError(f"unifi secrets must be mode 0600 (no group/other access): {path}")
    finally:
        os.close(fd)
