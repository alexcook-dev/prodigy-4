# Prodigy

Native macOS workspace shell (Command Center) — chat, files, terminal, Safari, Apple Mail & Calendar.

## Install production app (terminal)

`scripts/install.sh` bootstraps a clean Mac as needed:

| Dependency | What the script does |
|---|---|
| **bash** | Uses `/bin/bash` (re-exec if needed) |
| **Xcode CLT** | Installs if missing (`xcode-select`) |
| **Homebrew** | Official installer if missing |
| **GitHub CLI (`gh`)** | `brew install gh` if missing |
| **GitHub auth** | `gh auth login` (or use `GH_TOKEN`) for this private repo |
| **python3** | `brew install python` only if missing |

Then downloads the latest **Prodigy-*.dmg** release and installs to `~/Applications/Prodigy.app`.

### First install (from this repo)

```bash
git clone https://github.com/alexcook-dev/prodigy-4.git
cd prodigy-4
./scripts/install.sh
```

Pin a version: `./scripts/install.sh --version v0.1.1`

### Later / no clone (private repo, after `gh` exists)

```bash
bash <(gh api repos/alexcook-dev/prodigy-4/contents/scripts/install.sh --jq .content | base64 -d)
```

Unattended (CI): `NONINTERACTIVE=1 GH_TOKEN=… ./scripts/install.sh`  
Skip brew/gh bootstrap: `./scripts/install.sh --skip-deps`

Installs **`~/Applications/Prodigy.app`** (`dev.alexcook.Prodigy`).

Releases: https://github.com/alexcook-dev/prodigy-4/releases

## Dev vs production (important)

| | App name | Bundle ID | How you get it |
|---|---|---|---|
| **Production** | Prodigy | `dev.alexcook.Prodigy` | GitHub Release DMG / `install.sh` |
| **Development** | Prodigy Dev | `dev.alexcook.Prodigy.dev` | Xcode **Run** (Debug) |

They are **different apps**. Running in Xcode updates *Prodigy Dev* only — it does **not** overwrite your production install. After you merge and cut a release, update production with `install.sh` (or download the new DMG).

Preferences, SwiftData, and dock icons stay separate because the bundle IDs differ.

### In-app updates (production)

Production **Prodigy** checks GitHub Releases on launch (every ~6 hours) and shows an **Update** banner when a newer `Prodigy-*.dmg` is available. Also: **Prodigy → Check for Updates…** and **Settings → Updates**.

Uses `gh auth token` (or `GH_TOKEN`) because the repo is private. Tap **Update** to download the DMG and replace `~/Applications/Prodigy.app`.

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
