---
name: bead-waves
description: Close many issues in one session by working up to 5 at a time in parallel subagents, merging and reviewing after every wave. Use when the owner asks to "work through beads", "close as many issues as you can", "run a wave", "plan the next N waves", or wants sustained autonomous issue-clearing. Also use to resume such work after it was stopped mid-flight.
---

# bead-waves

Close the beads that don't need a decision from the owner. Work at most 5 at a
time, each in its own subagent. After every wave, merge it and have a fresh
agent review it, fix what the review finds, then start the next wave.
Invoking this skill is the grant of autonomy: pick the beads, commit, close,
continue, and say what you picked and why. `/bead-waves <ids...>` works those
beads instead of picking.

You already know how to plan, parallelise and review. These are the only
constraints.

## Choosing work and models

- **Backlog is `bd ready`, by priority.** A wave is work being run, not a
  place to park it. Don't invent a holding wave (`wave-anytime` or the like)
  for beads you aren't working yet.
- **Skip beads that need the owner** (a decision, access, an open question).
  Say which and why.
- **Choose a model per bead, and always pass it explicitly**; an agent
  spawned without one inherits the session's model. Match the model to the
  bead: clear, small, well-described work to a cheaper model, design judgment
  or a shared contract or a write path to a stronger one. Escalate a bead
  that fails review or its tests. The whole palette is available, not just
  one vendor's; verify an unfamiliar model id with a 1-task dispatch first.
  A `model:*` label on a bead overrides your choice.
- **The reviewer is at least as strong as the strongest implementer.** Review
  waves that touch business rules, SQL, auth, ops, deploy or a write path;
  skip it for docs, research and small tidies.
- Prefer many small beads to one big one. Split along seams in different code.

## Running a wave

- Put in each agent's prompt: the mechanism in full, what's out of scope, the
  wave's roster (ids, goals, files), and that "not safe to land, here's the
  blocker" is an acceptable answer. Cap its final report at ~200 words.
- Agents run targeted tests only. You run the full suite once on the merged
  tree. Reviewers don't run the suite.
- Agents file anything found outside their bead with
  `bd create ... --deps discovered-from:<their-id>`.
- Never read a file over ~50 KB whole (grep headings, read the section).
- Stop between waves, never mid-wave. "As many as possible" is not a stopping
  rule: ask for a cap when sustained work is implied.

## Recording the wave

Use the `wave` script in the project's checkout; the dashboard reads only what
it writes. Run `wave --help` for the commands.

- **Pick an unused name.** `wave show` first; use the highest number plus one.
  `plan` and `dispatch` refuse an existing name.
- **Record as you go:** `wave dispatch`, `wave model` for each agent and the
  reviewer (id `review`), `wave usage` or `wave tokens` as each finishes,
  `wave review start/done`, `wave merge start/done`, `wave deployed`. Batch
  them into one Bash call.
- **Before calling a wave done, run `wave check <name>`.** It lists member
  beads not closed; a bead left in the wrong state by an agent holds the wave
  open and the reviewer won't always notice.
- **Remove waves you created by mistake or for testing** with `wave drop <name>`.
- Read issue ids back from `bd create` output before citing them in commits.

## Read when needed (`reference.md`, same directory)

End-of-wave sweep, worktree and stopped-agent traps, finding the real model
registry. `history.md` is the earlier long version of this skill (cost
analysis, pi agent and model names, the bead mailbox between agents, test
and review rules); grep it for a topic when you hit that trap, but it is not
required reading.
