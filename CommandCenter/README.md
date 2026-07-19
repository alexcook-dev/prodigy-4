# Command Center

Native SwiftUI Mac workspace shell (Wave 0: **T2** + **T15**; Wave 1-D: **T16**).

## What this wave delivers

- **T2 — 4-pane shell:** left sidebar (Projects + Agents), center chat/preview,
  top-right files, bottom-right terminal. Placeholders only; real chat/provider/
  file-browser/terminal internals land in later waves.
- **T15 — Semantic colors:** Light + Dark adaptive tokens in the asset catalog.
  Views use `Theme.*` only — never raw hex.
- **T16 — Window layout:**
  - Draggable `NSSplitView` dividers (sidebar | center | right) with widths
    persisted via `autosaveName`
  - Below 960pt window width, the right column collapses to an overlay/drawer
    (Mail.app / Xcode pattern); no hard minimum window size (tiles to ~650–700)
  - Center-pane chat content capped at 960pt reading width on large displays

## Open / build

```bash
open CommandCenter/CommandCenter.xcodeproj
# or
xcodebuild -project CommandCenter/CommandCenter.xcodeproj -scheme CommandCenter -configuration Debug build
```

## Constraints baked in

| Constraint | How |
|---|---|
| Unsandboxed | `ENABLE_APP_SANDBOX = NO`, empty entitlements |
| Ad-hoc signing | `CODE_SIGN_IDENTITY = "-"`, `CODE_SIGNING_ALLOWED = YES` |
| SwiftData ready | Empty `modelContainer` on app entry; models in T3 |
| System Light/Dark | Asset-catalog color sets with Any + Dark appearances |
| No hard min window | `minWidth` 480 only as soft floor; collapse handles narrow tiles |

## Layout proportions (from wireframes + T16)

| Column | Ideal | Min | Max |
|---|---|---|---|
| Sidebar | 224pt | 160 | 320 |
| Center | flexible | 280 | — (content max-read 960) |
| Right (Files/Terminal) | 320pt | 200 | 480 |

| Behavior | Value |
|---|---|
| Right-column collapse breakpoint | 960pt window width |
| Right-column drawer width | 320pt |
| Max chat reading width | 960pt |
| Soft min window | 480 × 360 |

## T16 verify checklist

1. **Narrow tile (~650px):** resize/tile the window → right column leaves the
   split; toolbar shows “Show Files & Terminal”; chat stays usable in the center.
2. **Drawer:** open via toolbar or ⌘3/⌘4 → Files/Terminal overlay slides in from
   the trailing edge; scrim/close dismisses it.
3. **Dividers:** drag sidebar|center and center|right dividers; quit and relaunch
   → widths restore (`NSSplitView` autosave).
4. **Large display:** widen the window past ~1400px → chat column content stays
   within ~960pt, centered in the center pane.
