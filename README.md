# waves

Tools for running and watching **bead-waves**: working a
[beads](https://github.com/gastownhall/beads) project's issues about five at a
time in parallel Claude Code subagents, reviewing each wave before the next.

Three parts, meant to be used together:

| Part | Path | What it does |
|------|------|--------------|
| `wave` CLI | `bin/wave` | Records wave facts in the project's beads: labels member beads `wave-<name>`, and writes `bd kv` keys `wave.<name>.title`, `.dispatched`, `.deployed`. kv touches no bead, so no `updated_at` is bumped. |
| waves-dashboard | `waves-dashboard.el` | `M-x waves-dashboard`: an Emacs view of a project's waves (beads, trunk merges, deploy, beads opened while each ran), or a chronological time spine (`t`). Read-only. |
| bead-waves skill | `skill/bead-waves/SKILL.md` | The Claude Code skill that runs waves and calls `wave` to record them. |

Design rationale and the bd behaviour found while building it are in
`NOTES-2026-W42.md`.

## Dependencies

- **bd** (the beads CLI) on `PATH`. Developed against `bd version 1.2.2`;
  older versions are untested.
- **beads.el** ([r0man/beads.el](https://github.com/r0man/beads.el)),
  version 0.1.0, for the dashboard.
- **vui** ([d12frosted/vui.el](https://github.com/d12frosted/vui.el)),
  1.0.0 or later (a MELPA date version such as 20260902 satisfies this).
- Emacs 29.1 or later (what beads.el and vui require; tested on 30.2).
- Python 3.7+ for `bin/wave` (standard library only).
- git, for the merge history the dashboard reads.

## Install

### Emacs: waves-dashboard as a VC package from GitHub

`use-package`'s `:vc` keyword (built into Emacs 30) clones the repository
into `package-user-dir`, byte-compiles it and generates its autoloads. That
is the whole install, and the clone itself isn't needed. A complete init
file setup, including the dependencies:

```elisp
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/"))
(package-initialize)

;; vui comes from MELPA
(use-package vui :ensure t)

;; beads.el is not on MELPA, so install it from GitHub; its sources are in lisp/
(use-package beads
  :vc (:url "https://github.com/r0man/beads.el" :lisp-dir "lisp" :rev :newest))

(use-package waves-dashboard
  :vc (:url "https://github.com/jdblair/waves-dashboard" :rev :newest)
  :after beads)
```

Leave out the `vui` and `beads` blocks if you already install those another
way. `:rev :newest` tracks the tip of the default branch (`trunk`). Without
it, package-vc installs the latest release: the last commit that changed the
`Version:` header.

The first start after adding this clones and builds, and later starts just
load the package. package.el also records it in `package-selected-packages`
and `package-vc-selected-packages` in your `custom-set-variables`, which is
normal for any VC package.

- **Use:** `M-x waves-dashboard` in a beads project (see
  [Reading the dashboard](#reading-the-dashboard)).
- **Upgrade:** `M-x package-vc-upgrade RET waves-dashboard`, or
  `M-x package-vc-upgrade-all`. A running Emacs keeps the old keymap after an
  upgrade (`defvar-keymap` doesn't redefine an existing map), so restart
  Emacs to pick up new key bindings.
- **Check the install:** `M-x locate-library RET waves-dashboard` should
  point into `~/.emacs.d/elpa/waves-dashboard/`.
- **Uninstall:** `M-x package-delete RET waves-dashboard`, and remove the
  `use-package` block.
- **Emacs 29:** `use-package` has no `:vc` there. Run
  `M-x package-vc-install RET https://github.com/jdblair/waves-dashboard`
  once (and the same for beads.el, with its `lisp/` directory; see the
  `package-vc-selected-packages` docstring for `:lisp-dir`). Then use a plain
  `(use-package waves-dashboard :after beads)`.

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
the totals header (off, totals, totals by priority), `g` reloads (the buffer
does not refresh on its own), `RET` visits the bead at point, `q` quits.

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
open. To let an old wave finish, remove the old label from beads that moved
on.

Under the header, a wave's first line says when it started:

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
