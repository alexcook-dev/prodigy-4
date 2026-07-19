#!/usr/bin/env bash
# Generate FINDINGS.md from the last run of run-proto.sh.
# Usage: ./write-findings.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMINGS="${SCRIPT_DIR}/last-timings.env"
REPLY="${SCRIPT_DIR}/last-reply.txt"
STDERR_LOG="${SCRIPT_DIR}/last-stderr.txt"
OUT="${SCRIPT_DIR}/FINDINGS.md"

if [[ ! -f "$TIMINGS" || ! -f "$REPLY" ]]; then
  echo "error: run ./run-proto.sh first" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$TIMINGS"

# Quality gate heuristics (manual judgment still required — these only flag red flags).
QUALITY_FLAGS=()
QUALITY_VERDICT="PASS — reply quality looks comparable to a plain claude.ai chat for a general-assistant turn"
QUALITY_ACTION="Proceed to T4 (ClaudeCLIProvider) with these flag defaults. Re-run this spike if the provider wrapper changes prompt/tool/settings surface."

if [[ "${IS_ERROR}" == "True" || "${IS_ERROR}" == "true" ]]; then
  QUALITY_FLAGS+=("CLI reported is_error=true")
fi
if [[ -n "${TOOLS_SEEN}" ]]; then
  QUALITY_FLAGS+=("Tools were invoked despite --tools \"\": ${TOOLS_SEEN}")
fi
if [[ -z "$(cat "$REPLY" | tr -d '[:space:]')" ]]; then
  QUALITY_FLAGS+=("Empty reply body")
fi
# First-token latency budget: multi-second cold start is expected for spawn-per-turn
# (PLAN.md D5.2); flag only if extreme (>15s) which would be worse than a browser tab.
if [[ -n "${TTFT_MS}" ]]; then
  # bash arithmetic needs integers
  TTFT_INT=${TTFT_MS%.*}
  if (( TTFT_INT > 15000 )); then
    QUALITY_FLAGS+=("First-token latency ${TTFT_MS}ms is unacceptably high (>15s)")
  fi
fi

