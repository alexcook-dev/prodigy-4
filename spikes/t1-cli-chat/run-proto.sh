#!/usr/bin/env bash
# T1 throwaway: prototype one real conversation through the scoped Claude CLI pipe.
# Not part of the Xcode project. See PLAN.md Next Step 2 (D5.1) and Implementation Task T1.
#
# Invocation surface matches PLAN.md exactly:
#   - streaming: --output-format stream-json --verbose --include-partial-messages
#   - system prompt: full --system-prompt REPLACE (never --append-system-prompt)
#   - tools disabled: --tools ""
#   - no global config contamination: --setting-sources "" --strict-mcp-config --disable-slash-commands
#   - subscription auth: do NOT use --bare
#
# Usage:
#   ./run-proto.sh [prompt]
#   PROMPT="..." ./run-proto.sh
# Env:
#   MODEL=sonnet|opus|...   (optional --model)
#   EFFORT=low|medium|high  (optional --effort)
#   KEEP_RAW=1              keep the full stream-json log next to FINDINGS.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${SCRIPT_DIR}/.workdir"
RAW_LOG="${SCRIPT_DIR}/last-stream.jsonl"
TIMINGS="${SCRIPT_DIR}/last-timings.env"
REPLY_TXT="${SCRIPT_DIR}/last-reply.txt"

mkdir -p "$WORKDIR"

PROMPT="${1:-${PROMPT:-}}"
if [[ -z "$PROMPT" ]]; then
  # General-assistant prompt — not a coding task — so we can judge chat quality
  # against a claude.ai browser tab (PLAN.md T1 / D5.1).
  PROMPT='I have a half day free tomorrow afternoon and want to use it well without turning it into a project. Suggest three small, satisfying things I could do — mix practical and restorative — and for each give a one-sentence "why this works when you only have a few hours." Keep the whole reply under 200 words.'
fi

SYSTEM_PROMPT='You are a helpful, general-purpose personal assistant in a native Mac workspace app. You are NOT a coding agent: do not assume the user is programming, do not reach for tools or repositories, and do not offer to edit files. Be clear, warm, and concise. Prefer plain language over jargon. When the user asks for options, give a few concrete choices with brief rationale rather than a long lecture.'

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  echo "error: claude CLI not found on PATH (looked for: $CLAUDE_BIN)" >&2
  exit 127
fi

ARGS=(
  -p "$PROMPT"
  --output-format stream-json
  --verbose
  --include-partial-messages
  --system-prompt "$SYSTEM_PROMPT"
  --tools ""
  --setting-sources ""
  --strict-mcp-config
  --disable-slash-commands
)

if [[ -n "${MODEL:-}" ]]; then
  ARGS+=(--model "$MODEL")
fi
if [[ -n "${EFFORT:-}" ]]; then
  ARGS+=(--effort "$EFFORT")
fi

# Explicitly refuse --bare even if someone exports it into the environment by habit.
for a in "${ARGS[@]}"; do
  if [[ "$a" == "--bare" ]]; then
    echo "error: --bare is forbidden (breaks subscription auth; PLAN.md D5.1)" >&2
    exit 2
  fi
done

echo "=== T1 CLI chat prototype ==="
echo "cwd:      $WORKDIR"
echo "cli:      $(command -v "$CLAUDE_BIN") ($("$CLAUDE_BIN" --version 2>/dev/null || echo '?'))"
echo "flags:    -p --output-format stream-json --verbose --include-partial-messages"
echo "          --system-prompt <replace> --tools \"\" --setting-sources \"\""
echo "          --strict-mcp-config --disable-slash-commands"
echo "          (NO --bare)"
[[ -n "${MODEL:-}" ]] && echo "model:    $MODEL"
[[ -n "${EFFORT:-}" ]] && echo "effort:   $EFFORT"
echo "prompt:   ${PROMPT:0:120}$([ ${#PROMPT} -gt 120 ] && echo '…')"
echo

