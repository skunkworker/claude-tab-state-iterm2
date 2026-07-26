#!/bin/bash
# Toggle the Claude Code iTerm2 tab-color signaling on/off.
#
#   toggle.sh           # flip current state
#   toggle.sh on        # force enable
#   toggle.sh off       # force disable
#   toggle.sh status    # print current state
#
# Disabling drops a flag file that tab-state.sh checks; while present, every
# hook call just resets the tab to its default color instead of signaling.

set -u

FLAG="${HOME}/.claude/tab-state.disabled"
STATE_DIR="${HOME}/.claude/.tab-state"
TTY_REGISTRY="${STATE_DIR}/ttys"

# Clear every tab we have ever colored. Without this, an idle tab keeps its
# color until it happens to see another hook event, which may be never.
reset_registered_ttys() {
  local dev kept=""
  [ -e "$TTY_REGISTRY" ] || return 0
  while IFS= read -r dev; do
    [ -n "$dev" ] || continue
    # Drop ttys that are gone; keeping them would grow the file forever.
    [ -w "$dev" ] || continue
    printf '\033]6;1;bg;*;default\007' >"$dev" 2>/dev/null
    kept="${kept}${dev}"$'\n'
  done <"$TTY_REGISTRY"
  printf '%s' "$kept" >"$TTY_REGISTRY" 2>/dev/null
}

enable() {
  rm -f "$FLAG"
  echo "tab-state: ON"
}

disable() {
  mkdir -p "${HOME}/.claude" 2>/dev/null
  : >"$FLAG"
  echo "tab-state: OFF"
  reset_registered_ttys
  # The current terminal may not be registered yet (no hook has fired in it).
  { printf '\033]6;1;bg;*;default\007' >/dev/tty; } 2>/dev/null || true
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
