#!/usr/bin/env bash
# T4/T9 provider smoke (not part of the Xcode app). Exercises the same CLI
# surface ClaudeCLIProvider uses: persistent multi-turn stream-json, resume
# failure detection, D5.1 flags, and documents the LRU fallback rule.
#
# Usage: ./run-smoke.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${SCRIPT_DIR}/.workdir"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
SYSTEM='You are a concise assistant. Reply in very few words.'
COMMON=(
  --output-format stream-json
  --verbose
  --include-partial-messages
  --system-prompt "$SYSTEM"
  --tools ""
  --setting-sources ""
  --strict-mcp-config
  --disable-slash-commands
  --model haiku
  --effort low
)

# Refuse --bare
for a in "${COMMON[@]}"; do
  [[ "$a" == "--bare" ]] && { echo "FAIL: --bare present"; exit 2; }
done

echo "=== T4 smoke: persistent multi-turn stream-json ==="
python3 - <<'PY'
import json, subprocess, sys, os, threading, time

common = [
  "claude", "-p",
  "--input-format", "stream-json",
  "--output-format", "stream-json",
  "--verbose",
  "--include-partial-messages",
  "--system-prompt", "You are a concise assistant. Reply in very few words.",
  "--tools", "",
  "--setting-sources", "",
  "--strict-mcp-config",
  "--disable-slash-commands",
  "--model", "haiku",
  "--effort", "low",
]
# assert no --bare
assert "--bare" not in common

proc = subprocess.Popen(
    common,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    cwd=os.getcwd(),
    bufsize=1,
)

results = []
session_ids = []
text_deltas = []
tools_nonempty = False

def reader():
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = obj.get("type")
        if t == "system" and obj.get("subtype") == "init":
            session_ids.append(obj.get("session_id"))
            tools = obj.get("tools") or []
            if tools:
                global tools_nonempty
                tools_nonempty = True
            print(f"  init session={obj.get('session_id')} tools={tools} mcp={obj.get('mcp_servers')}")
        if t == "stream_event":
            ev = obj.get("event") or {}
            if ev.get("type") == "content_block_delta":
                d = ev.get("delta") or {}
                if d.get("type") == "text_delta" and d.get("text"):
                    text_deltas.append(d["text"])
        if t == "result":
            results.append(obj)
            print(f"  result[{len(results)}]: {obj.get('result')!r} is_error={obj.get('is_error')}")

th = threading.Thread(target=reader, daemon=True)
th.start()

def send(msg):
    payload = json.dumps({"type": "user", "message": {"role": "user", "content": msg}})
    proc.stdin.write(payload + "\n")
    proc.stdin.flush()

send("Say only: alpha")
for _ in range(80):
    if len(results) >= 1:
        break
    time.sleep(0.1)
assert len(results) >= 1, "no first result"
send("Say only: beta")
for _ in range(80):
    if len(results) >= 2:
        break
    time.sleep(0.1)
assert len(results) >= 2, "no second result (persistent multi-turn failed)"

proc.stdin.close()
proc.wait(timeout=10)

assert session_ids, "no session_id captured"
assert len(set(session_ids)) == 1, f"session_id changed across turns: {session_ids}"
assert text_deltas, "no text_delta events (streaming failed)"
assert not tools_nonempty, "tools were loaded — D5.1 isolation failed"
assert all(r.get("is_error") is False for r in results), "error result"
assert "--bare" not in common

print("PASS: persistent multi-turn + session_id + text_delta + tools empty")
print(f"  session_id={session_ids[0]}")
print(f"  deltas={len(text_deltas)} results={[r.get('result') for r in results]}")
PY

echo
echo "=== T4 smoke: resume-failure detection ==="
set +e
OUT=$("$CLAUDE_BIN" -p "hi" \
  --resume "00000000-0000-0000-0000-000000000000" \
  "${COMMON[@]}" 2>"$WORKDIR/resume-err.txt")
RC=$?
set -e
if grep -qi "No conversation found" "$WORKDIR/resume-err.txt"; then
  echo "PASS: resume failure detected on stderr (exit=$RC)"
else
  echo "WARN: expected 'No conversation found' on stderr; got:"
  head -5 "$WORKDIR/resume-err.txt"
  # Still OK if result is_error
  if echo "$OUT" | grep -q '"is_error":true'; then
    echo "PASS: resume failure via is_error result"
  else
    echo "FAIL: could not detect resume failure"
    exit 1
  fi
fi

echo
echo "=== T4 smoke: rehydrate prompt shape (unit) ==="
python3 - <<'PY'
# Mirrors ClaudeCLIProvider.rehydratePrompt
history = [
    ("user", "Hello"),
    ("assistant", "Hi there"),
]
user = "What next?"
preamble = (
    "The following is prior conversation history recovered after the previous session "
    "could not be resumed. Continue naturally from the latest user message; do not "
    "re-introduce yourself or summarize the history unless asked.\n"
)
parts = [preamble, "---", ""]
for role, content in history:
    label = "User" if role == "user" else "Assistant"
    parts.append(f"{label}: {content}")
    parts.append("")
parts.append(f"User: {user}")
prompt = "\n".join(parts)
assert "User: Hello" in prompt
assert "Assistant: Hi there" in prompt
assert prompt.endswith("User: What next?")
assert "could not be resumed" in prompt
print("PASS: rehydrate prompt embeds history + new user message")
PY

echo
echo "=== T9 smoke: LRU cap rule (unit) ==="
python3 - <<'PY'
MAX = 3
# Simulate: focused + 2 background keep persistent; 4th uses spawn-per-turn.
sessions = {}  # project_id -> "persistent"
lru = []

def touch(pid):
    if pid in lru:
        lru.remove(pid)
    lru.append(pid)

def should_use_persistent(pid):
    if pid in sessions:
        return True
    others = len([k for k in sessions if k != pid])
    return others < MAX

def obtain(pid):
    if should_use_persistent(pid):
        # evict if needed
        target = MAX - 1 if pid not in sessions else MAX
        while len(sessions) > target:
            victim = next(x for x in lru if x != pid and x in sessions)
            del sessions[victim]
            lru.remove(victim)
            print(f"  evicted {victim} (LRU)")
        sessions[pid] = "persistent"
        touch(pid)
        return "persistent"
    touch(pid)
    return "spawn-per-turn"

modes = []
for pid in ["A", "B", "C", "D"]:
    modes.append((pid, obtain(pid)))
print("  modes:", modes)
assert modes[0][1] == "persistent"
assert modes[1][1] == "persistent"
assert modes[2][1] == "persistent"
assert modes[3][1] == "spawn-per-turn", "4th Project must fall back to spawn-per-turn"
assert len(sessions) <= MAX
print("PASS: 4th concurrent Project falls back to spawn-per-turn; cap holds")
PY

echo
echo "=== ALL T4/T9 smokes passed ==="
