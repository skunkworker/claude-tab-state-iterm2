#!/bin/bash
# Test harness for tab-state.sh / toggle.sh.
#
# The scripts are driven through their env seams instead of a real terminal:
# TAB_STATE_DEV redirects the escapes to a file we can diff, TAB_STATE_FORCE
# skips iTerm2 detection, and HOME is a throwaway dir so the flag file, stop
# markers and tty registry never touch the real ~/.claude.
#
#   tests/run.sh          # run all
#   tests/run.sh green    # run tests whose name matches "green"

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAB_STATE="$ROOT/tab-state.sh"
TOGGLE="$ROOT/toggle.sh"
FILTER="${1:-}"

pass=0
fail=0
failed_names=""

ESC=$'\033'
BEL=$'\007'
GREEN="${ESC}]6;1;bg;red;brightness;0${BEL}${ESC}]6;1;bg;green;brightness;170${BEL}${ESC}]6;1;bg;blue;brightness;0${BEL}"
YELLOW="${ESC}]6;1;bg;red;brightness;235${BEL}${ESC}]6;1;bg;green;brightness;190${BEL}${ESC}]6;1;bg;blue;brightness;0${BEL}"
DEFAULT="${ESC}]6;1;bg;*;default${BEL}"

setup() {
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME/.claude"
  export TAB_STATE_DEV="$SANDBOX/out"
  export TAB_STATE_FORCE=1
  unset TMUX STY TAB_STATE_TMUX 2>/dev/null || true
  : >"$TAB_STATE_DEV"
}

teardown() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }

out() { cat "$TAB_STATE_DEV"; }

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

it() { # name -> skipped unless it matches $FILTER
  CURRENT="$1"
  case "$CURRENT" in
    *"$FILTER"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- arg handling

if it "rejects a missing argument"; then
  setup
  err=$("$TAB_STATE" 2>&1 >/dev/null)
  rc=$?
  check "$CURRENT: exit 1" "1" "$rc"
  case "$err" in
    usage:*) check "$CURRENT: prints usage" "yes" "yes" ;;
    *) check "$CURRENT: prints usage" "usage: ..." "$err" ;;
  esac
  teardown
fi

if it "rejects an unknown state"; then
  setup
  "$TAB_STATE" gren 2>/dev/null
  check "$CURRENT: exit 1" "1" "$?"
  check "$CURRENT: writes nothing" "" "$(out)"
  teardown
fi

# ------------------------------------------------------------------- happy path

if it "green paints the tab green"; then
  setup
  "$TAB_STATE" green
  check "$CURRENT" "$GREEN" "$(out)"
  teardown
fi

if it "start paints the tab green"; then
  setup
  "$TAB_STATE" start
  check "$CURRENT" "$GREEN" "$(out)"
  teardown
fi

if it "reset restores the default color"; then
  setup
  "$TAB_STATE" reset
  check "$CURRENT" "$DEFAULT" "$(out)"
  teardown
fi

# ------------------------------------------------------------ notification path

if it "yellow paints a real permission prompt"; then
  setup
  echo '{"message":"Claude needs your permission to use Bash"}' | "$TAB_STATE" yellow
  check "$CURRENT" "$YELLOW" "$(out)"
  teardown
fi

if it "yellow resets on the idle nudge"; then
  setup
  echo '{"message":"Claude is waiting for your input"}' | "$TAB_STATE" yellow
  check "$CURRENT" "$DEFAULT" "$(out)"
  teardown
fi

if it "yellow ignores the idle wording outside the message field"; then
  setup
  echo '{"cwd":"/tmp/waiting for your input","message":"Claude needs your permission to use Bash"}' |
    "$TAB_STATE" yellow
  check "$CURRENT" "$YELLOW" "$(out)"
  teardown
fi

if it "yellow parses the message without jq"; then
  setup
  stub="$SANDBOX/bin"
  mkdir -p "$stub"
  for c in sed grep printf date stat ps awk rm mkdir cat; do
    p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$stub/$c"
  done
  echo '{"message":"Claude is waiting for your input"}' |
    PATH="$stub" "$TAB_STATE" yellow
  check "$CURRENT" "$DEFAULT" "$(out)"
  teardown
fi

if it "yellow defaults to alerting on an unparseable payload"; then
  setup
  printf 'not json at all' | "$TAB_STATE" yellow
  check "$CURRENT" "$YELLOW" "$(out)"
  teardown
fi

if it "yellow does not hang on an open stdin"; then
  setup
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
  "$TAB_STATE" yellow <"$SANDBOX/stdin"
  elapsed=$((SECONDS - start))
  kill "$writer" 2>/dev/null
  wait "$writer" 2>/dev/null
  if [ "$elapsed" -lt 5 ]; then
    check "$CURRENT" "under 5s" "under 5s"
  else
    check "$CURRENT" "under 5s" "${elapsed}s"
  fi
  teardown
fi

# ------------------------------------------------------------ stop-marker race

if it "green is suppressed immediately after a reset"; then
  setup
  "$TAB_STATE" reset
  : >"$TAB_STATE_DEV"
  "$TAB_STATE" green
  check "$CURRENT" "" "$(out)"
  teardown
