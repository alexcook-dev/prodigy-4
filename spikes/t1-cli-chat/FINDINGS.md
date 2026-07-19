# T1 CLI Chat Prototype — Findings

**Date:** 2026-07-19T22:02Z
**Task:** PLAN.md Implementation Task T1 / Next Step 2 (D5.1)
**Branch:** `wave0.5-cli-spike`
**CLI:** `claude` 2.1.212 (Claude Code)
**Script:** `spikes/t1-cli-chat/run-proto.sh`

## Verdict

**PASS — proceed to T4.**

Scoped chat quality matches a plain claude.ai browser tab for a general personal
question. First-token latency is acceptable for cold spawn-per-turn. No flags that
block the Wave 2 provider work.

## What was tested

One real non-interactive conversation through the installed Claude Code CLI, using
exactly the scoped invocation PLAN.md specifies for V1 chat:

| Concern | Flag / choice | Observed in `system/init` |
|--------|----------------|---------------------------|
| Streaming | `--output-format stream-json --verbose --include-partial-messages` | `stream_event` + `text_delta` lines present |
| System prompt | full `--system-prompt` **replace** (never `--append-system-prompt`) | Reply is general-assistant, not coding-agent |
| Tools | disabled via `--tools ""` | `tools: []` |
| Config isolation | `--setting-sources ""` + `--strict-mcp-config` + `--disable-slash-commands` | `mcp_servers: []`, `slash_commands: []`, `skills: []`, `plugins: []` |
| Auth | **no** `--bare` (subscription OAuth/keychain intact) | `apiKeySource: "none"`, session created |
| Working dir | per-run cwd under `spikes/t1-cli-chat/.workdir` | `cwd` matches; session_id returned |

This is **spawn-per-turn** (`-p`), not the long-running persistent process planned
for T4. First-token numbers therefore include cold-start (config load + session
setup). PLAN.md D5.2 expects multi-second cold start in this mode; persistent
process is the latency fix for production chat.

Default prompt used (general assistant, not coding):

> I have a half day free tomorrow afternoon and want to use it well without turning
> it into a project. Suggest three small, satisfying things I could do — mix
> practical and restorative — and for each give a one-sentence "why this works when
> you only have a few hours." Keep the whole reply under 200 words.

## Latency

| Metric | Value | Notes |
|--------|------:|-------|
| **First-token (`ttft_ms`)** | **2060 ms** | CLI-reported primary signal |
| Stream TTFT (`ttft_stream_ms`) | 1548 ms | |
| Time to request | 314 ms | Local work before API call leaves |
| CLI duration | 7527 ms | Full turn |
| API duration | 8507 ms | |
| Wall-clock total | 8410 ms | Process start → exit |
| Notional cost | $0.0117 | Not billed on subscription (PLAN.md D5.4) |
| Model | `claude-opus-4-8[1m]` | Default for this login |

**First-token latency judgment:** Good for cold spawn (~2.1s). Comparable to opening
a fresh claude.ai turn. T4's persistent process should only improve this (eliminates
per-turn config/MCP/session cold start that D5.2 flags).

**UI note for T4/T5:** The stream emitted a `thinking` content block *before* the
first `text_delta`. Chat UI should treat thinking as the existing "Thinking…"
state (wf-3 #1), and only start appending bubble text on `text_delta`. Do not
confuse thinking start with first visible token.

**Usage note:** Stream also emitted a `rate_limit_event` with
`status: allowed_warning`, `rateLimitType: five_hour`, `utilization: 0.91`. Auth
still succeeded; this is ground truth for Step 10's advisory meter (D5.4), not a
failure of this spike.

## Reply (verbatim)

```
Here are three ways to make the afternoon count without it becoming a to-do list:

**1. Do one "future you" errand.**
Tackle a single nagging task — renew a passport, book that dentist appointment, clear the junk drawer.
*Why this works:* One finished thing gives a real sense of closure without demanding the whole day.

**2. Take a walk with no destination.**
Head out for an hour on foot, ideally somewhere green, and let yourself wander.
*Why this works:* Movement plus open time resets your mind faster than screens or naps, and it needs zero planning.

**3. Cook or bake something slightly involved.**
Pick a recipe with a few steps — fresh bread, a proper soup, a batch of cookies.
*Why this works:* It's absorbing and hands-on, and you end up with something tangible to enjoy that evening.

The trick is picking just one from each afternoon's mood — practical if you're restless, restorative if you're drained — rather than trying to fit all three in.
```

## Quality vs claude.ai browser tab

### Checklist

| Check | Result |
|-------|--------|
| Subscription auth worked (no API key, no `--bare`) | **yes** — session `3d9571ad-4565-4f80-829e-518a0ec9b015`, `apiKeySource: "none"` |
| System-prompt replace took effect | **yes** — general personal assistant; no coding-agent / repo / tool framing |
| No tools invoked | **yes** — `tools: []` in init; no `tool_use` in stream |
| Global MCP / CLAUDE.md contamination avoided | **yes** — empty MCP/skills/plugins/slash_commands; reply never mentions gbrain/gstack/Conductor |
| Streaming partials present | **yes** — multiple `content_block_delta` / `text_delta` events |
| First-token latency acceptable | **yes** — 2060 ms cold spawn |
| Empty / error reply | **no** — clean `end_turn`, `is_error: false` |

### Quality notes (human review)

- **Tone / persona:** Reads like a helpful claude.ai personal reply — warm, concrete,
  no "I'll scan the repo" or coding-agent identity. System-prompt **replace** is doing
  the job PLAN.md requires; do **not** switch to `--append-system-prompt` in T4.
- **Content quality:** Three concrete options, short rationales, under the requested
  length, no tool offers, no file-edit offers. Matches what a browser-tab Claude would
  produce for the same personal prompt.
- **Isolation proof:** Init event confirms tools/MCP/slash_commands empty. Without
  `--setting-sources ""` / `--strict-mcp-config` / `--disable-slash-commands`, this
  machine's global CLAUDE.md routing and ~100 gbrain MCP tools would load (PLAN.md
  D5.1 warning) — they did not.
- **Minor residual:** init still lists built-in agent names
  (`Explore`, `general-purpose`, `Plan`, …) and a `memory_paths.auto` under
  `~/.claude/projects/...`. Not contaminating the reply in this run; T4 should still
  keep the same isolation flags and treat memory/agents as something to watch if
  persona drift ever appears.

### Action

**Proceed to T4 (`ClaudeCLIProvider`) with these flag defaults.** Re-run
`./run-proto.sh` if the provider wrapper changes prompt, tools, or settings surface.
No quality-blocking issues found — nothing to fix before UI/provider work.

## Artifacts

| File | Purpose |
|------|---------|
| `run-proto.sh` | Driver — scoped CLI invocation + stream parse + timings |
| `write-findings.sh` | Regenerates a FINDINGS skeleton from the last run |
| `last-stream.jsonl` | Full stream-json stdout from this run (evidence for T4 event parsing) |
| `last-reply.txt` | Assembled assistant text |
| `last-timings.env` | Machine-readable metrics |
| `last-stderr.txt` | Drained stderr (empty this run; PLAN.md: undrained stderr can deadlock the child) |
| `.workdir/` | cwd used for the spawn (empty project stand-in; gitignored) |

## Re-run

```bash
cd spikes/t1-cli-chat
./run-proto.sh
./write-findings.sh
# overrides:
# MODEL=sonnet EFFORT=low ./run-proto.sh "Your prompt here"
```
