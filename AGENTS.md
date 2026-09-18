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

### Releasing

**Every user-visible change bumps `manifest.json` `version`, in the same commit.**
That version is the single source of truth: the panel header reads it from
`manifest.json` at runtime, so what a user sees is always what actually shipped.
It is also on the bar tooltip and available as `omarchy-shell lanarchy version`.

A release is three things, together:

1. bump `version` in `manifest.json` (semver: `0.9.3` → `0.10.0`, ten, not one)
2. add a `CHANGELOG.md` entry under that exact version
3. update the version badge in `README.md`

A pull request that changes behaviour without a version bump is incomplete: the
user cannot tell which build they are running, and a bug report cannot be tied to
a release.

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
