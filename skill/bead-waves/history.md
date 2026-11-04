---
name: bead-waves
description: Close many issues in one session by working ~5 at a time in parallel subagents, then code-reviewing each wave before the next. Use when the owner asks to "work through beads", "close as many issues as you can", "run a wave", "keep going until I stop you", or otherwise wants sustained autonomous issue-clearing rather than one specific fix. Also use when asked to resume such work after it was stopped mid-flight.
---

# bead-waves

Triage ~5 issues → one agent each (related small ones may share an agent) → coordinator runs the test suite once →
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

- **Model mix: default to `sonnet`; aim for 3 or 4 of every 5 beads on it**
  (owner, 2026-10-26; was 2 of 5). Median bead cost was 0.28M on sonnet
  against 1.02M on opus, and sonnet beads drew no more confirmed review
  findings. Use the stronger model only for the cases under Choosing a
  model, and escalate a sonnet bead that fails review or its tests. This
  ratio was measured on the Anthropic ladder only; once other providers are
  in rotation (see Choosing a model), re-check it against their real cost
  and defect data instead of assuming it still holds.
- **Review only risky waves.** Reviews found a real defect in 37 of 46
  waves (0.66M per defect), so they stay for any wave touching load or
  business rules, SQL, auth, ops, deploy or a write path. Skip the review
  for waves of only docs, research, specs, mockups or small UI tidies
  (~0.9M saved each). Do not review every second wave instead.
