// bead-waves wave-runner, as a reusable subagent workflow script.
//
// Replaces the old pattern of writing a long prose brief explaining the whole
// bead-waves protocol to one "wave-runner" subagent every time. This script
// encodes the stages (claim -> parallel workers -> merge -> review -> record)
// so a dispatch only needs to supply the roster.
//
// Usage from the controlling session, in the repo's cwd:
//
//   subagent({
//     workflow: "./wave-workflow.js",   // or an absolute path to this file
//     args: {
//       name: "wave-81",                // wave-<name>; `wave dispatch` refuses a used name
//       title: "UI 2: draft-drag bars, Launched chip in-field view, shift-click",
//       roster: [
//         { id: "ackbar-v3zt.1", model: "claude-opus-5",
//           task: "Implement ackbar-v3zt.1: <bead-specific brief>..." },
//         { id: "ackbar-i02c", model: "nflx-openai/gpt-5.6-sol",
//           task: "Implement ackbar-i02c: <bead-specific brief>..." },
//       ],
//       skipReview: false,              // true only when the wave plan says review is optional
//       reviewModel: "nflx-openai/gpt-5.6-sol",
//     },
//   });
//
// Leave the dispatch async (the default): a workflow awaited with
// `async: false` cannot relay a child's `contact_supervisor` question, so the
// host-zone hand-off below would fail with a transport error.
//
// Each roster[].task is still a full cold-start brief for that one bead (goal,
// files, acceptance, when to park) -- what this script removes is re-deriving
// and re-typing the wave *protocol* (claim, dispatch record, merge order,
// bookkeeping keys, review-or-skip, close-out) every time.
//
// Environment notes every bash-capable child needs are defined once below
// (HOST_ZONE_NOTE, WORKTREE_NOTE) and appended to each child's task, so a
// dispatch never has to restate them.
//
// The sandbox this script runs in has no filesystem/shell access -- every bd
// and wave CLI call happens inside a child step with bash tools, not here.
//
// Each worker gets worktree: true (one writer per cwd, no cross-bead file
// collisions while beads run in parallel). This needs the source checkout
// clean -- untracked files count -- at dispatch time: commit or stash any
// stray work in the repo before launching a wave, or the whole worker group
// is rejected before any child starts. Each worker still names its own
// branch inside its isolated worktree; worktrees share the main repo's git
// object store, so that branch and its commits are visible to the merge
// stage's `git merge` from the primary checkout once the worker finishes.

const name = args.name;
const roster = args.roster || [];
if (roster.length === 0) {
  throw new Error("wave-workflow: args.roster must list at least one {id, model, task}");
}
const unmodelled = roster.filter((r) => !r.id || typeof r.model !== "string" || !r.model.trim());
if (unmodelled.length > 0) {
  // A worker launched without an explicit model silently inherits the
  // controlling session's, so every bead would run on whatever that happens
  // to be instead of the model the wave plan chose for it.
  throw new Error(
    "wave-workflow: every roster entry needs an id and an explicit model; missing on: " +
      JSON.stringify(unmodelled.map((r) => r.id || r))
  );
}
const ids = roster.map((r) => r.id);
const idList = ids.join(" ");
const skipReview = !!args.skipReview;
const reviewModel = args.reviewModel || "nflx-openai/gpt-5.6-sol";
const HOST_ZONE_NOTE =
  "This sandbox's default/anonymous zone blocks local socket bind and Docker " +
  "(a sandbox capability limit, not a missing dependency). Postgres-backed tests " +
  "need zone_exec zone:\"host\", which you do NOT have. If you need a host-zone " +
  "pytest run, send the exact command to the controller with " +
  "contact_supervisor({reason:\"need_decision\"}) and wait for the relayed result -- " +
  "do not guess, skip, or treat a hang/no-docker message in your own zone as a real result.";
const WORKTREE_NOTE =
  "If you create a git worktree, never symlink node_modules (or any heavy directory) " +
  "into it from the main checkout: `git worktree remove --force` follows the link and " +
  "empties the main checkout's copy. Copy what you need instead, and run " +
  "`rm <worktree>/ui/node_modules` (no trailing slash) before removing the worktree.";

// Stage 1: claim the roster beads and record the wave's dispatch in bd kv.
const setup = await runs.run("setup", {
  agent: "worker",
  task:
    `In this repo, run exactly: \`wave dispatch ${name} ${idList}\`` +
    (args.title ? ` --title "${args.title}"` : "") +
    `. Then for each of these bead ids run \`bd update <id> --claim\`: ${idList}. ` +
    `Report the wave dispatch output and each claim's result. Do not touch any other bead or file.`,
});

