#!/bin/bash
# Install the iTerm2 tab-state signaling into ~/.claude.
#
#   install.sh              # symlink the worker + wire the hooks
#   install.sh --dry-run    # show what would change, touch nothing
#   install.sh --no-hooks   # symlink only, leave settings.json alone
#   install.sh --uninstall  # remove the symlink and the hook entries
#
# Idempotent: re-running replaces our own hook entries rather than stacking
# duplicates, and leaves every other hook in settings.json untouched.

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
LINK="${CLAUDE_DIR}/tab-state.sh"
SETTINGS="${CLAUDE_DIR}/settings.json"

DRY_RUN=0
DO_HOOKS=1
UNINSTALL=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-hooks) DO_HOOKS=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h | --help)
      cat <<'EOF'
usage: install.sh [--dry-run] [--no-hooks] [--uninstall]

  --dry-run     show what would change, touch nothing
  --no-hooks    symlink only, leave settings.json alone
  --uninstall   remove the symlink and our hook entries
EOF
      exit 0
      ;;
    *)
      echo "install.sh: unknown option '$arg'" >&2
      exit 2
      ;;
  esac
done

say() { printf '%s\n' "$*"; }
run() {
  if [ "$DRY_RUN" = 1 ]; then say "  would: $*"; else "$@"; fi
}

# --------------------------------------------------------------- the symlink

install_link() {
  mkdir -p "$CLAUDE_DIR"
  if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$ROOT/tab-state.sh" ]; then
    say "symlink: already correct ($LINK)"
    return 0
  fi
  # A plain file here is the old install style; it silently drifts from the
  # repo, so keep a copy aside and replace it with the link.
  if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    say "symlink: $LINK is a regular file, backing it up to ${LINK}.bak"
    run mv "$LINK" "${LINK}.bak"
  fi
  run ln -sfn "$ROOT/tab-state.sh" "$LINK"
  run chmod +x "$ROOT/tab-state.sh" "$ROOT/toggle.sh"
  say "symlink: $LINK -> $ROOT/tab-state.sh"
}

remove_link() {
  if [ -L "$LINK" ]; then
    run rm -f "$LINK"
    say "symlink: removed $LINK"
  else
    say "symlink: nothing to remove"
  fi
}

# ---------------------------------------------------------------- the hooks