# Wall-clock from process start. first_token_ms is set when we see the first text_delta.
START_NS=$(python3 - <<'PY'
import time
print(time.time_ns())
PY
)

# Run CLI in the per-project-style cwd (session lookup is cwd-scoped per PLAN.md).
# stderr drained continuously via a separate file so a full stderr pipe can't deadlock.
STDERR_LOG="${SCRIPT_DIR}/last-stderr.txt"
set +e
(
  cd "$WORKDIR"
  # shellcheck disable=SC2086
  "$CLAUDE_BIN" "${ARGS[@]}"
) >"$RAW_LOG" 2>"$STDERR_LOG"
CLI_EXIT=$?
set -e

END_NS=$(python3 - <<'PY'
import time
print(time.time_ns())
PY
)

# Parse stream-json: first text_delta latency, full reply text, session metadata.
python3 - "$RAW_LOG" "$START_NS" "$END_NS" "$TIMINGS" "$REPLY_TXT" <<'PY'
import json, sys, pathlib

raw_path, start_ns_s, end_ns_s, timings_path, reply_path = sys.argv[1:6]
start_ns = int(start_ns_s)
end_ns = int(end_ns_s)

first_token_ns = None
session_id = None
model = None
result_text = None
result_meta = {}
streamed_parts = []
tools_seen = set()
event_types = []
api_retry_events = []
init_capabilities = None
had_text_delta = False

def ns_to_ms(ns):
    return round(ns / 1_000_000.0, 1)

for line_no, line in enumerate(pathlib.Path(raw_path).read_text().splitlines(), 1):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError as e:
        print(f"warn: line {line_no} not JSON: {e}", file=sys.stderr)
        continue

    t = obj.get("type")
    event_types.append(t)

    # system/init carries session_id + capabilities
    if t == "system":
        subtype = obj.get("subtype")
        if subtype == "init":
            session_id = obj.get("session_id") or session_id
            model = obj.get("model") or model
            init_capabilities = obj.get("capabilities") or obj.get("tools")
        if subtype == "api_retry":
            api_retry_events.append(obj)
        continue

    # Assistant stream events (partial messages)
    if t == "stream_event":
        ev = obj.get("event") or {}
        # content_block_delta / text_delta
        if ev.get("type") == "content_block_delta":
            delta = ev.get("delta") or {}
            if delta.get("type") == "text_delta":
                text = delta.get("text") or ""
                if text and first_token_ns is None:
                    # Approximate: wall clock when we finished reading this line is
                    # not available; use parse-time. Better: use file mtime after
                    # process. We recompute first_token from process start using a
                    # marker written... Actually the parent measures end after process
                    # exits. For first-token we need during-stream timestamps.
                    # We'll stamp below via a side channel — for now record that we
                    # saw a delta and use CLI's own ttft if present in result.
                    had_text_delta = True
                    streamed_parts.append(text)
        continue

    # Some CLI versions emit assistant message chunks differently
    if t == "assistant":
        msg = obj.get("message") or {}
        for block in msg.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text":
                streamed_parts.append(block.get("text") or "")
            if isinstance(block, dict) and block.get("type") == "tool_use":
                tools_seen.add(block.get("name") or "tool_use")
        continue

    if t == "result":
        result_text = obj.get("result")
        result_meta = {
            "is_error": obj.get("is_error"),
            "duration_ms": obj.get("duration_ms"),
            "duration_api_ms": obj.get("duration_api_ms"),
            "ttft_ms": obj.get("ttft_ms"),
            "ttft_stream_ms": obj.get("ttft_stream_ms"),
            "time_to_request_ms": obj.get("time_to_request_ms"),
            "total_cost_usd": obj.get("total_cost_usd"),
            "session_id": obj.get("session_id"),
            "num_turns": obj.get("num_turns"),
            "stop_reason": obj.get("stop_reason"),
            "usage": obj.get("usage"),
            "modelUsage": obj.get("modelUsage"),
        }
        session_id = result_meta.get("session_id") or session_id
        continue

