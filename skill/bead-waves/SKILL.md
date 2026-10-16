---
name: bead-waves
description: Close many issues in one session by working ~5 at a time in parallel subagents, then code-reviewing each wave before the next. Use when the owner asks to "work through beads", "close as many issues as you can", "run a wave", "keep going until I stop you", or otherwise wants sustained autonomous issue-clearing rather than one specific fix. Also use when asked to resume such work after it was stopped mid-flight.
---

# bead-waves

Triage ~5 issues → one agent each → coordinator runs the test suite once →
commit per issue → fresh agent reviews the wave → fix findings → next wave.
Invoking this skill is the grant of autonomy: pick the issues, commit,
close, continue. Say the picks and why, don't wait for approval.
`/bead-waves <ids...>` works those issues instead of triaging.

Everything below is a trap that has already cost something. The loop shape
is obvious; these are not.

**A project may add its own copy of this skill with local commands, costs
and incident history. A project copy SHADOWS this file, so it should tell
you to read this one too — if it doesn't, read both anyway.**

## Cost and stopping

Order of magnitude, measured on one real project: **~110k tokens per
issue**, heavily skewed — five small ones averaged 67k each while two big
ones cost 415k between them. **Prefer many small issues to one big one.**
Waves of pure tidies can skip the review (~150k); they can't regress much.

Stop: between waves, never mid-flight (a killed wave loses everything spent
on it); when triage turns up only trivia; when a review finds no
correctness defects, since the next one is insurance rather than value.
Treat a stated budget ("two waves") as binding. **"As many as possible" is
not a stopping rule**, and the owner's usage is invisible from here, so ask
for a cap when sustained work is implied.

## Where agents work

**Default: the shared main checkout, with the test command and all writing
git commands forbidden in the prompt.** Two suites in one checkout deadlock
whenever the tests need an exclusive resource — a database container, a
fixed port, a lock file — and N worktrees mean N copies of that resource,
which is its own failure mode (see your project's copy for what it
exhausted).

**But work done that way arrives unvalidated**, since the agent could not
run the suite. So an issue needing its own test loop — a migration, a
schema change, anything iterating against a database — gets a worktree
**from the start**. Deciding this late costs a full redo.

Create the worktree yourself at local `HEAD`:

```bash
git worktree add -b wip/<id> .claude/worktrees/<id> HEAD
```

**The harness's `isolation: "worktree"` branches from a PUSHED commit**, so
such an agent would not see this session's local commits — fatal when a
later issue builds on an earlier one. A worktree agent may run the suite
and commit to its own branch; never push, never merge. You merge `--no-ff`,
re-run the suite on the merged tree, then remove the worktree and sweep.

## Prompts

