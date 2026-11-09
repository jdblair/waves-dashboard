---
name: bead-waves
description: Close many issues in one session by working up to 5 at a time in parallel subagents, merging and reviewing after every wave. Use when the owner asks to "work through beads", "close as many issues as you can", "run a wave", "plan the next N waves", or wants sustained autonomous issue-clearing. Also use to resume such work after it was stopped mid-flight.
---

# bead-waves

Close the beads that don't need a decision from the owner, at most 5 at a
time, one wave at a time. Invoking this skill is the grant of autonomy: pick
the beads, say what you picked and why, and continue. `/bead-waves <ids...>`
works those beads instead of picking.

## What the tooling already does

`wave-workflow.js` (this directory) is the wave-runner. One dispatch runs
claim -> parallel workers -> merge -> review -> fixes -> `wave check` ->
close as fixed stages; the file's header has a worked example.

```js
subagent({ workflow: "<abs path>/wave-workflow.js", args: {
  name, title, roster: [{ id, model, task }], skipReview, reviewModel } })
```

Leave it async: a workflow awaited with `async: false` cannot relay a child's
`contact_supervisor` question. Each worker runs in its own `worktree: true`
isolation (one writer per bead); that needs the repo checkout clean at
dispatch time (untracked files count) or the whole worker group is rejected
before any child starts, so commit or stash stray work first. The script
refuses a roster entry with no explicit model, gives every child the
host-zone and worktree-symlink rules, leaves parked beads open, and makes
the close stage run `wave check`. The
`wave` CLI (`wave --help`) owns the bookkeeping schema and refuses a name
that already has records. None of that belongs in a dispatch; each
`roster[].task` carries only that bead's cold-start brief — goal, files,
acceptance, and when to park.

## Yours to judge

- **Pick from `bd ready` by priority.** No holding wave for beads you aren't
  working yet.
- **Pick each bead's model.** Clear, contained work to a cheaper model;
  design judgment, a shared contract or a write path to a stronger one; the
  reviewer at least as strong as the strongest worker. Probe an unfamiliar
  id with a one-line `scout` dispatch first — a listed model can still 404.
- **Stay reachable while a wave runs** and answer its children through
  `subagent_supervisor`; host-zone (Postgres/Docker) runs need your zone.
  Don't code, review or apply fixes yourself, even when a finding looks
  small.
- **Stop between waves, never mid-wave.** A parked bead comes back in the
  wave's report with its question; that is the owner's decision point, not
  an interruption. Ask for a cap when the owner says "as many as possible".

## What no tool can reach

The workflow sandbox has no shell, so these stay with whoever has bash:

- **Sweep at the end of a wave, never mid-wave** — worktrees share a warm
  database. The evidence is `git branch --merged` plus worktree existence,
  not age: remove merged worktrees and their per-worktree container, volume
  and network by exact name, and keep the main checkout's. Run
  `rm <worktree>/ui/node_modules` (no trailing slash) before removing a
  worktree; `git worktree remove --force` follows a symlink and empties the
  main checkout's copy.
- **A child you stopped cannot be resumed.** `steer` a live one, `resume` a
  finished one. After a stop, read what it left uncommitted, then retry once
  with a fresh child told to judge that work against the brief; if the retry
  also fails, revert, leave the bead open with a comment, and tell the owner.

`history.md` is the old long version of this skill, for grepping only; the
`reference.md` it points at has been folded into this file.