fi

if it "start clears the stop marker so the next turn paints"; then
  setup
  "$TAB_STATE" reset
  "$TAB_STATE" start
  : >"$TAB_STATE_DEV"
  "$TAB_STATE" green
  check "$CURRENT" "$GREEN" "$(out)"
  teardown
fi

if it "green resumes once the stop marker ages out"; then
  setup
  "$TAB_STATE" reset
  # Backdate the marker past the 2s suppression window.
  touch -t 202001010000 "$HOME/.claude/.tab-state/stopped-out"
  : >"$TAB_STATE_DEV"
  "$TAB_STATE" green
  check "$CURRENT" "$GREEN" "$(out)"
  teardown
fi

# --------------------------------------------------------------- disable flag

if it "the disable flag forces a reset for every state"; then
  setup
  : >"$HOME/.claude/tab-state.disabled"
  for s in start green reset; do
    : >"$TAB_STATE_DEV"
    "$TAB_STATE" "$s"
    check "$CURRENT ($s)" "$DEFAULT" "$(out)"
  done
  : >"$TAB_STATE_DEV"
  echo '{"message":"needs permission"}' | "$TAB_STATE" yellow
  check "$CURRENT (yellow)" "$DEFAULT" "$(out)"
  teardown
fi

# ------------------------------------------------------------- terminal guards

if it "stays silent outside iTerm2"; then
  setup
  unset TAB_STATE_FORCE
  LC_TERMINAL="" TERM_PROGRAM="Apple_Terminal" "$TAB_STATE" green
  check "$CURRENT" "" "$(out)"
  teardown
fi

if it "recognizes iTerm2 from LC_TERMINAL"; then
  setup
  unset TAB_STATE_FORCE
  LC_TERMINAL="iTerm2" TERM_PROGRAM="" "$TAB_STATE" green
  check "$CURRENT" "$GREEN" "$(out)"
  teardown
fi

if it "stays silent under tmux unless opted in"; then
  setup
  TMUX="/tmp/tmux-0/default,1,0" "$TAB_STATE" green
  check "$CURRENT" "" "$(out)"
  teardown
fi

if it "wraps escapes for tmux passthrough when opted in"; then
  setup
  TMUX="/tmp/tmux-0/default,1,0" TAB_STATE_TMUX=1 "$TAB_STATE" reset
  expected="${ESC}Ptmux;${ESC}${ESC}]6;1;bg;*;default${BEL}${ESC}\\"
  check "$CURRENT" "$expected" "$(out)"
  teardown
fi

# ---------------------------------------------------------------- tty registry

if it "registers the tty it paints"; then
  setup
  "$TAB_STATE" green
  check "$CURRENT" "$TAB_STATE_DEV" "$(cat "$HOME/.claude/.tab-state/ttys")"
  teardown
fi

if it "registers each tty only once"; then
  setup
  "$TAB_STATE" start
  "$TAB_STATE" start
  "$TAB_STATE" start
  check "$CURRENT" "1" "$(wc -l <"$HOME/.claude/.tab-state/ttys" | tr -d ' ')"
  teardown
fi

if it "does not register on reset"; then
  setup
  "$TAB_STATE" reset
  check "$CURRENT" "no registry" "$([ -e "$HOME/.claude/.tab-state/ttys" ] && echo registry || echo "no registry")"
  teardown
fi

# -------------------------------------------------------------------- toggle.sh

if it "toggle reports status"; then
  setup
  check "$CURRENT (on)" "tab-state: ON" "$("$TOGGLE" status)"
  : >"$HOME/.claude/tab-state.disabled"
  check "$CURRENT (off)" "tab-state: OFF" "$("$TOGGLE" status)"
  teardown
fi

if it "toggle flips both directions"; then
  setup
  check "$CURRENT (to off)" "tab-state: OFF" "$("$TOGGLE" 2>/dev/null)"
  check "$CURRENT (to on)" "tab-state: ON" "$("$TOGGLE" 2>/dev/null)"
  teardown
fi

if it "toggle off clears registered tabs"; then
  setup
  "$TAB_STATE" green
  : >"$TAB_STATE_DEV"
  "$TOGGLE" off >/dev/null 2>&1
  check "$CURRENT" "$DEFAULT" "$(out)"
  teardown
fi

if it "toggle off prunes dead ttys from the registry"; then
  setup
  "$TAB_STATE" green
  echo "$SANDBOX/gone" >>"$HOME/.claude/.tab-state/ttys"
  "$TOGGLE" off >/dev/null 2>&1
  check "$CURRENT" "$TAB_STATE_DEV" "$(cat "$HOME/.claude/.tab-state/ttys")"
  teardown
fi

if it "toggle rejects an unknown subcommand"; then
  setup
  "$TOGGLE" bogus >/dev/null 2>&1
  check "$CURRENT: exit 2" "2" "$?"
  teardown
fi

# ------------------------------------------------------------------------ result

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf 'failed:\n%s' "$failed_names"
  exit 1
fi
