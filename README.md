# Claude Code — iTerm2 tab state signaling

Colors the **iTerm2 tab** to reflect what Claude Code is doing, so you can tell
at a glance across multiple tabs whether a session is working, waiting on you,
or idle.

Highest first: when two are true at once, the tab shows the higher one. One
exception is left: mid-turn, another agent's tool call repaints over a yellow
(see `docs/hardening.md`).

| Tab color | Meaning | Hook event |
|-----------|---------|------------|
| 🟡 yellow | Claude needs you: a permission prompt, an MCP server asking for input, or a background agent or teammate asking | `Notification` |
| 🔴 red    | the turn died on an API error | `StopFailure` |
| 🔵 blue   | waiting for subagents | `SubagentStart` / `SubagentStop` |
| 🟢 green  | Claude is running, or a manual `/compact` on an idle tab is | `UserPromptSubmit`, `PostToolUse`, `PreCompact` |
| 🟠 orange | stopped on a rate or usage limit; Claude Code may resume when it resets | `StopFailure` (`rate_limit`) |
| 🟣 magenta | turn over, background shells still running | `Stop` |
| 🩶 slate  | nothing running, but a wake-up is scheduled (`/loop`, a cron job) | `PostToolUse` on the scheduling tools |
| default   | done / idle / session over | `Stop`, `SessionEnd`, `SessionStart` |

Blue outranks green: while any subagent is outstanding the tab stays blue even
as the parent keeps calling tools, and it stays blue after `Stop` — subagents
outlive the turn that dispatched them, so a finished turn with work still
running does not go dark.

Red, orange, magenta and slate show only once the turn is over. Red and orange
stay until you send the next prompt; the idle nudge does not clear them. Orange
also clears when a resumed turn ends well — but a plain rate-limit error that
ran out of retries is not resumed, so if orange stays, prompt again. A
background dev server counts as a running shell, so a session that started one
stays magenta until the server stops. A yellow that appears after the turn — a
background agent asking — stays until your next prompt or the next `Stop`,
because no hook says you answered.

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
and the `agent_id` hook field), `StopFailure` needs **2.1.78**, and the
compaction pair needs **2.1.76** (`PostCompact`). `install.sh`
checks `claude --version` and simply leaves an event unwired on anything older
than it needs; every other color still works.

```sh
./install.sh --dry-run     # show what would change, touch nothing
./install.sh --no-hooks    # symlink only, edit settings.json yourself
./install.sh --uninstall   # remove the symlink and our hook entries
```

If you would rather wire it by hand, add this to `~/.claude/settings.json`:

