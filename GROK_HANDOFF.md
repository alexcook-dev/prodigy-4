# Grok Implementation Handoff

Run these from a terminal at the repo root: `/Users/alexcook/conductor/workspaces/prodigy-4/zagreb`

Full spec lives in **`PLAN.md`** (constraints, architecture, UI/UX spec, all 17
implementation tasks). Non-blocking deferred polish lives in **`TODOS.md`**. Visual
reference (wireframe PNGs + their HTML source for exact CSS values) is in
`docs/design/workspace-shell-20260719/`. Every grok command below tells grok to read
`PLAN.md` first — it is the single source of truth. Do not paraphrase the plan to grok
verbally; point it at the file.

## Why this isn't 17-way parallel

The tasks have real dependencies (you can't wire chat error states before the
provider exists; you can't bind a Project's folder before the Project model exists).
Naive full parallelism produces 17 worktrees that don't merge cleanly. Instead this
is **5 waves** — parallel *within* a wave, sequential *across* waves. Each wave ends
with you reviewing and merging before the next one starts.

```
Wave 0   (root, sequential)      T2 + T15  — scaffold + color system together
Wave 0.5 (parallel to Wave 0)    T1        — CLI prototype spike, zero UI dependency
Wave 1   (4 parallel streams)    A: T3→T11→T12   B: T6   C: T7→T10   D: T16
Wave 2   (sequential, needs Wave 1-A + Wave 0.5)   T4→T9
Wave 3   (parallel-ish, needs Wave 2)   T5→T13 · T14 · (integration: wire T6+T10 into T5)
Wave 4   (polish, needs Wave 1-A)       T17
```

T8 (usage display) is explicitly deferred post-V1 — not in any wave.

Each command uses `-w <name>` so grok works in an isolated git worktree on its own
branch. Nothing touches `main`/`office-hours` until you review a worktree's diff and
merge it yourself. Run the commands in a wave **at the same time** (separate terminal
tabs, or background with `&` — see the batch script at the bottom). Do not start the
next wave's commands until you've merged everything from the current one.

---

## Wave 0 — Scaffold + color system (sequential, run alone first)

```bash
grok -p "Read PLAN.md in full before doing anything else. Implement T2 and T15 together from the Implementation Tasks section: scaffold the native SwiftUI Mac app project with the 4-pane layout described in Next Steps 1 and the Information Architecture section (left sidebar split into Projects/Agents, center chat/preview pane, top-right file browser, bottom-right terminal placeholders) — AND build the semantic/adaptive color system from the Visual System section (Light+Dark via asset-catalog color sets or adaptive Color extensions, values as specified, never raw hex in any view). These two are one task because every view you scaffold needs to use the color system from the first line of code, not retrofit it later. Read the wireframe PNGs and HTML in docs/design/workspace-shell-20260719/ for exact layout proportions. Follow PLAN.md's Constraints section exactly (unsandboxed, ad-hoc signing, SwiftData for persistence — models come in a later wave, just get the app shell + navigation structure + color system in place). Verify per T2 and T15's Verify lines in PLAN.md. Do not implement chat, provider, file browser internals, or terminal internals yet — those are later waves; placeholders are fine." -w wave0-scaffold --permission-mode acceptEdits --effort high --disable-web-search
```

Review: `git -C <worktree-path> diff main...HEAD`. Merge to your working branch before
starting Wave 1.

---

## Wave 0.5 — CLI prototype spike (run in parallel with Wave 0, doesn't touch the Xcode project)

```bash
grok -p "Read PLAN.md in full, focus on Next Step 2's 'First task of this step, before any UI work' note and T1 in Implementation Tasks. Write a small throwaway script (not part of the Xcode project — a standalone shell/Swift script is fine) that drives the installed 'claude' CLI exactly as PLAN.md specifies: --output-format stream-json --verbose --include-partial-messages for streaming, full --system-prompt replace (never --append-system-prompt), tools disabled by default, --setting-sources/--strict-mcp-config/--disable-slash-commands to prevent global config contamination, and critically do NOT use --bare (it breaks subscription auth). Run one real conversation through it and report: does the reply quality match a claude.ai browser tab? What's the first-token latency? Report findings in the PR description, do not silently proceed if quality is bad — flag it." -w wave0-cli-spike --permission-mode acceptEdits --effort medium --disable-web-search
```

