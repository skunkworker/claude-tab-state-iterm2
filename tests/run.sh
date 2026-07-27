#!/bin/bash
# Test harness for tab-state.sh / toggle.sh / install.sh.
#
# The scripts are driven through their env seams instead of a real terminal:
# TAB_STATE_DEV redirects the escapes to a file we can diff, TAB_STATE_FORCE
# skips iTerm2 detection, and HOME is a throwaway dir so the flag file, stop
# markers and the tty registry never touch the real ~/.claude.
#
#   tests/run.sh          # run all
#   tests/run.sh green    # run tests whose name matches "green"

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAB_STATE="$ROOT/tab-state.sh"
TOGGLE="$ROOT/toggle.sh"
INSTALL="$ROOT/install.sh"
FILTER="${1:-}"

pass=0
fail=0
failed_names=""

ESC=$'\033'
BEL=$'\007'
GREEN="${ESC}]6;1;bg;red;brightness;0${BEL}${ESC}]6;1;bg;green;brightness;170${BEL}${ESC}]6;1;bg;blue;brightness;0${BEL}"
YELLOW="${ESC}]6;1;bg;red;brightness;235${BEL}${ESC}]6;1;bg;green;brightness;190${BEL}${ESC}]6;1;bg;blue;brightness;0${BEL}"
BLUE="${ESC}]6;1;bg;red;brightness;0${BEL}${ESC}]6;1;bg;green;brightness;150${BEL}${ESC}]6;1;bg;blue;brightness;200${BEL}"
DEFAULT="${ESC}]6;1;bg;*;default${BEL}"

setup() {
  teardown
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME/.claude"
  export TAB_STATE_DEV="$SANDBOX/out"
  export TAB_STATE_FORCE=1
  unset TMUX STY
  : >"$TAB_STATE_DEV"
  STATE_DIR="$HOME/.claude/.tab-state"
  REGISTRY="$STATE_DIR/tty-out"
  MARKER="$STATE_DIR/stopped-out"
  DISABLED="$HOME/.claude/tab-state.disabled"
  SETTINGS="$HOME/.claude/settings.json"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}
trap teardown EXIT

out() { cat "$TAB_STATE_DEV"; }
clear_out() { : >"$TAB_STATE_DEV"; }
exists() { if [ -e "$1" ]; then echo present; else echo absent; fi; }

# Render escapes readable so a mismatch is diagnosable.
show() { printf '%s' "$1" | sed -e "s/$ESC/<ESC>/g" -e "s/$BEL/<BEL>/g"; }

check() { # name expected actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    failed_names="${failed_names}    - $1"$'\n'
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' \
      "$1" "$(show "$2")" "$(show "$3")"
  fi
}

# Matching tests get a fresh sandbox; the last one is cleaned by the EXIT trap.
it() {
  CURRENT="$1"
  case "$CURRENT" in
    *"$FILTER"*)
      setup
      return 0
      ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- arg handling

if it "rejects a missing argument"; then
  err=$("$TAB_STATE" 2>&1 >/dev/null)
  check "$CURRENT: exit 1" "1" "$?"
  check "$CURRENT: prints usage" \
    "usage: tab-state.sh {start|green|yellow|reset|session|agent-start|agent-stop}" "$err"
fi

if it "rejects an unknown state"; then
  "$TAB_STATE" gren 2>/dev/null
  check "$CURRENT: exit 1" "1" "$?"
  check "$CURRENT: writes nothing" "" "$(out)"
fi

# ------------------------------------------------------------------- happy path

paints() { # state expected
  it "$1 paints the tab" || return 0
  "$TAB_STATE" "$1"
  check "$CURRENT" "$2" "$(out)"
}
paints green "$GREEN"
paints start "$GREEN"
paints reset "$DEFAULT"