# Merge in place with python3 (present on any machine with the Xcode CLT).
# The wiring spec lives here and nowhere else in this script; README.md
# documents the same table for anyone wiring it by hand.
merge_hooks() { # mode dry_run subagents_supported
  python3 - "$SETTINGS" "$1" "$2" "$3" <<'PY'
import json, os, re, shutil, sys

path, mode, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
min_version_ok = sys.argv[4] == "1"

# Follow a symlinked settings.json: os.replace below would otherwise swap the
# link itself for a regular file and detach it from whatever it pointed at.
path = os.path.realpath(path)

# (event, matcher, state). PreToolUse matters as much as PostToolUse: without
# it the tab stays yellow for the whole duration of a long tool call you just
# approved. The two Notification matchers split the real permission prompt from
# the idle nudge, which the script would otherwise have to tell apart by
# string-matching the payload.
SPEC = [
    ("UserPromptSubmit", None, "start"),
    ("PreToolUse", None, "green"),
    ("PostToolUse", None, "green"),
    ("Notification", "permission_prompt", "yellow"),
    ("Notification", "idle_prompt", "reset"),
    ("Stop", None, "reset"),
    ("SessionEnd", None, "session"),
    ("SessionStart", None, "session"),
    ("SubagentStart", None, "agent-start"),
    ("SubagentStop", None, "agent-stop"),
]

# Match only the exact commands this script generates (any state, so older
# wirings are recognised too). A substring test would also claim a wrapper
# that merely mentions the path, and delete it on uninstall.
OWNED = re.compile(
    r"^bash ~/\.claude/tab-state\.sh "
    r"(?:start|green|yellow|reset|session|agent-start|agent-stop)$"
)

def note(msg):
    print(("  would: " if dry else "  ") + msg)

data = {}
if os.path.exists(path):
    with open(path) as fh:
        text = fh.read().strip()
    try:
        data = json.loads(text) if text else {}
    except ValueError:
        print("  %s is not valid JSON — refusing to touch it" % path)
        sys.exit(1)

hooks = data.get("hooks") or {}

# Strip our previous entries so re-running never stacks duplicates. On install
# only touch events we are about to rewire: an event we do not ship (someone's
# hand-wired PreCompact, say) is theirs to keep. Uninstall clears all of them.
scope = [e for e, _, _ in SPEC] if mode == "install" else list(hooks)
for event in scope:
    groups = []
    for group in hooks.get(event, []):
        original = group.get("hooks", [])
        kept = [h for h in original if not OWNED.match(str(h.get("command", "")))]
        if len(kept) != len(original):
            note("unwired %s" % event)
        if kept:
            groups.append(dict(group, hooks=kept))
    if groups:
        hooks[event] = groups
    elif event in hooks:
        del hooks[event]

if mode == "install":
    wiring = SPEC
    if not min_version_ok:
        # SubagentStart arrived in 2.0.43. What an older Claude Code does with
        # an unknown hook event is untested here, so do not hand it one.
        wiring = [s for s in SPEC if not s[0].startswith("Subagent")]
        note("skipping SubagentStart/SubagentStop (needs Claude Code 2.0.43+)")
    for event, matcher, state in wiring:
        entry = {"type": "command", "command": "bash ~/.claude/tab-state.sh %s" % state}
        group = {"hooks": [entry]}
        if matcher:
            group = {"matcher": matcher, "hooks": [entry]}
        hooks.setdefault(event, []).append(group)
        note("wired %s%s -> %s" % (event, "/" + matcher if matcher else "", state))

if hooks:
    data["hooks"] = hooks
elif "hooks" in data:
    del data["hooks"]

if dry:
    sys.exit(0)

# One backup, not a rotation: the write below is atomic, so the copy only has
# to survive a bad merge, and this script is meant to be re-run freely.
if os.path.exists(path):
    shutil.copyfile(path, path + ".bak")
    print("  backup: %s.bak" % path)

# Write through a temp file so an interrupted install cannot truncate settings.
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    fh.write(json.dumps(data, indent=2) + "\n")
os.replace(tmp, path)
PY
}

# The blue subagent state needs SubagentStart (Claude Code 2.0.43). Assume a
# new enough version when `claude` is absent — someone installing this without
# the binary on PATH is wiring a machine they know better than we do.
version_supports_subagents() {
  local v major minor patch
  command -v claude >/dev/null 2>&1 || return 0
  v=$(claude --version 2>/dev/null) || return 0
  v=${v%% *}
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) return 0 ;;
  esac
  IFS=. read -r major minor patch <<<"$v"
  [ "$major" -gt 2 ] && return 0
  [ "$major" -lt 2 ] && return 1
  [ "$minor" -gt 0 ] && return 0
  [ "$patch" -ge 43 ]
}

install_hooks() {
  if ! command -v python3 >/dev/null 2>&1; then
    say "hooks: python3 not found — add the wiring block from README.md to"
    say "       $SETTINGS by hand, then run /hooks."
    return 1
  fi
  local subagents=0
  version_supports_subagents && subagents=1
  say "hooks:"
  merge_hooks "$1" "$DRY_RUN" "$subagents"
}

# ------------------------------------------------------------------- driver

[ "$DRY_RUN" = 1 ] && say "(dry run — nothing will be written)"

if [ "$UNINSTALL" = 1 ]; then
  remove_link
  [ "$DO_HOOKS" = 1 ] && install_hooks uninstall
  say ""
  say "Uninstalled. Run /hooks in Claude Code (or restart) to reload."
  exit 0
fi

install_link
if [ "$DO_HOOKS" = 1 ]; then
  install_hooks install || exit 1
fi

say ""
say "Done. Run /hooks in Claude Code (or restart) to load the new wiring."
say "Editing tab-state.sh needs no reload — it is read fresh on every call."
