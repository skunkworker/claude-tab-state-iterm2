# Hardening backlog

Proposals not yet implemented, ranked by how much real-world stuck-tab time they
remove. Started 2026-08-01 after a live incident (below) exposed a gap the
2026-08-01 registry work did not cover.

Line references are to the tree as of the date each item was written; re-grep
before acting on them.

## The incidents that prompted this

### 2026-08-01 — a live session's tab, spared by every check

A second session's tab sat green while nothing ran. The state dir told the whole
story:

| file | contents | time |
| --- | --- | --- |
| `stopped-ttys002` | `1785637968` | 19:32:48 — turn closed, tab reset |
| `tty-ttys002` | `/dev/ttys002 63589 busy` | **19:36:13** — repainted green |
| pid 63589 | alive, only MCP-server children | idle since |

**205 seconds** between the `Stop` and the repaint, against `STALE_AFTER=60`. So
the closed-turn latch had already expired, a late `green` found it stale, and
repainted. No `Stop` follows a post-turn tool event, so nothing was ever coming
to undo it.

`heal_registry` then inspected the tab and **deliberately spared it** — every
verdict passed: tty writable, owner alive, record only 10 minutes old against a
30-minute TTL. It is built for sessions that are dead or mute. This one was
alive and had painted itself recently.

The result was a **29-minute window** (60s to 30min) where a live session's tab
is green, nothing is running, and the sweep refuses to touch it. For a single-tab
user it never recovered at all, since nothing else ends a turn.

### 2026-08-12 — the same window, with the culprit named

It happened again, and this time the transcript identified what fires after a
turn ends:

| time | transcript event | effect |
| --- | --- | --- |
| 05:43:50 | `Stop` → `reset` | tab dark, marker written |
| 05:44:50 | idle nudge → `reset` | tab dark, marker rewritten |
| 05:46:52 | **`away_summary`** | tool hook → `green` → tab green, and stays |

`away_summary` is Claude Code summarizing what happened while you were away; the
session title is generated the same way. They are model calls of Claude Code's
own, so their tool hooks arrive with no `start` in front of them and no `Stop`
behind them. 122 seconds after the last reset, against a 60-second expiry.

## Resolved

### The latch's 60s expiry (was item 1; fixed 2026-08-12)

`STALE_AFTER` existed so a resumed or compacted session that never sends `start`
would not leave the tab dark for its whole duration. But a stale marker and a
genuinely resumed session are **indistinguishable by elapsed time**, and the two
failure modes are not equally bad: a falsely dark tab is the neutral default and
self-corrects at the next `Stop`, while a falsely green tab makes you ask "is it
hung?" until something else ends a turn.

The latch now has no expiry at all — only `start` reopens a turn. The resumed and
compacted cases are handled where they actually differ rather than by a
threshold: `SessionStart` with `source=compact` leaves every record alone, since
the turn that triggered the compact is still running.

This also retired the proposed watchdog (was item 2), which was going to fork a
`sleep` to second-guess paints made over a stale marker. With no stale path
there is no paint to second-guess.

### Two tests encoding opposite intents (was item 5; fixed 2026-08-12)

`tests/run.sh` asserted that a 30-second gap after `Stop` must **not** paint and
that a 3600-second gap **must** — forty lines apart, with `STALE_AFTER` as the
arbitrary divider. The second test *was* the incident scenario, pinned as
correct, which is why the suite stayed green through a real bug. Both are now one
deliberate statement: the latch never expires, and a `green` that arrives after
it closed clears its own tab if that tab is still registered busy.

### `agent-stop` had the window `green` was hardened against (was item 3; fixed 2026-08-12)

`agent-stop`'s `else paint_busy` was a check followed by a paint with no
re-check — the identical shape the `green` arm was fixed for on 2026-08-01, so
a `Stop` landing between the test and the paint stranded the tab green through a
narrower door. The re-validation now lives inside `paint_busy`
(`tab-state.sh:195-201`), so every caller inherits it, and the
`[ "$state" = green ]` dispatch-name test — the tell that the fix had been at
the wrong altitude — is gone with it.

## Open

### 1. `kill -0` proves a pid exists, not that it is your session

`tab-state.sh:166`

macOS recycles pids. A recycled owner makes a dead session's tab **immortal**:
the sweep sees a live owner, and the record either sits in an exempt state or
gets refreshed by the unrelated process's existence, so it is never swept.

Fix: one `ps -o comm= -p "$o"` in the sweep, checking the command is `claude`.
This is off the hot path — it runs only in `heal_registry`, once per turn end —
so the fork is affordable. Cheaper alternative if the fork is unwelcome: record
the owner's start time alongside its pid and compare, which is fork-free at
read time but needs one at write time.

### 2. Record writes are not atomic

`tab-state.sh:96`

`register_tty` redirects with `>`, which is `O_TRUNC`, so a foreign sweep
running concurrently during parallel tool calls can read a zero-length or
partial record.

Today this fails safe — `read -r d o s` fails, the sweep `continue`s — but that
is luck rather than design, and a future reader of a partial record might not be
so lucky. Either write to a temp file and `mv` it into place (one extra fork on
the hot path, probably not worth it), or leave it and document that every reader
must treat a short read as "skip", which is the cheap and honest option.
