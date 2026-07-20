# Prodigy

Native macOS workspace shell (Command Center) — chat, files, terminal, Safari, Apple Mail & Calendar.

## Install production app (terminal)

This repo is **private**. Authenticate once with [GitHub CLI](https://cli.github.com/):

```bash
gh auth login
```

Then install / update production Prodigy from the latest GitHub Release:

```bash
# Recommended (works on private repos via gh):
bash <(gh api repos/alexcook-dev/prodigy-4/contents/scripts/install.sh --jq .content | base64 -d)
```

From a clone of this repo:

```bash
./scripts/install.sh
# pin a version:
./scripts/install.sh --version v0.1.0
```

Installs **`~/Applications/Prodigy.app`** (`dev.alexcook.Prodigy`).

Releases: https://github.com/alexcook-dev/prodigy-4/releases

## Dev vs production (important)

| | App name | Bundle ID | How you get it |
|---|---|---|---|
| **Production** | Prodigy | `dev.alexcook.Prodigy` | GitHub Release DMG / `install.sh` |
| **Development** | Prodigy Dev | `dev.alexcook.Prodigy.dev` | Xcode **Run** (Debug) |

They are **different apps**. Running in Xcode updates *Prodigy Dev* only — it does **not** overwrite your production install. After you merge and cut a release, update production with `install.sh` (or download the new DMG).

Preferences, SwiftData, and dock icons stay separate because the bundle IDs differ.

## Ship a new production build

```bash
# 1. Bump version (optional)
echo 0.1.1 > VERSION

# 2. Package + publish GitHub Release + DMG
./scripts/release.sh
# or draft first:
./scripts/release.sh --draft 0.1.1
```

Local package only (no upload):

```bash
./scripts/package-dmg.sh
# → dist/Prodigy-0.1.0.dmg
# → dist/Prodigy.app
```

CI: push a tag `v0.1.0` (or run **Release Prodigy DMG** workflow) on a macOS runner.

## Develop in Xcode

```bash
open CommandCenter/CommandCenter.xcodeproj
```

Debug configuration produces **Prodigy Dev**. Release configuration produces **Prodigy** (what the DMG ships).

```bash
xcodebuild -project CommandCenter/CommandCenter.xcodeproj \
  -scheme CommandCenter -configuration Debug build
```

See [CommandCenter/README.md](CommandCenter/README.md) for shell/layout details.
