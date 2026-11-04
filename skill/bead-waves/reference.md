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

## Finding the real model registry (provider/id strings)

Skill text and this project's `bd remember` notes name models loosely
("gpt-5.6", "sonnet"). Turning that into an exact `provider/id` string that
actually resolves takes two steps, and skipping either one burns a wasted
dispatch (observed 2026-11-04: `nflx-openai/gpt-5.6-cyber` is listed in the
local cache but returns a live 404; `nflx-openai/gpt-5.6-sol` — the one
already recorded as `wave.1.model.review` — works).

1. **List what the session's own registry advertises:**
   `subagent({ action: "models" })` on pi. This is long (500+ entries) and
   gets truncated in the tool's own display; it has no query/filter option
   (`options.query`/`options.view` are rejected — don't try them). For a
   full-text search of one family, read the on-disk cache files directly
   instead of re-requesting the tool output:
   - `~/.pi/agent/models-store.json` — per-provider model id lists (e.g.
     `.openai.models[].id`) refreshed from each provider's own API.
   - `~/.pi/agent/models-netflix.json` — the Netflix gateway's declared
     provider prefixes (`nflx-openai`, `nflx-anthropic`, ...).
   - `~/.pi/agent/auth.json` — which provider keys are actually configured
     (confirms a provider is reachable at all before trying its models).

   ```bash
   python3 -c "
   import json
   d = json.load(open('/Users/jblair/.pi/agent/models-store.json'))
   ids = [m.get('id') if isinstance(m, dict) else m for m in d['openai']['models']]
   print([i for i in ids if '5.6' in i])
   "
   ```

2. **This list is the provider's catalog, not a promise the Netflix gateway
   (NCP) has wired that exact id up yet.** A name showing in
   `models-store.json` can still 404 with `ModelDefinitionNotFound` when
   dispatched. The only real confirmation is the 1-task dispatch the skill
   already requires before fanning out a wave (see Pi harness specifics):

   ```
   subagent({ agent: "scout", model: "nflx-openai/gpt-5.6-sol",
              task: "Reply with exactly the text 'model check ok' and nothing else." })
   ```

   A 404 `ModelDefinitionNotFound` means try a sibling id from the same
   family's list (`-cyber`, `-luna`, `-sol`, `-terra`, etc.) and re-probe;
   it does not mean the whole family is unavailable. Record the one that
   actually resolves with `wave model <name> <id> <model>` as usual — and
   prefer an id a prior wave already proved out (grep `bd kv list` for
   `wave.*.model.*` before probing from scratch; `gpt-5.6-sol` was already
   on record from a past reviewer assignment).

## Bookkeeping

Read issue IDs back from the create command's output before citing them in
a commit message; invented ones needed two amends. When an agent's report
corrects a premise you gave it, carry the correction into the commit message
and the issue.
