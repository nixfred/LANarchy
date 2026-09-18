#!/bin/bash
# Local smoke for Lanarchy marketplace layout (no GUI, no plugin remove).
set -euo pipefail
cd "$(dirname "$0")"

echo "== validate"
omarchy plugin validate .

echo "== unit tests"
fail=0
for t in test_*.py; do
  if ! python3 "$t"; then
    echo "FAIL $t"
    fail=1
  fi
done
(( fail == 0 ))

echo "== inventory dump"
python3 inventory_cli.py dump >/tmp/lanarchy-inv-dump.json
python3 - <<'PY'
import json
d=json.load(open("/tmp/lanarchy-inv-dump.json"))
assert d.get("schemaVersion") == 2
assert isinstance(d.get("nodes"), list) and d["nodes"]
assert "groups" in d
print("nodes", len(d["nodes"]), "groups", len(d.get("groups") or []))
PY

echo "== refuse empty inventory write"
python3 - <<'PY'
import json, tempfile, os, subprocess
from pathlib import Path
fd, name = tempfile.mkstemp(suffix=".json"); os.close(fd)
Path(name).write_text(json.dumps({"schemaVersion": 2, "nodes": []}) + "\n")
r = subprocess.run(["python3", "inventory_cli.py", "write", name], capture_output=True, text=True)
os.unlink(name)
assert r.returncode != 0, "empty write should fail"
print("refused ok:", (r.stderr or r.stdout)[:120])
PY

echo "== probe snapshot shape"
python3 - <<'PY'
from probe import run_probe
d = run_probe(write_stdout=False)
assert "as_of" in d and "machines" in d and "groups" in d
ext = [g for g in d["groups"] if g.get("zone") == "external"]
print("as_of", d["as_of"])
print("machines", len(d["machines"]), "groups", len(d["groups"]), "external", len(ext))
# degraded must mean real downs
for g in d["groups"]:
    if g.get("status") == "degraded":
        assert int(g.get("down") or 0) > 0, g
print("degraded-policy ok")
PY

echo "== discover (autofind)"
python3 - <<'PY'
from discover_lib import collect_discover
rows = collect_discover()
assert isinstance(rows, list)
print("discover candidates", len(rows))
PY

echo "== user state seeds from the shipped default"
[[ -f inventory.default.json ]] || { echo "missing inventory.default.json"; exit 1; }
if git ls-files --error-unmatch inventory.json >/dev/null 2>&1; then
  echo "inventory.json must stay untracked (plugin update would conflict with an edited lab)"
  exit 1
fi
python3 - <<'PY_SEED'
import json, shutil, tempfile
from pathlib import Path
import plugin_paths

with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    shutil.copy("inventory.default.json", tmp / "inventory.default.json")
    original = plugin_paths.plugin_config_dir
    original_state = plugin_paths.state_dir
    plugin_paths.plugin_config_dir = lambda: tmp
    # state_dir must be redirected too, or this test writes its fixture over the
    # user's real inventory.
    plugin_paths.state_dir = lambda: tmp
    try:
        live = plugin_paths.ensure_user_inventory()
        assert live.is_file(), "first run must seed inventory.json"
        assert json.loads(live.read_text())["schemaVersion"] == 2
        live.write_text(json.dumps({"schemaVersion": 2, "nodes": [{"id": "mine"}]}) + "\n")
        plugin_paths.ensure_user_inventory()
        assert json.loads(live.read_text())["nodes"][0]["id"] == "mine", "must never re-seed over user state"
    finally:
        plugin_paths.plugin_config_dir = original
        plugin_paths.state_dir = original_state
print("seed ok")
PY_SEED

echo "== no runtime state is written into the plugin tree"
python3 - <<'PY_STATE'
import plugin_paths
from pathlib import Path

plugin = plugin_paths.plugin_config_dir()
state = plugin_paths.state_dir()
assert state != plugin, "state dir must not be the plugin dir"
for fn in (plugin_paths.inventory_path, plugin_paths.history_path,
           plugin_paths.notify_state_path, plugin_paths.snapshot_path,
           plugin_paths.unifi_secrets_path, plugin_paths.panel_heartbeat_path):
    p = fn()
    assert plugin not in p.parents, f"{p} is inside the watched plugin tree"
# the shell hot-reloads a local plugin on ANY change under it, so a write here
# reloads the plugin roughly once a second while the panel is open
leftovers = [n for n in ("inventory.json", "snapshot.json", "history.json",
                         "notify-state.json", ".panel-heartbeat",
                         ".daemon.lock", ".probe.lock")
             if (plugin / n).exists()]
env = plugin_paths.pycache_env()
assert env["PYTHONPYCACHEPREFIX"].startswith(str(state)), "bytecode must not land in the plugin tree"
assert not leftovers, f"still writing into the plugin tree: {leftovers}"
print("state is outside the plugin tree")
PY_STATE

echo "== required marketplace files"
for f in manifest.json LICENSE README.md preview.png Panel.qml; do
  [[ -f $f ]] || { echo "missing $f"; exit 1; }
done
# no symlinks in plugin tree (marketplace rule)
if find . -type l -not -path './.git/*' | grep -q .; then
  echo "symlinks present:"; find . -type l -not -path './.git/*'
  exit 1
fi

echo "SMOKE OK"
