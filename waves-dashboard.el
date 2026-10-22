;;; waves-dashboard.el --- bead-waves timeline for a beads project -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John D. Blair
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: John D. Blair
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (vui "1.0.0") (beads "0.1.0"))
;; Keywords: tools, project
;; URL: https://github.com/jdblair/waves-dashboard

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.  See the LICENSE file.

;;; Commentary:

;; `M-x waves-dashboard' shows the bead-waves activity of the project at
;; `default-directory' (with \\[universal-argument], of a project you pick):
;; one collapsible section per wave with its beads, trunk merges, deploy and
;; the beads it opened, plus the queued waves.  `$' adds the
;; token counts: per bead and review, the grand total and each wave's.  `t' toggles to a
;; chronological time spine.
;;
;; Data, all read-only:
;;   - membership: `wave-<name>' bead labels;
;;   - wave facts: bd kv keys wave.<name>.title / .dispatched / .deployed,
;;     the review and merge phases (.review.started / .review.finished /
;;     .merge.started / .merge.completed), wave.<name>.model.<bead id> and
;;     wave.<name>.tokens.<bead id>,
;;     written by the `wave' script (bin/wave in this repo);
;;   - merges: `git log --first-parent --merges' subjects naming bead ids;
;;   - fallback deploy for waves with no kv record: "Deployed ... (trunk SHA"
;;     close reasons, timed by the latest close (shown with ~).
;;
;; Rendering reuses beads' own dashboard pieces, private ones included
;; (`beads-section--issue-line-vnode', `beads-dashboard--section-header').
;; `waves-dashboard--check-beads-api' warns at load time if an update to
;; the beads package removes them.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'iso8601)
(require 'project)
(require 'vui)
(require 'beads-section)
(require 'beads-dashboard)

(declare-function beads-show "beads-command-show")

(defgroup waves-dashboard nil
  "Bead-waves timeline dashboard."
  :group 'beads)

(defcustom waves-dashboard-expanded-shipped 3
  "Number of most recent shipped waves shown expanded by default."
  :type 'integer)

(defcustom waves-dashboard-merge-history "90 days ago"
  "How far back `git log' looks for merge commits."
  :type 'string)