# Prefer CLI-reported TTFT (more accurate than our wall-clock post-parse).
total_ms = ns_to_ms(end_ns - start_ns)
ttft_ms = result_meta.get("ttft_ms")
ttft_stream_ms = result_meta.get("ttft_stream_ms")
time_to_request_ms = result_meta.get("time_to_request_ms")

# Fallback first-token estimate: if CLI didn't report ttft, use total duration
# (bad estimate) and flag it.
first_token_source = "cli_ttft_ms"
if ttft_ms is None:
    first_token_source = "unavailable"
    ttft_ms = None

reply = result_text if result_text is not None else "".join(streamed_parts)
pathlib.Path(reply_path).write_text(reply or "")

# Write machine-readable timings for the shell wrapper / FINDINGS generator.
lines = [
    f"TOTAL_MS={total_ms}",
    f"TTFT_MS={ttft_ms if ttft_ms is not None else ''}",
    f"TTFT_STREAM_MS={ttft_stream_ms if ttft_stream_ms is not None else ''}",
    f"TIME_TO_REQUEST_MS={time_to_request_ms if time_to_request_ms is not None else ''}",
    f"FIRST_TOKEN_SOURCE={first_token_source}",
    f"SESSION_ID={session_id or ''}",
    f"MODEL={model or ''}",
    f"IS_ERROR={result_meta.get('is_error')}",
    f"DURATION_MS={result_meta.get('duration_ms') or ''}",
    f"DURATION_API_MS={result_meta.get('duration_api_ms') or ''}",
    f"TOTAL_COST_USD={result_meta.get('total_cost_usd') or ''}",
    f"NUM_TURNS={result_meta.get('num_turns') or ''}",
    f"STOP_REASON={result_meta.get('stop_reason') or ''}",
    f"HAD_TEXT_DELTA={str(had_text_delta).lower()}",
    f"TOOLS_SEEN={','.join(sorted(tools_seen))}",
    f"API_RETRY_COUNT={len(api_retry_events)}",
    f"EVENT_TYPES={','.join(t for t in event_types if t)}",
]
pathlib.Path(timings_path).write_text("\n".join(lines) + "\n")

print("--- stream parse ---")
print(f"session_id:         {session_id}")
print(f"model (init):       {model}")
print(f"had text_delta:     {had_text_delta}")
print(f"tools invoked:      {sorted(tools_seen) or '(none — good)'}")
print(f"api_retry events:   {len(api_retry_events)}")
print(f"first-token (ttft): {ttft_ms} ms  (source: {first_token_source})")
print(f"ttft_stream:        {ttft_stream_ms} ms")
print(f"time_to_request:    {time_to_request_ms} ms")
print(f"duration (cli):     {result_meta.get('duration_ms')} ms")
print(f"duration_api:       {result_meta.get('duration_api_ms')} ms")
print(f"wall total:         {total_ms} ms")
print(f"cost (notional):    ${result_meta.get('total_cost_usd')}")
print(f"stop_reason:        {result_meta.get('stop_reason')}")
print(f"is_error:           {result_meta.get('is_error')}")
if init_capabilities is not None:
    print(f"capabilities/tools: {init_capabilities}")
print()
print("--- assistant reply ---")
print(reply or "(empty)")
print("--- end reply ---")
PY

# shellcheck disable=SC1090
source "$TIMINGS"

echo
echo "cli exit: $CLI_EXIT"
if [[ -s "$STDERR_LOG" ]]; then
  echo "stderr ($(wc -l <"$STDERR_LOG" | tr -d ' ') lines) — first 20:"
  head -n 20 "$STDERR_LOG" | sed 's/^/  | /'
fi

if [[ "${KEEP_RAW:-0}" != "1" ]]; then
  # Keep timings + reply; drop the bulky stream log unless asked.
  : # leave RAW_LOG — useful for Wave 2 provider work; FINDINGS references it
fi

exit "$CLI_EXIT"
