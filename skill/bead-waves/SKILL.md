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

Measured on one real project: **~110k tokens per issue**, heavily skewed —
five small ones averaged 67k each, two big ones cost 415k between them.
**Prefer many small issues to one big one.** Waves of pure tidies can skip
the review (~150k).

**Token rules (owner, 2026-10-22, from a measured analysis of 46 reviewed
waves, 245 beads; one project's report: docs/notes/wave-token-analysis.md).**
A recent wave cost ~6.1M price-weighted tokens: implementation 58%,
coordinator 26%, review 10%, fix agents 5%. The levers, biggest first:

- **Model mix: aim for about 2 of every 5 beads on `sonnet`.** Median bead
  cost was 0.28M on sonnet against 1.02M on opus, and sonnet beads drew no
  more confirmed review findings. Saves ~1.0 to 1.4M per wave.
- **Review only risky waves.** Reviews found a real defect in 37 of 46
  waves (0.66M per defect), so they stay for any wave touching load or
  business rules, SQL, auth, ops, deploy or a write path. Skip the review
  for waves of only docs, research, specs, mockups or small UI tidies
  (~0.9M saved each). Do not review every second wave instead.
- **No separate fix agents.** Apply review fixes yourself (or send them back
  to the bead's own agent with SendMessage while its context is warm); fresh
  fix agents cost ~0.69M each, mostly re-reading code.
- **A fresh coordinator every 2 to 3 waves.** Past ~200k context each
  coordinator turn costs 30 to 40k; end the session (summary, beads synced)
  and let the owner start a new one. **Batch bookkeeping**: one Bash call
  for several `wave` and `bd` commands, not one turn each (bookkeeping was
  22% of coordinator spend).
- **Split big beads; agents hand back at ~150k context** with a report of
  what is left, rather than running to 300k+ (the top 10% of agents spent
  30% of agent tokens). Point agents at the functions they need in big files
  (`api.py`, `load.py`) instead of letting each re-read them whole.
- **Lean agent testing:** tail-only test output, one mutation per new
  assertion, and reviewers do not repeat the agent's mutations.

Stop between waves, never mid-flight (a killed wave loses everything spent
on it); when triage turns up only trivia; or when a review finds no
correctness defects, since the next one is insurance. Treat a stated budget
("two waves") as binding. **"As many as possible" is not a stopping rule**,
and the owner's usage is invisible from here, so ask for a cap when
sustained work is implied.

## Choosing a model

Pick a model per bead when you spawn its agent (the Agent tool's `model`).

- **Cheaper (`sonnet`):** small and well specified — a clear fix, rename,
  docs, a test for existing behaviour, a one-file change.
- **Stronger:** needs design judgment, touches several files or modules, or
  has a vague description. When in doubt, use the stronger one.
- **A `model:cheap` or `model:strong` label on the bead overrides this.**
- **Escalate:** a cheap-model bead that fails review or its tests is
  re-queued on the stronger model.
- **The reviewer is always the stronger model**, or a cheap model's mistakes
  go unseen. **Cost cap (owner, 2026-10-19): a reviewer, primary or second
  opinion, costs no more than Opus 5.5** (`opus`, `sonnet`, `haiku`). Never
  pass a pricier model such as `fable` for a review, even when it is the
  session's model; pass `opus` explicitly.
- **Choose for every bead, every wave** (owner, 2026-10-19). Many beads are
  `sonnet` work; running everything on the strongest model wastes the
  owner's usage. Say in the wave's picks which bead got which model.
- **Second opinions.** Where other models are available, use them for
  reviews and critiques where a differently trained reader helps: a second
  review of a risky wave, a critique of a design note or plan. Never let a
  second opinion replace the primary review. The same cost cap applies.

Always pass `model` explicitly: an agent spawned without one inherits the
session's model, so a session left on `sonnet` would silently run every bead
cheap. Record it with `wave model <name> <id> <model>` as you spawn each
agent (and again on a retry); the dashboard shows it beside the bead. If an
agent was spawned without a `model`, record the session's model with
`--inherited`, so the record says it was not a choice.

## Where agents work

**Default: the shared main checkout, with the test command and all writing
git commands forbidden in the prompt.** Two suites in one checkout deadlock
when the tests need an exclusive resource (a database container, a fixed
port, a lock file), and N worktrees mean N copies of it, which has its own
failure mode.

**But that work arrives unvalidated**, since the agent can't run the suite.
An issue needing its own test loop (a migration, a schema change, anything
iterating against a database) gets a worktree **from the start**; deciding
late costs a full redo. Create it yourself at local `HEAD`:

```bash
git worktree add -b wip/<id> .claude/worktrees/<id> HEAD
```

**The harness's `isolation: "worktree"` branches from a PUSHED commit**, so
that agent wouldn't see this session's local commits. A worktree agent may
run targeted tests (see Running tests) and commit to its own branch; never
push, never merge. You merge `--no-ff`, run the full suite once on the final
merged tree, then remove the worktree and sweep.

## Running tests

Suites cost minutes each and compete for the same database container, so
plan who runs what (owner, 2026-10-21; one wave ran the full suite in every
agent, again after each merge, again in review):

- **Agents run targeted tests only:** the test files for the code they
  touch, plus the dependents of any shared function or contract they change
  (grep for importers and callers, and name them in the prompt). They also
  run their own mutation checks. They do not run the full suite.
- **The coordinator runs the full suite once, on the final merged tree**,
  not after each branch merge. Run the ops or script suite only when `ops/`
  or the scripts changed, and the UI suite (`npm test`, `npm run build`)
  only when `ui/` changed. After review fixes: targeted tests in the fix
  branch, then one full run after the merge.
- **Reviewers do not run the suite.** Tell them it passes. They run only the
  test files they mutate or use to reproduce a finding.
- **The merged-tree run is the safety net** for cross-branch breakage, so
  never skip it. An agent changing a shared contract (a signature, a load
  field, a signal shape) must run the tests of every dependent it can find;
  a green targeted run does not prove the contract held.

## Prompts

State the mechanism in full (don't make them re-derive the issue), name the
thing most likely to go wrong, say what is out of scope, and **authorise
"no"** — a well-evidenced "not safe to land, here's the blocker" is a good
outcome. The best results came from agents that refused part of a task with
evidence, the worst from briefs that said what to conclude instead of what
to check.

Put the wave's roster in each prompt: every bead id, its one-line goal, and
the files it's expected to touch. Ask each agent to report exactly what it
changed in files others share. Two agents editing one file is usually fine;
two changing a *contract* in it is a semantic conflict no textual merge
catches, and only the suite will find it.

## Agents talking mid-wave

Agents can't list their siblings. Put both channels in every prompt of a
wave where two issues touch the same code.

**1. The bead is the mailbox.** Comment on the *other* agent's bead:

```bash
bd comments add <their-id> "from <my-id>: <what changed>, <file:function>, <what they must do>"
bd comments <my-id>          # read what others left for me
```

Give the sender's bead id, the exact file and symbol, and whether it's a
heads-up or a blocker.

**2. Report to the coordinator** for anything that changes the plan. Only
the coordinator sees all reports; it relays with `SendMessage` and decides
conflicts.

- **Same file, different code:** no message; list the file in your report.
- **Same function or block:** comment on the other bead *before* editing,
  naming the lines. If you both need them, stop and report; the coordinator
  picks the order.
- **A contract change** (signature, return shape, config key, schema,
  route, what a test fixture means): comment on every bead in the wave that
  might call it, and say so in your report.
- **The other bead's premise is wrong:** comment on it and report. Don't
  fix their issue in your branch.

There are no push notifications. Read your bead's comments right after
starting, before editing a shared file, and before writing your report.

- **bd calls contend for embedded Dolt's lock.** Few messages per agent,
  never poll, retry once after a pause if a call hangs.
- **Worktree agents must use the main checkout's database**:
  `bd -C <main checkout> comments …`. A worktree's `.beads/` may be a stale
  copy, and comments written there are lost.

## Record the wave

Use the `wave` script (this repo's bin/; install: see README) for every
wave, in the project's checkout. It writes what the owner's
`M-x waves-dashboard` reads; nothing else records it, so a skipped call is a
gap nobody can fill later.

```bash
wave dispatch <name> --title "<what the wave is>" <ids...>   # as agents start
wave review start <name>                                   # as the reviewer is spawned
wave review done <name> --findings N --fixed M             # its fixes are in, suites pass
wave merge start <name>                                    # before committing the wave
wave merge done <name>                                     # right after the commit
wave deployed <name>                                       # right after the push/deploy
wave tokens <name> <id> <count> [--add]                    # as each agent finishes
wave plan <name> --title "…" <ids...>                      # plan ahead, don't start
```

- **Tokens.** When a bead's agent finishes, record the `total_tokens` (or
  `subagent_tokens`) from its task notification. Know what it is: the
  agent's final context size, not its spend (real price-weighted cost was a
  median 4.75x that number), and the coordinator is not in it. Record it
  anyway, for comparison between beads: `wave tokens <name> <id> <count>`. Use `--add` for
  a retry, an escalation or a fix round sent back to the same bead, so the
  count is the bead's whole cost. The dashboard shows tokens on `$`. Record
  the reviewer under the id `review` (`wave tokens <name> review <count>`).
- **Review and merge phases.** Call `wave review start` when you spawn the
  reviewer, and `wave review done --findings N --fixed M` once its fixes are
  in and the suites pass (N: findings it reported, M: how many you fixed).
  Call `wave merge start` before committing the wave and `wave merge done`
  after the commit (it takes trunk's sha; `--sha` to override), then
  `wave deployed` after the push. A wave with no review simply skips
  `wave review`: `wave merge start` doesn't need one. `done` refuses
  without its `start`; starting a phase again overwrites it with a warning
  and clears its end. All take `--at <ISO with offset>` when recording late.

- `<name>` is the label suffix: `wave-12` is named `12`; a one-issue wave
  can use the issue's short id.
- **Don't run `bd label add` yourself.** `wave` labels only beads that
  don't carry the label yet.
- `wave deployed` takes the sha from trunk; pass `--sha` if something else
  was deployed, and `--at <ISO with offset>` if recording late. A guessed
  time is worse than a late, honest one; say so in the wave's NOTES.
- A wave with nothing to deploy gets no `wave deployed`; closing its beads
  is enough.
- Writes land in the Dolt working set and are committed with the next
  `bd dolt commit`.

## Review and merge

Record both phases (see Record the wave): `wave review start` /
`wave review done` around the review, `wave merge start` /
`wave merge done` around the commit.

Tell the reviewer the suite passes, so it skips what tests already catch
(and tell it not to run the suite: targeted files for mutations only);
name the riskiest invariant first; ask for CONFIRMED vs PLAUSIBLE; ask it
to say plainly which commits are clean, and not to manufacture findings.

- **A test written against buggy behaviour pins the bug.** Ask for
  mutation-checked tests: break the fix, confirm the test goes red, restore,
  and report the mutation. Choose an assertion's instrument by running the
  mutation, not by reasoning about precision; tests that could not fail have
  shipped both ways (a visibility check that passed because a parent was
  hidden anyway, an own-property check that passed through an ancestor).
- **Never merge a change that makes a latent bug reachable**, even when
  another issue owns the fix. Fix it in the same branch.
- Ask specifically for what would **only fail in production**: a deployed
  config value, a route a deploy gate curls, an unwritten operator step.
  A green suite can't give you these.

## End of each wave: sweep

Shut down what the wave stopped using at the end of each wave, not at
session end. **Never sweep mid-wave**: agents in worktrees are reusing a warm
database, and a wrong guess looks like a broken test to another session.
Worktree existence and attachment counts are the evidence, not age or a
stale-looking name.

1. **Confirm no test run is live.** A bare process-name grep lies (see the
   waiter trap); match the actual interpreter invocation, or probe a lock.
2. **Confirm merged**: `git branch --merged <main> | grep wip/`.
3. Remove each merged worktree, then its per-worktree resources (container,
   volume, network), by exact name; no blanket prune.
4. Keep the main checkout's long-lived test resource.

## Harness traps

**A symlink in a worktree can empty its target.** An agent that symlinks
`ui/node_modules` (or any heavy directory) from the main checkout into its
worktree puts the main copy at risk: `git worktree remove --force` followed
the link and emptied the main checkout's `node_modules` (restored with
`npm ci`). Before removing a worktree run `rm <worktree>/ui/node_modules`
(no trailing slash, so only the link goes), and tell agents to do the same
before they finish. For a deploy build, copy the built `ui/dist` into a
clean worktree instead of linking `node_modules`.

**Orphaned background waiters.** An agent that abandons a background run
leaves an `until ...; do sleep N; done` shell polling a file nothing will
write. They don't appear in `ListAgents`; look for what they wait on:

```bash
ps -eo pid,ppid,etimes,args | grep -E "[u]ntil .*pgrep"
```

A waiter whose own `pgrep -f "<pattern>"` appears in its own command line
matches itself and never exits, and `pgrep -f <testcmd>` counts it as a live
test run. Killing one is safe.

**A finished agent can keep burning tokens.** If one agent's
task-notification repeats and its token count **creeps up between notices**,
leftover background work is re-invoking it. `TaskStop` it the first time the
number moves; its report and branch are unaffected.

**When you stop an agent yourself**, check its branch first; it may have
committed. You can resume it with `SendMessage` and ask for the report it
never delivered, saying the stop was your call and asking what it had *not*
finished.

**When the owner stops an agent**, it cannot be resumed: `SendMessage`
refuses. Clean up and retry once with a fresh agent:

1. Look at what it left (`git status`, `git diff`, its branch or worktree).
   The work is uncommitted and untested; never commit it as is.
2. Spawn one fresh agent with the original brief plus: "a previous agent was
   stopped partway; its unverified changes are in these files; judge each part
   against the brief, keep what is right, fix or finish the rest". Name where
   it stopped if the notification says.
3. If the retry is stopped or fails too, don't spawn a third: revert or park
   the changes, leave the bead open with a comment, and tell the owner.

Ask the owner first only if the stop might have meant "don't do this at all"
rather than "not like this".

## Bookkeeping

Read issue IDs back from the create command's output before citing them in
a commit message; invented ones needed two amends. When an agent's report
corrects a premise you gave it, carry the correction into the commit message
and the issue.
