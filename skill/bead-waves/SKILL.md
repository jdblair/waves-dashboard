---
name: bead-waves
description: Close many issues in one session by working up to 5 at a time in parallel subagents, merging and reviewing after every wave. Use when the owner asks to "work through beads", "close as many issues as you can", "run a wave", "plan the next N waves", or wants sustained autonomous issue-clearing. Also use to resume such work after it was stopped mid-flight.
---

# bead-waves

Close the beads that don't need a decision from the owner. Work at most 5 at a
time, each in its own subagent. After every wave, merge it and have a fresh
agent review it, fix what the review finds, then start the next wave.
Invoking this skill is the grant of autonomy: pick the beads, say what you
picked and why, and continue. `/bead-waves <ids...>` works those beads instead
of picking. Stop between waves, never mid-wave, and ask for a cap when the
owner says "as many as possible".

## Controller and wave-runner

Keep the controlling session's context clean. The controller picks the roster
and spawns **one wave-runner subagent per wave** (strong model), then reads its
short report. The controller does not code, review or apply fixes itself, even
when a finding looks small.

The wave-runner owns the whole wave: the `wave` bookkeeping, the worker
subagents, the merge and full suite, the reviewer, and the review's fixes. It
never asks the owner anything mid-wave. A bead that needs the owner is
**parked**: marked and commented with the question, left open, and the rest of
the wave finishes. Its final report (~200 words) gives the merged sha, suite
result, findings and fixes, and the parked beads with their questions.

## Rules

- **Backlog is `bd ready` by priority.** Don't invent a holding wave
  (`wave-anytime`) for beads you aren't working yet.
- **Always pass `model` explicitly** for each worker; an agent spawned without
  one inherits the session's. Match it to the bead: small and clear to a
  cheaper model, design judgment or a shared contract to a stronger one. The
  reviewer is at least as strong as the strongest worker.
- **Record via `wave`** (see `wave --help`): `wave show` first and pick an
  unused name, and run `wave check <name>` before calling a wave done.
  `wave drop` removes a wave made by mistake.

`reference.md` has the end-of-wave sweep and worktree traps; `history.md` is
the old long version of this skill, for grepping only.
