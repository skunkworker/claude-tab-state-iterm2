# Changelog

## Unreleased

### Added

- **Blue tab while subagents are running.** `SubagentStart` and `SubagentStop`
  both carry an `agent_id`, so each outstanding subagent gets a token file and
  "any running?" is a glob — no shared counter to race on. Blue outranks green,
  and survives `Stop`, because subagents outlive the turn that dispatched them.
  Needs Claude Code 2.0.43+.

### Fixed

- The tab no longer sticks green when a session is interrupted, quit, or
  crashes — `Stop` doesn't fire for those, so `SessionEnd` now resets too.
- The tab no longer stays yellow for the whole duration of a long tool call you
  just approved. `PreToolUse` paints green; `PostToolUse` only fires at the end.
- A late `PostToolUse` green from a parallel tool call can no longer land after
  `Stop` and strand the tab green. `reset` closes the turn and `start` reopens
  it.
- The idle nudge and a real permission prompt are now told apart by Claude
  Code's `idle_prompt` / `permission_prompt` matchers rather than by string
  matching the payload. The old filter grepped the whole JSON, so a path
  containing "waiting for your input" hid a real prompt, and any rewording of
  the nudge would have broken it.
- An unclosed stdin can no longer hang the hook until Claude Code's timeout.
- Unknown or missing arguments now exit 1 instead of succeeding silently, so a
  typo in `settings.json` is visible. Exit 1 and not 2: Claude Code reads hook
  exit 2 as "block this tool call".
- Nothing is written to stderr on the normal path.
- `toggle.sh off` clears every tab it has colored, not just the current one.

### Added

- `install.sh` — symlinks the worker and merges the hook block into
  `settings.json`. Backs up first, writes atomically, refuses to touch the file
  if it doesn't already parse, and only claims entries it generated, so
  re-running is safe and unrelated hooks survive. `--dry-run`, `--no-hooks`,
  `--uninstall`.
- `tests/run.sh` — 69 assertions driven through env seams rather than a real
  terminal.
- `tests/probe-hooks.sh` — verifies the hook contract against the installed
  Claude Code by running a real session in a sandboxed temp dir. Catches the
  failure the unit tests structurally cannot: Claude Code changing what it
  sends. Manual, not in CI — it needs the `claude` binary and spends tokens.
- CI (shellcheck, plus the suite on macOS and Ubuntu), `LICENSE`, `.gitignore`.

### Changed

- Only runs under iTerm2 now. Other terminals render `OSC 6` as literal garbage
  in the scrollback. `TAB_STATE_FORCE=1` overrides.
- tmux and screen are unsupported rather than half-supported: DCS passthrough
  was tried and removed, since every pane shares one iTerm2 tab.
- `jq` is no longer used; the message is extracted with parameter expansion.
- Roughly 3x faster per tool call. The tty walk asks each level for `ppid` and
  `tty` in one `ps` (~21ms → ~11ms); a full-table `ps -ax` snapshot uses fewer
  processes but is about twice as slow, because it resolves the tty name of
  every process on the machine. The disable check now runs before the walk, so
  a disabled feature costs almost nothing.

### Migration

Run `./install.sh` and then `/hooks` — the wiring changed enough that old
`settings.json` entries no longer cover it:

- `UserPromptSubmit` moves from `green` to `start`
- `Notification` splits into `permission_prompt` → `yellow` and `idle_prompt` →
  `reset`. **Without this split an unmatched `Notification` hook turns the tab
  yellow on the idle nudge**, since the script no longer inspects the payload.
- `SessionEnd` / `SessionStart` use `session` (drains subagent tokens)
- `PreToolUse`, `SubagentStart`, `SubagentStop` are new