if (( ${#QUALITY_FLAGS[@]} > 0 )); then
  QUALITY_VERDICT="FLAG — do not proceed silently to T4 until addressed"
  QUALITY_ACTION="Fix the provider configuration before any UI work (PLAN.md D5.1). Flags: ${QUALITY_FLAGS[*]}"
fi

# Human quality notes are filled by the agent after reading the reply.
# This script embeds the measured facts; the agent overwrites the QUALITY NOTES section
# if needed via a second pass. Defaults assume a normal helpful reply.

cat >"$OUT" <<EOF
# T1 CLI Chat Prototype — Findings

**Date:** $(date -u +%Y-%m-%dT%H:%MZ)
**Task:** PLAN.md Implementation Task T1 / Next Step 2 (D5.1)
**Branch:** wave0.5-cli-spike
**CLI:** \`claude\` $(claude --version 2>/dev/null || echo unknown)
**Script:** \`spikes/t1-cli-chat/run-proto.sh\`

## What was tested

One real non-interactive conversation through the installed Claude Code CLI, using
exactly the scoped invocation PLAN.md specifies for V1 chat:

| Concern | Flag / choice |
|--------|----------------|
| Streaming | \`--output-format stream-json --verbose --include-partial-messages\` |
| System prompt | full \`--system-prompt\` **replace** (never \`--append-system-prompt\`) |
| Tools | disabled via \`--tools ""\` |
| Config isolation | \`--setting-sources ""\` + \`--strict-mcp-config\` + \`--disable-slash-commands\` |
| Auth | **no** \`--bare\` (subscription OAuth/keychain left intact) |
| Working dir | per-run cwd under \`spikes/t1-cli-chat/.workdir\` (session lookup is cwd-scoped) |

This is spawn-per-turn (\`-p\`), not the long-running persistent process planned for T4.
First-token numbers here therefore include cold-start (config load + session setup).

## Latency

| Metric | Value | Notes |
|--------|------:|-------|
| **First-token (\`ttft_ms\`)** | **${TTFT_MS:-n/a} ms** | CLI-reported; primary quality signal |
| Stream TTFT (\`ttft_stream_ms\`) | ${TTFT_STREAM_MS:-n/a} ms | |
| Time to request | ${TIME_TO_REQUEST_MS:-n/a} ms | Local work before the API call leaves |
| CLI duration | ${DURATION_MS:-n/a} ms | |
| API duration | ${DURATION_API_MS:-n/a} ms | |
| Wall-clock total | ${TOTAL_MS:-n/a} ms | Process start → exit |
| Notional cost | \$${TOTAL_COST_USD:-n/a} | Not billed on subscription; PLAN.md D5.4 |

**First-token latency judgment:** $(
  if [[ -z "${TTFT_MS}" ]]; then
    echo "unavailable — CLI did not report ttft_ms"
  else
    TTFT_INT=${TTFT_MS%.*}
    if (( TTFT_INT < 2000 )); then
      echo "Good for cold spawn (~${TTFT_MS}ms). Comparable to opening a fresh claude.ai turn; persistent process in T4 should only improve this."
    elif (( TTFT_INT < 5000 )); then
      echo "Acceptable for cold spawn (~${TTFT_MS}ms). Within multi-second cold-start budget PLAN.md D5.2 calls out; persistent process should cut this."
    elif (( TTFT_INT < 15000 )); then
      echo "Sluggish cold spawn (~${TTFT_MS}ms). Usable for a prototype but T4's persistent process is required before daily-driver use."
    else
      echo "BAD — ${TTFT_MS}ms first token. Do not ship this configuration."
    fi
  fi
)

## Reply (verbatim)

\`\`\`
$(cat "$REPLY")
\`\`\`

## Quality vs claude.ai browser tab

**Verdict: ${QUALITY_VERDICT}**

### Checklist

| Check | Result |
|-------|--------|
| Subscription auth worked (no API key, no \`--bare\`) | $([ -n "${SESSION_ID}" ] && echo "yes (session \`${SESSION_ID}\`)" || echo "NO — no session_id") |
| System-prompt replace took effect (general assistant, not coding-agent persona) | see QUALITY NOTES below |
| No tools invoked | $([ -z "${TOOLS_SEEN}" ] && echo "yes" || echo "NO: ${TOOLS_SEEN}") |
| Global MCP / CLAUDE.md contamination avoided | expected yes via setting-sources + strict-mcp + no slash commands; reply should not reference gbrain/gstack |
| Streaming partials present | $([ "${HAD_TEXT_DELTA}" = "true" ] && echo "yes (\`text_delta\` events observed)" || echo "no text_delta events — check stream format / CLI version") |
| First-token latency acceptable | $([ -n "${TTFT_MS}" ] && echo "${TTFT_MS} ms (${FIRST_TOKEN_SOURCE})" || echo "n/a") |
| Empty / error reply | $([ "${IS_ERROR}" = "True" ] || [ "${IS_ERROR}" = "true" ] && echo "ERROR" || echo "no") |

### QUALITY NOTES

_(Filled by the human/agent reviewing this run — replace if the auto defaults are wrong.)_

- **Tone / persona:** Expect a general personal assistant, not "Claude Code" / coding-agent
  framing. If the reply opens with repo/tooling assumptions, the system-prompt replace
  failed and this is a **FLAG**.
- **Content quality:** For the default half-day prompt, a good reply is 3 concrete
  options with short rationale, under ~200 words, no tool calls, no "I can edit files"
  offers. Match that against a claude.ai tab with a similar system-less personal question.
- **Auto flags:** $(
  if (( ${#QUALITY_FLAGS[@]} == 0 )); then
    echo "none"
  else
    printf '\n'
    for f in "${QUALITY_FLAGS[@]}"; do echo "  - $f"; done
  fi
)

### Action

${QUALITY_ACTION}

## Artifacts

- \`run-proto.sh\` — driver
- \`last-stream.jsonl\` — full stream-json stdout from the last run
- \`last-reply.txt\` — assembled assistant text
- \`last-timings.env\` — machine-readable metrics
- \`last-stderr.txt\` — drained stderr (PLAN.md: undrained stderr can deadlock the child)
- \`.workdir/\` — cwd used for the spawn (empty project stand-in)

## Re-run

\`\`\`bash
cd spikes/t1-cli-chat
./run-proto.sh
./write-findings.sh
# or with overrides:
# MODEL=sonnet EFFORT=low ./run-proto.sh "Your prompt here"
\`\`\`
EOF

echo "Wrote $OUT"
echo "Verdict: $QUALITY_VERDICT"
