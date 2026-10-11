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
# Everything happens in a temp dir with its own --settings file. That file is
# loaded *on top of* your ~/.claude settings, not instead of them, so your own
# hooks — tab-state.sh included — fire in the probe session too. Your user
# settings stay loaded on purpose: their `env` may carry the API setup the
# session needs. Run from a terminal, the probe may recolor that tab; run from
# inside Claude Code, the nested session has no tty and tab-state.sh stays out.
#
# What it checks, in order of how quietly each would break us:
#   1. SubagentStart / SubagentStop both fire.
#   2. Both carry agent_id, and the two AGREE. The blue "waiting for subagents"
#      state is one token file per agent_id, so if the ids ever stopped
#      matching, tokens would leak and the tab would stick blue forever.
#   3. tab-state.sh still extracts agent_id from the REAL payloads — the
#      captured ones, not a fixture. Payloads gain fields over time.
#   4. The events that drive the other colors still fire.
#   5. Slate: CronCreate's real payload carries `recurring` and returns the job
#      `id` that CronDelete then takes, and tab-state.sh's `schedule` turns the
#      pair into a token and back. Tokens are named by that id.
#   6. Magenta: a background shell is a child of `claude` with
#      `shell-snapshots` on its command line, which is all the script looks for.
#
# It canNOT check, from `claude -p`: the Notification matchers (they need an
# interactive prompt or ~60s of interactive idle), StopFailure (it needs a real
# API error), ScheduleWakeup (only a /loop has it), or whether a turn Claude
# Code starts by itself sends UserPromptSubmit. See the notes it prints.

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

EVENTS="$SANDBOX/events"
mkdir -p "$EVENTS"

# One file per hook call, named after its event. Hooks run in parallel — a
# background subagent's SubagentStart lands with the Agent tool's PostToolUse —
# and appends to one shared log interleave mid-line.
#
# After each PostToolUse it also records how many background shells the
# session has, counted the way tab-state.sh counts them. The hook may run under
# a `sh -c`, so it asks both its parent and its grandparent.
cat >"$SANDBOX/probe.sh" <<EOF
#!/bin/bash
cat >"\$(mktemp "$EVENTS/\$1.XXXXXX")"
if [ "\$1" = PostToolUse ]; then
  n=0
  for p in \$PPID \$(ps -o ppid= -p \$PPID); do
    n=\$((n + \$(pgrep -P "\$p" -f shell-snapshots 2>/dev/null | wc -l)))
  done
  echo "\$n" >"\$(mktemp "$EVENTS/SHELLS.XXXXXX")"
fi
exit 0
EOF
chmod +x "$SANDBOX/probe.sh"

python3 - "$SANDBOX/probe.sh" >"$SANDBOX/settings.json" <<'PY'
import json, sys
probe = sys.argv[1]
events = ["SessionStart", "UserPromptSubmit", "PostToolUse",
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
  claude --settings ./settings.json --permission-mode acceptEdits \
    --allowedTools 'Task,Bash(sleep 20),CronCreate,CronDelete,ToolSearch' \
    -p 'Do these steps in order, one tool call each. 1) Use the Task tool exactly once with subagent_type general-purpose and the prompt "reply with the single word pong". 2) Use the Bash tool with run_in_background set to true to run: sleep 20 3) Use CronCreate with cron "17 3 1 1 *", prompt "probe", and recurring false. 4) Use CronDelete with the id that CronCreate returned. Then reply with just the word pong.'
) >"$SANDBOX/session.out" 2>&1 || {
  echo "probe: the Claude Code session failed:" >&2
  tail -20 "$SANDBOX/session.out" >&2
  exit 2
}

echo
python3 - "$EVENTS" "$SANDBOX" "$ROOT/tab-state.sh" <<'PY'
import json, os, subprocess, sys, tempfile

events, sandbox, tab_state = sys.argv[1], sys.argv[2], sys.argv[3]

# In the order they were written, which is the order the hooks ran.
seen = {}
paths = [os.path.join(events, f) for f in os.listdir(events)]
for path in sorted(paths, key=os.path.getmtime):
    event = os.path.basename(path).split(".")[0]
    try:
        seen.setdefault(event, []).append(json.load(open(path)))
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
for event in ("SessionStart", "UserPromptSubmit", "PostToolUse", "Stop",
              "SessionEnd"):
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

# Slate. Real payloads only: a fixture would only prove the script agrees with
# whoever wrote the fixture.
print()
print("scheduling contract (slate)")
posts = seen.get("PostToolUse", [])
create = next((e for e in posts if e.get("tool_name") == "CronCreate"), None)
delete = next((e for e in posts if e.get("tool_name") == "CronDelete"), None)
check(create is not None, "PostToolUse fires for CronCreate")
check(delete is not None, "PostToolUse fires for CronDelete")
resp = (create or {}).get("tool_response")
job = resp.get("id") if isinstance(resp, dict) else None
check(bool(job), "CronCreate's tool_response carries the job id", repr(resp)[:120])
check((create or {}).get("tool_input", {}).get("recurring") is False,
      "CronCreate's tool_input carries recurring:false")
check(bool(job) and (delete or {}).get("tool_input", {}).get("id") == job,
      "CronDelete takes the same id", "a delete would miss its token otherwise")
if create and delete and job:
    home = os.path.join(sandbox, "schedhome")
    os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
    dev = os.path.join(sandbox, "schedout")
    open(dev, "w").close()
    env = dict(os.environ, HOME=home, TAB_STATE_DEV=dev, TAB_STATE_FORCE="1")
    env.pop("TMUX", None)
    env.pop("STY", None)
    wake = os.path.join(home, ".claude", ".tab-state", "wake-schedout-at-" + job)
    for payload, want, label in ((create, True, "schedule records the real CronCreate"),
                                 (delete, False, "schedule drops it on the real CronDelete")):
        subprocess.run(["bash", tab_state, "schedule"], input=json.dumps(payload),
                       text=True, env=env, check=False)
        check(os.path.exists(wake) == want, label, os.path.basename(wake))

print()
print("background shells (magenta)")
shells = [n for n in seen.get("SHELLS", []) if isinstance(n, int)]
check(any(n >= 1 for n in shells), "a background shell carries shell-snapshots",
      "counts seen: %s" % shells)

# Orange, slate and the after-turn yellow all rely on the turn Claude Code
# starts by itself — here, to report the background agent and shell — opening
# with UserPromptSubmit, like a prompt you type.
print()
print("turns Claude Code starts by itself")
woken = [e for e in seen.get("UserPromptSubmit", [])
         if "<task-notification>" in str(e.get("prompt", ""))]
check(bool(woken), "a task notification's turn sends UserPromptSubmit",
      "%d such turn(s)" % len(woken))

print()
print("NOT COVERED from `claude -p`, each checked by other means:")
print("  StopFailure `error` values: read from the Claude Code binary.")
print("  ScheduleWakeup `stop` / `delaySeconds`: from its tool schema.")

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