(defcustom waves-dashboard-wrap t
  "Non-nil wraps long lines to the window width.
Each continuation lines up under the text it continues: an issue's
title, a merge's subject, an event's text.  Nil truncates lines."
  :type 'boolean)

(defcustom waves-dashboard-refresh-interval 60
  "Seconds between reloads while auto-refresh (\\`a') is on."
  :type 'integer)

(defface waves-dashboard-requeued
  '((t :inherit shadow))
  "Face for a bead that has moved on to a later wave.")

(defface waves-dashboard-totals
  '((t :inherit font-lock-function-name-face))
  "Face for the totals header toggled with \\`T' and for token counts.")

(defface waves-dashboard-detail
  '((t :inherit font-lock-type-face))
  "Face for secondary details: a wave's dispatch or first-merge line,
the bead an opened bead was discovered from, and the key hints.")

;;; Beads API guard

(defconst waves-dashboard--beads-api
  '(beads-section--issue-line-vnode
    beads-section--plain-button
    beads-section--propertize
    beads-dashboard--section-header
    beads-dashboard--empty-line
    beads-dashboard--error-line
    beads-dashboard--loading-line
    beads-dashboard--bump
    beads-from-json
    beads-thing-propertize)
  "Beads functions, several private, that this file depends on.")

(defun waves-dashboard--check-beads-api ()
  "Return the beads functions this file needs that are missing.
Warn about them, so a beads package update that renames one shows
up when this file loads rather than as a broken buffer."
  (let ((missing (cl-remove-if #'fboundp waves-dashboard--beads-api)))
    (when missing
      (display-warning 'waves-dashboard
                       (format "beads no longer provides: %s"
                               (mapconcat #'symbol-name missing ", "))))
    missing))

(waves-dashboard--check-beads-api)

;;; Model

(cl-defstruct (waves-dashboard-wave
               (:constructor waves-dashboard-wave--make)
               (:copier nil))
  "One wave: its recorded facts and what the data says happened."
  name title dispatched deployed deployed-approx sha
  review-started review-finished findings fixed
  merge-started merge-completed merge-sha
  beads merges opened state start end requeued models tokens)

(defconst waves-dashboard--states
  '((shipped   "🚀" "[deployed]"  "shipped")
    (merged    "📦" "[merged]"    "merged")
    (merging   "🔀" "[merging]"   "merging")
    (reviewed  "📝" "[reviewed]"  "reviewed")
    (in-review "🔍" "[in review]" "in review")
    (done      "✅" "[closed]"    "done")
    (in-flight "🚧" "[in flight]" "in flight")
    (queued    "📋" "[queued]"    "queued"))
  "Wave states in precedence order, as (STATE EMOJI TEXT TOTALS-LABEL).
EMOJI and TEXT are the header icons (\\`e' switches between them),
TOTALS-LABEL names the state in the totals header.")

(defconst waves-dashboard--active-states '(queued in-flight in-review reviewed merging)
  "States of a wave that has not finished: not merged, done or shipped.
An open bead that also carries the label of a later wave in one of
these states has moved on to that wave.")

(defun waves-dashboard--time (s)
  "Return ISO-8601 string S as a float time, or nil."
  (when (and (stringp s) (not (string-empty-p s)))
    (ignore-errors (float-time (encode-time (iso8601-parse s))))))

(defun waves-dashboard--json (text)
  "Parse TEXT as JSON into alists and lists, nil for empty output."
  (if (string-blank-p text)
      nil
    (let ((json-object-type 'alist)
          (json-array-type 'list)
          (json-key-type 'symbol))
      (json-read-from-string text))))

(defun waves-dashboard--parse-merges (text)
  "Parse git log TEXT of SHA TAB ISO-DATE TAB SUBJECT lines."
  (cl-loop for line in (split-string text "\n" t)
           for f = (split-string line "\t")
           when (= (length f) 3)
           collect (list :sha (nth 0 f)
                         :time (waves-dashboard--time (nth 1 f))
                         :subject (nth 2 f))))

(defun waves-dashboard--subject-ids (subject known)
  "Return the bead ids in merge SUBJECT that are keys of hash table KNOWN.
Only subjects of the form \"Merge <ids>[: text]\" count, and only the
ids before the colon: other merges into trunk merely mention beads."
  (let ((pos 0) ids)
    (setq subject (if (string-match "\\`Merge \\([^:]*\\)" subject)
                      (match-string 1 subject)
                    ""))
    (while (string-match
            "\\_<\\([a-z][a-z0-9]*-[a-z0-9]+\\(?:\\.[0-9]+\\)*\\)\\_>"
            subject pos)
      (let ((id (match-string 1 subject)))
        (when (and (gethash id known) (not (member id ids)))
          (push id ids)))
      (setq pos (match-end 0)))
    (nreverse ids)))

(defun waves-dashboard--wave-labels (issue)
  "Return the wave names from ISSUE's `wave-' labels."
  (cl-loop for l in (alist-get 'labels issue)
           when (string-prefix-p "wave-" l)
           collect (substring l 5)))

(defun waves-dashboard--name< (a b)
  "Order wave names A and B numerically when both are numbers."
  (let ((na (and (string-match-p "\\`[0-9]+\\'" a) (string-to-number a)))
        (nb (and (string-match-p "\\`[0-9]+\\'" b) (string-to-number b))))
    (cond ((and na nb) (< na nb))
          (na t)
          (nb nil)
          (t (string< a b)))))

(defun waves-dashboard--apply-kv (wave key value)
  "Store the kv fact KEY with VALUE on WAVE.
KEY is title, dispatched, deployed, review.started, review.finished,
merge.started or merge.completed."
  (pcase key
    ("title" (setf (waves-dashboard-wave-title wave) value))
    ("dispatched"
     (setf (waves-dashboard-wave-dispatched wave)
           (waves-dashboard--time value)))
    ("deployed"
     (let ((parts (split-string value " " t)))
       (setf (waves-dashboard-wave-deployed wave)
             (waves-dashboard--time (car parts))
             (waves-dashboard-wave-sha wave) (cadr parts))))
    ("review.started"
     (setf (waves-dashboard-wave-review-started wave)
           (waves-dashboard--time (car (split-string value " " t)))))
    ("review.finished"
     (let ((parts (split-string value " " t)))
       (setf (waves-dashboard-wave-review-finished wave)
             (waves-dashboard--time (car parts)))
       (dolist (p (cdr parts))
         (when (string-match "\\`\\(findings\\|fixed\\)=\\([0-9]+\\)\\'" p)
           (let ((n (string-to-number (match-string 2 p))))
             (if (equal (match-string 1 p) "findings")
                 (setf (waves-dashboard-wave-findings wave) n)
               (setf (waves-dashboard-wave-fixed wave) n)))))))
    ("merge.started"
     (setf (waves-dashboard-wave-merge-started wave)
           (waves-dashboard--time (car (split-string value " " t)))))
    ("merge.completed"
     (let ((parts (split-string value " " t)))
       (setf (waves-dashboard-wave-merge-completed wave)
             (waves-dashboard--time (car parts))
             (waves-dashboard-wave-merge-sha wave) (cadr parts))))))

(defun waves-dashboard--fallback-deploy (wave)
  "Infer WAVE's deploy from \"Deployed ...\" close reasons."
  (let (latest sha)
    (dolist (b (waves-dashboard-wave-beads wave))
      (let ((reason (or (alist-get 'close_reason b) "")))
        (when (string-match-p "\\`Deployed\\b" reason)
          (let ((t1 (waves-dashboard--time (alist-get 'closed_at b))))
            (when (and t1 (or (null latest) (> t1 latest)))
              (setq latest t1)))
          (when (and (null sha)
                     (string-match "trunk \\([0-9a-f]\\{7,40\\}\\)" reason))
            (setq sha (match-string 1 reason))))))
    (when latest
      (setf (waves-dashboard-wave-deployed wave) latest
            (waves-dashboard-wave-deployed-approx wave) t)
      (unless (waves-dashboard-wave-sha wave)
        (setf (waves-dashboard-wave-sha wave) sha)))))

(defun waves-dashboard--settle (wave)
  "Fill in WAVE's start, end and state from its facts and beads."
  (let* ((beads (waves-dashboard-wave-beads wave))
         (statuses (mapcar (lambda (b) (alist-get 'status b)) beads))
         (all-closed (and beads (cl-every (lambda (s) (equal s "closed"))
                                          statuses)))
         (merge-times (delq nil (mapcar (lambda (m) (plist-get m :time))
                                        (waves-dashboard-wave-merges wave))))
         (close-times (delq nil (mapcar (lambda (b)
                                          (waves-dashboard--time
                                           (alist-get 'closed_at b)))
                                        beads))))
    (unless (waves-dashboard-wave-deployed wave)
      (waves-dashboard--fallback-deploy wave))
    (setf (waves-dashboard-wave-start wave)
          (or (waves-dashboard-wave-dispatched wave)
              (and merge-times (apply #'min merge-times))))
    (setf (waves-dashboard-wave-end wave)
          (or (waves-dashboard-wave-deployed wave)
              (and all-closed close-times (apply #'max close-times))))
    ;; Most advanced first; keep in step with `waves-dashboard--states'.
    (setf (waves-dashboard-wave-state wave)
          (cond ((waves-dashboard-wave-deployed wave) 'shipped)
                ((waves-dashboard-wave-merge-completed wave) 'merged)
                ((waves-dashboard-wave-merge-started wave) 'merging)
                ((waves-dashboard-wave-review-finished wave) 'reviewed)
                ((waves-dashboard-wave-review-started wave) 'in-review)
                (all-closed 'done)
                ((or (waves-dashboard-wave-start wave)
                     (cl-some (lambda (s) (member s '("in_progress" "closed")))
                              statuses))
                 'in-flight)
                (t 'queued)))))

(defun waves-dashboard--discovered-from (issue)
  "Return the ids ISSUE was discovered from."
  (cl-loop for d in (alist-get 'dependencies issue)
           when (equal (alist-get 'type d) "discovered-from")
           collect (alist-get 'depends_on_id d)))

(defun waves-dashboard--assign-opened (waves wave-of created)
  "Attach each CREATED issue to the wave in WAVES that opened it.
A bead counts only when it has a discovered-from link to one of a
wave's beads, which is how an agent files what it found while working.
Beads added by hand, even during a wave, are not attributed to it.
WAVE-OF maps bead ids to wave names."
  (let ((by-name (make-hash-table :test 'equal)))
    (dolist (w waves) (puthash (waves-dashboard-wave-name w) w by-name))
    (dolist (c created)
      (let* ((linked (cl-loop for src in (waves-dashboard--discovered-from c)
                              thereis (car (gethash src wave-of))))
             (target (and linked (gethash linked by-name))))
        (when target
          (push c (waves-dashboard-wave-opened target)))))
    (dolist (w waves)
      (setf (waves-dashboard-wave-opened w)
            (nreverse (waves-dashboard-wave-opened w))))))

(defun waves-dashboard--fmt-tokens (n)
  "Format token count N compactly: 950, 67k, 1.2M."
  (cond ((< n 1000) (format "%d" n))
        ((< n 999500) (format "%dk" (round n 1000)))
        (t (format "%.1fM" (/ n 1e6)))))

(defun waves-dashboard--model (issues kv merges created)
  "Build the list of waves from bd and git data.
ISSUES are wave-labelled beads, KV the bd kv alist, MERGES parsed
merge commits, CREATED the beads to search for ones a wave opened.
Running and shipped waves come newest first, queued ones after."
  (let ((table (make-hash-table :test 'equal))
        (wave-of (make-hash-table :test 'equal)))
    (cl-flet ((wave (name)
                (or (gethash name table)
                    (puthash name (waves-dashboard-wave--make :name name)
                             table))))
      (dolist (is issues)
        (dolist (name (waves-dashboard--wave-labels is))
          (push is (waves-dashboard-wave-beads (wave name)))
          (push name (gethash (alist-get 'id is) wave-of))))
      (dolist (pair kv)
        (let ((k (format "%s" (car pair))))
          (cond
           ((string-match
             (concat "\\`wave\\.\\(.+\\)\\."
                     "\\(title\\|dispatched\\|deployed"
                     "\\|review\\.started\\|review\\.finished"
                     "\\|merge\\.started\\|merge\\.completed\\)\\'")
             k)
            (waves-dashboard--apply-kv (wave (match-string 1 k))
                                       (match-string 2 k)
                                       (format "%s" (cdr pair))))
           ((string-match "\\`wave\\.\\(.+?\\)\\.model\\.\\(.+\\)\\'" k)
            (push (cons (match-string 2 k) (format "%s" (cdr pair)))
                  (waves-dashboard-wave-models (wave (match-string 1 k)))))
           ((string-match "\\`wave\\.\\(.+?\\)\\.tokens\\.\\(.+\\)\\'" k)
            (let ((n (format "%s" (cdr pair))))
              (when (string-match-p "\\`[0-9]+\\'" n)
                (push (cons (match-string 2 k) (string-to-number n))
                      (waves-dashboard-wave-tokens (wave (match-string 1 k))))))))))
      (dolist (m merges)
        (let* ((ids (waves-dashboard--subject-ids (plist-get m :subject)
                                                  wave-of))
               (names (delete-dups
                       (cl-loop for id in ids append (gethash id wave-of)))))
          (dolist (name names)
            (push (append m (list :ids ids))
                  (waves-dashboard-wave-merges (wave name)))))))
    (let ((waves (hash-table-values table)))
      (dolist (w waves)
        (setf (waves-dashboard-wave-beads w)
              (sort (waves-dashboard-wave-beads w)
                    (lambda (a b)
                      (let ((pa (or (alist-get 'priority a) 9))
                            (pb (or (alist-get 'priority b) 9)))
                        (if (= pa pb)
                            (string< (alist-get 'id a) (alist-get 'id b))
                          (< pa pb)))))
              (waves-dashboard-wave-merges w)
              (sort (waves-dashboard-wave-merges w)
                    (lambda (a b) (< (or (plist-get a :time) 0)
                                     (or (plist-get b :time) 0)))))
        (waves-dashboard--settle w))
      (waves-dashboard--assign-opened waves wave-of created)
      (waves-dashboard--mark-requeued waves)
      (let ((active (cl-remove-if (lambda (w) (eq (waves-dashboard-wave-state w)
                                                  'queued))
                                  waves))
            (queued (cl-remove-if-not
                     (lambda (w) (eq (waves-dashboard-wave-state w) 'queued))
                     waves)))
        (append
         (sort active (lambda (a b)
                        (> (or (waves-dashboard-wave-start a)
                               (waves-dashboard-wave-end a) 0)
                           (or (waves-dashboard-wave-start b)
                               (waves-dashboard-wave-end b) 0))))
         (sort queued (lambda (a b)
                        (waves-dashboard--name< (waves-dashboard-wave-name a)
                                                (waves-dashboard-wave-name b)))))))))

;;; Re-queued beads

(defun waves-dashboard--later-p (a b)
  "Non-nil when wave B comes after wave A.
A wave that hasn't started comes after every started one; equal
starts, or two unstarted waves, are ordered by name."
  (let ((sa (waves-dashboard-wave-start a))
        (sb (waves-dashboard-wave-start b)))
    (cond ((and sa sb (/= sa sb)) (> sb sa))
          ((and sa (null sb)) t)
          ((and (null sa) sb) nil)
          (t (waves-dashboard--name< (waves-dashboard-wave-name a)
                                     (waves-dashboard-wave-name b))))))

(defun waves-dashboard--mark-requeued (waves)
  "Record on each of WAVES which of its open beads moved to a later wave.
A bead is re-queued when it is not closed and also carries the label
of a later wave that hasn't finished (see
`waves-dashboard--active-states').  Sets each wave's `requeued' slot
to an alist of bead id . later wave name, naming the latest such
wave."
  (let ((by-name (make-hash-table :test 'equal)))
    (dolist (w waves) (puthash (waves-dashboard-wave-name w) w by-name))
    (dolist (w waves)
      (let (marks)
        (dolist (b (waves-dashboard-wave-beads w))
          (unless (equal (alist-get 'status b) "closed")
            (let (target)
              (dolist (name (waves-dashboard--wave-labels b))
                (let ((other (gethash name by-name)))
                  (when (and other (not (eq other w))
                             (memq (waves-dashboard-wave-state other)
                                   waves-dashboard--active-states)
                             (waves-dashboard--later-p w other)
                             (or (null target)
                                 (waves-dashboard--later-p target other)))
                    (setq target other))))
              (when target
                (push (cons (alist-get 'id b) (waves-dashboard-wave-name target))
                      marks)))))
        (setf (waves-dashboard-wave-requeued w) (nreverse marks))))))

(defun waves-dashboard--all-requeued-p (w)
  "Non-nil when every bead of wave W is closed or re-queued.
At least one has to be re-queued."
  (let ((marks (waves-dashboard-wave-requeued w)))
    (and marks
         (cl-every (lambda (b)
                     (or (equal (alist-get 'status b) "closed")
                         (assoc (alist-get 'id b) marks)))
                   (waves-dashboard-wave-beads w)))))

;;; Bead sort

(defconst waves-dashboard--sort-keys
  '(priority id type status title model tokens)
  "Bead sort keys in the order `s' cycles through them.")

(defun waves-dashboard--sort-value (w b key)
  "Return bead B's sort value in wave W for KEY: a number or a string."
  (let ((id (alist-get 'id b)))
    (pcase key
      ('priority (or (alist-get 'priority b) 9))
      ('id (or id ""))
      ('type (or (alist-get 'issue_type b) ""))
      ('status (or (alist-get 'status b) ""))
      ('title (downcase (or (alist-get 'title b) "")))
      ('model (or (cdr (assoc id (waves-dashboard-wave-models w))) "~"))
      ('tokens (or (cdr (assoc id (waves-dashboard-wave-tokens w))) -1)))))

(defun waves-dashboard--sorted-beads (w key reverse)
  "Return wave W's beads sorted by KEY (nil keeps the model's order),
REVERSE flipping it.  Ties fall back to the model's order (priority,
then id), so the result is stable."
  (let ((beads (copy-sequence (waves-dashboard-wave-beads w))))
    (when key
      (setq beads
            (seq-sort-by
             #'car
             (lambda (a b) (if (numberp a) (< a b) (string< a b)))
             (cl-loop for b in beads collect (cons (waves-dashboard--sort-value w b key) b))))
      (setq beads (mapcar #'cdr beads)))
    (if reverse (nreverse beads) beads)))

;;; Wave sort

(defconst waves-dashboard--wave-sort-keys '(default state lexical created start)
  "Wave sort keys in the order `w' cycles through them.
`default' is the model's order: started waves newest first, then queued.")

(defconst waves-dashboard--state-order
  '(in-flight in-review reviewed merging queued done merged shipped)
  "Wave states from most to least in need of attention, for the `state' sort.
Work in progress first, then queued waves, then finished ones.  Waves
of one state are ordered by name.")

(defun waves-dashboard--wave-created (w)
  "Return the creation time of wave W: its earliest bead's, or nil."
  (let ((times (delq nil (mapcar (lambda (b)
                                   (waves-dashboard--time
                                    (alist-get 'created_at b)))
                                 (waves-dashboard-wave-beads w)))))
    (and times (apply #'min times))))

(defun waves-dashboard--sorted-waves (waves key reverse)
  "Return WAVES sorted by KEY (`default' keeps the order), REVERSE flipping it.
Waves lacking the time KEY sorts by stay after the others, by name,
whichever way REVERSE points."
  (let ((name< (lambda (a b) (waves-dashboard--name<
                              (waves-dashboard-wave-name a)
                              (waves-dashboard-wave-name b)))))
    (cond
     ((memq key '(nil default))
      (if reverse (reverse waves) waves))
     ((eq key 'state)
      (let ((sorted (sort (copy-sequence waves)
                          (lambda (a b)
                            (let ((ra (seq-position waves-dashboard--state-order
                                                    (waves-dashboard-wave-state a)))
                                  (rb (seq-position waves-dashboard--state-order
                                                    (waves-dashboard-wave-state b))))
                              (if (= ra rb) (funcall name< a b) (< ra rb)))))))
        (if reverse (nreverse sorted) sorted)))
     (t
      (let* ((value (pcase key
                      ('lexical #'waves-dashboard-wave-name)
                      ('created #'waves-dashboard--wave-created)
                      ('start #'waves-dashboard-wave-start)))
             (known (cl-remove-if-not value waves))
             (unknown (sort (copy-sequence (cl-remove-if value waves)) name<))
             (known (sort (copy-sequence known)
                          (lambda (a b)
                            (let ((va (funcall value a)) (vb (funcall value b)))
                              (cond ((eq key 'lexical) (funcall name< a b))
                                    ((/= va vb) (< va vb))
                                    (t (funcall name< a b))))))))
        (append (if reverse (nreverse known) known) unknown))))))

;;; Totals

(defun waves-dashboard--wave-token-sum (w)
  "Return (TOTAL . REVIEW) tokens recorded for wave W, or nil if none.
TOTAL includes the reviewer, recorded under the id `review'."
  (when-let* ((tokens (waves-dashboard-wave-tokens w)))
    (cons (apply #'+ (mapcar #'cdr tokens))
          (cdr (assoc "review" tokens)))))

(defun waves-dashboard--wave-tokens-text (w)
  "Return the token total suffix for wave W's heading, or nil if none."
  (when-let* ((sum (waves-dashboard--wave-token-sum w)))
    (concat " " (waves-dashboard--tag nil (car sum)))))

(defun waves-dashboard--tag (model spent)
  "Return \"[MODEL SPENT]\", or nil when both are nil.
SPENT shows only while the token toggle is on."
  (let ((tag (string-join
              (delq nil (list model (and spent waves-dashboard--tokens
                                         (waves-dashboard--fmt-tokens spent))))
              " ")))
    (unless (string-empty-p tag)
      (propertize (format "[%s]" tag) 'face 'waves-dashboard-totals))))

(defun waves-dashboard--tokens-lines (waves)
  "Return the token header line for WAVES: the overall total."
  (let* ((sums (cl-loop for w in waves
                        for sum = (waves-dashboard--wave-token-sum w)
                        when sum collect (cons w sum)))
         (beads (cl-loop for (w . _) in sums
                         sum (cl-count-if-not (lambda (p) (equal (car p) "review"))
                                              (waves-dashboard-wave-tokens w)))))
    (if (null sums)
        (list "  Tokens  none recorded (wave tokens <wave> <id> <count>)")
      (list
       (format "  Tokens  %s across %d waves · %d beads · %s per bead"
               (waves-dashboard--fmt-tokens (apply #'+ (mapcar #'cadr sums)))
               (length sums) beads
               (if (> beads 0)
                   (waves-dashboard--fmt-tokens
                    (round (cl-loop for (w . _) in sums
                                    sum (cl-loop for (id . n) in (waves-dashboard-wave-tokens w)
                                                 unless (equal id "review") sum n))
                           beads))
                 "-"))))))

(defun waves-dashboard--tokens-vnode (waves on)
  "Return the token header block for WAVES, or nil unless ON."
  (when on
    (apply #'vui-vstack
           (mapcar (lambda (l) (vui-text (waves-dashboard--hang l 10)
                                         :face 'waves-dashboard-totals))
                   (waves-dashboard--tokens-lines waves)))))

(defun waves-dashboard--totals (waves)
  "Return summary counts over WAVES as a plist.
:waves counts waves by state (an alist), and :queued, :new, :closed
are alists of priority . count with the total under key `all'.
Queued counts the beads of queued waves, new the beads opened by
a wave, closed the closed beads of each wave.  A bead counts once
per category, so one opened in a wave and closed in a later one
counts as new in the first and closed in the second.  :merges
counts distinct merge commits."
  (let ((seen (make-hash-table :test 'equal))
        (merges (make-hash-table :test 'equal))
        states queued new closed)
    (cl-flet ((add (cat b)
                (let ((id (alist-get 'id b)))
                  (unless (gethash (cons cat id) seen)
                    (puthash (cons cat id) t seen)
                    (let ((p (or (alist-get 'priority b) 'none)))
                      (pcase cat
                        ('queued (push p queued))
                        ('new (push p new))
                        ('closed (push p closed))))))))
      (dolist (w waves)
        (let ((state (waves-dashboard-wave-state w)))
          (push state states)
          (dolist (b (waves-dashboard-wave-beads w))
            (when (eq state 'queued) (add 'queued b))
            (when (equal (alist-get 'status b) "closed") (add 'closed b)))
          (dolist (b (waves-dashboard-wave-opened w)) (add 'new b))
          (dolist (m (waves-dashboard-wave-merges w))
            (puthash (plist-get m :sha) t merges)))))
    (cl-flet ((tally (xs)
                (let (out)
                  (dolist (x xs) (cl-incf (alist-get x out 0)))
                  (cons (cons 'all (length xs)) out))))
      (list :waves (tally states)
            :queued (tally queued)
            :new (tally new)
            :closed (tally closed)
            :merges (hash-table-count merges)))))

;;; Events (time spine)

(defun waves-dashboard--findings-text (w)
  "Return wave W's review counts as text, e.g. \"3 findings, 2 fixed\".
Nil when the review recorded neither count."
  (let ((n (waves-dashboard-wave-findings w))
        (f (waves-dashboard-wave-fixed w)))
    (when (or n f)
      (string-join
       (delq nil (list (and n (format "%d finding%s" n (if (= n 1) "" "s")))
                       (and f (format "%d fixed" f))))
       ", "))))

(defun waves-dashboard--events (waves)
  "Return the chronological event list for WAVES.
Each event is a plist with :time :wave :kind :id and :text."
  (let (events)
    (dolist (w waves)
      (let ((name (waves-dashboard-wave-name w)))
        (when-let* ((t1 (waves-dashboard-wave-dispatched w)))
          (push (list :time t1 :wave name :kind "dispatched"
                      :text (or (waves-dashboard-wave-title w) ""))
                events))
        (dolist (m (waves-dashboard-wave-merges w))
          (push (list :time (plist-get m :time) :wave name :kind "merged"
                      :id (car (plist-get m :ids))
                      :text (let ((s (plist-get m :subject)))
                              (if (string-match "\\`Merge [^:]*: *" s)
                                  (substring s (match-end 0))
                                "")))
                events))
        (dolist (b (waves-dashboard-wave-beads w))
          (when-let* ((t1 (waves-dashboard--time (alist-get 'closed_at b))))
            (push (list :time t1 :wave name :kind "closed"
                        :id (alist-get 'id b) :issue b
                        :text (alist-get 'title b))
                  events)))
        (dolist (b (waves-dashboard-wave-opened w))
          (push (list :time (waves-dashboard--time (alist-get 'created_at b))
                      :wave name :kind "opened"
                      :id (alist-get 'id b) :issue b
                      :text (alist-get 'title b))
                events))
        (dolist (p `((,(waves-dashboard-wave-review-started w) "review-started" "")
                     (,(waves-dashboard-wave-review-finished w) "review-finished"
                      ,(or (waves-dashboard--findings-text w) ""))
                     (,(waves-dashboard-wave-merge-started w) "merge-started" "")
                     (,(waves-dashboard-wave-merge-completed w) "merge-completed"
                      ,(or (waves-dashboard-wave-merge-sha w) ""))))
          (when (car p)
            (push (list :time (nth 0 p) :wave name :kind (nth 1 p)
                        :text (nth 2 p))
                  events)))
        (when-let* ((t1 (waves-dashboard-wave-deployed w)))
          (push (list :time t1 :wave name
                      :kind (if (waves-dashboard-wave-deployed-approx w)
                                "deployed~" "deployed")
                      :text (or (waves-dashboard-wave-sha w) ""))
                events))))
    (sort (cl-remove-if-not (lambda (e) (plist-get e :time)) events)
          (lambda (a b) (< (plist-get a :time) (plist-get b :time))))))

;;; Loading

(defun waves-dashboard--run (dir command on-ok on-err)
  "Run COMMAND (a list) in DIR; call ON-OK with stdout or ON-ERR with a message."
  (let* ((default-directory dir)
         (out (generate-new-buffer " *waves-dashboard-out*"))
         (err (generate-new-buffer " *waves-dashboard-err*")))
    (condition-case e
        (make-process
         :name "waves-dashboard"
         :buffer out
         :stderr err
         :command command
         :connection-type 'pipe
         :noquery t
         :sentinel
         (lambda (proc _event)
           (unless (process-live-p proc)
             (let ((code (process-exit-status proc))
                   (stdout (with-current-buffer out (buffer-string)))
                   (stderr (with-current-buffer err (buffer-string))))
               (kill-buffer out)
               (let ((kill-buffer-query-functions nil))
                 (kill-buffer err))
               (if (zerop code)
                   (funcall on-ok stdout)
                 (funcall on-err (format "%s: %s" (string-join command " ")
                                         (string-trim stderr))))))))
      (error (kill-buffer out) (kill-buffer err)
             (funcall on-err (error-message-string e))))))

(defun waves-dashboard--series (dir commands on-ok on-err &optional results)
  "Run COMMANDS (an alist of KEY . COMMAND) in DIR one after another.
Call ON-OK with an alist of KEY . STDOUT when all succeed, or ON-ERR
with the first failure.  A command whose car is `:optional' yields
an empty string instead of failing.  Sequential on purpose: bd's
embedded Dolt takes an exclusive lock, and concurrent bd processes
in one project stall each other.  RESULTS accumulates across steps."
  (if (null commands)
      (funcall on-ok results)
    (let* ((c (car commands))
           (key (car c))
           (optional (eq (cadr c) :optional))
           (cmd (if optional (cddr c) (cdr c)))
           (next (lambda (out)
                   (waves-dashboard--series dir (cdr commands) on-ok on-err
                                            (cons (cons key out) results)))))
      (waves-dashboard--run
       dir cmd next
       (lambda (msg)
         (if optional (funcall next "") (funcall on-err msg)))))))

(defun waves-dashboard--git-merges-command ()
  "Return the command listing trunk's first-parent merges."
  (list "sh" "-c"
        (concat "ref=$(git rev-parse --verify -q trunk || "
                "git rev-parse --verify -q main || echo HEAD); "
                "git log --first-parent --merges "
                "--format='%h%x09%cI%x09%s' "
                (shell-quote-argument
                 (concat "--since=" waves-dashboard-merge-history))
                " \"$ref\"")))

(defun waves-dashboard--collect (root resolve reject)
  "Load ROOT's wave data asynchronously; RESOLVE with the wave list.
One `bd list --all' feeds both the wave members and the beads
opened by waves.  Narrower bd queries are no help in bd 1.2.2:
--label-pattern and --label-regex are ignored, and `bd label list-all'
takes over 20 s on a ~740-bead project where `bd list --all' takes 0.4."
  (waves-dashboard--series
   root
   `((issues "bd" "list" "--all" "--json" "--limit" "0")
     (kv "bd" "kv" "list" "--json")
     (merges :optional ,@(waves-dashboard--git-merges-command)))
   (lambda (r)
     (let ((all (waves-dashboard--json (alist-get 'issues r))))
       (funcall resolve
                (waves-dashboard--model
                 (cl-remove-if-not #'waves-dashboard--wave-labels all)
                 (waves-dashboard--json (alist-get 'kv r))
                 (waves-dashboard--parse-merges (alist-get 'merges r))
                 all))))
   reject))

;;; Rendering

(defvar-local waves-dashboard--root nil
  "Project root shown in this waves dashboard buffer.")

(defvar-local waves-dashboard--last-data nil
  "Last loaded wave list, shown while a refresh is loading.")

(defvar-local waves-dashboard--emoji t
  "Non-nil shows emoji wave-state icons, nil short text names.
Mirrors the root component's `emoji' state for the render functions.")

(defvar-local waves-dashboard--tokens nil
  "Non-nil shows the token counts recorded with `wave tokens'.
Mirrors the root component's `tokens' state for the render functions.")

(defvar-local waves-dashboard--sort nil
  "Bead sort within each wave: nil (priority, then id) or a key of
`waves-dashboard--sort-keys'.  Mirrors the root component's `sort' state.")

(defvar-local waves-dashboard--sort-reverse nil
  "Non-nil reverses the bead sort.  Mirrors the root's `sort-reverse' state.")

(defvar-local waves-dashboard--timer nil
  "Auto-refresh timer of this dashboard buffer, or nil when off.")

(defun waves-dashboard--fmt-time (time &optional approx)
  "Format float TIME for display; prefix ~ when APPROX."
  (if time
      (concat (if approx "~" "")
              (format-time-string "%a %d %b %H:%M" time))
    "-"))

(defun waves-dashboard--hang (s col)
  "Return S with continuation lines aligned at column COL.
Only has an effect when `waves-dashboard-wrap' is on."
  (if waves-dashboard-wrap
      (propertize s 'wrap-prefix `(space :align-to ,col))
    s))

(defun waves-dashboard--issue (alist)
  "Return a `beads-issue' for bead ALIST."
  (beads-from-json 'beads-issue alist))

(defun waves-dashboard--issue-head (alist)
  "Return the columns before the title in bead ALIST's issue line.
Mirrors the format in `beads-section--issue-line-vnode'."
  (let ((p (alist-get 'priority alist)))
    (format "  %-14s %-4s %-10s %-14s "
            (or (alist-get 'id alist) "")
            (if p (format "P%d" p) "--")
            (or (alist-get 'issue_type alist) "")
            (or (alist-get 'status alist) ""))))

(defun waves-dashboard--title-column (alist)
  "Return the column where beads puts bead ALIST's title in an issue line."
  (length (waves-dashboard--issue-head alist)))

(defun waves-dashboard--issue-row (alist &optional suffix dim)
  "Return the beads issue line for bead ALIST, with optional SUFFIX text.
DIM draws the whole line in `waves-dashboard-requeued'.  beads' own
row forces its face, so a dim row is built the same way (columns,
section property, RET visits) with that face instead.  When
wrapping, continuation lines align under the title."
  (let* ((hang (and waves-dashboard-wrap
                    `(space :align-to ,(waves-dashboard--title-column alist))))
         (props (and hang (list 'wrap-prefix hang)))
         (issue (waves-dashboard--issue alist))
         (row (if dim
                  (let ((id (alist-get 'id alist)))
                    (vui-button
                        (beads-section--propertize
                         (concat (waves-dashboard--issue-head alist)
                                 (or (alist-get 'title alist) ""))
                         (beads-issue-section :issue issue) props)
                      :no-decoration t
                      :face 'waves-dashboard-requeued
                      :help-echo nil
                      :on-click (lambda () (beads-show id))))
                (beads-section--issue-line-vnode issue props))))
    (if suffix
        (apply #'vui-hstack :spacing 0 row
               ;; vui-text's :face overrides text properties, so each
               ;; run with its own face (a token tag) is a text of its own.
               (let ((pos 0) runs)
                 (while (< pos (length suffix))
                   (let* ((face (get-text-property pos 'face suffix))
                          (end (or (next-single-property-change pos 'face suffix)
                                   (length suffix))))
                     (push (apply #'vui-text (substring-no-properties suffix pos end)
                                  :face (cond (dim 'waves-dashboard-requeued)
                                              (face)
                                              (t 'waves-dashboard-detail))
                                  props)
                           runs)
                     (setq pos end)))
                 (nreverse runs)))
      row)))

(defun waves-dashboard--state-icon (state)
  "Return the header icon for wave STATE, from `waves-dashboard--states'.
Text names such as [deployed] replace the emoji when
`waves-dashboard--emoji' is nil.  An unknown state shows as queued."
  (let ((row (or (assq state waves-dashboard--states)
                 (assq 'queued waves-dashboard--states))))
    (if waves-dashboard--emoji (nth 1 row) (nth 2 row))))

(defun waves-dashboard--header-title (w)
  "Return the section header text for wave W."
  (let ((title (waves-dashboard-wave-title w)))
    (concat "wave-" (waves-dashboard-wave-name w)
            (if title (concat " — " title) "")
            (pcase (waves-dashboard-wave-state w)
              ('shipped
               (format " · deployed %s%s"
                       (waves-dashboard--fmt-time
                        (waves-dashboard-wave-deployed w)
                        (waves-dashboard-wave-deployed-approx w))
                       (if-let* ((sha (waves-dashboard-wave-sha w)))
                           (format " (%s)" sha) "")))
              ('merged
               (format " · merged %s%s"
                       (waves-dashboard--fmt-time
                        (waves-dashboard-wave-merge-completed w))
                       (if-let* ((sha (waves-dashboard-wave-merge-sha w)))
                           (format " (%s)" sha) "")))
              ('merging
               (format " · merging since %s"
                       (waves-dashboard--fmt-time
                        (waves-dashboard-wave-merge-started w))))
              ('reviewed
               (format " · reviewed %s%s"
                       (waves-dashboard--fmt-time
                        (waves-dashboard-wave-review-finished w))
                       (if-let* ((counts (waves-dashboard--findings-text w)))
                           (format " (%s)" counts) "")))
              ('in-review
               (format " · in review since %s"
                       (waves-dashboard--fmt-time
                        (waves-dashboard-wave-review-started w))))
              ('done " · all closed, no deploy")
              ('in-flight " · in flight")
              ('queued " · queued")
              (_ ""))
            (if (waves-dashboard--all-requeued-p w) " · re-queued" ""))))

(defun waves-dashboard--default-collapsed (waves)
  "Return the wave names in WAVES that start out collapsed."
  (let ((shipped 0) names)
    (dolist (w waves)
      (pcase (waves-dashboard-wave-state w)
        ((guard (waves-dashboard--all-requeued-p w))
         (push (waves-dashboard-wave-name w) names))
        ('queued (push (waves-dashboard-wave-name w) names))
        ((or 'shipped 'merged 'done)
         (when (> (cl-incf shipped) waves-dashboard-expanded-shipped)
           (push (waves-dashboard-wave-name w) names)))))
    names))

(defun waves-dashboard--collapsed-p (name collapsed defaults)
  "Return non-nil when wave NAME is collapsed.
COLLAPSED is the alist of explicit toggles, DEFAULTS the names that
start out collapsed."
  (if-let* ((cell (assoc name collapsed)))
      (cdr cell)
    (member name defaults)))

(defun waves-dashboard--toggler (buffer name collapsed defaults)
  "Return a callback toggling wave NAME in BUFFER.
COLLAPSED and DEFAULTS are the current collapse state."
  (lambda ()
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (beads-dashboard--bump
         :collapsed
         (cons (cons name (not (waves-dashboard--collapsed-p
                                name collapsed defaults)))
               (cl-remove name collapsed :key #'car :test #'equal)))))))

(defun waves-dashboard--fold (buffer key collapsed default)
  "Return (FOLDED . TOGGLE) for the foldable part KEY in BUFFER.
COLLAPSED is the alist of explicit toggles; DEFAULT is KEY's folded
state until it is toggled.  TOGGLE flips it."
  (let ((folded (if-let* ((cell (assoc key collapsed))) (cdr cell) default)))
    (cons folded
          (lambda ()
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (beads-dashboard--bump
                 :collapsed
                 (cons (cons key (not folded))
                       (cl-remove key collapsed :key #'car :test #'equal)))))))))

(defun waves-dashboard--subsection (text face fold children)
  "Return a foldable subsection headed by TEXT in FACE.
FOLD is (FOLDED . TOGGLE) from `waves-dashboard--fold'.  CHILDREN, a
list of vnodes, show when it is not folded."
  (let ((head (beads-thing-propertize
               (concat "  " (beads-dashboard--toggle-glyph (car fold)) " " text)
               '(:kind section))))
    (apply #'vui-vstack
           (vui-button head
             :no-decoration t
             :face face
             :help-echo nil
             :on-click (cdr fold))
           (unless (car fold) children))))

(defun waves-dashboard--all-closed-p (beads)
  "Non-nil when every bead in BEADS is closed."
  (cl-every (lambda (b) (equal (alist-get 'status b) "closed")) beads))

(defun waves-dashboard--phase-lines (w)
  "Return one text line per review or merge phase recorded for wave W."
  (cl-flet ((line (label started end-word ended extra)
              (concat "    " label " started " (waves-dashboard--fmt-time started)
                      (if ended
                          (format " · %s %s" end-word
                                  (waves-dashboard--fmt-time ended))
                        "")
                      (if (and extra (not (string-empty-p extra)))
                          (format " · %s" extra)
                        ""))))
    (delq nil
          (list
           (when (or (waves-dashboard-wave-review-started w)
                     (waves-dashboard-wave-review-finished w))
             (line "Review" (waves-dashboard-wave-review-started w)
                   "finished" (waves-dashboard-wave-review-finished w)
                   (string-join
                    (delq nil
                          (list (waves-dashboard--findings-text w)
                                (waves-dashboard--tag
                                 (cdr (assoc "review" (waves-dashboard-wave-models w)))
                                 (cdr (assoc "review" (waves-dashboard-wave-tokens w))))))
                    " · ")))
           (when (or (waves-dashboard-wave-merge-started w)
                     (waves-dashboard-wave-merge-completed w))
             (line "Merge" (waves-dashboard-wave-merge-started w)
                   "completed" (waves-dashboard-wave-merge-completed w)
                   (waves-dashboard-wave-merge-sha w)))))))

(defun waves-dashboard--wave-vnode (w collapsed-p on-toggle fold)
  "Return the section vnode for wave W.
COLLAPSED-P folds it; ON-TOGGLE is the header click callback.  FOLD
is called with a subsection name and its default folded state, and
returns that subsection's (FOLDED . TOGGLE).  Subsections start
folded when everything in them is closed; merges follow the wave's
beads."
  (let* ((beads (waves-dashboard-wave-beads w))
         (merges (waves-dashboard-wave-merges w))
         (opened (waves-dashboard-wave-opened w))
         (beads-closed (and beads (waves-dashboard--all-closed-p beads))))
    (apply
     #'vui-vstack
     (beads-dashboard--section-header
      ;; Continuations line up under "wave-", after the glyph and icon.
      (waves-dashboard--hang
       (format "%s (%d)%s" (waves-dashboard--header-title w) (length beads)
               (or (and waves-dashboard--tokens
                        (waves-dashboard--wave-tokens-text w))
                   ""))
       5)
      (waves-dashboard--state-icon (waves-dashboard-wave-state w))
      collapsed-p nil on-toggle)
     (unless collapsed-p
       (list
        (when-let* ((lines (waves-dashboard--phase-lines w)))
          (apply #'vui-vstack
                 (mapcar (lambda (l) (vui-text (waves-dashboard--hang l 4)
                                               :face 'waves-dashboard-detail))
                         lines)))
        (waves-dashboard--subsection
         (concat
          (format "%s (%d)"
                  (cond ((waves-dashboard-wave-dispatched w)
                         (format "Dispatched %s"
                                 (waves-dashboard--fmt-time
                                  (waves-dashboard-wave-dispatched w))))
                        ((waves-dashboard-wave-start w)
                         (format "First merge %s (no dispatch recorded)"
                                 (waves-dashboard--fmt-time
                                  (waves-dashboard-wave-start w))))
                        (t "Beads"))
                  (length beads))
          (and (or waves-dashboard--sort waves-dashboard--sort-reverse)
               (format " · by %s%s" (or waves-dashboard--sort 'priority)
                       (if waves-dashboard--sort-reverse " ↓" ""))))
         'waves-dashboard-detail
         (funcall fold "beads" beads-closed)
         (if beads
             (let ((marks (waves-dashboard-wave-requeued w))
                   (beads (waves-dashboard--sorted-beads
                           w waves-dashboard--sort waves-dashboard--sort-reverse))
                   (models (waves-dashboard-wave-models w))
                   (tokens (waves-dashboard-wave-tokens w)))
               (mapcar (lambda (b)
                         (let* ((id (alist-get 'id b))
                                (to (cdr (assoc id marks)))
                                (model (cdr (assoc id models)))
                                (spent (cdr (assoc id tokens)))
                                (tag (waves-dashboard--tag model spent))
                                (suffix (concat
                                         (and tag (concat "  " tag))
                                         (and to (format "  → wave-%s" to)))))
                           (waves-dashboard--issue-row
                            b (and (not (string-empty-p suffix)) suffix) to)))
                       beads))
           (list (beads-dashboard--empty-line "No labelled beads."))))
        (when merges
          (waves-dashboard--subsection
           (format "Merges (%d)" (length merges))
           'font-lock-comment-face
           (funcall fold "merges" beads-closed)
           (mapcar
            (lambda (m)
              (let ((head (format "    %s  %s  "
                                  (format-time-string "%H:%M" (plist-get m :time))
                                  (plist-get m :sha))))
                (vui-text (waves-dashboard--hang
                           (concat head (string-remove-prefix
                                         "Merge " (plist-get m :subject)))
                           (length head)))))
            merges)))
        (when opened
          (waves-dashboard--subsection
           (format "Opened by the wave (%d)" (length opened))
           'font-lock-comment-face
           (funcall fold "opened" (waves-dashboard--all-closed-p opened))
           (mapcar
            (lambda (b)
              (let ((src (car (waves-dashboard--discovered-from b))))
                (waves-dashboard--issue-row
                 b (and src (format "  ← %s" src)))))
            opened))))))))

(defun waves-dashboard--event-vnode (e)
  "Return the time-spine line for event E."
  (let* ((head (format "  %s  %-10s %-15s %-14s "
                       (format-time-string "%H:%M" (plist-get e :time))
                       (concat "wave-" (plist-get e :wave))
                       (plist-get e :kind)
                       (or (plist-get e :id) "")))
         (line (waves-dashboard--hang (concat head (or (plist-get e :text) ""))
                                      (length head)))
         (issue (plist-get e :issue))
         (id (plist-get e :id)))
    (cond
     (issue
      (beads-section--plain-button
       (beads-section--propertize
        line (beads-issue-section :issue (waves-dashboard--issue issue)))
       (lambda () (beads-show id))))
     (id (beads-section--plain-button line (lambda () (beads-show id))))
     (t (vui-text line :face (if (string-prefix-p "deployed" (plist-get e :kind))
                                 'bold 'default))))))

(defun waves-dashboard--spine-vnode (waves)
  "Return the chronological time-spine vnode for WAVES, grouped by day."
  (let (rows day)
    (dolist (e (waves-dashboard--events waves))
      (let ((d (format-time-string "%A %d %B %Y" (plist-get e :time))))
        (unless (equal d day)
          (setq day d)
          (push (vui-text d :face 'bold) rows))
        (push (waves-dashboard--event-vnode e) rows)))
    (if rows
        (apply #'vui-vstack (nreverse rows))
      (beads-dashboard--empty-line "No timed events yet."))))

(defun waves-dashboard--totals-lines (totals by-priority)
  "Return the header text lines for TOTALS, from `waves-dashboard--totals'.
BY-PRIORITY adds a row per category broken down by priority."
  (let* ((ws (plist-get totals :waves))
         (states (mapconcat
                  #'identity
                  (cl-loop for (s _ _ label) in waves-dashboard--states
                           for n = (alist-get s ws)
                           when n collect (format "%d %s" n label))
                  ", "))
         (summary
          (format "  Totals  %d waves%s · %d queued · %d new · %d closed · %d merges"
                  (alist-get 'all ws 0)
                  (if (string-empty-p states) "" (format " (%s)" states))
                  (alist-get 'all (plist-get totals :queued) 0)
                  (alist-get 'all (plist-get totals :new) 0)
                  (alist-get 'all (plist-get totals :closed) 0)
                  (plist-get totals :merges))))
    (if (not by-priority)
        (list summary)
      (let* ((cats '((:queued . "queued") (:new . "new") (:closed . "closed")))
             (prios (sort (delete-dups
                           (cl-loop for (c . _) in cats
                                    append (cl-loop for (p . _) in (plist-get totals c)
                                                    unless (eq p 'all) collect p)))
                          (lambda (a b) (< (if (numberp a) a 99)
                                           (if (numberp b) b 99)))))
             (head (concat (format "  %-8s" "")
                           (mapconcat (lambda (p)
                                        (format "%4s" (if (numberp p) (format "P%d" p) "P?")))
                                      prios ""))))
        (append
         (list summary head)
         (cl-loop for (c . label) in cats
                  collect (concat (format "  %-8s" label)
                                  (mapconcat (lambda (p)
                                               (format "%4d" (alist-get p (plist-get totals c) 0)))
                                             prios ""))))))))

(defun waves-dashboard--totals-vnode (waves mode)
  "Return the totals header block for WAVES in MODE, or nil when off.
MODE is nil, `totals' or `priority'."
  (when mode
    (apply #'vui-vstack
           (mapcar (lambda (l) (vui-text (waves-dashboard--hang l 10)
                                         :face 'waves-dashboard-totals))
                   (waves-dashboard--totals-lines
                    (waves-dashboard--totals waves) (eq mode 'priority))))))

(defun waves-dashboard--footer ()
  "Return the key-hint footer vnode."
  (vui-text (waves-dashboard--hang
             "KEYS: TAB/S-TAB next/prev · SPC fold · C/E collapse/expand all · 1/2/3 fold level · t waves/timeline · T totals · $ token totals · s/S sort beads/reverse · w/W sort waves/reverse · e emoji/text · a auto-refresh · g refresh · RET visit · q quit"
             6)
            :face 'waves-dashboard-detail))

(vui-defcomponent waves-dashboard--root-component (project-root)
  "Root of the waves dashboard for PROJECT-ROOT."
  :state ((generation 0) (view 'waves) (collapsed nil) (totals nil)
           (emoji t) (tokens nil) (sort nil) (sort-reverse nil)
           (wave-sort 'default) (wave-sort-reverse nil))
  :render
  (let* ((buffer (current-buffer))
         (_ (setq waves-dashboard--emoji emoji
                  waves-dashboard--tokens tokens
                  waves-dashboard--sort sort
                  waves-dashboard--sort-reverse sort-reverse))
         (async (vui-use-async (list 'waves project-root generation)
                  (lambda (resolve reject)
                    (waves-dashboard--collect project-root resolve reject))))
         (status (plist-get async :status))
         (waves (if (eq status 'ready)
                    (setq waves-dashboard--last-data (plist-get async :data))
                  waves-dashboard--last-data))
         (header (vui-hstack :spacing 0
                   (vui-text "Waves-Dashboard" :face 'bold)
                   (vui-text " — " :face 'shadow)
                   (vui-text (file-name-nondirectory
                              (directory-file-name project-root))
                             :face 'font-lock-constant-face)
                   (vui-text (concat (if (eq view 'spine) " · timeline" " · waves")
                                     (and (eq view 'waves)
                                          (or (not (eq wave-sort 'default))
                                              wave-sort-reverse)
                                          (format " · by %s%s" wave-sort
                                                  (if wave-sort-reverse " ↓" "")))
                                     (if waves-dashboard--timer " · auto" ""))
                             :face 'shadow))))
    (vui-vstack
     :spacing 1
     header
     (when waves (waves-dashboard--totals-vnode waves totals))
     (when waves (waves-dashboard--tokens-vnode waves tokens))
     (cond
      ((eq status 'error)
       (beads-dashboard--error-line (plist-get async :error)))
      ((and (not (eq status 'ready)) (null waves))
       (beads-dashboard--loading-line))
      ((null waves)
       (beads-dashboard--empty-line
        "No waves: no wave-* labels and no wave.* kv records."))
      ((eq view 'spine) (waves-dashboard--spine-vnode waves))
      (t
       (let ((defaults (waves-dashboard--default-collapsed waves)))
         (apply #'vui-vstack
                :spacing 1
                (mapcar
                 (lambda (w)
                   (let ((name (waves-dashboard-wave-name w)))
                     (waves-dashboard--wave-vnode
                      w
                      (waves-dashboard--collapsed-p name collapsed defaults)
                      (waves-dashboard--toggler buffer name collapsed defaults)
                      (lambda (sub default)
                        (waves-dashboard--fold
                         buffer (concat name "/" sub) collapsed default)))))
                 (waves-dashboard--sorted-waves
                  waves wave-sort wave-sort-reverse))))))
     (waves-dashboard--footer))))

;;; Mode and commands

;; Newer vui binds `vui--root-instance' only while rendering and keeps the
;; buffer's tree in `vui--mounted-root', read through `vui--buffer-root'.
(declare-function vui--buffer-root "vui")
(defvar vui--root-instance)

(defun waves-dashboard--root ()
  "Return the vui root instance mounted in the current buffer.
Works with vui before and after `vui--buffer-root' existed."
  (if (fboundp 'vui--buffer-root)
      (vui--buffer-root)
    vui--root-instance))

(defun waves-dashboard-refresh ()
  "Reload the waves dashboard data."
  (interactive)
  (beads-dashboard--bump
   :generation
   (1+ (or (plist-get (vui-instance-state (waves-dashboard--root)) :generation) 0))))

(defun waves-dashboard-toggle-view ()
  "Switch between the per-wave sections and the time spine."
  (interactive)
  (beads-dashboard--bump
   :view
   (if (eq (plist-get (vui-instance-state (waves-dashboard--root)) :view) 'spine)
       'waves 'spine)))

(defun waves-dashboard-cycle-totals ()
  "Cycle the totals header: off, totals, totals by priority."
  (interactive)
  (beads-dashboard--bump
   :totals
   (pcase (plist-get (vui-instance-state (waves-dashboard--root)) :totals)
     ('nil 'totals) ('totals 'priority) (_ nil))))

(defun waves-dashboard-toggle-tokens ()
  "Toggle the token counts: a header, per-wave totals and per-bead counts."
  (interactive)
  (beads-dashboard--bump
   :tokens
   (not (plist-get (vui-instance-state (waves-dashboard--root)) :tokens))))

(defun waves-dashboard-cycle-sort ()
  "Cycle the bead sort within each wave through `waves-dashboard--sort-keys'."
  (interactive)
  (let* ((cur (or (plist-get (vui-instance-state (waves-dashboard--root)) :sort) 'priority))
         (next (or (cadr (memq cur waves-dashboard--sort-keys))
                   (car waves-dashboard--sort-keys))))
    (beads-dashboard--bump :sort (unless (eq next 'priority) next))
    (message "Beads sorted by %s" next)))

(defun waves-dashboard-reverse-sort ()
  "Reverse the bead sort within each wave."
  (interactive)
  (beads-dashboard--bump
   :sort-reverse
   (not (plist-get (vui-instance-state (waves-dashboard--root)) :sort-reverse))))

(defun waves-dashboard-cycle-wave-sort ()
  "Cycle the wave order through `waves-dashboard--wave-sort-keys'."
  (interactive)
  (let* ((cur (or (plist-get (vui-instance-state (waves-dashboard--root)) :wave-sort)
                  'default))
         (next (or (cadr (memq cur waves-dashboard--wave-sort-keys))
                   (car waves-dashboard--wave-sort-keys))))
    (beads-dashboard--bump :wave-sort next)
    (message "Waves sorted by %s" next)))

(defun waves-dashboard-reverse-wave-sort ()
  "Reverse the wave order."
  (interactive)
  (beads-dashboard--bump
   :wave-sort-reverse
   (not (plist-get (vui-instance-state (waves-dashboard--root)) :wave-sort-reverse))))

(defun waves-dashboard-toggle-emoji ()
  "Toggle the wave-state icons between emoji and short text names."
  (interactive)
  (beads-dashboard--bump
   :emoji
   (not (plist-get (vui-instance-state (waves-dashboard--root)) :emoji))))

(defun waves-dashboard--tick (buffer)
  "Reload BUFFER if it is live and shown; stop the timer when it is gone."
  (cond
   ((not (buffer-live-p buffer)))
   ((get-buffer-window buffer t)
    (with-current-buffer buffer (waves-dashboard-refresh)))))

(defun waves-dashboard--stop-timer ()
  "Cancel this buffer's auto-refresh timer."
  (when (timerp waves-dashboard--timer)
    (cancel-timer waves-dashboard--timer))
  (setq waves-dashboard--timer nil))

(defun waves-dashboard-toggle-auto-refresh ()
  "Toggle reloading every `waves-dashboard-refresh-interval' seconds.
Only a visible buffer is reloaded; the timer dies with the buffer."
  (interactive)
  (if waves-dashboard--timer
      (waves-dashboard--stop-timer)
    (let ((buffer (current-buffer))
          (secs waves-dashboard-refresh-interval))
      (setq waves-dashboard--timer
            (run-with-timer secs secs #'waves-dashboard--tick buffer))
      (add-hook 'kill-buffer-hook #'waves-dashboard--stop-timer nil t)))
  (message "Waves auto-refresh %s"
           (if waves-dashboard--timer
               (format "on (every %ds)" waves-dashboard-refresh-interval)
             "off"))
  ;; Redraw the header's " · auto" marker; the data is unchanged.
  (when (waves-dashboard--root)
    (vui--rerender-instance (waves-dashboard--root))))

(defconst waves-dashboard--subsections '("beads" "merges" "opened")
  "Names of the foldable subsections inside a wave.")

(defun waves-dashboard--fold-alist (waves wave-folded subs-folded)
  "Return the explicit fold alist for WAVES.
WAVE-FOLDED is the folded state of every wave.  SUBS-FOLDED is that of
every subsection, or `default' to leave subsections at their defaults."
  (let (alist)
    (dolist (w waves)
      (let ((name (waves-dashboard-wave-name w)))
        (push (cons name wave-folded) alist)
        (unless (eq subs-folded 'default)
          (dolist (sub waves-dashboard--subsections)
            (push (cons (concat name "/" sub) subs-folded) alist)))))
    (nreverse alist)))

(defun waves-dashboard--set-folds (wave-folded subs-folded)
  "Fold all waves to WAVE-FOLDED and their subsections to SUBS-FOLDED."
  (beads-dashboard--bump
   :collapsed
   (waves-dashboard--fold-alist waves-dashboard--last-data
                                wave-folded subs-folded)))

(defun waves-dashboard-collapse-all ()
  "Fold every wave down to its header."
  (interactive)
  (waves-dashboard--set-folds t 'default))

(defun waves-dashboard-expand-all ()
  "Open every wave, leaving its subsections at their default folds."
  (interactive)
  (waves-dashboard--set-folds nil 'default))

(defun waves-dashboard-level-1 ()
  "Show wave headers only (same as `waves-dashboard-collapse-all')."
  (interactive)
  (waves-dashboard-collapse-all))

(defun waves-dashboard-level-2 ()
  "Open every wave with all its subsections folded."
  (interactive)
  (waves-dashboard--set-folds nil t))

(defun waves-dashboard-level-3 ()
  "Open every wave and every subsection."
  (interactive)
  (waves-dashboard--set-folds nil nil))

(defvar-keymap waves-dashboard-mode-map
  :parent beads-section-mode-map
  "g" #'waves-dashboard-refresh
  "t" #'waves-dashboard-toggle-view
  "T" #'waves-dashboard-cycle-totals
  "$" #'waves-dashboard-toggle-tokens
  "s" #'waves-dashboard-cycle-sort
  "S" #'waves-dashboard-reverse-sort
  "w" #'waves-dashboard-cycle-wave-sort
  "W" #'waves-dashboard-reverse-wave-sort
  "e" #'waves-dashboard-toggle-emoji
  "C" #'waves-dashboard-collapse-all
  "E" #'waves-dashboard-expand-all
  "1" #'waves-dashboard-level-1
  "2" #'waves-dashboard-level-2
  "3" #'waves-dashboard-level-3
  "a" #'waves-dashboard-toggle-auto-refresh
  "q" #'quit-window)

(define-derived-mode waves-dashboard-mode beads-section-mode "Waves"
  "Major mode for the bead-waves dashboard.

\\{waves-dashboard-mode-map}"
  :interactive nil
  (setq-local truncate-lines (not waves-dashboard-wrap))
  (setq-local word-wrap t)
  (setq-local revert-buffer-function
              (lambda (_ignore _noconfirm) (waves-dashboard-refresh))))

(defun waves-dashboard--adjacent-window ()
  "Return a live window beside the selected one, or nil when there is none.
Tries right, below, left, then above; skips the minibuffer."
  (cl-some (lambda (dir)
             (let ((win (window-in-direction dir)))
               (and win (not (window-minibuffer-p win)) win)))
           '(right below left above)))

(defun waves-dashboard--display-adjacent (buffer _alist)
  "Display BUFFER in a window beside the selected one; return that window.
Reuses another window already showing BUFFER, else the adjacent window,
else splits the selected one.  Returns nil, leaving the choice to
`display-buffer', when none of those is possible."
  (when-let* ((win (or (cl-find-if (lambda (w) (not (eq w (selected-window))))
                                  (get-buffer-window-list buffer nil t))
                       (waves-dashboard--adjacent-window)
                       (split-window-sensibly))))
    (set-window-buffer win buffer)
    win))

;;;###autoload
(defun waves-dashboard-new-window (&optional pick)
  "Like `waves-dashboard', but show it in the window beside this one.
Splits the window when it is alone.  With prefix argument PICK,
prompt for the project.

`vui-mount' ends in `switch-to-buffer', which would put the dashboard
in this window before `waves-dashboard' pops to it; that call is
turned into a plain `set-buffer' so the pop decides the window."
  (interactive "P")
  (let ((display-buffer-overriding-action
         (cons (list #'waves-dashboard--display-adjacent) nil)))
    (cl-letf (((symbol-function 'switch-to-buffer)
               (lambda (buffer &rest _) (set-buffer buffer))))
      (waves-dashboard pick))))

;;;###autoload
(defun waves-dashboard (&optional pick)
  "Show the bead-waves dashboard for the current project.
With prefix argument PICK, prompt for the project."
  (interactive "P")
  (let* ((dir (if pick
                  (project-prompt-project-dir)
                default-directory))
         (root (or (locate-dominating-file dir ".beads")
                   (user-error "No beads project at %s" dir)))
         (root (file-name-as-directory (expand-file-name root)))
         (buf (get-buffer-create
               (format "*waves: %s*"
                       (file-name-nondirectory (directory-file-name root))))))
    (with-current-buffer buf
      (unless (eq major-mode 'waves-dashboard-mode)
        (waves-dashboard-mode))
      (setq default-directory root
            waves-dashboard--root root)
      (vui-mount (vui-component 'waves-dashboard--root-component
                                :project-root root)
                 (buffer-name)))
    (pop-to-buffer buf)))

(provide 'waves-dashboard)
;;; waves-dashboard.el ends here
