# Agent Instructions

**LANarchy** — Omarchy Quickshell bar plugin (`nixfred.lanarchy`). A fork of
[Lanarchy](https://github.com/DonnieFi/OmarPlugs) by Donnie Fiander. This repository root *is* the plugin (marketplace layout: `manifest.json` at root).

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

`~/.config/omarchy/plugins/nixfred.lanarchy/` (or a local symlink of that name)

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

### Commits

Never add `Co-authored-by: Cursor` (or any Cursor/agent co-author trailer). Commits are the user's alone.

### Secrets

Never commit `unifi-secrets.json`, inventory dumps with keys, or snapshots from a live mesh. Examples only (e.g. `unifi-secrets.json.example`).

### Git

- Remote for this repo: `origin` → `nixfred/LANarchy` (must be **public** for marketplace).
- `upstream` → `DonnieFi/OmarPlugs` is fetch-only; its push URL is disabled. Never push there.
- Commit and push only when the user asks.
- Keep commits atomic; do not mix plugin code with unrelated docs unless asked.

## Style

- Prefer the Omarchy plugin develop guide shape for user-facing docs: Install · Usage · Configure · Remove · Dependencies · IPC
- Screenshots in docs must be panel-only (no desktop chrome)
- QML theming: use `Color` / `Style` / theme `colors.toml` — not hard-coded status greens.
  **One exception, deliberately:** the bar mark's green / amber / red
  (`statusGreen` / `statusAmber` / `statusRed` in `Panel.qml`). A theme may define
  a "green" that is not green — one shipped palette has green `#708c8b`, yellow
  `#7b8768` and red `#b9968f`, which at icon size are the same colour — and the
  one thing the mark exists to answer is whether the lab is up. Everything else
  in the panel still follows the theme.
