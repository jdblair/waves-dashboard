# Dependencies (beads.el, vui and theirs) are taken from an Emacs package
# directory.  beads.el keeps its sources in lisp/, so that is added too.
# An installed waves-dashboard package is left out, and this checkout comes
# first: -L keeps its order, and the first directory with a match wins.
EMACS ?= emacs
ELPA  ?= $(HOME)/.emacs.d/elpa
DEPS  := $(filter-out $(ELPA)/waves-dashboard%,$(wildcard $(ELPA)/*/)) $(wildcard $(ELPA)/beads/lisp/)
LOAD_PATH ?= -L . $(foreach d,$(DEPS),-L $(d))

BATCH = $(EMACS) -Q --batch $(LOAD_PATH)
PYTHON ?= python3

.PHONY: test test-el test-wave check clean

test: test-el test-wave

test-el:
	@$(BATCH) -l test/waves-dashboard-test.el -f ert-run-tests-batch-and-exit

# bin/wave against a stub bd on PATH: no real beads database is touched.
test-wave:
	@$(PYTHON) -m unittest discover -s test -p 'test_*.py'

# Byte-compile with every warning shown; fails only on errors.  The .elc
# is removed afterwards so a stale one can never shadow the source.
check:
	@$(BATCH) --eval '(setq byte-compile-warnings t)' \
	  -f batch-byte-compile waves-dashboard.el
	@rm -f waves-dashboard.elc

clean:
	rm -f *.elc test/*.elc
	rm -rf test/__pycache__
