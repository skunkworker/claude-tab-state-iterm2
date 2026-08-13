# Changelog

Dated entries, newest first. This is a personal tool with no releases to
version, so the date something landed is the useful thing to know.

## 2026-08-12

### Fixed

- **A finished tab went green again a couple of minutes later.** Caught in a
  transcript: the turn ended at 05:43:50 and the tab went dark, the idle nudge
  reset it again at 05:44:50, and at 05:46:52 an `away_summary` — Claude Code
  summarizing what happened while you were away — fired a tool hook that
  painted the tab green. Nothing follows that hook, so the tab stayed green.
  The turn latch used to expire after 60s, which was the whole hole: Claude
  Code does model work of its own after a turn ends (away summaries, session
  titling), and those hooks arrive with no `start` in front of them and no
  `Stop` behind them. The latch no longer expires at all — only `start` reopens
  a turn. A `green` that arrives after the turn closed now also clears the tab
  if it is still registered busy, since it is the last event that tab will see.
- **A compact no longer closes the turn it interrupted.** `SessionStart` fires
  for compaction too, and it was being treated as a session boundary: stop
  marker written, subagent tokens dropped, tab reset — while the turn that
  triggered it was still running. With the latch now permanent that would have
  darkened the whole rest of the turn. Compaction leaves every record alone.
- **`agent-stop` inherited the stuck-green window `green` was fixed for.** Its
  `else paint_busy` was the same test-then-paint shape, so a `Stop` landing
  between the two stranded the tab. The post-paint re-check moved into
  `paint_busy` itself, where every caller gets it and no future paint site can
  forget it — which also retired the `[ "$state" = green ]` dispatch-name test.

### Changed

- The stop marker is a flag rather than a timestamp, so `reset` and the session
  boundaries no longer fork `date`. `now_epoch` went with it; the subagent
  sweep, its only remaining caller, reads the clock itself.
- "Which painted states outlive their turn" is one predicate, `outlives_turn`,
  shared by the foreign sweep and our own tab. It was being stated twice with
  opposite polarity — exempt `agents|hold` there, heal only `busy` here — which
  meant a state added later would have aged out of other tabs but been spared
  forever on your own, the only tab a single-tab user has.
- `start` and `green` are separate dispatch arms again; the merged arm had to
  re-test its own verb twice to tell them apart.
- `sweep_agents` asks the fork-free "any outstanding?" before forking `date`,
  and the disabled-flag drain uses one `rm` for the leftovers rather than one
  per file.

## 2026-08-01

### Fixed

- **A tab could stay green forever.** Seen in the wild: a session whose hook
  config was rewritten underneath it mid-session stopped firing hooks at all,
  and its tab had been green for 22 hours. Every recovery path — `Stop`, the
  idle nudge, `SessionStart`, `SessionEnd` — needs an event in that tab's own
  terminal, so a session that stops delivering them (killed, crashed, or wired
  out from under itself) strands its tab with nothing left to notice. Painted
  tabs now record their owning pid, and every turn end sweeps the registry:
  gone tty or dead owner is cleared outright, and a tab still marked busy whose
  record nothing has refreshed for `TAB_STATE_BUSY_TTL_MIN` (30 minutes) is
  cleared too. Waiting on you or on a subagent is exempt from the timeout — by
  name, so a state added later ages out rather than silently inheriting the
  exemption and becoming un-healable.
- `green` re-checks the turn latch after painting. The latch was a check
  followed by a paint, so a `Stop` landing between the two left the tab green
  with no further hook coming to correct it — the same dead end by a much
  narrower door.

### Changed

- The tty registry is now the set of *currently painted* tabs: entries are
  dropped the moment a tab goes back to default, rather than accumulating until
  a session boundary reaped them.
- Records carry `dev owner state`. Resolving the tty sets both values directly
  instead of printing one through a command substitution, which also drops a
  subshell fork from the hot path.

### Added

- 24 assertions covering the sweep: dead owners, live owners, the quiet-tab
  timeout and its exemptions, an unrecognized state, legacy records, that
  sweeping stays off the hot path, and that a sweep never touches the tab of
  the session running it. 85 -> 109.
- `TAB_STATE_AGENT_TTL_SEC` overrides the subagent staleness backstop, which
  the README already documented as tunable while the script hard-coded it.
- A real interleaving for the mid-paint `Stop`, rather than trusting the
  re-check by inspection: pointing `TAB_STATE_DEV` at a fifo makes the paint
  block on its open, which is exactly the window the Stop has to land in.

## 2026-07-26 (later)

### Fixed

- Disabling the feature while a subagent was running stranded the tab blue.
  The disabled fast path exits before the subagent bookkeeping, so it swallowed
  the `SubagentStop` that would have cleared the token; re-enabling then showed
  "waiting for subagents" for an agent that had long finished, until the 2h
  staleness sweep. Both `toggle.sh off` and the disabled path now drain them.
- `install.sh` followed a symlinked `settings.json` — the atomic write replaced
  the link itself with a regular file, detaching it from its target.

### Changed

- `install.sh` skips `SubagentStart`/`SubagentStop` on Claude Code older than
  2.0.43 rather than handing an old version an event name it may not know.
- Session boundaries reap `tty-`/`stopped-` records for ttys that no longer
  exist. One accumulated per terminal ever used and nothing removed them.
- `.editorconfig` plus `shfmt -d .` in CI. shfmt reads the indent settings from
  `.editorconfig`, so CI and your editor cannot drift. Zero reformatting — the
  existing style already conformed.

### Added

- Tests for all of the above, including stubbed `PATH`s that take `python3` or
  a specific `claude --version` away: 69 -> 85 assertions.

## 2026-07-26

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