State the mechanism in full (don't make them re-derive the issue), name the
thing most likely to go wrong, say what is out of scope, and **authorise
"no"** — a well-evidenced "not safe to land, here's the blocker" is a good
outcome. In practice the best results came from agents that refused part of
a task with evidence, and the worst from briefs that told an agent what to
conclude instead of what to check.

Tell each agent which files another agent is touching concurrently, and ask
it to report exactly what it changed there. Two agents independently
editing one file is usually fine; two agents independently changing a
*contract* in the same file is a semantic conflict no textual merge catches,
and only the suite will find it.

## Agents talking to each other mid-wave

There is no bead-id → agent lookup, and agents can't list their siblings.
Two channels work today. Put both in every prompt of a wave where two
issues touch the same code.

**1. The bead is the mailbox.** To tell the agent working on another bead
something, comment on *that* bead:

```bash
bd comments add <their-id> "from <my-id>: <what changed>, <file:function>, <what they must do>"
bd comments <my-id>          # read what others left for me
```

Always give the message the sender's bead id, the exact file and symbol,
and whether it's a heads-up or a blocker. Comments are durable, so they also
leave a record of why two commits interact.

**2. Report to the coordinator** for anything that changes the plan. The
coordinator relays with `SendMessage` and decides conflicts. Agents can't
see each other's reports, only the coordinator can.

What to say, and when:

- **Same file, different code:** no message needed. Textual merges handle
  it. Just list the file in your report.
- **Same function or block:** comment on the other bead *before* editing,
  naming the lines you'll change. If both of you need the same lines, stop
  and report to the coordinator, who picks the order. Don't race.
- **A contract change** (a signature, return shape, config key, schema,
  route, or what a test fixture means): comment on every bead in the wave
  that might call it, and say so in your report. This is the semantic
  conflict no textual merge catches.
- **You found the other bead's premise wrong:** comment on it, and report.
  Don't fix their issue in your branch.

When to check your own bead's comments: right after starting, before
editing any file the prompt named as shared, and before writing your
report. There are no push notifications, so a message only works if it's
read at those points.

Two traps:

- **bd calls in one project contend for embedded Dolt's lock.** Keep
  messages to a few per agent, never poll in a loop, and retry once after a
  pause if a call hangs.
- **Worktree agents must address the main checkout's database**:
  `bd -C <main checkout> comments …`. A worktree's own `.beads/` may be a
  stale copy, and comments written there are lost.

The coordinator puts the wave's roster in each prompt: every bead id in the
wave, its one-line goal, and the files it's expected to touch. Without the
roster, an agent can't know whom to tell.

## Record the wave

Use the `wave` script (`wave` from this repo's bin/; install: see README)
for every wave, in the project's checkout. It writes the facts that the
owner's `M-x waves-dashboard` reads. Nothing else records them, so a skipped
call is a gap nobody can fill later.

```bash
wave dispatch <name> --title "<what the wave is>" <ids...>   # as agents start
wave deployed <name>                                       # right after the deploy
```

- `<name>` is the wave's label suffix: `wave-12` is named `12`. A
  one-issue wave can use the issue's short id (`wave-k3x`).
- **Don't run `bd label add` yourself.** `wave` labels only the beads
  that don't carry the label yet. A planned wave labelled earlier keeps its
  `updated_at`, and the dispatch time goes into `bd kv`, not onto any bead.
- To plan a wave ahead without starting it, use
  `wave plan <name> --title "…" <ids...>`.
- `wave deployed` takes the sha from trunk. Pass `--sha` if what was
  deployed isn't trunk's tip, and `--at <ISO with offset>` if you record it
  late. A guessed time is worse than a late, honest one, so say so in the
  wave's NOTES.
- A wave with nothing to deploy gets no `wave deployed`. Closing its beads
  is enough, and the dashboard shows it as done.
- The writes go to the Dolt working set. They're committed with the next
  `bd dolt commit`, like any other bd write.

## Review and merge

Tell the reviewer the suite passes, so it skips what tests already catch;
name the riskiest invariant first; ask for CONFIRMED vs PLAUSIBLE; ask it
to say plainly which commits are clean, and not to manufacture findings.

- **A test written against buggy behaviour pins the bug.** Ask for
  mutation-checked tests — break the fix, confirm the test goes red,
  restore. Report the mutation. Two regressions on one project shipped with
  *passing* tests, one of which asserted the bug was correct.
- **Pick an assertion's instrument by running the mutation**, not by
  reasoning about which is more precise. Both directions have shipped a
  test that could not fail: a UI-visibility assertion that passed with the
  guarded lines deleted because a parent was hidden anyway, and an
  own-property assertion that passed because every breakage path worked
  through an ancestor.
- **Never merge a change that makes a latent bug reachable**, even when a
  separate issue owns the fix. Fix it in the same branch.
- Ask specifically for what would **only fail in production**: a deployed
  config value, a route a deploy gate curls, an operator step nobody wrote
  down. Those are the findings a green suite cannot give you.

## End of each wave: sweep before starting the next

Shut down what the wave stopped using at the **end of each wave**, not at
session end. A session-end checklist is the floor, not the cadence.

Order matters, and each step is a check rather than a command:

1. **Confirm no test run is live.** Do not trust a bare process-name grep —
   see the waiter trap below, which makes that check lie in both
   directions. Match the actual interpreter invocation, or use a tool that
   probes a lock.
2. **Confirm merged before removing anything**: `git branch --merged <main>
   | grep wip/`.
3. Remove each merged worktree, then its per-worktree resources (container,
   volume, network). Prefer a project tool that removes by exact name after
   inspecting attachment counts over any blanket prune.
4. Keep the main checkout's own long-lived test resource. It is meant to
   survive.

**Never sweep mid-wave.** Agents in worktrees are deliberately reusing a
warm database, and a wrong guess looks like a broken test to another
session. Attachment counts and worktree existence are the evidence — not
age, and not a name looking stale.

## Harness traps that cost real time

**Orphaned background waiters.** An agent that abandons a background run
leaves an `until ...; do sleep N; done` shell polling a file nothing will
write. These don't appear in `ListAgents` and may not match a grep for your
test command — **look for what they wait on**:

```bash
ps -eo pid,ppid,etimes,args | grep -E "[u]ntil .*pgrep"
```

A waiter whose own `pgrep -f "<pattern>"` pattern appears in its own
command line **matches itself and can never exit**. Worse, it also makes
your own pre-sweep check lie: `pgrep -f <testcmd>` counts those waiters as
live test runs. Killing a waiter is safe — it does no work, and whatever it
waits on has already finished if the agent reported. Its `sleep` child
reparents to init and exits within one interval.

**A finished agent can keep burning tokens.** If the same task-notification
fires repeatedly for one agent and its reported token count **creeps up
between notices**, it is being re-invoked by its own leftover background
work, not merely re-reported. Stop it with `TaskStop`. Its delivered report
and committed branch are unaffected. Do this the first time the number
moves.

**When you stop an agent yourself**, check its branch before assuming the
work is lost — it may have committed already. You can also resume it with
`SendMessage` and ask for the report it never delivered; say that the stop
was your call, and ask it to state plainly what it had *not* finished.

## Bookkeeping

Read issue IDs back from the create command's output before citing them in
a commit message. Inventing plausible-looking ones needed two amends.

When an agent's report corrects a premise you gave it, carry the correction
into the commit message and the issue — a brief's wrong number otherwise
propagates into the permanent record.
