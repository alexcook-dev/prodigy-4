# Command Center

Native SwiftUI Mac workspace shell.

## What this worktree delivers

- **T2 — 4-pane shell:** left sidebar (Projects + Agents), center chat/preview,
  top-right files, bottom-right terminal.
- **T15 — Semantic colors:** Light + Dark adaptive tokens in the asset catalog.
  Views use `Theme.*` only — never raw hex.
- **T7 — SwiftTerm terminal:** embedded PTY shell via `NSViewRepresentable`,
  main-thread data feed, alt-screen resize (SIGWINCH on pane drag for vim/less),
  visible "Shell exited (code N)" + Restart (never a frozen pane).
- **T10 — Keyboard passthrough:** `KeyPassthroughTerminalView` overrides
  `performKeyEquivalent` to return `false` for exactly ⌘1–⌘4 so pane switching
  works while the shell is first responder; Esc and all other keys stay in the
  terminal (vim-safe).

## Open / build

```bash
open CommandCenter/CommandCenter.xcodeproj
# or
xcodebuild -project CommandCenter/CommandCenter.xcodeproj -scheme CommandCenter -configuration Debug build
```

**Debug** builds **Prodigy Dev** (`dev.alexcook.Prodigy.dev`) — safe for Xcode Run.
**Release** builds **Prodigy** (`dev.alexcook.Prodigy`) for DMG/GitHub production.
They never overwrite each other. See root [README.md](../README.md) for install/release.

SwiftTerm 1.15+ is pulled via SPM. Building Metal shaders requires the Xcode
Metal toolchain (`xcodebuild -downloadComponent MetalToolchain` once if missing);
the app forces the software renderer at runtime.

## Constraints baked in

| Constraint | How |
|---|---|
| Unsandboxed | `ENABLE_APP_SANDBOX = NO`, empty entitlements |
| Ad-hoc signing | `CODE_SIGN_IDENTITY = "-"`, `CODE_SIGNING_ALLOWED = YES` |
| SwiftData ready | Empty `modelContainer` on app entry; models in T3 |
| System Light/Dark | Asset-catalog color sets with Any + Dark appearances |
| Terminal never frozen | Process-ended bar + Restart on shell exit |
| Esc stays in terminal | No window-level Esc; only file-preview will bind Esc later |

## Layout proportions (from wireframes)

| Column | Ideal width |
|---|---|
| Sidebar | 224pt |
| Center | flexible |
| Right (Files/Terminal) | 320pt |

## Manual verify (T7 / T10)

1. Launch app, click Terminal (or ⌘4) so the PTY is first responder.
2. Run `vim` — Esc returns to normal mode inside vim; center pane does not flip.
3. From inside the shell, press ⌘1–⌘4 — panes switch (menu Navigate + passthrough).
4. Run `exit` or kill the shell — dimmed buffer + "Shell exited (code N)" + Restart.
5. Restart restores a live prompt.
