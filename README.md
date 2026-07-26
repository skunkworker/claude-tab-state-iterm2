# Claude Code — iTerm2 tab state signaling

Colors the **iTerm2 tab** to reflect what Claude Code is doing, so you can tell
at a glance across multiple tabs whether a session is working, waiting on you,
or idle.

| Tab color | Meaning | Hook event |
|-----------|---------|------------|
| 🟢 green  | Claude is running | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` |
| 🟡 yellow | Claude needs you (permission / question) | `Notification` |
| default   | done / idle / session over | `Stop`, `SessionEnd`, `SessionStart` |

## Install

```sh
git clone https://github.com/skunkworker/claude-tab-state-iterm2
cd claude-tab-state-iterm2
./install.sh
```

Then run `/hooks` in Claude Code (or restart it) to load the wiring.

`install.sh` symlinks `tab-state.sh` to `~/.claude/tab-state.sh` and merges the
hook block into `~/.claude/settings.json`. It backs the file up first, only
touches entries that mention `tab-state.sh`, and leaves every other hook alone —
so re-running it is safe and never stacks duplicates.

```sh
./install.sh --dry-run     # show what would change, touch nothing
./install.sh --no-hooks    # symlink only, edit settings.json yourself
./install.sh --uninstall   # remove the symlink and our hook entries
```

If you would rather wire it by hand, add this to `~/.claude/settings.json`:

```json
"hooks": {
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh start" }] }],
  "PreToolUse":       [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh green" }] }],
  "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh green" }] }],
  "Notification":     [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh yellow" }] }],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh reset" }] }],
  "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh reset" }] }],
  "SessionStart":     [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh reset" }] }]
}
```

Editing `tab-state.sh` needs no reload — it is read fresh on every hook call.
Only changing the wiring above requires `/hooks`.

## Toggle

```sh
./toggle.sh          # flip on/off
./toggle.sh off      # force off
./toggle.sh on       # force on
./toggle.sh status   # show state
```

`off` drops `~/.claude/tab-state.disabled` and immediately clears every tab the
script has ever colored. While the flag exists, each hook call clears anything
still colored and exits before doing any real work, so a disabled feature costs
almost nothing per tool call.

## How it works

- **Tab color, not title.** Uses iTerm2's tab-color escape (`OSC 6;1;bg`).
  It's a dedicated channel — Claude Code never writes tab color — so nothing
  competes with it and the reset (`6;1;bg;*;default`) is reliable. With multiple
  tabs the color stays in the individual tab cell. The tab *title* is left
  untouched, so Claude's own topic titles are preserved.
  - Tab *title* signaling (a 🟢/🟡 emoji in the title) was tried first but is
    less reliable: Claude Code also writes the title, so the two fight and the
    marker flickers/persists. Title-only is better if you usually run a single
    full-width tab (color then looks like a bar across the whole title bar).

- **Finding the terminal.** Hooks run in a subprocess with **no controlling
  terminal**, so writing to `/dev/tty` silently fails (this was why an earlier
  version "never changed colors"). The script walks up the process tree from
  `$PPID` to the parent `claude` process and writes to its real `/dev/ttysNNN`.
  Each session resolves its own tty, so multiple instances color the right tab.
  The walk asks each level for `ppid` and `tty` in one `ps`, which matters
  because it runs on every `PostToolUse`. A single full-table `ps -ax` snapshot
  needs fewer processes but measures about twice as slow — it resolves the tty
  name of every process on the machine.

- **Idle vs. real prompts.** The `Notification` event fires both for genuine
  permission/question prompts **and** for the idle "Claude is waiting for your
  input" nudge (~60s after a turn ends). The script reads the notification
  payload's `message` field and only turns the tab yellow for the former; the
  idle nudge resets instead. A payload it cannot parse is treated as a real
  prompt — better a spurious yellow than a missed one.

- **Not getting stuck.** `Stop` does not fire when you interrupt, quit, or
  crash, which used to leave the tab green with nothing behind it — hence
  `SessionEnd`. And with parallel tool calls a slow `PostToolUse` green can
  land *after* `Stop`'s reset. Nothing in the payload can order those two, so
  `reset` closes the turn and `start` reopens it: green does not paint in
  between. It is a latch rather than a timeout, because any timeout short
  enough to be useful is also short enough to lose under load. A closed turn
  does expire after 60s so that a session resumed without a `start` heals
  itself rather than staying dark.

- **Why `PreToolUse` too.** `PostToolUse` fires when a tool *finishes*. Without
  `PreToolUse`, approving a three-minute test run leaves the tab yellow for the
  whole run, claiming it needs you when it doesn't.

## Requirements and limits

- **macOS + iTerm2.** The script checks `LC_TERMINAL` / `TERM_PROGRAM` and stays
  silent elsewhere, because terminals without OSC 6 support render the escape as
  literal garbage in the scrollback. Set `TAB_STATE_FORCE=1` to override.
- **tmux / screen are unsupported.** The escape reaches the multiplexer rather
  than the tab, so the script stays silent there. DCS passthrough was tried and
  removed: every pane shares one iTerm2 tab, so the signal cannot mean what it
  means everywhere else.
- **No dependencies beyond bash.** `install.sh` needs `python3` to edit
  `settings.json`; `tab-state.sh` itself shells out only to `ps` and `date`.

## Customizing

- **Colors:** edit the `set_color R G B` values in `tab-state.sh` (0–255).
- **Yellow trigger:** the idle filter matches the string
  `waiting for your input`; if a future Claude Code version rewords that nudge,
  update the `grep` pattern.

## Development

```sh
tests/run.sh           # run everything
tests/run.sh install   # run tests whose name matches "install"
shellcheck *.sh tests/run.sh
```

Tests drive the scripts through env seams rather than a real terminal:
`TAB_STATE_DEV` redirects the escapes into a file, `TAB_STATE_FORCE=1` skips
iTerm2 detection, and `HOME` points at a sandbox so flag files, stop markers and
the tty registry never touch your real `~/.claude`.

## Files

- `tab-state.sh` — the worker; `~/.claude/tab-state.sh` symlinks to it.
- `toggle.sh` — enable/disable the feature.
- `install.sh` — symlink + hook wiring.
- `tests/run.sh` — the test suite.

## License

MIT — see [LICENSE](LICENSE).
