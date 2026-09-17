# Agent Instructions

**Lanarchy** — Omarchy Quickshell bar plugin (`donnie.homelab-mesh`). This repository root *is* the plugin (marketplace layout: `manifest.json` at root).

`CLAUDE.md` is a pointer here — keep project guidance in this file only.

## Layout

- `Panel.qml` + Python collectors — the plugin
- `README.md` — Install · Usage · Configure · Remove
- `docs/` — architecture and screenshots
- Dotfiles (`.agents/`, `.beads/`, `.cursor/`, …) are gitignored — do not commit them

## Work

Before changing behaviour, read:

- [`README.md`](README.md) — install, Search network, IPC
- [`docs/architecture.md`](docs/architecture.md) — inventory / history / notify sidecars

Runtime install path (usually a symlink to this tree):

`~/.config/omarchy/plugins/donnie.homelab-mesh/` (or a local symlink of that name)

### Tests

```bash
./smoke.sh                 # validate + unit + probe + discover + refuse-empty
for t in test_*.py; do python3 "$t"; done
omarchy plugin validate .
```

After QML changes: `omarchy-restart-shell`, then summon and smoke the panel.

### Secrets

Never commit `unifi-secrets.json`, inventory dumps with keys, or snapshots from a live mesh. Examples only (e.g. `unifi-secrets.json.example`).

### Git

- Remote for this repo: `github` → `DonnieFi/OmarPlugs` (must be **public** for marketplace).
- Commit and push only when the user asks.
- Keep commits atomic; do not mix plugin code with unrelated docs unless asked.

## Style

- Prefer the Omarchy plugin develop guide shape for user-facing docs: Install · Usage · Configure · Remove · Dependencies · IPC
- Screenshots in docs must be panel-only (no desktop chrome)
- QML theming: use `Color` / `Style` / theme `colors.toml` — not hard-coded status greens
