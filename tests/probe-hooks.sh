#!/bin/bash
# Verify the Claude Code hook contract this project depends on, against the
# Claude Code actually installed on this machine.
#
#   tests/probe-hooks.sh          # run the probe
#   tests/probe-hooks.sh --keep   # keep the sandbox dir for inspection
#
# NOT part of tests/run.sh and not run in CI: this starts a real Claude Code
# session, so it needs the `claude` binary and spends API tokens. Run it by
# hand when upgrading Claude Code.
#
# Everything happens in a temp dir with its own --settings file. Your real
# ~/.claude is never read or written.
#
# What it checks, in order of how quietly each would break us:
#   1. SubagentStart / SubagentStop both fire.
#   2. Both carry agent_id, and the two AGREE. The blue "waiting for subagents"
#      state is one token file per agent_id, so if the ids ever stopped
#      matching, tokens would leak and the tab would stick blue forever.
#   3. tab-state.sh still extracts agent_id from the REAL payloads — the
#      captured ones, not a fixture. Payloads gain fields over time.
#   4. The events that drive the other colors still fire.
#
# It canNOT check the two Notification matchers: permission_prompt needs an
# interactive permission prompt, and idle_prompt fires ~60s into an interactive
# idle. Neither is reachable from `claude -p`. See the note it prints.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

for tool in claude python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "probe: $tool not found — cannot run" >&2
    exit 2
  }
done

SANDBOX=$(mktemp -d)
cleanup() {
  if [ "$KEEP" = 1 ]; then
    echo "sandbox kept at $SANDBOX"
  else
    rm -rf "$SANDBOX"
  fi
}
trap cleanup EXIT

LOG="$SANDBOX/events.log"
: >"$LOG"

# Flatten each payload onto one line so the log stays greppable. JSON escapes
# newlines inside strings, so nothing is lost.
cat >"$SANDBOX/probe.sh" <<EOF
#!/bin/bash
printf '%s ' "\$1" >>"$LOG"
tr -d '\n' >>"$LOG"
printf '\n' >>"$LOG"
exit 0
EOF
chmod +x "$SANDBOX/probe.sh"

python3 - "$SANDBOX/probe.sh" >"$SANDBOX/settings.json" <<'PY'
import json, sys
probe = sys.argv[1]
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "SubagentStart", "SubagentStop", "Stop", "SessionEnd"]
hooks = {e: [{"hooks": [{"type": "command",
                         "command": "bash %s %s" % (probe, e)}]}] for e in events}
# Wired so a future version that *does* deliver these headlessly shows up.
hooks["Notification"] = [
    {"matcher": m, "hooks": [{"type": "command",
                              "command": "bash %s NOTIF-%s" % (probe, m)}]}
    for m in ("permission_prompt", "idle_prompt")
]
print(json.dumps({"hooks": hooks}, indent=1))
PY

echo "probe: starting a real Claude Code session (this spends tokens)..."
(
  cd "$SANDBOX" || exit 1
  claude --settings ./settings.json --allowedTools Task --permission-mode acceptEdits \
    -p 'Use the Task tool exactly once with subagent_type general-purpose and the prompt "reply with the single word pong". Then reply with just that word.'
) >"$SANDBOX/session.out" 2>&1 || {
  echo "probe: the Claude Code session failed:" >&2
  tail -20 "$SANDBOX/session.out" >&2
  exit 2
}

echo
python3 - "$LOG" "$SANDBOX" "$ROOT/tab-state.sh" <<'PY'
import json, os, subprocess, sys, tempfile

log, sandbox, tab_state = sys.argv[1], sys.argv[2], sys.argv[3]

seen = {}
for line in open(log):
    line = line.strip()
    if not line or " " not in line:
        continue
    event, _, raw = line.partition(" ")
    try:
        seen.setdefault(event, []).append(json.loads(raw))
    except ValueError:
        seen.setdefault(event, []).append({})

failures = []

def check(ok, label, detail=""):
    print("  %s %s%s" % ("ok  " if ok else "FAIL", label, ("  — " + detail) if detail else ""))
    if not ok:
        failures.append(label)

print("events observed: %s" % (", ".join(sorted(seen)) or "(none)"))
print()

print("subagent contract")
start = (seen.get("SubagentStart") or [None])[0]
stop = (seen.get("SubagentStop") or [None])[0]
check(start is not None, "SubagentStart fires")
check(stop is not None, "SubagentStop fires")

sid = (start or {}).get("agent_id")
pid = (stop or {}).get("agent_id")
check(bool(sid), "SubagentStart carries agent_id", repr(sid))
check(bool(pid), "SubagentStop carries agent_id", repr(pid))
check(bool(sid) and sid == pid, "the two agent_ids agree",
      "blue would stick forever otherwise")

print()
print("other events driving the colors")
for event in ("SessionStart", "UserPromptSubmit", "PreToolUse",
              "PostToolUse", "Stop", "SessionEnd"):
    check(event in seen, "%s fires" % event)

# The point of this stage: our own parser, against the payload as shipped today
# rather than against a fixture written when the payload was smaller.
print()
print("tab-state.sh against the captured payloads")
if start and stop and sid and sid == pid:
    home = os.path.join(sandbox, "fakehome")
    os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
    dev = os.path.join(sandbox, "out")
    env = dict(os.environ, HOME=home, TAB_STATE_DEV=dev, TAB_STATE_FORCE="1")
    env.pop("TMUX", None)
    env.pop("STY", None)

    def run(state, payload):
        open(dev, "w").close()
        subprocess.run(["bash", tab_state, state], input=json.dumps(payload),
                       text=True, env=env, check=False)
        return open(dev).read()

    BLUE = "\033]6;1;bg;red;brightness;0\007\033]6;1;bg;green;brightness;150\007\033]6;1;bg;blue;brightness;200\007"
    GREEN = "\033]6;1;bg;red;brightness;0\007\033]6;1;bg;green;brightness;170\007\033]6;1;bg;blue;brightness;0\007"

    run("start", {})
    painted = run("agent-start", start)
    check(painted == BLUE, "agent-start paints blue on the real payload",
          "%d-byte payload, %d keys" % (len(json.dumps(start)), len(start)))

    state_dir = os.path.join(home, ".claude", ".tab-state")
    tokens = [f for f in os.listdir(state_dir) if f.startswith("agent-")]
    check(len(tokens) == 1 and sid.replace("/", "_") in tokens[0],
          "the token is keyed by the real agent_id", str(tokens))

    painted = run("agent-stop", stop)
    check(painted == GREEN, "agent-stop hands the tab back to green",
          "%d-byte payload, %d keys" % (len(json.dumps(stop)), len(stop)))
    tokens = [f for f in os.listdir(state_dir) if f.startswith("agent-")]
    check(not tokens, "no token leaked", str(tokens))
else:
    check(False, "cannot exercise tab-state.sh", "the subagent contract failed above")

print()
notif = [e for e in seen if e.startswith("NOTIF-")]
if notif:
    print("NOT COVERED: Notification matchers — unexpectedly saw %s" % notif)
else:
    print("NOT COVERED: the permission_prompt / idle_prompt Notification matchers.")
    print("  Neither is reachable from `claude -p`: one needs an interactive")
    print("  permission prompt, the other ~60s of interactive idle. Check them by")
    print("  eye — after install, a permission prompt should turn the tab yellow,")
    print("  and walking away for a minute should return it to the default.")

print()
if failures:
    print("%d check(s) failed: %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("hook contract intact.")
PY