if it "paints without writing to stderr"; then
  # A missing stop marker is the normal case, so the redirect that reads it
  # must not leak "No such file or directory" into the hook's stderr.
  check "$CURRENT (green)" "" "$("$TAB_STATE" green 2>&1 >/dev/null)"
  check "$CURRENT (start)" "" "$("$TAB_STATE" start 2>&1 >/dev/null)"
  check "$CURRENT (reset)" "" "$("$TAB_STATE" reset 2>&1 >/dev/null)"
fi

# ------------------------------------------------------------ notification path

# The permission_prompt / idle_prompt matchers do the splitting now, so yellow
# paints unconditionally and reads no payload at all. The idle nudge is wired
# to `reset` and is covered by the reset tests.
if it "yellow paints regardless of the payload"; then
  echo '{"message":"Claude is waiting for your input"}' | "$TAB_STATE" yellow
  check "$CURRENT (ignores stdin)" "$YELLOW" "$(out)"
  clear_out
  "$TAB_STATE" yellow </dev/null
  check "$CURRENT (no stdin)" "$YELLOW" "$(out)"
fi

if it "agent events do not hang on an open stdin"; then
  # A fifo held open by a slow writer. It must be a fifo rather than a pipeline:
  # bash waits for every member of a pipeline, so `sleep 6 | script` would time
  # the writer even after the script has already given up.
  mkfifo "$SANDBOX/stdin"
  (
    exec 3>"$SANDBOX/stdin"
    sleep 6
    exec 3>&-
  ) &
  writer=$!
  start=$SECONDS
  "$TAB_STATE" agent-start <"$SANDBOX/stdin"
  elapsed=$((SECONDS - start))
  kill "$writer" 2>/dev/null
  wait "$writer" 2>/dev/null
  if [ "$elapsed" -lt 5 ]; then
    check "$CURRENT" "under 5s" "under 5s"
  else
    check "$CURRENT" "under 5s" "${elapsed}s"
  fi
fi

# --------------------------------------------------------------- the turn latch

if it "green is suppressed while the turn is closed"; then
  "$TAB_STATE" reset
  clear_out
  "$TAB_STATE" green
  check "$CURRENT" "" "$(out)"
fi

if it "the latch holds well past a couple of seconds"; then
  # The old implementation used a 2s window; a late green must still lose.
  "$TAB_STATE" reset
  clear_out
  printf '%s\n' "$(($(date +%s) - 30))" >"$MARKER"
  "$TAB_STATE" green
  check "$CURRENT" "" "$(out)"
fi

if it "start reopens the turn so the next green paints"; then
  "$TAB_STATE" reset
  "$TAB_STATE" start
  clear_out
  "$TAB_STATE" green
  check "$CURRENT" "$GREEN" "$(out)"
fi

if it "a turn that never sends start self-heals"; then
  "$TAB_STATE" reset
  printf '%s\n' "$(($(date +%s) - 3600))" >"$MARKER"
  clear_out
  "$TAB_STATE" green
  check "$CURRENT" "$GREEN" "$(out)"
fi

# ------------------------------------------------------------- subagent colour

agent() { # agent-start|agent-stop id
  printf '{"agent_id":"%s","agent_type":"general-purpose"}' "$2" | "$TAB_STATE" "$1"
}

if it "agent-start paints the tab blue"; then
  "$TAB_STATE" start
  clear_out
  agent agent-start ag_one
  check "$CURRENT" "$BLUE" "$(out)"
fi

if it "green stays blue while a subagent is outstanding"; then
  "$TAB_STATE" start
  agent agent-start ag_one
  clear_out
  "$TAB_STATE" green
  check "$CURRENT" "$BLUE" "$(out)"
fi

if it "blue holds when one of two subagents finishes"; then
  "$TAB_STATE" start
  agent agent-start ag_one
  agent agent-start ag_two
  clear_out
  agent agent-stop ag_one
  check "$CURRENT (still blue)" "$BLUE" "$(out)"
  clear_out
  agent agent-stop ag_two
  check "$CURRENT (back to green)" "$GREEN" "$(out)"
fi

