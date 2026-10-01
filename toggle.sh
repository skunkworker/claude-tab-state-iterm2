#!/bin/bash
# Toggle the Claude Code iTerm2 tab-color signaling on/off.
#
#   toggle.sh           # flip current state
#   toggle.sh on        # force enable
#   toggle.sh off       # force disable
#   toggle.sh status    # print current state
#
# Disabling drops a flag file that tab-state.sh checks; while present, every
# hook call clears anything we painted instead of signaling.

set -u

FLAG="${HOME}/.claude/tab-state.disabled"
TAB_STATE="$(cd "$(dirname "$0")" && pwd)/tab-state.sh"
RESET_SEQ='\033]6;1;bg;*;default\007'

enable() {
  rm -f "$FLAG"
  echo "tab-state: ON"
}

disable() {
  mkdir -p "${HOME}/.claude" 2>/dev/null
  : >"$FLAG"
  echo "tab-state: OFF"
  # Clear every tab we have ever painted now, rather than whenever each next
  # sees a hook event — which, for an idle tab, may be never. With the flag
  # down, any call into tab-state.sh is exactly that drain.
  bash "$TAB_STATE" reset </dev/null
  # The current terminal may not be registered yet (no hook has fired in it).
  { printf '%b' "$RESET_SEQ" >/dev/tty; } 2>/dev/null || true
}

status() {
  if [ -e "$FLAG" ]; then echo "tab-state: OFF"; else echo "tab-state: ON"; fi
}

case "${1:-toggle}" in
  on) enable ;;
  off) disable ;;
  status) status ;;
  toggle)
    if [ -e "$FLAG" ]; then enable; else disable; fi
    ;;
  *)
    echo "usage: toggle.sh [on|off|toggle|status]" >&2
    exit 2
    ;;
esac