```json
"hooks": {
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh start" }] }],
  "PostToolUse": [
    { "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh green" }] },
    { "matcher": "ScheduleWakeup|CronCreate|CronDelete", "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh schedule" }] }
  ],
  "Notification": [
    { "matcher": "permission_prompt",        "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh yellow" }] },
    { "matcher": "elicitation_dialog",       "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh yellow" }] },
    { "matcher": "elicitation_url_dialog",   "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh yellow" }] },
    { "matcher": "agent_needs_input",        "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh yellow" }] },
    { "matcher": "worker_permission_prompt", "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh yellow" }] },
    { "matcher": "idle_prompt",              "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh idle" }] }
  ],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh reset" }] }],
  "StopFailure":      [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh failure" }] }],
  "PreCompact":       [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh compact-start" }] }],
  "PostCompact":      [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/tab-state.sh compact-end" }] }],
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
  The walk stops at a `claude` with no tty: that is a headless `claude -p` run
  from inside another session, and the tab further up belongs to the parent.
  The walk asks each level for `ppid` and `tty` in one `ps`, which matters
  because it runs on every `PostToolUse`. A single full-table `ps -ax` snapshot
  needs fewer processes but measures about twice as slow — it resolves the tty
  name of every process on the machine.

- **Idle vs. real prompts.** The `Notification` event fires both for genuine
  "needs you" moments **and** for the idle "Claude is waiting for your input"
  nudge (~60s after a turn ends). Claude Code tags each with a type, so each
  "needs you" type (`permission_prompt`, `elicitation_dialog`,
  `elicitation_url_dialog`, `agent_needs_input`, `worker_permission_prompt`) is
  wired to yellow, `idle_prompt` to `idle`, and the script never has to look at
  the payload. An earlier version string-matched the message text, which broke
  whenever a path happened to contain the same wording and would have broken
  again on any rewording.

- **Failed and paused turns.** A turn that dies on an API error sends
  `StopFailure` instead of `Stop`, with an `error` field. `rate_limit` paints
  orange, because Claude Code may resume by itself when the limit resets; every
  other error, including types added later, paints red. A small file keeps the
  failure, because the idle nudge repaints the tab a minute later and must not
  erase it — which is why `idle_prompt` has its own `idle` state rather than
  sharing `reset`. Your next prompt clears it, and so does a `Stop`: a turn
  that ended well answers the failure before it. A `StopFailure` with no turn
  open is ignored: it comes from Claude Code's own work after a turn (titling,
  away summaries), and a good turn should not turn red for it.

- **Scheduled wake-ups.** No hook fires when a `/loop` wake-up or a cron job
  fires, so a second `PostToolUse` entry, matched to `ScheduleWakeup`,
  `CronCreate` and `CronDelete` only, records what is pending: one token per
  wake-up, holding
  when it is due and when to stop believing it. A one-shot (a `/loop` wake-up,
  a one-shot cron job) is dropped by the first prompt at or after its due time,
  which is its own firing — a turn Claude Code starts by itself sends
  `UserPromptSubmit` like a prompt you type — and expires 15 minutes after it
  was due if that prompt never comes. A prompt you send earlier leaves it
  alone. A recurring job lasts until `CronDelete` or its 7-day expiry. Cron
  tokens are named by the job id that `CronCreate` returns and `CronDelete`
  takes, so a delete drops exactly its own job. `/clear` and other session
  boundaries drop them all: whether Claude Code keeps cron jobs across `/clear`
  is not known, and a dark tab is the safe guess.

- **Manual `/compact`.** Between turns it is work with no turn around it, so
  on an idle tab `PreCompact` paints green and `PostCompact` puts the default
  back. Any other color after a turn says more than green does, so it stays. A
  compact that is cancelled sends no `PostCompact`; the idle nudge ends it.
  Mid-turn compaction changes nothing.

- **Counting subagents.** `SubagentStart` and `SubagentStop` both carry an
  `agent_id`, so each outstanding subagent gets its own token file and "any
  running?" is a glob. A counter in a shared file would be a read-modify-write
  race between the hooks of agents starting and finishing at the same moment.
  Tokens are keyed by tty as well, so a second session in another tab cannot
  color yours. If a `SubagentStop` never arrives, session boundaries drain the
  set, and every turn end — in any tab — drops tokens older than the TTL. The
  token is an empty file whose mtime is its start time. The sweep used to run
  only on agent events, so a tab that never saw another one stayed blue for
  good; that was caught live, six hours after the lost `SubagentStop`.

- **Counting background shells.** No hook fires when a background shell ends,
  and a foreground command that hits its timeout is moved to the background
  with nothing in any payload to say so. So there is nothing to count from
  hooks; instead, `Stop` asks the process table. Every shell Claude Code starts
  is a direct child of `claude` that sources a file from
  `~/.claude/shell-snapshots`, so one `pgrep` answers "any left?". It runs once
  per turn end, never on a tool call. When the last shell ends, Claude Code
  wakes up to report it; the tool hooks of that turn find no shells and clear
  the tab, and its `Stop` checks again.

- **Not getting stuck.** `Stop` does not fire when the turn ends on an API error
  — Claude Code sends `StopFailure` instead, so both reset. Nor does it fire
  when you quit, which used to leave the tab green with nothing behind it —
  hence `SessionEnd`; a crash sends nothing and is left to the sweep below. An
  interrupt (Esc) sends neither `Stop` nor `SessionEnd`, so that tab stays green
  until your next prompt, the idle nudge, or the sweep. And with parallel tool
  calls a slow `PostToolUse` green can land *after* `Stop`'s reset. Nothing in
  the payload can order those two, so `reset` closes the turn and `start`
  reopens it: green does not paint in between. The latch file marks the turn
  *open*, so lost state — a toggle, a drained state dir — reads as closed: dark
  until your next prompt, never green for good. An earlier version marked it
  closed, and toggling the feature off and on reopened every tab's latch. The
  latch is still a check followed by a paint, so `green` re-reads it afterwards
  — a `Stop` that slips between the two would otherwise be painted over by a
  green nobody is coming back to undo.

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
  minutes, since every tool call rewrites it — waiting on you (yellow) is
  exempt *by name*; blue, magenta, red, orange and slate are exempt only while
  what backs them remains (a subagent token, a background shell, a failure
  file, a wake-up token), all being legitimately long-lived. A state added
  later ages out rather than silently becoming un-healable. Clearing a tab that
  turns out to still be working costs nothing: its next tool call repaints it.

- **Why not `PreToolUse`.** It used to be wired, on the theory that approving a
  three-minute test run otherwise leaves the tab yellow for the whole run. It
  never helped: `PreToolUse` fires *before* the permission prompt, and no hook
  fires on approval, so the yellow lasts until `PostToolUse` either way. It
  only doubled the cost of every tool call. `install.sh` unwires it.

## Requirements and limits

- **macOS + iTerm2.** The script checks `LC_TERMINAL` / `TERM_PROGRAM` and stays
  silent elsewhere, because terminals without OSC 6 support render the escape as
  literal garbage in the scrollback. Set `TAB_STATE_FORCE=1` to override.
- **tmux / screen are unsupported.** The escape reaches the multiplexer rather
  than the tab, so the script stays silent there. DCS passthrough was tried and
  removed: every pane shares one iTerm2 tab, so the signal cannot mean what it
  means everywhere else.
- **No dependencies beyond bash.** `install.sh` needs `python3` to edit
  `settings.json`; `tab-state.sh` itself shells out only to `ps`, `find` and
  `pgrep`.

## Customizing

- **Colors:** edit the `R G B` values of the `paint` calls in `tab-state.sh`
  (0–255).
- **Subagent staleness:** `TAB_STATE_AGENT_TTL_SEC` (default 7200, i.e. 2h) is
  how long a subagent whose `SubagentStop` never arrived is believed, rounded
  up to whole minutes. Raise it if you run longer agents than that.
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

CI pins shellcheck 0.11.0 and shfmt 3.14.1, the versions Homebrew ships, so a
local run and CI agree. Bump the pins in `.github/workflows/ci.yml` when you
upgrade the tools.

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
actually shipped rather than as fixtured. It does the same for slate
(`CronCreate` returns the job id `CronDelete` takes), for magenta (a background
shell carries `shell-snapshots`), and for the turns Claude Code starts by
itself (they send `UserPromptSubmit`). Worth running when you upgrade Claude
Code.

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