if it "a finished turn stays blue while subagents run"; then
  # Subagents outlive the turn that dispatched them.
  "$TAB_STATE" start
  agent agent-start ag_one
  clear_out
  "$TAB_STATE" reset
  check "$CURRENT" "$BLUE" "$(out)"
fi

if it "the last subagent of a closed turn restores the default"; then
  "$TAB_STATE" start
  agent agent-start ag_one
  "$TAB_STATE" reset
  clear_out
  agent agent-stop ag_one
  check "$CURRENT" "$DEFAULT" "$(out)"
fi

if it "session boundaries forget outstanding subagents"; then
  "$TAB_STATE" start
  agent agent-start ag_one
  agent agent-start ag_two
  clear_out
  "$TAB_STATE" session
  check "$CURRENT (default)" "$DEFAULT" "$(out)"
  check "$CURRENT (drained)" "0" "$(find "$STATE_DIR" -name 'agent-*' | wc -l | tr -d ' ')"
fi

if it "agent events without an agent_id are ignored"; then
  "$TAB_STATE" start
  clear_out
  echo '{"session_id":"abc"}' | "$TAB_STATE" agent-start
  check "$CURRENT (no paint)" "" "$(out)"
  check "$CURRENT (no token)" "0" "$(find "$STATE_DIR" -name 'agent-*' | wc -l | tr -d ' ')"
fi

if it "stale subagent tokens are swept"; then
  "$TAB_STATE" start
  agent agent-start ag_stuck
  # A SubagentStop that never arrived must not strand the tab blue forever.
  printf '%s\n' "$(($(date +%s) - 100000))" >"$STATE_DIR/agent-out-ag_stuck"
  clear_out
  agent agent-start ag_live
  agent agent-stop ag_live
  check "$CURRENT (swept)" "$GREEN" "$(out)"
fi

if it "an agent_id cannot escape the state directory"; then
  "$TAB_STATE" start
  agent agent-start '../../../../tmp/pwned'
  check "$CURRENT" "absent" "$(exists /tmp/pwned)"
  check "$CURRENT (contained)" "1" "$(find "$STATE_DIR" -name 'agent-*' | wc -l | tr -d ' ')"
fi

# --------------------------------------------------------------- disable flag

if it "the disable flag clears painted tabs and drains the registry"; then
  "$TAB_STATE" green
  : >"$DISABLED"
  clear_out
  "$TAB_STATE" green
  check "$CURRENT (cleared)" "$DEFAULT" "$(out)"
  check "$CURRENT (drained)" "absent" "$(exists "$REGISTRY")"
fi

if it "disabling forgets outstanding subagents"; then
  # While off, the SubagentStop that would clear a token never reaches us, so
  # keeping tokens would strand the tab blue on re-enable.
  "$TAB_STATE" start
  agent agent-start ag_one
  : >"$DISABLED"
  "$TAB_STATE" green
  check "$CURRENT (drained)" "0" "$(find "$STATE_DIR" -name 'agent-*' | wc -l | tr -d ' ')"
  rm -f "$DISABLED"
  "$TAB_STATE" start
  clear_out
  "$TAB_STATE" green
  check "$CURRENT (green after re-enable)" "$GREEN" "$(out)"
fi

if it "toggle off forgets outstanding subagents"; then
  "$TAB_STATE" start
  agent agent-start ag_one
  "$TOGGLE" off >/dev/null 2>&1
  check "$CURRENT (drained)" "0" "$(find "$STATE_DIR" -name 'agent-*' | wc -l | tr -d ' ')"
  "$TOGGLE" on >/dev/null 2>&1
  "$TAB_STATE" start
  clear_out
  "$TAB_STATE" green
  check "$CURRENT (green after re-enable)" "$GREEN" "$(out)"
fi

if it "session reaps records for ttys that are gone"; then
  "$TAB_STATE" green
  echo "$SANDBOX/vanished" >"$STATE_DIR/tty-vanished"
  : >"$STATE_DIR/stopped-vanished"
  "$TAB_STATE" session
  check "$CURRENT (dead tty gone)" "absent" "$(exists "$STATE_DIR/tty-vanished")"
  check "$CURRENT (its marker gone)" "absent" "$(exists "$STATE_DIR/stopped-vanished")"
  check "$CURRENT (live tty kept)" "present" "$(exists "$REGISTRY")"
