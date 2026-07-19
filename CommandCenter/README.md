# Command Center

Native SwiftUI Mac workspace shell (Wave 0: **T2** + **T15**).

## What this wave delivers

- **T2 — 4-pane shell:** left sidebar (Projects + Agents), center chat/preview,
  top-right files, bottom-right terminal. Placeholders only; real chat/provider/
  file-browser/terminal internals land in later waves.
- **T15 — Semantic colors:** Light + Dark adaptive tokens in the asset catalog.
  Views use `Theme.*` only — never raw hex.

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

## Layout proportions (from wireframes)

| Column | Ideal width |
|---|---|
| Sidebar | 224pt |
| Center | flexible |
| Right (Files/Terminal) | 320pt |
