# Claude Code — iTerm2 tab state signaling

Colors the **iTerm2 tab** to reflect what Claude Code is doing, so you can tell
at a glance across multiple tabs whether a session is working, waiting on you,
or idle.

| Tab color | Meaning | Hook event |
|-----------|---------|------------|
| 🟢 green  | Claude is running | `UserPromptSubmit`, `PostToolUse` |
| 🟡 yellow | Claude needs you (permission / question) | `Notification` |
| default   | done / idle | `Stop` |

## Files

- `tab-state.sh` — the worker. Source of truth. `~/.claude/tab-state.sh` is a
  symlink to this file, so edits here are live.
- `toggle.sh` — enable/disable the feature.
- `README.md` — this file.

## How it works

- **Tab color, not title.** Uses iTerm2's tab-color escape (`OSC 6 ;1;bg`).
  It's a dedicated channel — Claude Code never writes tab color — so nothing
  competes with it and the reset (`6;1;bg;*;default`) is reliable. With
  multiple tabs the color stays in the individual tab cell. The tab *title* is
  left untouched, so Claude's own topic titles are preserved.
  - Tab *title* signaling (a 🟢/🟡 emoji in the title) was tried first but is
    less reliable: Claude Code also writes the title, so the two fight and the
    marker flickers/persists. Title-only is better if you usually run a single
    full-width tab (color then looks like a bar across the whole title bar).

- **Finding the terminal.** Hooks run in a subprocess with **no controlling
  terminal**, so writing to `/dev/tty` silently fails (this was why an earlier
  version "never changed colors"). The script walks up the process tree from
  `$PPID` to the parent `claude` process and writes to its real `/dev/ttysNNN`.
  Each session resolves its own tty, so multiple instances color the right tab.

- **Idle vs. real prompts.** The `Notification` event fires both for genuine
  permission/question prompts **and** for the idle "Claude is waiting for your
  input" nudge (~60s after a turn ends). The script reads the notification
  message from stdin and only turns the tab yellow for the former; the idle
  nudge resets instead.

## Wiring (in `~/.claude/settings.json`)

```json
"hooks": {
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh green" }] }],
  "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh green" }] }],
  "Notification":     [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh yellow" }] }],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh reset" }] }]
}
```

After editing `settings.json`, reload with `/hooks` (or restart Claude Code).
Editing `tab-state.sh` needs no reload — it's read fresh on every hook call.

## Toggle

```sh
~/dev/ai_tools/claude-tab-state/toggle.sh          # flip on/off
~/dev/ai_tools/claude-tab-state/toggle.sh off      # force off
~/dev/ai_tools/claude-tab-state/toggle.sh on       # force on
~/dev/ai_tools/claude-tab-state/toggle.sh status   # show state
```

`off` drops `~/.claude/tab-state.disabled`. While it exists, every hook call
just resets the tab to default instead of signaling, so no tab stays colored.

## Customizing

- **Colors:** edit the `set_color R G B` values in `tab-state.sh` (0–255).
- **Yellow trigger:** the idle filter matches the string
  `waiting for your input`; if a future Claude Code version rewords
  this nudge, update that `grep` pattern.

## Reinstall (e.g. on a new machine)

```sh
ln -sf ~/dev/ai_tools/claude-tab-state/tab-state.sh ~/.claude/tab-state.sh
chmod +x ~/dev/ai_tools/claude-tab-state/*.sh
# then add the hooks block above to ~/.claude/settings.json
```