fi

if it "the disable flag stays silent once nothing is painted"; then
  : >"$DISABLED"
  "$TAB_STATE" green
  check "$CURRENT" "" "$(out)"
fi

# ------------------------------------------------------------- terminal guards

if it "stays silent outside iTerm2"; then
  unset TAB_STATE_FORCE
  LC_TERMINAL="" TERM_PROGRAM="Apple_Terminal" "$TAB_STATE" green
  check "$CURRENT" "" "$(out)"
fi

if it "recognizes iTerm2 from LC_TERMINAL"; then
  unset TAB_STATE_FORCE
  LC_TERMINAL="iTerm2" TERM_PROGRAM="" "$TAB_STATE" green
  check "$CURRENT" "$GREEN" "$(out)"
fi

if it "stays silent under tmux"; then
  TMUX="/tmp/tmux-0/default,1,0" "$TAB_STATE" green
  check "$CURRENT" "" "$(out)"
fi

if it "stays silent under screen"; then
  STY="1234.pts-0.host" "$TAB_STATE" green
  check "$CURRENT" "" "$(out)"
fi

# ---------------------------------------------------------------- tty registry

if it "registers the tty it paints"; then
  "$TAB_STATE" green
  check "$CURRENT" "$TAB_STATE_DEV" "$(cat "$REGISTRY")"
fi

if it "registering is idempotent"; then
  "$TAB_STATE" start
  "$TAB_STATE" green
  "$TAB_STATE" green
  check "$CURRENT" "1" "$(wc -l <"$REGISTRY" | tr -d ' ')"
fi

if it "does not register on reset"; then
  "$TAB_STATE" reset
  check "$CURRENT" "absent" "$(exists "$REGISTRY")"
fi

# -------------------------------------------------------------------- toggle.sh

if it "toggle reports status"; then
  check "$CURRENT (on)" "tab-state: ON" "$("$TOGGLE" status)"
  : >"$DISABLED"
  check "$CURRENT (off)" "tab-state: OFF" "$("$TOGGLE" status)"
fi

if it "toggle flips both directions"; then
  check "$CURRENT (to off)" "tab-state: OFF" "$("$TOGGLE" 2>/dev/null)"
  check "$CURRENT (to on)" "tab-state: ON" "$("$TOGGLE" 2>/dev/null)"
fi

if it "toggle off clears registered tabs"; then
  "$TAB_STATE" green
  clear_out
  "$TOGGLE" off >/dev/null 2>&1
  check "$CURRENT" "$DEFAULT" "$(out)"
fi

if it "toggle off prunes dead ttys from the registry"; then
  "$TAB_STATE" green
  echo "$SANDBOX/gone" >"$STATE_DIR/tty-gone"
  "$TOGGLE" off >/dev/null 2>&1
  check "$CURRENT (dead dropped)" "absent" "$(exists "$STATE_DIR/tty-gone")"
  check "$CURRENT (live kept)" "present" "$(exists "$REGISTRY")"
fi

if it "toggle rejects an unknown subcommand"; then
  "$TOGGLE" bogus >/dev/null 2>&1
  check "$CURRENT: exit 2" "2" "$?"
fi

# -------------------------------------------------------------------- install.sh

# settings.json with an unrelated hook plus the old-style wiring, so we can
# assert the merge is surgical.
seed_settings() {
  cat >"$SETTINGS" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [{"matcher":"Bash","hooks":[{"type":"command","command":"unrelated-tool --hook"}]}],
    "UserPromptSubmit": [{"hooks":[{"type":"command","command":"bash ~/.claude/tab-state.sh green"}]}],
    "Stop": [{"hooks":[{"type":"command","command":"bash ~/.claude/tab-state.sh reset"}]}]
  }
}
JSON
}