Review the findings before Wave 2 — if grok reports the scoped chat feels worse than
claude.ai, fix the provider config (per PLAN.md's own instruction) before building T4
on top of it.

---

## Wave 1 — Four parallel streams (after Wave 0 is merged)

Run all four of these together:

**Stream A — data model + Projects (T3 → T11 → T12):**
```bash
grok -p "Read PLAN.md in full. Implement T3, T11, and T12 from Implementation Tasks in sequence (they build on each other, same subsystem): T3 — SwiftData models for Project/Agent/Thread/Message plus the two independent sidebar sections (Projects and Agents, NOT nested, per Constraints); T11 — Project creation flow with a folder picker + 'start empty' fallback (creates ~/Projects/<name>), the 'quick chat' entry point auto-creating a real hidden Project, and enforce single-thread-per-Project for V1 (tab bar '+' opens file previews only); T12 — Archive action (archived: Bool on Project) plus an active/archived filter toggle in the sidebar, same pattern as Claude's/ChatGPT's own Projects lists. Follow the Visual System section for all colors/type — no raw hex. Verify per each task's Verify line in PLAN.md." -w wave1-data --permission-mode acceptEdits --effort high --disable-web-search
```

**Stream B — file browser (T6):**
```bash
grok -p "Read PLAN.md in full. Implement T6 from Implementation Tasks: FileManager-based file tree/list with lazy per-directory loading (enumerate only a directory's immediate children on expand, off the main thread — never recursively walk the tree up front, per Next Step 4). Build the tree/browsing/preview UI now; the final 'flip center pane to preview' wiring depends on the chat view which doesn't exist yet in this wave — stub that connection point clearly (e.g. a TODO comment or a protocol the chat view will conform to later) rather than guessing at the chat view's shape. Follow the Visual System section for colors/type. Verify per T6's Verify line in PLAN.md." -w wave1-files --permission-mode acceptEdits --effort high --disable-web-search
```

**Stream C — terminal (T7 → T10):**
```bash
grok -p "Read PLAN.md in full. Implement T7 and T10 from Implementation Tasks together (same subsystem): T7 — embed a terminal panel using SwiftTerm (NSViewRepresentable wrapper around its TerminalView, main-thread data-feed dispatch, alt-screen resize handling for vim/less, visible 'process ended' state on shell exit, never a frozen pane); T10 — the keyboard-passthrough contract: subclass/wrap TerminalView to override performKeyEquivalent:, returning false (pass through) for exactly ⌘1-⌘4, forwarding every other key including Esc to the terminal untouched. This resolves a real AppKit risk PLAN.md's Premises section names explicitly — read that context too. Verify per each task's Verify line, especially: open vim in the terminal, confirm Esc stays inside vim and never affects anything else; ⌘1-⌘4 switch panes from inside a running shell." -w wave1-terminal --permission-mode acceptEdits --effort high --disable-web-search
```

**Stream D — window layout (T16):**
```bash
grok -p "Read PLAN.md in full. Implement T16 from Implementation Tasks: draggable NSSplitView dividers between sidebar/center/right-column (widths persisted per-window), a width breakpoint below which the right column (Files/Terminal) collapses to an overlay/drawer (same pattern as Mail.app/Xcode at narrow widths — no hard minimum window size, Mac windows tile to ~650-700px routinely and that's daily use), and a max reading width (~900-1000px) for the center-pane chat content on large displays. This can be built against the Wave 0 scaffold's placeholder panes — it doesn't need real data. Verify per T16's Verify line in PLAN.md." -w wave1-window --permission-mode acceptEdits --effort high --disable-web-search
```

Review and merge all four before Wave 2. Resolve any merge conflicts between streams
yourself (they touch different files by design, but the root layout view may need a
light manual reconciliation between Stream A's sidebar and Stream D's split view).

---

## Wave 2 — Provider (sequential, needs Wave 1 Stream A merged + Wave 0.5 findings reviewed)

```bash
grok -p "Read PLAN.md in full. Implement T4 and T9 from Implementation Tasks together (same subsystem): T4 — the ModelProvider protocol plus ClaudeCLIProvider driving the installed claude CLI as one long-running process per conversation (stream-json stdio both directions), spawn-per-turn (-p + --resume) as fallback if persistent mode misbehaves. Apply every constraint from Next Step 2 exactly: session_id capture and cwd-scoped --resume (cwd = the Project's working folder from T11), resume-failure fallback by rehydrating from SwiftData when Claude Code has garbage-collected the transcript, the exact chat-defaults from D5.1 (system-prompt replace, tools off, --setting-sources/--strict-mcp-config/--disable-slash-commands), never --bare, and the typed system/api_retry error categories. T9 — LRU-capped (3) background process lifecycle: only the focused Project's process stays alive plus up to 2 more backgrounded ones, idle teardown, falls back to spawn-per-turn beyond the cap; a background reply finishing should set the Project's hasUnviewedActivity flag (from the Visual System's status-dot spec) so the UI can react in Wave 3. This depends on T3's Project model (already merged) for the cwd binding. Verify per each task's Verify line in PLAN.md." -w wave2-provider --permission-mode acceptEdits --effort high --disable-web-search
```

Review and merge before Wave 3 — this is the highest-risk wave (real subprocess
management), read the diff carefully, and actually run it against your real Claude
Code subscription before moving on.

---

## Wave 3 — Chat UI + launch behavior (needs Wave 2 merged)

**Stream A — chat + errors (T5 → T13):**
```bash
grok -p "Read PLAN.md in full. Implement T5 and T13 from Implementation Tasks together: T5 — wire the central chat pane to ModelProvider with streaming markdown rendering (pick a Swift markdown renderer that tolerates incremental text) and a model/effort picker in the composer (no usage-meter pill — that's explicitly cut from V1, see NOT in Scope); T13 — the category-specific error banner from Next Step 2 / the Interaction States table: one banner shape, dynamic text/CTA per api_retry category (authentication_failed, billing_error, rate_limit, overloaded, and CLI-process-died), exact copy is specified in PLAN.md, partial replies preserved and tagged. Also finish the two integration points left open in Wave 1: wire Stream B's file-tree selection to flip this chat pane into preview mode (Next Step 4), and wire Stream C's ⌘2 (always go to Chat tab) and ⌘⏎-from-preview (go to chat + insert a file reference into the composer) into this view now that it exists. Verify per each task's Verify line in PLAN.md, plus: file selection flips the center pane to preview and back cleanly; ⌘2 and ⌘⏎ behave exactly as the Responsive & Accessibility section specifies." -w wave3-chat --permission-mode acceptEdits --effort high --disable-web-search
```

**Stream B — launch behavior (T14):**
```bash
grok -p "Read PLAN.md in full. Implement T14 from Implementation Tasks: on app launch, auto-select the most-recently-active Project (lastActiveAt timestamp, updated on selection) and resume its most recent thread via the session-resume path from T4/D5.3 — skip any picker screen. True first-run (zero Projects exist ever) still shows the wf-2 greeting screen from docs/design/workspace-shell-20260719/wf-2-firstrun.png, unaffected by this. Verify per T14's Verify line in PLAN.md." -w wave3-launch --permission-mode acceptEdits --effort medium --disable-web-search
```

Review and merge both before Wave 4.

---

## Wave 4 — Accessibility polish (needs Wave 1 Stream A merged)

```bash
grok -p "Read PLAN.md in full. Implement T17 from Implementation Tasks: add SwiftUI accessibility labels/values to the status-dot component ('Streaming' / 'Idle', not color-only), and make the per-row Archive action (from T12) focus-visible and keyboard-activatable (Space/Enter) or reachable via the standard macOS contextual-menu key, not hover/right-click only. Verify per T17's Verify line in PLAN.md." -w wave4-a11y --permission-mode acceptEdits --effort medium --disable-web-search
```

---

## Constraints every wave must respect (repeat offenders if skipped)

These cut across every task above — grok gets told to read PLAN.md, but if a stream
seems to be drifting, check for these specifically:

1. **No raw hex colors anywhere** — always the semantic/adaptive tokens from T15.
2. **`--bare` is never used** on the claude CLI — it breaks subscription auth.
3. **Esc never fires while the terminal is first responder** — this is the one
   finding the design review's adversarial verification flagged as most likely to
   silently break (vim is unusable if this regresses).
4. **cwd is always scoped per-Project** when spawning the CLI — session resume
   depends on it.
5. **Single thread per Project in V1** — don't let an agent "helpfully" build
   multi-thread support, it's explicitly deferred.
6. **No usage-meter pill in the V1 composer** — explicitly cut, don't let it creep
   back in from the wireframe.

## Run a wave in parallel (batch script)

Example for Wave 1 — save as a script or paste directly:

```bash
#!/usr/bin/env bash
set -e
cd /Users/alexcook/conductor/workspaces/prodigy-4/zagreb

grok -p "$(cat <<'EOF'
<Stream A prompt from above>
EOF
)" -w wave1-data --permission-mode acceptEdits --effort high --disable-web-search &

grok -p "$(cat <<'EOF'
<Stream B prompt from above>
EOF
)" -w wave1-files --permission-mode acceptEdits --effort high --disable-web-search &

grok -p "$(cat <<'EOF'
<Stream C prompt from above>
EOF
)" -w wave1-terminal --permission-mode acceptEdits --effort high --disable-web-search &

grok -p "$(cat <<'EOF'
<Stream D prompt from above>
EOF
)" -w wave1-window --permission-mode acceptEdits --effort high --disable-web-search &

wait
echo "Wave 1 complete — review each worktree before merging."
```

Each `grok -w` call prints the worktree path it created — that's where you review
(`git -C <path> diff main...HEAD`) before merging into your working branch.

## After each wave

1. `git -C <worktree-path> status` and `git -C <worktree-path> diff main...HEAD` —
   read the actual diff, don't trust it blind.
2. Build and run the app (or the relevant slice) yourself.
3. Merge only what you've reviewed. Stage by explicit path, never `git add -A`.
4. Update the checkboxes in `PLAN.md`'s Implementation Tasks section as tasks land.
5. Only then start the next wave.
