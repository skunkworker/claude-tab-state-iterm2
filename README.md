# Claude Code — iTerm2 tab state signaling

Colors the **iTerm2 tab** to reflect what Claude Code is doing, so you can tell
at a glance across multiple tabs whether a session is working, waiting on you,
or idle.

| Tab color | Meaning | Hook event |
|-----------|---------|------------|
| 🟢 green  | Claude is running | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` |
| 🔵 blue   | waiting for subagents | `SubagentStart` / `SubagentStop` |
| 🟡 yellow | Claude needs you (permission / question) | `Notification` (`permission_prompt`) |
| default   | done / idle / session over | `Stop`, `SessionEnd`, `SessionStart` |

Blue outranks green: while any subagent is outstanding the tab stays blue even
as the parent keeps calling tools, and it stays blue after `Stop` — subagents
outlive the turn that dispatched them, so a finished turn with work still
running does not go dark.

## Install

```sh
git clone https://github.com/skunkworker/claude-tab-state-iterm2
cd claude-tab-state-iterm2
./install.sh
```

Then run `/hooks` in Claude Code (or restart it) to load the wiring.

`install.sh` symlinks `tab-state.sh` to `~/.claude/tab-state.sh` and merges the
hook block into `~/.claude/settings.json`. It backs the file up first, claims
only the exact commands it generates, and leaves every other hook alone — so
re-running it is safe and never stacks duplicates.

The blue subagent state needs Claude Code **2.0.43 or newer** (`SubagentStart`
and the `agent_id` hook field). `install.sh` checks `claude --version` and
simply leaves those two events unwired on anything older; every other color
still works.

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
  "Notification": [
    { "matcher": "permission_prompt", "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh yellow" }] },
    { "matcher": "idle_prompt",       "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh reset" }] }
  ],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh reset" }] }],
  "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh session" }] }],
  "SessionStart":     [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh session" }] }],
  "SubagentStart":    [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh agent-start" }] }],
  "SubagentStop":     [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh agent-stop" }] }]
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
  input" nudge (~60s after a turn ends). Claude Code splits them with the
  `permission_prompt` and `idle_prompt` matchers, so the two are wired to
  different states and the script never has to look at the payload. An earlier
  version string-matched the message text, which broke whenever a path happened
  to contain the same wording and would have broken again on any rewording.

- **Counting subagents.** `SubagentStart` and `SubagentStop` both carry an
  `agent_id`, so each outstanding subagent gets its own token file and "any
  running?" is a glob. A counter in a shared file would be a read-modify-write
  race between the hooks of agents starting and finishing at the same moment.
  Tokens are keyed by tty as well, so a second session in another tab cannot
  color yours. If a `SubagentStop` never arrives, session boundaries drain the
  set and a staleness sweep is the backstop.

- **Not getting stuck.** `Stop` does not fire when you interrupt, quit, or
  crash, which used to leave the tab green with nothing behind it — hence
  `SessionEnd`. And with parallel tool calls a slow `PostToolUse` green can
  land *after* `Stop`'s reset. Nothing in the payload can order those two, so
  `reset` closes the turn and `start` reopens it: green does not paint in
  between. The latch is still a check followed by a paint, so `green` re-reads
  it afterwards — a `Stop` that slips between the two would otherwise be
  painted over by a green nobody is coming back to undo.

- **Why the latch has no expiry.** It used to lapse after 60s, so that a
  session resumed without a `start` healed rather than staying dark. That
  window was the bug: a turn ended at 05:43:50 and three minutes later an
  `away_summary` — Claude Code summarizing what happened while you were away —
  fired a tool hook that found the latch stale and painted the tab green for
  good. Claude Code does model work of its own after your turn ends, and those
  hooks arrive with no `start` in front of them and, crucially, no `Stop`
  behind them, so nothing is ever coming to undo the paint. The two mistakes
  are not equally expensive: a falsely **dark** tab is the neutral default and
  the next `Stop` corrects it, while a falsely **green** tab has you asking "is
  it hung?" indefinitely. So the latch never lapses — only `start` reopens a
  turn — and a `green` that finds the turn closed *and* its own tab still
  registered busy clears it, since that stray hook is the last event that tab
  will ever see.

- **Compaction is not a session boundary.** `SessionStart` also fires when the
  context is compacted, but the turn that triggered it is still running with
  its subagents still outstanding. So a compact touches nothing: closing the
  latch would darken the rest of that turn, and opening it would unlatch a turn
  that had already ended — the same stuck-green bug by another route.

- **Tabs other sessions abandoned.** Every one of those recovery paths needs a
  hook event *in the tab's own terminal*. A session that stops delivering them
  — `SIGKILL`, a crash, or its hook config rewritten mid-session, after which
  Claude Code fires nothing there again — strands its tab colored, and only
  another terminal can notice. So the registry of painted tabs records who owns
  each one, and a sweep clears it: a tty that is gone, or an owner that no
  longer exists, is cleared and forgotten. Every session boundary sweeps, and
  that is the guarantee — the next `claude` you start in any tab heals the
  others. Turn ends sweep as well, which only shortens the wait. An owner still
  alive keeps its tab unless its record has been `busy` and untouched for 30
  minutes, since every tool call rewrites it — waiting on you (yellow) or on a
  subagent (blue) is exempt *by name*, both being legitimately long-lived, so a
  state added later ages out rather than silently becoming un-healable.
  Clearing a tab that turns out to still be working costs nothing: its next
  tool call repaints it.

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
- **Subagent staleness:** `TAB_STATE_AGENT_TTL_SEC` (default 7200, i.e. 2h) is
  how long a subagent whose `SubagentStop` never arrived is believed. Raise it
  if you run longer agents than that.
- **Abandoned-tab timeout:** `TAB_STATE_BUSY_TTL_MIN` (default 30 minutes) is
  how long a green tab may go without a hook event before another tab's turn
  end clears it. Raise it if you routinely run single tool calls longer than
  that and dislike the tab dropping to default until the call returns.

## Development

```sh
tests/run.sh           # run everything
tests/run.sh install   # run tests whose name matches "install"
shellcheck --severity=style *.sh tests/*.sh
shfmt -d .             # flagless: takes its settings from .editorconfig
```

Tests drive the scripts through env seams rather than a real terminal:
`TAB_STATE_DEV` redirects the escapes into a file, `TAB_STATE_FORCE=1` skips
iTerm2 detection, and `HOME` points at a sandbox so flag files, stop markers and
the tty registry never touch your real `~/.claude`.

That suite proves the scripts behave; it cannot prove Claude Code still sends
what they expect. For that:

```sh
tests/probe-hooks.sh   # verify the hook contract against installed Claude Code
```

It starts a real Claude Code session in a temp dir with its own `--settings`
(so it needs the `claude` binary and spends tokens — hence not in CI), then
checks that `SubagentStart`/`SubagentStop` fire, that both carry `agent_id`,
that **the two ids agree** — tokens would leak and the tab would stick blue if
they ever stopped — and that `tab-state.sh` still parses the payloads as
actually shipped rather than as fixtured. Worth running when you upgrade
Claude Code.

## Files

- `tab-state.sh` — the worker; `~/.claude/tab-state.sh` symlinks to it.
- `toggle.sh` — enable/disable the feature.
- `install.sh` — symlink + hook wiring.
- `tests/run.sh` — the test suite.
- `tests/probe-hooks.sh` — verifies the hook contract against installed Claude
  Code. Manual; needs the `claude` binary.
- `docs/hardening.md` — the two stuck-tab incidents, what they cost, and the
  gaps still open. Read before touching the turn latch or the sweep.

## License

MIT — see [LICENSE](LICENSE).