count_hooks() { # substring -> how many hook commands contain it
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for gs in d.get("hooks",{}).values() for g in gs
          for h in g["hooks"] if sys.argv[2] in h["command"]))' "$SETTINGS" "$1"
}

if it "install wires every event"; then
  seed_settings
  "$INSTALL" >/dev/null 2>&1
  check "$CURRENT" "10" "$(count_hooks tab-state.sh)"
fi

if it "install wires both Notification matchers"; then
  seed_settings
  "$INSTALL" >/dev/null 2>&1
  check "$CURRENT" "idle_prompt=reset permission_prompt=yellow" \
    "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
out=[]
for g in d["hooks"]["Notification"]:
    state=g["hooks"][0]["command"].rsplit(" ",1)[1]
    out.append("%s=%s" % (g.get("matcher","-"), state))
print(" ".join(sorted(out)))' "$SETTINGS")"
fi

if it "install wires the subagent events"; then
  seed_settings
  "$INSTALL" >/dev/null 2>&1
  check "$CURRENT" "agent-start agent-stop" \
    "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(d["hooks"][e][0]["hooks"][0]["command"].rsplit(" ",1)[1]
                for e in ("SubagentStart","SubagentStop")))' "$SETTINGS")"
fi

if it "install preserves unrelated settings and hooks"; then
  seed_settings
  "$INSTALL" >/dev/null 2>&1
  check "$CURRENT (model)" "opus" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["model"])' "$SETTINGS")"
  check "$CURRENT (foreign hook)" "1" "$(count_hooks unrelated-tool)"
fi

if it "install leaves hand-wired events it does not ship"; then
  seed_settings
  python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["hooks"]["PreCompact"] = [{"hooks": [
    {"type": "command", "command": "bash ~/.claude/tab-state.sh reset"}]}]
json.dump(d, open(p, "w"))
PY
  "$INSTALL" >/dev/null 2>&1
  check "$CURRENT" "1" \
    "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["hooks"].get("PreCompact",[])))' "$SETTINGS")"
fi

if it "install does not claim a wrapper that merely mentions the path"; then
  cat >"$SETTINGS" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-wrapper.sh --then tab-state.sh reset"}]}]}}
JSON
  "$INSTALL" >/dev/null 2>&1
  check "$CURRENT" "1" "$(count_hooks my-wrapper.sh)"
fi

if it "install is idempotent"; then
  seed_settings
  "$INSTALL" >/dev/null 2>&1
  "$INSTALL" >/dev/null 2>&1
  "$INSTALL" >/dev/null 2>&1
  check "$CURRENT (ours)" "10" "$(count_hooks tab-state.sh)"
  check "$CURRENT (foreign)" "1" "$(count_hooks unrelated-tool)"
  check "$CURRENT (one backup)" "1" "$(find "$HOME/.claude" -name 'settings.json.bak*' | wc -l | tr -d ' ')"
fi

if it "install --dry-run writes nothing"; then
  seed_settings
  before=$(cat "$SETTINGS")
  "$INSTALL" --dry-run >/dev/null 2>&1
  check "$CURRENT (settings)" "$before" "$(cat "$SETTINGS")"
  check "$CURRENT (symlink)" "absent" "$(exists "$HOME/.claude/tab-state.sh")"
fi

if it "install replaces a drifted regular-file copy with a symlink"; then
  cp "$TAB_STATE" "$HOME/.claude/tab-state.sh"
  "$INSTALL" --no-hooks >/dev/null 2>&1
  check "$CURRENT (link)" "$TAB_STATE" "$(readlink "$HOME/.claude/tab-state.sh")"
  check "$CURRENT (backup)" "present" "$(exists "$HOME/.claude/tab-state.sh.bak")"
fi

if it "install backs settings up before rewriting"; then
  seed_settings
  before=$(cat "$SETTINGS")
  "$INSTALL" >/dev/null 2>&1
  check "$CURRENT" "$before" "$(cat "$SETTINGS.bak")"