// Stage 2: one worker per roster bead, in parallel, each on model r.model.
const workers = await runs.all(
  roster.map((r) => ({
    key: `work-${r.id}`,
    agent: "worker",
    model: r.model,
    worktree: true,
    // Optional per-bead override for a worker that needs more than the 30-minute
    // default (e.g. a retry of a bead that timed out once already). Omit for the
    // normal case.
    ...(r.timeoutMs ? { options: { timeoutMs: r.timeoutMs } } : {}),
    task:
      `${r.task}\n\nWhen the implementation is ready: commit it on its own short-lived branch ` +
      `(name it wip/${name}-${r.id}) rather than main, run the targeted tests for what you touched, ` +
      `and report the branch name, head sha, and a one-paragraph summary of the change and its tests. ` +
      `If this bead needs an owner decision you cannot reasonably default past, do not guess: ` +
      `comment the exact question on ${r.id} with `+ "\`bd comment " + `${r.id}`+ "\`" + `, leave it open, ` +
      `commit nothing, and report it as parked with the question. ${HOST_ZONE_NOTE} ${WORKTREE_NOTE}`,
  }))
);

const landed = [];
const parked = [];
workers.forEach((w, i) => {
  const r = roster[i];
  if (w.ok) landed.push({ ...r, result: w.output });
  else parked.push({ ...r, result: w.output });
});

// Stage 3: merge every landed worker's branch into main, in roster order, and
// record per-bead model usage. This step does NOT attempt a host-zone full
// suite itself (it cannot); it runs what it can in its own zone and reports
// exactly what host-zone command the controller should run before `wave merge
// done` is recorded.
const mergeTask =
  `Run \`wave merge start ${name}\`. Then, in this order, merge each of these branches into main ` +
  `(one at a time; resolve any conflict by reading both diffs, never by discarding either side ` +
  `silently -- if a conflict needs a judgment call you can't make safely, stop and report it instead ` +
  `of guessing): ${landed.map((l) => `wip/${name}-${l.id}`).join(", ")}. ` +
  `Delete each branch after a clean merge. For every one of these roster entries, after merging, run: ` +
  landed.map((l) => `\`wave model ${name} ${l.id} ${l.model}\``).join(" and ") +
  `. Run the full test suite in your own (anonymous) zone and report its result, then tell the ` +
  `controller the exact full-suite command to re-run in host zone (it has Postgres-backed tests that ` +
  `need real local networking) via contact_supervisor, and wait for the relayed result before treating ` +
  `the merge as verified. ${HOST_ZONE_NOTE} ${WORKTREE_NOTE} Report the merged head sha.`;

const merge =
  landed.length > 0
    ? await runs.run("merge", { agent: "worker", task: mergeTask })
    : { ok: false, output: "no worker landed a change; nothing to merge" };

// Stage 4: review, unless the wave plan says to skip it.
let review = null;
if (!skipReview && landed.length > 0) {
  review = await runs.run("review", {
    agent: "reviewer",
    model: reviewModel,
    task:
      `Review the wave-${name} merge just completed (merged sha reported in: ${JSON.stringify(merge.output).slice(0, 2000)}). ` +
      `Read the actual diff on main for each of these beads and check it against its stated goal: ` +
      JSON.stringify(landed.map((l) => ({ id: l.id, goal: l.task.slice(0, 300) }))) +
      `. Report findings as a list (file, line/area, concern, suggested fix) and your overall verdict ` +
      `(pass / pass-with-fixes-needed / concerns). Do not fix anything yourself in this step.`,
  });
}

// Stage 5: apply review fixes, if any were found, then record review/merge
// completion and close the landed beads. This step also runs with bash, so it
// does the actual `wave review done` / `wave merge done` / `bd close` calls.
const closeTask =
  `wave-${name} is merged. Review result: ${review ? JSON.stringify(review.output).slice(0, 3000) : "skipped per wave plan"}. ` +
  `If the review found fixable issues, fix them on main now (minimal, correct changes) and verify with the ` +
  `targeted tests plus your own zone's full suite; ask the controller via contact_supervisor for any host-zone ` +
  `verification you need, same as before. Then run \`wave review start ${name}\` and ` +
  `\`wave review done ${name} --findings N --fixed M\` with the real counts (skip the review commands entirely ` +
  `if review was skipped per plan). Run \`wave merge done ${name}\` (defaults to the current trunk/HEAD sha). ` +
  `Close each of these landed beads with \`bd close <id>\` and a close reason naming the wave and merged sha: ` +
  JSON.stringify(landed.map((l) => l.id)) +
  `. Do not touch the parked beads: ${JSON.stringify(parked.map((p) => p.id))} -- they stay open with their ` +
  `parked question already commented by the worker. ${HOST_ZONE_NOTE} ` +
  `Finally run \`wave check ${name}\` and quote its output verbatim in your report. It exits non-zero and ` +
  `lists any member bead that is not closed: the parked beads above are expected there, so do NOT close a ` +
  `bead just to make it pass -- an unexpected id in that list is a real gap, report it. ` +
  `Report back (~200 words): which beads closed, which stayed parked and why, the merged sha, the review ` +
  `verdict, the full-suite result, and the \`wave check\` output.`;

const close =
  landed.length > 0
    ? await runs.run("close", { agent: "worker", task: closeTask })
    : { ok: false, output: "nothing landed; nothing to close" };

return {
  name,
  landed: landed.map((l) => l.id),
  parked: parked.map((p) => ({ id: p.id, note: p.result })),
  setup: setup.output,
  merge: merge.output,
  review: review ? review.output : "skipped",
  close: close.output,
};
