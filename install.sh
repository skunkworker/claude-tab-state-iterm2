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

# The hook wiring, as event:state pairs. PreToolUse matters as much as
# PostToolUse: without it the tab stays yellow for the whole duration of a
# long tool call you just approved.
HOOK_SPEC="UserPromptSubmit:start
PreToolUse:green
PostToolUse:green
Notification:yellow
Stop:reset
SessionEnd:reset
SessionStart:reset"

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

json_block() {
  local event state
  say '"hooks": {'
  while IFS=: read -r event state; do
    say "  \"$event\": [{ \"hooks\": [{ \"type\": \"command\", \"command\": \"bash ~/.claude/tab-state.sh $state\" }] }],"
  done <<<"$HOOK_SPEC"
  say '}'
}

# Merge in place with python3 (present on any machine with the Xcode CLT).
# Reads the spec on argv so the wiring lives in exactly one place.
merge_hooks() {
  local mode="$1"
  python3 - "$SETTINGS" "$mode" "$HOOK_SPEC" <<'PY'
import json, os, sys

path, mode, spec = sys.argv[1], sys.argv[2], sys.argv[3]
pairs = [line.split(":", 1) for line in spec.splitlines() if line.strip()]

data = {}
if os.path.exists(path):
    with open(path) as fh:
        text = fh.read().strip()
    data = json.loads(text) if text else {}

hooks = data.get("hooks") or {}
changed = []

def ours(entry):
    return "tab-state.sh" in str(entry.get("command", ""))

# Strip our previous entries first so re-running never stacks duplicates,
# then drop any group we emptied. Everything else is left exactly as-is.
for event in list(hooks):
    groups = []
    for group in hooks[event]:
        kept = [h for h in group.get("hooks", []) if not ours(h)]
        if len(kept) != len(group.get("hooks", [])):
            changed.append("unwired %s" % event)
        if kept:
            group = dict(group, hooks=kept)
            groups.append(group)
        elif not group.get("hooks"):
            groups.append(group)
    if groups:
        hooks[event] = groups
    else:
        del hooks[event]

if mode == "install":
    for event, state in pairs:
        entry = {"type": "command", "command": "bash ~/.claude/tab-state.sh %s" % state}
        hooks.setdefault(event, []).append({"hooks": [entry]})
        changed.append("wired %s -> %s" % (event, state))

if hooks:
    data["hooks"] = hooks
elif "hooks" in data:
    del data["hooks"]

rendered = json.dumps(data, indent=2) + "\n"
json.loads(rendered)  # never write something we cannot read back

if os.environ.get("DRY_RUN") == "1":
    for c in changed:
        print("  would: %s" % c)
    sys.exit(0)

if os.path.exists(path):
    backup = path + ".bak"
    n = 0
    while os.path.exists(backup):
        n += 1
        backup = "%s.bak.%d" % (path, n)
    with open(path) as src, open(backup, "w") as dst:
        dst.write(src.read())
    print("  backup: %s" % backup)

# Write through a temp file so an interrupted install cannot truncate settings.
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    fh.write(rendered)
os.replace(tmp, path)
for c in changed:
    print("  %s" % c)
PY
}

install_hooks() {
  if ! command -v python3 >/dev/null 2>&1; then
    say "hooks: python3 not found — add this to $SETTINGS by hand:"
    json_block
    return 1
  fi
  if [ -e "$SETTINGS" ] && ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SETTINGS" 2>/dev/null; then
    say "hooks: $SETTINGS is not valid JSON — refusing to touch it"
    return 1
  fi
  say "hooks:"
  export DRY_RUN
  merge_hooks "$1"
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