fi

if it "install refuses to touch malformed settings"; then
  echo '{ broken' >"$SETTINGS"
  "$INSTALL" >/dev/null 2>&1
  check "$CURRENT (exit 1)" "1" "$?"
  check "$CURRENT (untouched)" "{ broken" "$(cat "$SETTINGS")"
fi

if it "uninstall removes only our entries"; then
  seed_settings
  "$INSTALL" >/dev/null 2>&1
  "$INSTALL" --uninstall >/dev/null 2>&1
  check "$CURRENT (ours)" "0" "$(count_hooks tab-state.sh)"
  check "$CURRENT (foreign)" "1" "$(count_hooks unrelated-tool)"
  check "$CURRENT (symlink)" "absent" "$(exists "$HOME/.claude/tab-state.sh")"
fi

# A dir of symlinks to the tools install.sh needs, minus the ones named. Lets a
# test take a single binary away without breaking the rest of the script.
stub_path_without() { # tool...
  local keep drop=" $* " bin="$SANDBOX/stubbin" p
  mkdir -p "$bin"
  for keep in mkdir ln chmod readlink rm mv cat python3 claude; do
    case "$drop" in *" $keep "*) continue ;; esac
    p=$(command -v "$keep" 2>/dev/null) && ln -sf "$p" "$bin/$keep"
  done
  printf '%s' "$bin"
}

if it "install without python3 explains itself and changes nothing"; then
  seed_settings
  before=$(cat "$SETTINGS")
  PATH="$(stub_path_without python3)" "$INSTALL" >"$SANDBOX/msg" 2>&1
  check "$CURRENT (exit 1)" "1" "$?"
  check "$CURRENT (untouched)" "$before" "$(cat "$SETTINGS")"
  check "$CURRENT (points at README)" "yes" \
    "$(grep -qi 'README' "$SANDBOX/msg" && echo yes || echo no)"
fi

fake_claude() { # version -> a PATH with that `claude` in front
  local bin="$SANDBOX/fakebin"
  mkdir -p "$bin"
  printf '#!/bin/bash\necho "%s (Claude Code)"\n' "$1" >"$bin/claude"
  chmod +x "$bin/claude"
  printf '%s:%s' "$bin" "$PATH"
}

if it "install skips the subagent events on Claude Code older than 2.0.43"; then
  seed_settings
  PATH="$(fake_claude 2.0.42)" "$INSTALL" >/dev/null 2>&1
  check "$CURRENT (skipped)" "0" "$(count_hooks agent-start)"
  check "$CURRENT (rest wired)" "8" "$(count_hooks tab-state.sh)"
fi

if it "install wires the subagent events on 2.0.43 and newer"; then
  seed_settings
  PATH="$(fake_claude 2.0.43)" "$INSTALL" >/dev/null 2>&1
  check "$CURRENT (2.0.43)" "1" "$(count_hooks agent-start)"
  seed_settings
  PATH="$(fake_claude 3.1.0)" "$INSTALL" >/dev/null 2>&1
  check "$CURRENT (3.1.0)" "1" "$(count_hooks agent-start)"
fi

if it "install follows a symlinked settings.json"; then
  real="$SANDBOX/real-settings.json"
  seed_settings
  mv "$SETTINGS" "$real"
  ln -s "$real" "$SETTINGS"
  "$INSTALL" >/dev/null 2>&1
  check "$CURRENT (still a link)" "$real" "$(readlink "$SETTINGS")"
  check "$CURRENT (target rewritten)" "10" \
    "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for gs in d.get("hooks",{}).values() for g in gs
          for h in g["hooks"] if "tab-state.sh" in h["command"]))' "$real")"
fi

if it "install rejects an unknown option"; then
  "$INSTALL" --nope >/dev/null 2>&1
  check "$CURRENT: exit 2" "2" "$?"
fi

# ------------------------------------------------------------------------ result

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf 'failed:\n%s' "$failed_names"
  exit 1
fi
