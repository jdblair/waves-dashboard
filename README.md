# waves

Tools for running and watching **bead-waves**: working a
[beads](https://github.com/gastownhall/beads) project's issues about five at a
time in parallel Claude Code subagents, reviewing each wave before the next.

Three parts, meant to be used together:

| Part | Path | What it does |
|------|------|--------------|
| `wave` CLI | `bin/wave` | Records wave facts in the project's beads: labels member beads `wave-<name>`, and writes `bd kv` keys `wave.<name>.title`, `.dispatched`, `.deployed`, and `.model.<bead id>`. kv touches no bead, so no `updated_at` is bumped. |
| waves-dashboard | `waves-dashboard.el` | `M-x waves-dashboard`: an Emacs view of a project's waves (beads, trunk merges, deploy, beads opened while each ran), or a chronological time spine (`t`). Read-only. |
| bead-waves skill | `skill/bead-waves/SKILL.md` | The Claude Code skill that runs waves and calls `wave` to record them. |

Design rationale and the bd behaviour found while building it are in
`NOTES-2026-W42.md`.

## Dependencies

- **bd** (the beads CLI, [gastownhall/beads](https://github.com/gastownhall/beads))
  on `PATH`. Developed against `bd version 1.2.2`; older versions are
  untested.
- **beads.el** ([r0man/beads.el](https://github.com/r0man/beads.el)),
  version 0.1.0, for the dashboard. It isn't on MELPA, so install it from
  GitHub before waves-dashboard (see [Install](#install)).
- **vui** ([d12frosted/vui.el](https://github.com/d12frosted/vui.el)),
  1.0.0 or later (a MELPA date version such as 20260902 satisfies this).
  It installs from MELPA automatically as a dependency.
- Emacs 29.1 or later (what beads.el and vui require; tested on 30.2).
- Python 3.7+ for `bin/wave` (standard library only).
- git, for the merge history the dashboard reads.

## Install

### Emacs: waves-dashboard as a VC package from GitHub

`use-package`'s `:vc` keyword (built into Emacs 30) clones the repository
into `package-user-dir`, byte-compiles it and generates its autoloads. That
is the whole install, and the clone itself isn't needed.

**Install beads.el first.** waves-dashboard declares its dependencies in
`Package-Requires` (`beads`, `vui`), but package.el can only fetch
dependencies from package archives. vui is on MELPA, so it comes
automatically. [beads.el](https://github.com/r0man/beads.el) is not on any
archive, so it needs its own `:vc` block, **placed before** waves-dashboard's.
beads.el keeps its sources in `lisp/`, hence `:lisp-dir`. Its own
dependencies (transient, sesman, vui) come from the archives. See its
[README](https://github.com/r0man/beads.el#readme) for its setup and
commands.

```elisp
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/"))
(package-initialize)

;; beads.el: not on MELPA, so from GitHub. Must come before waves-dashboard.
(use-package beads
  :vc (:url "https://github.com/r0man/beads.el" :lisp-dir "lisp" :rev :newest))

;; vui comes from MELPA as a declared dependency
(use-package waves-dashboard
  :vc (:url "https://github.com/jdblair/waves-dashboard" :rev :newest)
  :after beads)
```

With the blocks the other way round, the first start installs
waves-dashboard but warns `Failed to install the following dependencies:
beads` and `Cannot load waves-dashboard`. beads.el installs right after, and
from the next start on everything works. So the order only costs one
restart, but beads-first starts clean. Both orders were checked on a fresh
`package-user-dir` (Emacs 30.2). Skip the beads block if you already
install beads.el another way.

`:rev :newest` tracks the tip of the default branch (`trunk`). Without
it, package-vc installs the latest release: the last commit that changed the
`Version:` header.

The first start after adding this clones and builds, and later starts just
load the package. package.el also records it in `package-selected-packages`
and `package-vc-selected-packages` in your `custom-set-variables`, which is
normal for any VC package.

Long lines wrap to the window width, each continuation lined up under the
text it continues (an issue's title, a merge's subject). Set
`waves-dashboard-wrap` to nil to truncate lines instead. You don't need
`visual-line-mode`.

- **Use:** `M-x waves-dashboard` in a beads project (see
  [Reading the dashboard](#reading-the-dashboard)).
- **Upgrade:** `M-x package-vc-upgrade RET waves-dashboard`, or
  `M-x package-vc-upgrade-all`. A running Emacs keeps the old keymap after an
  upgrade (`defvar-keymap` doesn't redefine an existing map), and an open
  dashboard keeps running the code it was opened with, so restart Emacs
  after upgrading.
- **Check the install:** `M-x locate-library RET waves-dashboard` should
  point into `~/.emacs.d/elpa/waves-dashboard/`.
- **Uninstall:** `M-x package-delete RET waves-dashboard`, and remove the
  `use-package` block.
- **Emacs 29:** `use-package` has no `:vc` there. Install once by hand,
  beads.el first:
  `(package-vc-install '(beads :url "https://github.com/r0man/beads.el" :lisp-dir "lisp"))`,
  then `M-x package-vc-install RET https://github.com/jdblair/waves-dashboard`.
  Then use a plain `(use-package waves-dashboard :after beads)`.

### wave and the bead-waves skill

`wave` and the skill are not Emacs packages, so for those clone the
repository somewhere, e.g. `~/src/waves-dashboard`:

    git clone https://github.com/jdblair/waves-dashboard ~/src/waves-dashboard

**wave** — put it on `PATH`:

    ln -s ~/src/waves-dashboard/bin/wave ~/.local/bin/wave

**bead-waves skill** — link it into Claude Code's user skills:

    ln -s ~/src/waves-dashboard/skill/bead-waves ~/.claude/skills/bead-waves

**waves-dashboard from the local clone** — instead of GitHub, point
`use-package` at the clone:

```elisp
(use-package waves-dashboard
  :vc (:url "/home/you/src/waves-dashboard" :rev :newest)
  :after beads)
```

A local `:url` must be an absolute path: `"~/src/waves-dashboard"` fails
with "Empty checkout for waves-dashboard" (checked on Emacs 30.2).

This copies the clone into your package directory, so pick up later commits
with `M-x package-vc-upgrade`. To run straight from the working tree instead,
use `M-x package-vc-install-from-checkout` or plain `load-path`:

```elisp
(add-to-list 'load-path "~/src/waves-dashboard")
(autoload 'waves-dashboard "waves-dashboard" nil t)
```

## Reading the dashboard

`M-x waves-dashboard` opens the current project; with `C-u` it asks for one.
Keys: `t` switches between the per-wave view and the time spine, `T` cycles
the totals header (off, totals, totals by priority), `C` collapses and `E` expands all waves (`E` leaves each wave's
subsections at their defaults), and `1`/`2`/`3` set a fold level: wave
headers only, waves open with subsections folded, everything open. `e` swaps the
emoji state icons for text names (`[deployed]`, `[closed]`, `[in flight]`,
`[queued]`), `g` reloads, `a` toggles auto-refresh (every
`waves-dashboard-refresh-interval` seconds, 60 by default; only while the
buffer is visible), `RET` visits the bead at point, `q` quits.

Each wave's header shows its state:

| Icon | Header ends with | Meaning |
|------|------------------|---------|
| 🚀 | `· deployed <time> (<sha>)` | A deploy is recorded. |
| ✅ | `· all closed, no deploy` | Every bead with the wave's label is closed and nothing was deployed. |
| 🚧 | `· in flight` | Started (dispatched, merged, or a bead in progress or closed), but not all beads are closed. |
| 📋 | `· queued` | Beads are labelled, nothing has happened yet. |

A recorded deploy always wins, so a wave shows 🚀 even if some of its beads
are still open. A deploy time with a leading `~` has no kv record. It was
inferred from `Deployed … (trunk <sha>…)` close reasons and timed by the
wave's latest close.

"In flight" doesn't tell you why. The wave may still be being worked, or a
bead may have moved to a later wave and kept its old label (`wave dispatch`
adds labels and never removes them), or a bead may have been abandoned
open.

The dashboard does mark the second case. An open bead that also carries the
label of a *later* wave, one that's queued or in flight, is drawn dimmed in
the earlier wave (face `waves-dashboard-requeued`) with `→ wave-N` after it.
When every bead of a wave is closed or re-queued like this, the wave starts
collapsed and its header ends in `· re-queued`. Its state doesn't change. To
let an old wave finish properly, remove the old label from the beads that
moved on.

Inside an open wave there are three foldable parts (`RET`, `SPC` or a click
on the heading): the wave's own beads under its "Dispatched" or "First
merge" line, "Merges", and "Opened during the wave". Each starts folded when
everything in it is closed. Merges follow the wave's beads.

A wave's first line says when it started:

- **Dispatched <time>**: the `wave.<name>.dispatched` kv record that
  `wave dispatch` writes.
- **First merge <time> (no dispatch recorded)**: there is no dispatch
  record, so the start falls back to the earliest trunk merge belonging to
  the wave. That means a first-parent merge whose subject starts
  `Merge <ids>:` with one of those ids labelled for the wave. This start is
  always later than the real one, by however long the first agent took.

A missing dispatch record is normal for waves that ran before `wave` was
used: a backfill only fills facts with a source. On a new wave it means the
orchestrating session skipped `wave dispatch`.

"Opened during the wave" lists beads created between the wave's start and
its deploy (or its last close). A bead discovered-from one of the wave's
beads always counts. A bead labelled for some wave was filed as that wave's
work, so it doesn't count. When windows overlap, the latest-started wave
gets the bead.

## Development

    make test    # 11 ERT tests on synthetic fixtures (test/fixtures/)
    make check   # byte-compile with all warnings shown

Both take dependencies from `ELPA` (default `~/.emacs.d/elpa`), adding every
package directory plus `beads/lisp`, where beads.el keeps its sources. Override
`ELPA` or `LOAD_PATH` if yours live elsewhere.

## Known risk: beads.el private helpers

waves-dashboard renders with beads.el's own dashboard pieces, including
private (`--`) functions such as `beads-section--issue-line-vnode` and
`beads-dashboard--section-header`. That was a deliberate trade for the
identical look and little code, but a beads.el update may rename or remove
them without notice. `waves-dashboard--check-beads-api` warns at load time if
any are missing, and the `waves-dashboard-beads-api-present` test fails. Run
`make test` after upgrading beads.el.

## License

GPL-3.0-or-later. See `LICENSE`.
