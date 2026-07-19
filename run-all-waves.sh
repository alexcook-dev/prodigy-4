#!/usr/bin/env bash
# Runs all 5 waves of GROK_HANDOFF.md end to end, unattended.
# Parallel within a wave, sequential across waves, auto-merges each wave's
# worktrees into the branch you started on before moving to the next wave.
#
# Safety net: fails loudly (set -e discipline via explicit checks) on any
# grok run error or merge conflict, and stops rather than continuing on top
# of a broken wave. It does NOT replace reading the logs — read logs/ after
# each wave, especially wave0.5 (the CLI-quality spike) and wave2 (the
# provider/subprocess code) which the handoff doc flagged as highest-risk.

set -uo pipefail
cd "$(dirname "$0")"
REPO_ROOT=$(git rev-parse --show-toplevel) && cd "$REPO_ROOT"
BASE_BRANCH=$(git branch --show-current)
LOG_DIR="$REPO_ROOT/.grok-wave-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
echo "==> Base branch: $BASE_BRANCH"
echo "==> Logs: $LOG_DIR"

command -v grok >/dev/null 2>&1 || { echo "grok CLI not found on PATH"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found on PATH (required to parse worktree list)"; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree is dirty. Commit or stash before running this (grok worktrees branch off HEAD)."
  exit 1
fi

# --- run a set of grok commands in parallel, wait, fail loudly on any error ---
run_parallel() {
  local -a pids=()
  local -a names=()
  local i=0
  while [ $((i+1)) -le $# ]; do
    local name="${!((i+1))}"
    local cmd="${!((i+2))}"
    echo "  -> launching: $name"
    eval "$cmd" > "$LOG_DIR/$name.log" 2>&1 &
    pids+=($!)
    names+=("$name")
    i=$((i+2))
  done
  local fail=0
  for idx in "${!pids[@]}"; do
    if ! wait "${pids[$idx]}"; then
      echo "  !! FAILED: ${names[$idx]} — see $LOG_DIR/${names[$idx]}.log"
      fail=1
    else
      echo "  ok: ${names[$idx]} — see $LOG_DIR/${names[$idx]}.log"
    fi
  done
  if [ "$fail" -eq 1 ]; then
    echo "==> A grok run failed. Stopping before merge. Fix and re-run manually from GROK_HANDOFF.md, or re-run this script once resolved."
    exit 1
  fi
}

# --- merge every worktree created since a baseline snapshot, then remove it ---
merge_new_worktrees() {
  local before="$1"
  local after
  after=$(grok worktree list --json 2>/dev/null || echo "[]")
  local new_paths
  new_paths=$(comm -13 \
    <(echo "$before" | jq -r '.[].path' | sort) \
    <(echo "$after"  | jq -r '.[].path' | sort))
  if [ -z "$new_paths" ]; then
    echo "  (no new worktrees found to merge — check logs, this may indicate a problem)"
    return
  fi
  while IFS= read -r wpath; do
    [ -z "$wpath" ] && continue
    local branch
    branch=$(git -C "$wpath" branch --show-current)
    echo "  -> merging $branch (from $wpath)"
    if ! git merge --no-ff "$branch" -m "Merge $branch (grok wave, automated)"; then
      echo "==> MERGE CONFLICT on $branch. Resolve manually (git status), commit, then re-run this script — already-merged waves are skipped by nothing here, so re-running will redo prior waves. Prefer finishing the rest by hand from GROK_HANDOFF.md instead."
      exit 1
    fi
    grok worktree rm --force "$wpath" >/dev/null 2>&1 || true
  done <<< "$new_paths"
}

snapshot() { grok worktree list --json 2>/dev/null || echo "[]"; }

# =========================================================================
echo ""
echo "=== Wave 0 (scaffold + color system) + Wave 0.5 (CLI spike), in parallel ==="
BEFORE=$(snapshot)
run_parallel \
  "wave0-scaffold" 'grok -p "Read PLAN.md in full before doing anything else. Implement T2 and T15 together from the Implementation Tasks section: scaffold the native SwiftUI Mac app project with the 4-pane layout described in Next Steps 1 and the Information Architecture section (left sidebar split into Projects/Agents, center chat/preview pane, top-right file browser, bottom-right terminal placeholders) — AND build the semantic/adaptive color system from the Visual System section (Light+Dark via asset-catalog color sets or adaptive Color extensions, values as specified, never raw hex in any view). These two are one task because every view you scaffold needs to use the color system from the first line of code, not retrofit it later. Read the wireframe PNGs and HTML in docs/design/workspace-shell-20260719/ for exact layout proportions. Follow PLAN.md'\''s Constraints section exactly (unsandboxed, ad-hoc signing, SwiftData for persistence — models come in a later wave, just get the app shell + navigation structure + color system in place). Verify per T2 and T15'\''s Verify lines in PLAN.md. Do not implement chat, provider, file browser internals, or terminal internals yet — those are later waves; placeholders are fine." -w wave0-scaffold --permission-mode acceptEdits --effort high --disable-web-search' \
  "wave0.5-cli-spike" 'grok -p "Read PLAN.md in full, focus on Next Step 2'\''s '\''First task of this step, before any UI work'\'' note and T1 in Implementation Tasks. Write a small throwaway script (not part of the Xcode project — a standalone shell/Swift script is fine) that drives the installed '\''claude'\'' CLI exactly as PLAN.md specifies: --output-format stream-json --verbose --include-partial-messages for streaming, full --system-prompt replace (never --append-system-prompt), tools disabled by default, --setting-sources/--strict-mcp-config/--disable-slash-commands to prevent global config contamination, and critically do NOT use --bare (it breaks subscription auth). Run one real conversation through it and report: does the reply quality match a claude.ai browser tab? What'\''s the first-token latency? Report findings in the PR description, do not silently proceed if quality is bad — flag it." -w wave0.5-cli-spike --permission-mode acceptEdits --effort medium --disable-web-search'
merge_new_worktrees "$BEFORE"
echo "==> Wave 0/0.5 merged. READ $LOG_DIR/wave0.5-cli-spike.log before trusting Wave 2's provider work below — this script does not evaluate that judgment for you."

# =========================================================================
echo ""
echo "=== Wave 1 (data/Projects, files, terminal, window — 4 parallel streams) ==="
BEFORE=$(snapshot)
run_parallel \
  "wave1-data" 'grok -p "Read PLAN.md in full. Implement T3, T11, and T12 from Implementation Tasks in sequence (they build on each other, same subsystem): T3 — SwiftData models for Project/Agent/Thread/Message plus the two independent sidebar sections (Projects and Agents, NOT nested, per Constraints); T11 — Project creation flow with a folder picker + '\''start empty'\'' fallback (creates ~/Projects/<name>), the '\''quick chat'\'' entry point auto-creating a real hidden Project, and enforce single-thread-per-Project for V1 (tab bar '\''+'\'' opens file previews only); T12 — Archive action (archived: Bool on Project) plus an active/archived filter toggle in the sidebar, same pattern as Claude'\''s/ChatGPT'\''s own Projects lists. Follow the Visual System section for all colors/type — no raw hex. Verify per each task'\''s Verify line in PLAN.md." -w wave1-data --permission-mode acceptEdits --effort high --disable-web-search' \
  "wave1-files" 'grok -p "Read PLAN.md in full. Implement T6 from Implementation Tasks: FileManager-based file tree/list with lazy per-directory loading (enumerate only a directory'\''s immediate children on expand, off the main thread — never recursively walk the tree up front, per Next Step 4). Build the tree/browsing/preview UI now; the final '\''flip center pane to preview'\'' wiring depends on the chat view which doesn'\''t exist yet in this wave — stub that connection point clearly (e.g. a TODO comment or a protocol the chat view will conform to later) rather than guessing at the chat view'\''s shape. Follow the Visual System section for colors/type. Verify per T6'\''s Verify line in PLAN.md." -w wave1-files --permission-mode acceptEdits --effort high --disable-web-search' \
  "wave1-terminal" 'grok -p "Read PLAN.md in full. Implement T7 and T10 from Implementation Tasks together (same subsystem): T7 — embed a terminal panel using SwiftTerm (NSViewRepresentable wrapper around its TerminalView, main-thread data-feed dispatch, alt-screen resize handling for vim/less, visible '\''process ended'\'' state on shell exit, never a frozen pane); T10 — the keyboard-passthrough contract: subclass/wrap TerminalView to override performKeyEquivalent:, returning false (pass through) for exactly ⌘1-⌘4, forwarding every other key including Esc to the terminal untouched. This resolves a real AppKit risk PLAN.md'\''s Premises section names explicitly — read that context too. Verify per each task'\''s Verify line, especially: open vim in the terminal, confirm Esc stays inside vim and never affects anything else; ⌘1-⌘4 switch panes from inside a running shell." -w wave1-terminal --permission-mode acceptEdits --effort high --disable-web-search' \
  "wave1-window" 'grok -p "Read PLAN.md in full. Implement T16 from Implementation Tasks: draggable NSSplitView dividers between sidebar/center/right-column (widths persisted per-window), a width breakpoint below which the right column (Files/Terminal) collapses to an overlay/drawer (same pattern as Mail.app/Xcode at narrow widths — no hard minimum window size, Mac windows tile to ~650-700px routinely and that'\''s daily use), and a max reading width (~900-1000px) for the center-pane chat content on large displays. This can be built against the Wave 0 scaffold'\''s placeholder panes — it doesn'\''t need real data. Verify per T16'\''s Verify line in PLAN.md." -w wave1-window --permission-mode acceptEdits --effort high --disable-web-search'
merge_new_worktrees "$BEFORE"
echo "==> Wave 1 merged (resolve any residual layout overlap between wave1-data's sidebar and wave1-window's split view by hand if needed)."

# =========================================================================
echo ""
echo "=== Wave 2 (provider + background process lifecycle) ==="
BEFORE=$(snapshot)
run_parallel \
  "wave2-provider" 'grok -p "Read PLAN.md in full. Implement T4 and T9 from Implementation Tasks together (same subsystem): T4 — the ModelProvider protocol plus ClaudeCLIProvider driving the installed claude CLI as one long-running process per conversation (stream-json stdio both directions), spawn-per-turn (-p + --resume) as fallback if persistent mode misbehaves. Apply every constraint from Next Step 2 exactly: session_id capture and cwd-scoped --resume (cwd = the Project'\''s working folder from T11), resume-failure fallback by rehydrating from SwiftData when Claude Code has garbage-collected the transcript, the exact chat-defaults from D5.1 (system-prompt replace, tools off, --setting-sources/--strict-mcp-config/--disable-slash-commands), never --bare, and the typed system/api_retry error categories. T9 — LRU-capped (3) background process lifecycle: only the focused Project'\''s process stays alive plus up to 2 more backgrounded ones, idle teardown, falls back to spawn-per-turn beyond the cap; a background reply finishing should set the Project'\''s hasUnviewedActivity flag (from the Visual System'\''s status-dot spec) so the UI can react in Wave 3. This depends on T3'\''s Project model (already merged) for the cwd binding. Verify per each task'\''s Verify line in PLAN.md." -w wave2-provider --permission-mode acceptEdits --effort high --disable-web-search'
merge_new_worktrees "$BEFORE"
echo "==> Wave 2 merged. This is the highest-risk wave (real subprocess management against your real subscription) — READ $LOG_DIR/wave2-provider.log and the actual diff before trusting Wave 3."

# =========================================================================
echo ""
echo "=== Wave 3 (chat UI + errors + integration, launch behavior — parallel) ==="
BEFORE=$(snapshot)
run_parallel \
  "wave3-chat" 'grok -p "Read PLAN.md in full. Implement T5 and T13 from Implementation Tasks together: T5 — wire the central chat pane to ModelProvider with streaming markdown rendering (pick a Swift markdown renderer that tolerates incremental text) and a model/effort picker in the composer (no usage-meter pill — that'\''s explicitly cut from V1, see NOT in Scope); T13 — the category-specific error banner from Next Step 2 / the Interaction States table: one banner shape, dynamic text/CTA per api_retry category (authentication_failed, billing_error, rate_limit, overloaded, and CLI-process-died), exact copy is specified in PLAN.md, partial replies preserved and tagged. Also finish the two integration points left open in Wave 1: wire Stream B'\''s file-tree selection to flip this chat pane into preview mode (Next Step 4), and wire Stream C'\''s ⌘2 (always go to Chat tab) and ⌘⏎-from-preview (go to chat + insert a file reference into the composer) into this view now that it exists. Verify per each task'\''s Verify line in PLAN.md, plus: file selection flips the center pane to preview and back cleanly; ⌘2 and ⌘⏎ behave exactly as the Responsive & Accessibility section specifies." -w wave3-chat --permission-mode acceptEdits --effort high --disable-web-search' \
  "wave3-launch" 'grok -p "Read PLAN.md in full. Implement T14 from Implementation Tasks: on app launch, auto-select the most-recently-active Project (lastActiveAt timestamp, updated on selection) and resume its most recent thread via the session-resume path from T4/D5.3 — skip any picker screen. True first-run (zero Projects exist ever) still shows the wf-2 greeting screen from docs/design/workspace-shell-20260719/wf-2-firstrun.png, unaffected by this. Verify per T14'\''s Verify line in PLAN.md." -w wave3-launch --permission-mode acceptEdits --effort medium --disable-web-search'
merge_new_worktrees "$BEFORE"
echo "==> Wave 3 merged."

# =========================================================================
echo ""
echo "=== Wave 4 (accessibility polish) ==="
BEFORE=$(snapshot)
run_parallel \
  "wave4-a11y" 'grok -p "Read PLAN.md in full. Implement T17 from Implementation Tasks: add SwiftUI accessibility labels/values to the status-dot component ('\''Streaming'\'' / '\''Idle'\'', not color-only), and make the per-row Archive action (from T12) focus-visible and keyboard-activatable (Space/Enter) or reachable via the standard macOS contextual-menu key, not hover/right-click only. Verify per T17'\''s Verify line in PLAN.md." -w wave4-a11y --permission-mode acceptEdits --effort medium --disable-web-search'
merge_new_worktrees "$BEFORE"

echo ""
echo "=== All 5 waves merged into $BASE_BRANCH. ==="
echo "Logs: $LOG_DIR"
echo "T8 (usage display) was intentionally skipped — deferred post-V1 per PLAN.md."
echo "Next: build and run the app yourself, check off PLAN.md's Implementation Tasks, and read every wave log — none of this was reviewed as it went."