- **No separate fix agents.** Apply review fixes yourself (or send them back
  to the bead's own agent with SendMessage while its context is warm); fresh
  fix agents cost ~0.69M each, mostly re-reading code.
- **Recommend a restart: after 3 waves in one session, or once your context
  passes ~200k tokens (or the harness has compacted it once), whichever
  comes first.** Past ~200k each coordinator turn costs 30 to 40k. At the
  next wave boundary (never mid-wave), tell the owner plainly, with the
  reason, and offer the handoff: end-of-wave sweep done, beads synced, a
  short summary of what is merged, deployed, planned and waiting on the
  owner, so a new session can pick up from `bd` alone. Recommend once per
  boundary; the owner decides. **Batch bookkeeping**: one Bash call
  for several `wave` and `bd` commands, not one turn each (bookkeeping was
  22% of coordinator spend).
- **Split big beads** (owner, 2026-10-30): cache reads grow with turns times
  context, so one long agent costs more than the same work in small ones.
  Split along seams in different code (a file, a module, a layer), each piece
  with enough in its description that its agent needn't re-explore. For an
  unclear bead, make the first piece a research bead whose finding goes into
  the others' descriptions. Don't split pieces that read the same code; that
  repeats the reads, and grouping them back is the same as the big bead.
  **Dispatch sub-beads in the same wave only if they are independent** (no
  shared contract, none needs another's output); otherwise put each
  dependent piece in a later wave, after the one it needs has landed.
- **Agents hand back at ~150k context** with a report of
  what is left, rather than running to 300k+ (the top 10% of agents spent
  30% of agent tokens). Point agents at the functions they need in big files
  (`api.py`, `load.py`) instead of letting each re-read them whole.
- **Never read `docs/design/README.md` whole** (owner, 2026-10-26). It is
  ~274 KB, about 70k tokens, and costs more than the median bead. Put this in
  every agent and reviewer prompt: grep its headings, read only the section
  you edit or cite. The same goes for any file over ~50 KB.
- **Group related small beads into one agent** (owner, 2026-10-26). Two or
  three small beads on the same file or module go to one agent, sequentially,
  so they share one cold start instead of re-reading the same code. Record
  each bead's tokens with `wave tokens ... --add`. Do not group beads that
  need different models, or two that change the same contract. **Group only
  related beads** (owner, 2026-10-30): a chained bead B re-reads all of A's
  context on every turn, so an unrelated pair adds cache reads and saves
  almost no writes. Unrelated beads get separate fresh agents.
- **Short agent reports:** each agent's final report is at most ~200 words
  (see Prompts). The coordinator re-reads every report on every later turn.
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

- **Default `sonnet`:** a clear fix, rename, docs, a test for existing
  behaviour, a UI tidy, a change in one or two files, or anything with a
  concrete description. When in doubt, start on `sonnet` and escalate.
- **Stronger:** needs design judgment, touches several modules, changes a
  shared contract (signature, schema, route, signal shape) or a write path,
  or has a vague description.
- **A `model:cheap` or `model:strong` label on the bead overrides this.**
- **Escalate:** a cheap-model bead that fails review or its tests is
  re-queued on the stronger model.
- **The reviewer is always the stronger model**, or a cheap model's mistakes
  go unseen. **Cost cap (owner, 2026-10-19, widened 2026-11-03 to a $ ceiling
  once the palette crossed providers): a reviewer, primary or second
  opinion, costs no more than the median `wave usage ... review --cost`
  recorded for an Opus 5.5 review** (check `wave show` for the current
  figure; it was never a statement about Opus itself, just the strongest
  model the owner was willing to spend on a review). A name-based cap
  ("opus, sonnet, haiku") only worked while every option was Anthropic;
  once OpenAI and open-weight models are in rotation (see below) their
  pricing doesn't line up with Anthropic's tiers, so check the $ figure, not
  the model's name, before assigning a reviewer. Never guess a model is
  cheap because it sounds small (a vendor's "mini"/"nano"/"flash" tier isn't
  always cheaper than Anthropic's equivalent) — look up its real cost from a
  prior `wave usage` record, or from a 1-task probe, before trusting it as a
  reviewer.
  - **No Opus 5.5 `wave usage` record yet (a fresh project, or before this
    rule existed)?** The cap has nothing to compare against until one
    exists. Run one Opus 5.5 review as the baseline, record it with `wave
    usage <name> review --cost N ...`, and use that figure from then on; if
    spending on an Opus 5.5 baseline isn't wanted, ask the owner for an
    explicit $ ceiling instead of guessing one. Don't apply the cap against
    an assumed number.
  - **No eligible model fits under the cap** (the only stronger-tier
    options on hand all cost more than the ceiling)? Don't substitute a
    weaker primary reviewer to stay under budget — a cap is a ceiling on
    what the primary reviewer may cost, not license to downgrade which
    model reviews. Use the cheapest model that still qualifies as "the
    stronger model" for this wave, or ask the owner to raise the ceiling or
    skip the review (see Review only risky waves). A second opinion stays
    optional either way.
- **Choose for every bead, every wave** (owner, 2026-10-19). Many beads are
  `sonnet` work; running everything on the strongest model wastes the
  owner's usage. Say in the wave's picks which bead got which model.
- **Second opinions.** Where other models are available, use them for
  reviews and critiques where a differently trained reader helps: a second
  review of a risky wave, a critique of a design note or plan. Never let a
  second opinion replace the primary review. The same cost cap applies.
- **Deliberately rotate model families, not just providers within
  Anthropic** (owner, 2026-11-03). The point isn't only cost — it's
  building real quality-vs-cost data across the whole palette (see
  Tracking quality and cost over time, below). On a bead that's otherwise
  `sonnet`-shaped (clear scope, low blast radius, not a write or
  business-rule path), route some of them to a different family
  deliberately: OpenAI's line, an open-weight model, or Anthropic's Haiku
  tier, instead of defaulting to the same Anthropic model every time purely
  because it's familiar. Record the model and real usage/cost as usual
  (`wave model`, `wave usage`); the comparison only works if every bead's
  real model and cost are on the record, cheap and pricier alike. Don't
  rotate a bead that's already `cheap`/`strong`-labeled or that needs the
  stronger model's judgment — the point is to compare like-for-like work,
  not to run a risky bead on an unproven model to get a data point.

Always pass `model` explicitly: an agent spawned without one inherits the
session's model, so a session left on `sonnet` would silently run every bead
cheap. Record it with `wave model <name> <id> <model>` as you spawn each
agent (and again on a retry); the dashboard shows it beside the bead. If an
agent was spawned without a `model`, record the session's model with
`--inherited`, so the record says it was not a choice.

**Record the reviewer's model too, under the id `review`**: `wave model
<name> review <model>`, called when the reviewer is spawned (same call as
`wave review start`). This is not optional just because the reviewer isn't a
bead: the dashboard's cost cap check (reviewer no pricier than the recorded
Opus 5.5 figure) reads this field, and a review run without it recorded
looks like a gap no different from a skipped review when someone audits the
wave later.
Same rule for a second opinion: its own id (e.g. `review-2`), its own
`wave model` call.

## The real palette (not just Anthropic)

The conservative default above was written when the only models on hand
were Anthropic's. That's no longer true: a Netflix-gateway pi session like
this one also serves OpenAI's line (including reasoning tiers like o3/o4-
mini and newer non-numbered codenames such as `gpt-5.6-sol`/`gpt-5.6-terra`),
Gemini, and genuinely open-weight models (DeepSeek, GLM, Kimi, Nemotron,
`gpt-oss-120b`) through a Baseten-backed provider — on top of Anthropic's
own cheap tier, Haiku. Don't assume the palette is Anthropic-only just
because earlier waves only used it; check the registry (`subagent({ action:
"models" })` on pi, or equivalent) before defaulting back to the old habit.

- **The exact provider/id string is gateway-specific and must be verified,
  the same way agent names must be** (see Pi harness specifics, below) —
  the same trap, one more provider wide. A model that resolves under one
  provider prefix (`nflx-anthropic/claude-sonnet-5`) does not mean a
  same-named model resolves the same way under another provider's prefix;
  confirm with a 1-task dispatch before committing a whole bead to it.
- **"Open" and "cheap" are not the same axis as "weaker."** An open-weight
  model can be perfectly adequate for a `sonnet`-shaped bead (a clear fix,
  a rename, a docs change) at a fraction of the cost — that's exactly the
  kind of bead to use for deliberate rotation. It can also be a poor fit for
  anything needing the judgment calls Choosing a model reserves for the
  stronger tier; don't assume cheap-and-open is the same thing as
  narrow-but-safe.
- **Haiku is a real option for genuinely small beads** (a one-line fix, a
  skip/fake of a single test, a doc correction) — it was available under
  the conservative default too, just never used. Try it there before
  reaching for sonnet by habit.

## Tracking quality and cost over time

The point of widening the palette is to find out, over many waves, whether
a cheaper or different-family model gets comparably few post-merge bugs at
lower cost than Anthropic's ladder — not to decide this from one wave. Two
signals, both read from data `wave` already keeps or can keep:

- **Token/cost efficiency over time.** `wave usage`/`wave tokens` already
  records real cost per bead per model, forever, across every wave. The
  useful view is a rollup across *all* waves grouped by model, trended over
  calendar time, not a single wave's numbers — one wave's cost difference is
  noise; a trend across dozens is a signal. This is a dashboard/reporting
  concern, not something to compute by hand mid-wave.
- **Post-merge bugs, attributed back to the model that wrote the code.**
  When a later bead is a real regression in work this skill shipped, the
  normal `discovered-from` link (see Prompts) already lets the dashboard
  trace it back to the wave, and from there to `wave model <name> <id>`'s
  recorded model — but only when the regression was filed with that link.
  A regression found and fixed without going through that ceremony (a
  quick fix, a different session, a user report with no bead at all) won't
  show up that way. `git blame` on the fixed lines, read back to the
  introducing commit's bead id (commit messages already say `<id>: ...`),
  is a fallback that works from the commit history alone and catches what
  the bd link misses — at the cost of needing a human glance to confirm a
  commit is really a fix before counting it as one.
- **This is a slow signal by design.** Don't try to draw a conclusion from
  one wave's worth of rotated beads; keep recording model and real cost
  accurately so the dashboard has something to show once enough waves have
  landed. Treat an early read as a hypothesis, not a verdict.

## Pi harness specifics (agent and model names)

On pi (the `subagent`/`agent_team` tools), agent and model names are harness-
and gateway-specific, not the vendor names you'd guess from training data.
Two failure modes cost a whole wave's first launch attempt each (2026-10-31):

- **`agent:` is a role from the pi agent catalog, not a free-text label.**
  There is no `general` agent. Use `worker` for implementation beads,
  `reviewer` for the wave review (subject to the cost cap above), `scout` for
  quick recon, `researcher` for research-only beads. List the valid set with
  the tool's catalog/discovery action (or read the error: an unknown agent
  name returns the full valid list) before guessing.
- **`model:` must be a name the active gateway's registry actually serves**,
  not a vendor API id like `anthropic/claude-sonnet-4-5`. The registry is
  per-deployment (seen here: `nflx-anthropic/claude-sonnet-5`-style aliases
  behind a Netflix gateway, reachable by the bare alias `claude-sonnet-5`).
  Before the wave's first dispatch, check the session's own model alias
  (`echo $PI_MODEL`, or read it from the environment) and reuse that alias
  family for subagents instead of inventing a vendor string; if a dispatch
  fails with "Unknown subagent model", the error lists the closest real
  registry entries — use one of those, don't retry the same guess.
- **Verify both with a 1-task dispatch before fanning out 5.** A bad agent or
  model name fails every task in the wave identically and immediately (so no
  tokens are burned), but it still costs a full round trip per wrong guess,
  and a stale `agent_team`/`subagent` run's old failure notices can keep
  arriving after you've already relaunched correctly — match notices to the
  run id you're waiting on, not just the content, before reacting to them.
  **The local model-list cache can itself be wrong**: an id it lists can
  still 404 live (`ModelDefinitionNotFound`) if the gateway hasn't wired it
  up. See "Finding the real model registry" in `reference.md` for where to
  read the cache and how to probe it before committing a bead to it.
  (2026-11-04: `nflx-openai/gpt-5.6-cyber` was listed but 404'd;
  `nflx-openai/gpt-5.6-sol` worked and is the one already on record from a
  prior reviewer assignment.)
- **This applies per provider, not just once.** Confirming
  `nflx-anthropic/claude-sonnet-5` resolves says nothing about whether
  `nflx-openai/gpt-5.6-terra` or a Baseten-backed open model does; each
  provider prefix in the registry is its own namespace with its own exact
  id strings. Verify every new provider/family the first time it's used,
  not just the first model ever used in the session. (Observed here,
  2026-11-03: this gateway's Baseten-backed provider listed model ids that
  themselves contain a vendor/model path, e.g. `openai/gpt-oss-120b` — so
  don't assume a slash always separates provider from model on sight; check
  the registry's own id string for the provider in front of you rather than
  pattern-matching from another provider's convention.)

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
- **A test file that hangs, or a batch of failures that look infrastructural
  (a port, a container, a local server, a network dial), is not
  automatically "pre-existing" or "unrelated to this wave"** (owner,
  2026-10-30: a coordinator gave up on a hanging ops-script test file and
  called eight unrelated-looking failures "pre-existing environment
  issues" without checking; all nine passed once run with real
  infrastructure access, including tests directly relevant to a bead just
  closed in that same wave). Before reporting a gap in confidence or writing
  a failure off: confirm the actual root cause (what specifically is
  unavailable, not just that something looks environmental), and check
  whether the current execution context has ANY path to the needed
  capability (a different sandbox tier, a elevated runner, a flag, a
  teardown-and-retry) before accepting the gap as unfixable this session. A
  gap that turns out fixable costs one extra check; one that goes unchecked
  and is wrongly reported as fine, or wrongly written off as unrelated, costs
  the owner's trust in every other claim in the same report.

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

**Cap the report** (owner, 2026-10-26): tell each agent its final report is
at most ~200 words, in a fixed shape: files changed (flag any shared file or
contract), tests run and result, what is left or refused and why, anything
filed. No narration of steps; the diff is the record. Tell every agent not to
read `docs/design/README.md` whole: grep its headings and read only the
section it needs.

Tell agents to file anything they find outside their bead with
`bd create ... --deps discovered-from:<their-id>`. The dashboard lists under
"Opened by the wave" only beads carrying that link.

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

**Pick an unused wave name before dispatching (incident, 2026-11-03).** A
coordinator starting fresh in a project with wave history already past
wave-46 (plus lettered sub-waves and named waves) guessed `1` as a fresh
start and ran `wave dispatch 1 ...`. `wave dispatch` does not check for an
existing name: it silently overwrote that project's real wave-1's title and
dispatched timestamp (its review/merge sub-records, stored separately,
survived only because this coordinator's dispatch never touched those keys).
The damage was recoverable from `bd`'s Dolt history/git, but only because it
was caught by the owner, not by the tool. Before the first `wave dispatch` or
`wave plan` of a session in a project you have not just dispatched in
yourself: run `wave show` and take the highest numeric suffix across ALL
forms it prints (plain `wave-N`, lettered `wave-30a`, and named waves like
`wave-yrkj` do not count toward the numeric sequence, but make sure you are
reading the numeric ones, not a lettered or named one, as the ceiling) — or
`bd list --label wave-N` / `bd kv get wave.N.title` for a specific `N` you are
about to use, if `wave show`'s output is long — then dispatch at that number
plus one, never at a guessed small number and never at a name you have not
confirmed is unused. This holds even when the skill's own example shows
small names like `wave-12`: those are illustrations, not a suggestion to
restart numbering. If you ever discover you dispatched onto an existing
name by mistake, stop reusing that name immediately, move your own records
to a confirmed-free name (relabel the beads, and copy any kv keys you wrote
under the old name to the new one), and tell the owner what happened and
which name collided so they can decide whether to recover the original from
Dolt/git — don't try to silently reconstruct the original yourself, you do
not have its original title/ids once overwritten. **Tool gap worth raising**
with the `wave` script's maintainer: `wave dispatch`/`wave plan` could refuse
(or require `--force`) when the target name already has a `wave.<name>.title`
or `wave.<name>.dispatched` key, instead of overwriting silently — this skill
cannot fix that from here, only work around it by checking first.

```bash
wave dispatch <name> --title "<what the wave is>" <ids...>   # as agents start
wave model <name> <id> <model> [--inherited]                # as each agent (and the reviewer) spawns
wave review start <name>                                   # as the reviewer is spawned
wave review done <name> --findings N --fixed M             # its fixes are in, suites pass
wave merge start <name>                                    # before committing the wave
wave merge done <name>                                     # right after the commit
wave deployed <name>                                       # right after the push/deploy
wave tokens <name> <id> <count> [--add]                    # as each agent finishes
wave usage <name> <id> [--input N] [--output N]            # as each agent finishes,
           [--cache-read N] [--cache-write N]              # when the harness reports a
           [--cost N] [--turns N] [--add]                  # real input/output/cost split
wave plan <name> --title "…" <ids...>                      # plan ahead, don't start
```

- **Tokens.** When a bead's agent finishes, record its spend. If the harness
  only gives a single lump number (Claude Code's `total_tokens` or
  `subagent_tokens` from the task notification), know what it is: the
  agent's final context size, not its spend (real price-weighted cost was a
  median 4.75x that number), and the coordinator is not in it. Record it
  anyway, for comparison between beads: `wave tokens <name> <id> <count>`.
  If the harness instead reports a real input/output/cache-read/cache-write/
  cost breakdown (for example, a native per-child usage report), use
  `wave usage <name> <id> --input N --output N ...` instead: it is the more
  accurate record, and it rewrites `wave tokens`'s total from input+output so
  the dashboard's `$` view keeps working either way. Use `--add` on either
  command for a retry, an escalation or a fix round sent back to the same
  bead, so the recorded value is the bead's whole cost. Record
  the reviewer under the id `review` (`wave tokens <name> review <count>` or
  `wave usage <name> review --cost N ...`), and its model the same way as any
  bead's (`wave model <name> review <model>`, see Choosing a model) — the
  model call is not covered by `wave tokens`/`wave usage` and is easy to
  forget for a non-bead id, but the dashboard's reviewer-cost-cap check
  depends on it being there.
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

At the end of every wave, read "End of each wave: sweep" in `reference.md`
(same directory) and follow it. **Never sweep mid-wave**: agents in worktrees
are reusing a warm database.

## Harness traps

Read "Harness traps" in `reference.md` when a worktree is removed, an agent
looks stuck or keeps burning tokens, or an agent is stopped (by you or the
owner). Always `rm <worktree>/ui/node_modules` (no trailing slash) before
`git worktree remove`: a symlinked `node_modules` gets emptied in the main
checkout.

## Bookkeeping

Read "Bookkeeping" in `reference.md` before writing commit messages.
