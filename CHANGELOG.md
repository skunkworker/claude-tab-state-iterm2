# Changelog

## Unreleased

### Fixed

- The tab no longer sticks green when a session is interrupted, quit, or
  crashes — `Stop` doesn't fire for those, so `SessionEnd` now resets too.
- The tab no longer stays yellow for the whole duration of a long tool call you
  just approved. `PreToolUse` paints green; `PostToolUse` only fires at the end.
- A late `PostToolUse` green from a parallel tool call can no longer land after
  `Stop` and strand the tab green. `reset` closes the turn and `start` reopens
  it.
- The idle-nudge filter reads the payload's `message` field instead of grepping
  the whole JSON, so a path containing "waiting for your input" no longer hides
  a real permission prompt.
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
- `tests/run.sh` — 57 assertions driven through env seams rather than a real
  terminal.
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

Run `./install.sh` and then `/hooks`. `UserPromptSubmit` moves from `green` to
`start`, and `PreToolUse` / `SessionEnd` / `SessionStart` are new. Old wiring
keeps working — `green` still paints green — but a turn is only reopened by
`start`, so without it the tab relies on the 60s staleness backstop.
