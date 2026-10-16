# Dependencies (beads.el, vui and theirs) are taken from an Emacs package
# directory.  beads.el keeps its sources in lisp/, so that is added too.
EMACS ?= emacs
ELPA  ?= $(HOME)/.emacs.d/elpa
LOAD_PATH ?= $(foreach d,$(wildcard $(ELPA)/*/) $(wildcard $(ELPA)/beads/lisp/),-L $(d)) -L .

BATCH = $(EMACS) -Q --batch $(LOAD_PATH)

.PHONY: test check clean

test:
	@$(BATCH) -l test/waves-dashboard-test.el -f ert-run-tests-batch-and-exit

# Byte-compile with every warning shown; fails only on errors.  The .elc
# is removed afterwards so a stale one can never shadow the source.
check:
	@$(BATCH) --eval '(setq byte-compile-warnings t)' \
	  -f batch-byte-compile waves-dashboard.el
	@rm -f waves-dashboard.elc

clean:
	rm -f *.elc test/*.elc
