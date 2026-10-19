;;; waves-dashboard-test.el --- tests for waves-dashboard -*- lexical-binding: t; -*-

;; Run from the repo root: make test
;; or: emacs -Q --batch -L ~/.emacs.d/elpa/beads/lisp -L <vui dir> \
;;       -L . -l test/waves-dashboard-test.el -f ert-run-tests-batch-and-exit
;; Fixtures are synthetic: an invented static-site generator project
;; ("demo-" ids) with waves 6-11 and hotfix, shaped like real bd and git
;; output on 2026-10-16.

;;; Code:

(require 'ert)
(require 'waves-dashboard)

(defconst wdt--dir
  (expand-file-name "fixtures/" (file-name-directory
                                 (or load-file-name buffer-file-name))))

(defun wdt--read (file)
  (with-temp-buffer
    (insert-file-contents (expand-file-name file wdt--dir))
    (buffer-string)))

(defun wdt--model (&optional kv)
  (waves-dashboard--model
   (waves-dashboard--json (wdt--read "demo-waves.json"))
   kv
   (waves-dashboard--parse-merges (wdt--read "demo-merges.txt"))
   (waves-dashboard--json (wdt--read "demo-created.json"))
   (waves-dashboard--time "2026-10-16T09:30:00Z")))

(defun wdt--wave (name waves)
  (cl-find name waves :key #'waves-dashboard-wave-name :test #'equal))

(ert-deftest waves-dashboard-beads-api-present ()
  (should (null (waves-dashboard--check-beads-api))))

(ert-deftest waves-dashboard-fallback-deploy-from-close-reasons ()
  (let* ((waves (wdt--model))
         (w6 (wdt--wave "6" waves))
         (w7 (wdt--wave "7" waves)))
    (should (eq (waves-dashboard-wave-state w6) 'shipped))
    (should (waves-dashboard-wave-deployed-approx w6))
    (should (equal (waves-dashboard-wave-sha w6) "3c9e1d7"))
    (should (equal (waves-dashboard-wave-sha w7) "5a0f2b8"))
    ;; Latest "Deployed" close of wave 6 was 08:18:55Z; demo-k8dp closed
    ;; later (08:40Z) as a duplicate, which must not count.
    (should (= (waves-dashboard-wave-deployed w6)
               (waves-dashboard--time "2026-10-16T08:18:55Z")))))

(ert-deftest waves-dashboard-kv-beats-fallback ()
  (let* ((waves (wdt--model '((wave.6.deployed . "2026-10-16T08:16:41Z 3c9e1d7")
                              (wave.6.title . "Sidecars and safety")
                              (wave.8.dispatched . "2026-10-16T09:05:00Z"))))
         (w6 (wdt--wave "6" waves))
         (w8 (wdt--wave "8" waves)))
    (should-not (waves-dashboard-wave-deployed-approx w6))
    (should (= (waves-dashboard-wave-deployed w6)
               (waves-dashboard--time "2026-10-16T08:16:41Z")))
    (should (equal (waves-dashboard-wave-title w6) "Sidecars and safety"))
    (should (eq (waves-dashboard-wave-state w8) 'in-flight))))

(ert-deftest waves-dashboard-merges-attach-to-waves ()
  (let* ((waves (wdt--model))
         (w6 (wdt--wave "6" waves))
         (subjects (mapcar (lambda (m) (plist-get m :subject))
                           (waves-dashboard-wave-merges w6))))
    (should (member "Merge demo-r8tq" subjects))
    ;; Not a bead id before the colon: stays out of every wave.
    (should-not (cl-some (lambda (s) (string-prefix-p "Merge cssfix" s)) subjects))))

(ert-deftest waves-dashboard-queued-waves-last ()
  (let* ((waves (wdt--model))
         (states (mapcar #'waves-dashboard-wave-state waves))
         (first-queued (cl-position 'queued states)))
    (should first-queued)
    (should (cl-every (lambda (s) (eq s 'queued)) (nthcdr first-queued states)))
    ;; hotfix merged after wave 7 deployed, so it is the newest.
    (should (equal (waves-dashboard-wave-name (car waves)) "hotfix"))))

(ert-deftest waves-dashboard-opened-skips-other-waves-beads ()
  ;; demo-w4nv was created 08:10Z, inside wave 6 (first merge 07:15Z,
  ;; deploy ~08:18Z), but it carries wave-7: filed as wave 7's work, not
  ;; found during wave 6.
  (let* ((waves (wdt--model))
         (w6 (wdt--wave "6" waves))
         (opened (mapcar (lambda (b) (alist-get 'id b))
                         (waves-dashboard-wave-opened w6))))
    (should-not (member "demo-w4nv" opened))))

(ert-deftest waves-dashboard-opened-during-wave ()
  ;; Inside one window: an unlabelled bead is opened during it, a
  ;; labelled one is not unless discovered from one of the wave's beads.
  (let* ((member '((id . "x-1") (status . "open") (labels "wave-1")))
         (found '((id . "x-2") (created_at . "2026-10-16T10:30:00Z")))
         (planned '((id . "x-3") (created_at . "2026-10-16T10:30:00Z")
                    (labels "wave-2")))
         (linked '((id . "x-4") (created_at . "2026-10-16T10:30:00Z")
                   (labels "wave-2")
                   (dependencies ((type . "discovered-from")
                                  (depends_on_id . "x-1")))))
         (waves (waves-dashboard--model
                 (list member planned linked)
                 '((wave.1.dispatched . "2026-10-16T10:00:00Z"))
                 nil
                 (list member found planned linked)
                 (waves-dashboard--time "2026-10-16T11:00:00Z")))
         (opened (mapcar (lambda (b) (alist-get 'id b))
                         (waves-dashboard-wave-opened (wdt--wave "1" waves)))))
    (should (equal opened '("x-2" "x-4")))))

(ert-deftest waves-dashboard-subject-ids ()
  (let ((known (make-hash-table :test 'equal)))
    (puthash "demo-mt4q" t known)
    (puthash "demo-5ffz" t known)
    (should (equal (waves-dashboard--subject-ids
                    "Merge demo-mt4q, demo-5ffz: link-check tests" known)
                   '("demo-mt4q" "demo-5ffz")))
    ;; A merge that only mentions a bead, or names one after the colon.
    (should-not (waves-dashboard--subject-ids
                 "Make a new save cancel the running rebuild (demo-mt4q item 2)" known))
    (should-not (waves-dashboard--subject-ids
                 "Merge cssfix: demo-mt4q message lint fix" known))))

(ert-deftest waves-dashboard-events-sorted ()
  (let* ((events (waves-dashboard--events (wdt--model)))
         (times (mapcar (lambda (e) (plist-get e :time)) events)))
    (should events)
    (should (equal times (sort (copy-sequence times) #'<)))))

(ert-deftest waves-dashboard-totals ()
  ;; Expected values are counted independently from the model.
  (let* ((waves (wdt--model))
         (totals (waves-dashboard--totals waves))
         (queued-beads (cl-loop for w in waves
                                when (eq (waves-dashboard-wave-state w) 'queued)
                                append (waves-dashboard-wave-beads w)))
         (closed-ids (delete-dups
                      (cl-loop for w in waves
                               append (cl-loop for b in (waves-dashboard-wave-beads w)
                                               when (equal (alist-get 'status b) "closed")
                                               collect (alist-get 'id b))))))
    (should (= (alist-get 'all (plist-get totals :waves)) (length waves)))
    (should (> (length queued-beads) 0))
    (should (= (alist-get 'all (plist-get totals :queued)) (length queued-beads)))
    (should (= (alist-get 'all (plist-get totals :closed)) (length closed-ids)))
    ;; Priority buckets add up to the total.
    (dolist (c '(:queued :new :closed))
      (let ((al (plist-get totals c)))
        (should (= (alist-get 'all al)
                   (apply #'+ (mapcar #'cdr (cl-remove 'all al :key #'car)))))))
    (should (= (plist-get totals :merges)
               (length (delete-dups
                        (cl-loop for w in waves
                                 append (mapcar (lambda (m) (plist-get m :sha))
                                                (waves-dashboard-wave-merges w)))))))))

(ert-deftest waves-dashboard-totals-dedupes-and-splits ()
  ;; A bead in two waves counts once per category; one opened in one wave
  ;; and closed in another counts as new and as closed.
  (let* ((b1 '((id . "x-1") (status . "closed") (priority . 1)))
         (b2 '((id . "x-2") (status . "open") (priority . 2)))
         (w1 (waves-dashboard-wave--make :name "1" :state 'shipped
                                         :beads (list b1)
                                         :merges '((:sha "aaa") (:sha "bbb"))))
         (w2 (waves-dashboard-wave--make :name "2" :state 'queued
                                         :beads (list b1 b2)
                                         :opened (list b1)
                                         :merges '((:sha "aaa"))))
         (totals (waves-dashboard--totals (list w1 w2))))
    (should (equal (alist-get 'all (plist-get totals :closed)) 1))
    (should (equal (alist-get 'all (plist-get totals :new)) 1))
    (should (equal (alist-get 'all (plist-get totals :queued)) 2))
    (should (equal (alist-get 1 (plist-get totals :queued)) 1))
    (should (equal (plist-get totals :merges) 2))
    (let ((lines (waves-dashboard--totals-lines totals t)))
      (should (string-match-p "2 waves (1 shipped, 1 queued)" (car lines)))
      (should (string-match-p "P1  *P2" (nth 1 lines)))
      (should (= (length lines) 5)))
    (should (= (length (waves-dashboard--totals-lines totals nil)) 1))))

(ert-deftest waves-dashboard-wrap-title-column ()
  ;; The hanging indent must land exactly where beads puts the title,
  ;; including when a field overflows its column width.
  (dolist (b '(((id . "demo-a1") (title . "Short") (status . "open")
                (priority . 2) (issue_type . "task"))
               ((id . "demo-very-long-id.12") (title . "Overflowing id")
                (status . "in_progress") (priority . 0)
                (issue_type . "feature"))))
    (with-temp-buffer
      (vui--render-vnode (waves-dashboard--issue-row b))
      (goto-char (point-min))
      (search-forward (alist-get 'title b))
      (let ((title-col (- (match-beginning 0) (line-beginning-position))))
        (should (= title-col (waves-dashboard--title-column b)))
        (should (equal (get-text-property (match-beginning 0) 'wrap-prefix)
                       `(space :align-to ,title-col)))))))

(ert-deftest waves-dashboard-wrap-off ()
  (let ((waves-dashboard-wrap nil))
    (should-not (get-text-property 0 'wrap-prefix
                                   (waves-dashboard--hang "x" 4)))))

(defun wdt--requeue-model (&rest extra-beads)
  "Wave 1 started 10:00, wave 2 at 11:00, wave 3 at 10:30 and shipped.
demo-a (open) is in waves 1 and 2, demo-b (closed) only in wave 1.
EXTRA-BEADS are added as they are."
  (let ((beads (append
                (list '((id . "demo-a") (status . "open") (labels "wave-1" "wave-2"))
                      '((id . "demo-b") (status . "closed") (labels "wave-1")
                        (closed_at . "2026-10-16T10:30:00Z"))
                      '((id . "demo-s") (status . "closed") (labels "wave-3")
                        (closed_at . "2026-10-16T11:00:00Z")))
                extra-beads)))
    (waves-dashboard--model
     beads
     '((wave.1.dispatched . "2026-10-16T10:00:00Z")
       (wave.2.dispatched . "2026-10-16T11:00:00Z")
       (wave.3.dispatched . "2026-10-16T10:30:00Z")
       (wave.3.deployed . "2026-10-16T11:30:00Z abc1234"))
     nil nil (waves-dashboard--time "2026-10-16T12:00:00Z"))))

(ert-deftest waves-dashboard-requeued-marks-later-waves-only ()
  (let* ((waves (wdt--requeue-model))
         (w1 (wdt--wave "1" waves))
         (w2 (wdt--wave "2" waves)))
    (should (equal (waves-dashboard-wave-requeued w1) '(("demo-a" . "2"))))
    ;; Wave 1 is earlier than wave 2, so nothing in wave 2 is re-queued.
    (should-not (waves-dashboard-wave-requeued w2))
    (should (waves-dashboard--all-requeued-p w1))
    (should (string-suffix-p " · re-queued" (waves-dashboard--header-title w1)))
    (should-not (string-match-p "re-queued" (waves-dashboard--header-title w2)))
    (should (member "1" (waves-dashboard--default-collapsed waves)))
    (should-not (member "2" (waves-dashboard--default-collapsed waves)))))

(ert-deftest waves-dashboard-requeued-needs-all-moved ()
  ;; One open bead that stays in wave 1: dimming yes, collapse no.
  (let* ((waves (wdt--requeue-model
                 '((id . "demo-c") (status . "open") (labels "wave-1"))))
         (w1 (wdt--wave "1" waves)))
    (should (assoc "demo-a" (waves-dashboard-wave-requeued w1)))
    (should-not (waves-dashboard--all-requeued-p w1))
    (should-not (member "1" (waves-dashboard--default-collapsed waves)))))

(ert-deftest waves-dashboard-requeued-ignores-shipped-waves ()
  ;; demo-d is open in wave 1 and in wave 3, which is later but shipped:
  ;; not re-queued.
  (let* ((waves (wdt--requeue-model
                 '((id . "demo-d") (status . "open") (labels "wave-1" "wave-3"))))
         (w1 (wdt--wave "1" waves)))
    (should-not (assoc "demo-d" (waves-dashboard-wave-requeued w1)))))

(ert-deftest waves-dashboard-requeued-row-is-dim ()
  (with-temp-buffer
    (vui--render-vnode
     (waves-dashboard--issue-row
      '((id . "demo-a") (title . "Moved") (status . "open") (priority . 2)
        (issue_type . "task"))
      "  → wave-2" t))
    (goto-char (point-min))
    (search-forward "Moved")
    (should (eq (get-text-property (match-beginning 0) 'face)
                'waves-dashboard-requeued))
    (goto-char (match-beginning 0))
    (should (equal (beads-section-issue-id-at-point) "demo-a"))
    (search-forward "→ wave-2")
    (should (eq (get-text-property (match-beginning 0) 'face)
                'waves-dashboard-requeued))))

(defun wdt--fold-defaults (w)
  "Render wave W's sections and return the (SUB . DEFAULT) pairs it asked for."
  (let (calls)
    (waves-dashboard--wave-vnode
     w nil #'ignore
     (lambda (sub default) (push (cons sub default) calls) (cons default #'ignore)))
    (nreverse calls)))

(ert-deftest waves-dashboard-subsections-fold-when-all-closed ()
  (let* ((closed '((id . "demo-b") (status . "closed")))
         (open '((id . "demo-a") (status . "open")))
         (done (waves-dashboard-wave--make
                :name "1" :state 'done :beads (list closed)
                :merges '((:sha "aaa" :time 1.0 :subject "Merge demo-b"))
                :opened (list open)))
         (busy (waves-dashboard-wave--make
                :name "2" :state 'in-flight :beads (list open closed)
                :merges '((:sha "bbb" :time 1.0 :subject "Merge demo-a"))
                :opened (list closed))))
    ;; Wave's beads all closed: beads and merges fold; an open bead opened
    ;; during it keeps that list open.
    (should (equal (wdt--fold-defaults done)
                   '(("beads" . t) ("merges" . t) ("opened" . nil))))
    (should (equal (wdt--fold-defaults busy)
                   '(("beads" . nil) ("merges" . nil) ("opened" . t))))))

(ert-deftest waves-dashboard-subsection-folds-and-toggles ()
  (let ((buf (generate-new-buffer " *wdt-fold*")))
    (unwind-protect
        (progn
          ;; A toggle in COLLAPSED beats the default.
          (should (car (waves-dashboard--fold buf "1/beads" nil t)))
          (should-not (car (waves-dashboard--fold buf "1/beads" '(("1/beads")) t)))
          (should (car (waves-dashboard--fold buf "1/beads" '(("1/beads" . t)) nil)))
          ;; Folded hides the children, unfolded shows them.
          (dolist (folded '(t nil))
            (with-temp-buffer
              (vui--render-vnode
               (waves-dashboard--subsection "Merges (1)" 'default
                                            (cons folded #'ignore)
                                            (list (vui-text "child line"))))
              (should (equal (not folded)
                             (and (string-match-p "child line" (buffer-string)) t)))
              (should (string-match-p (if folded "▸\\|▶" "▾\\|▼")
                                      (buffer-string))))))
      (kill-buffer buf))))

;;; waves-dashboard-test.el ends here

(ert-deftest waves-dashboard-model-kv-and-row ()
  (let* ((waves (wdt--model '(("wave.6.model.demo-r8tq" . "sonnet")
                              ("wave.6.title" . "T"))))
         (w1 (wdt--wave "6" waves)))
    (should (equal (cdr (assoc "demo-r8tq" (waves-dashboard-wave-models w1)))
                   "sonnet"))
    (should (equal (waves-dashboard-wave-title w1) "T"))
    (should-not (assoc "model.demo-a" (waves-dashboard-wave-models w1)))
    (with-temp-buffer
      (vui--render-vnode (waves-dashboard--wave-vnode
                          w1 nil #'ignore
                          (lambda (_ d) (cons nil #'ignore))))
      (goto-char (point-min))
      (should (search-forward "[sonnet]" nil t)))))

(ert-deftest waves-dashboard-tokens-kv-and-row ()
  (let* ((waves (wdt--model '(("wave.6.model.demo-r8tq" . "sonnet")
                              ("wave.6.tokens.demo-r8tq" . "67400")
                              ("wave.6.tokens.review" . "90000")
                              ("wave.6.tokens.demo-a" . "junk"))))
         (w1 (wdt--wave "6" waves)))
    (should (equal (cdr (assoc "demo-r8tq" (waves-dashboard-wave-tokens w1)))
                   67400))
    (should-not (assoc "demo-a" (waves-dashboard-wave-tokens w1)))
    (cl-flet ((render (on)
                (with-temp-buffer
                  (setq waves-dashboard--tokens on)
                  (vui--render-vnode (waves-dashboard--wave-vnode
                                      w1 nil #'ignore
                                      (lambda (_ d) (cons nil #'ignore))))
                  (buffer-string))))
      (let ((off (render nil)) (on (render t)))
        (should (string-search "[sonnet]" off))
        (should-not (string-search "67k" off))
        (should (string-search "[sonnet 67k]" on))
        (should (string-search "· 157k tokens (review 90k)" on))))
    (let ((lines (waves-dashboard--tokens-lines waves)))
      (should (equal (car lines)
                     "  Tokens  157k across 1 waves · 1 beads · 67k per bead"))
      (should (equal (cadr lines)
                     "          wave-6        157k  review 90k")))
    (should (equal (waves-dashboard--tokens-lines (wdt--model))
                   '("  Tokens  none recorded (wave tokens <wave> <id> <count>)")))))

(ert-deftest waves-dashboard-fmt-tokens ()
  (should (equal (waves-dashboard--fmt-tokens 950) "950"))
  (should (equal (waves-dashboard--fmt-tokens 67400) "67k"))
  (should (equal (waves-dashboard--fmt-tokens 999499) "999k"))
  (should (equal (waves-dashboard--fmt-tokens 999500) "1.0M"))
  (should (equal (waves-dashboard--fmt-tokens 1250000) "1.2M")))

(ert-deftest waves-dashboard-state-icon-emoji-or-text ()
  (let ((waves-dashboard--emoji t))
    (should (equal (waves-dashboard--state-icon 'shipped) "🚀")))
  (let ((waves-dashboard--emoji nil))
    (should (equal (mapcar #'waves-dashboard--state-icon
                           '(shipped done in-flight queued))
                   '("[deployed]" "[closed]" "[in flight]" "[queued]")))))

(ert-deftest waves-dashboard-auto-refresh-toggles-timer ()
  (with-temp-buffer
    (waves-dashboard-mode)
    (let ((waves-dashboard-refresh-interval 3600))
      (waves-dashboard-toggle-auto-refresh)
      (should (timerp waves-dashboard--timer))
      (waves-dashboard-toggle-auto-refresh)
      (should-not waves-dashboard--timer))))

(ert-deftest waves-dashboard-tick-refreshes-only-shown-buffers ()
  (let ((calls 0))
    (cl-letf (((symbol-function 'waves-dashboard-refresh)
               (lambda () (cl-incf calls))))
      (with-temp-buffer
        (waves-dashboard--tick (current-buffer))      ; not shown
        (should (= calls 0))
        (save-window-excursion
          (switch-to-buffer (current-buffer))
          (waves-dashboard--tick (current-buffer))
          (should (= calls 1))))
      (waves-dashboard--tick (get-buffer-create " gone"))
      (kill-buffer " gone"))))

(ert-deftest waves-dashboard-fold-alist-levels ()
  (let* ((waves (list (waves-dashboard-wave--make :name "6")))
         (name "6"))
    (should (equal (waves-dashboard--fold-alist waves t 'default)
                   `((,name . t))))
    (should (equal (waves-dashboard--fold-alist waves nil t)
                   `((,name . nil) (,(concat name "/beads") . t)
                     (,(concat name "/merges") . t)
                     (,(concat name "/opened") . t))))
    (should (equal (mapcar #'cdr (waves-dashboard--fold-alist waves nil nil))
                   '(nil nil nil nil)))))

(ert-deftest waves-dashboard-display-adjacent ()
  (save-window-excursion
    (delete-other-windows)
    (let ((buf (generate-new-buffer " *wd-adjacent*"))
          (first (selected-window)))
      (unwind-protect
          (progn
            ;; Alone: it splits, and the new window shows the buffer.
            (let ((win (waves-dashboard--display-adjacent buf nil)))
              (should (window-live-p win))
              (should-not (eq win first))
              (should (eq (window-buffer win) buf)))
            ;; Shown in another window: it is reused, nothing else splits.
            (let ((n (length (window-list))))
              (should (eq (waves-dashboard--display-adjacent buf nil)
                          (get-buffer-window buf)))
              (should (= n (length (window-list)))))
            ;; Shown only in the selected window: it still moves beside it.
            (set-window-buffer (get-buffer-window buf) (window-buffer first))
            (set-window-buffer first buf)
            (select-window first)
            (should-not (eq (waves-dashboard--display-adjacent buf nil) first)))
        (kill-buffer buf)))))

;;; Review and merge phases

(defun wdt--phase-wave (kv &optional status)
  "Wave 1: one bead with STATUS (default closed) and the kv facts KV."
  (wdt--wave "1" (waves-dashboard--model
                  (list `((id . "demo-a") (status . ,(or status "closed"))
                          (labels "wave-1")
                          (closed_at . "2026-10-16T10:30:00Z")))
                  (append '((wave.1.dispatched . "2026-10-16T10:00:00Z")) kv)
                  nil nil (waves-dashboard--time "2026-10-16T12:00:00Z"))))

(defconst wdt--rs '(wave.1.review.started . "2026-10-16T10:40:00Z"))
(defconst wdt--rf '(wave.1.review.finished . "2026-10-16T11:00:00Z findings=3 fixed=2"))
(defconst wdt--ms '(wave.1.merge.started . "2026-10-16T11:10:00Z"))
(defconst wdt--mc '(wave.1.merge.completed . "2026-10-16T11:15:00Z abc1234"))
(defconst wdt--dp '(wave.1.deployed . "2026-10-16T11:30:00Z abc1234"))

(ert-deftest waves-dashboard-phase-state-precedence ()
  (dolist (case `((nil done)
                  ((,wdt--rs) in-review)  ; all closed, but review beats done
                  ((,wdt--rs ,wdt--rf) reviewed)
                  ((,wdt--rs ,wdt--rf ,wdt--ms) merging)
                  ((,wdt--ms) merging)    ; review skipped
                  ((,wdt--rs ,wdt--ms ,wdt--mc) merged)
                  ((,wdt--mc) merged)
                  ((,wdt--rs ,wdt--rf ,wdt--ms ,wdt--mc ,wdt--dp) shipped)
                  ((,wdt--mc ,wdt--dp) shipped)))
    (should (equal (list (car case)
                         (waves-dashboard-wave-state (wdt--phase-wave (car case))))
                   case))))

(ert-deftest waves-dashboard-phase-beats-in-flight ()
  (should (eq (waves-dashboard-wave-state (wdt--phase-wave nil "open")) 'in-flight))
  (should (eq (waves-dashboard-wave-state
               (wdt--phase-wave (list wdt--rs) "open"))
              'in-review)))

(ert-deftest waves-dashboard-phase-kv-parsed ()
  (let ((w (wdt--phase-wave (list wdt--rs wdt--rf wdt--ms wdt--mc))))
    (should (= (waves-dashboard-wave-review-started w)
               (waves-dashboard--time "2026-10-16T10:40:00Z")))
    (should (= (waves-dashboard-wave-review-finished w)
               (waves-dashboard--time "2026-10-16T11:00:00Z")))
    (should (equal (list (waves-dashboard-wave-findings w)
                         (waves-dashboard-wave-fixed w))
                   '(3 2)))
    (should (= (waves-dashboard-wave-merge-completed w)
               (waves-dashboard--time "2026-10-16T11:15:00Z")))
    (should (equal (waves-dashboard-wave-merge-sha w) "abc1234"))
    (should (equal (waves-dashboard--findings-text w) "3 findings, 2 fixed")))
  ;; No counts recorded: no counts shown.  One finding is singular.
  (let ((w (wdt--phase-wave '((wave.1.review.started . "2026-10-16T10:40:00Z")
                              (wave.1.review.finished . "2026-10-16T11:00:00Z")))))
    (should (waves-dashboard-wave-review-finished w))
    (should-not (waves-dashboard--findings-text w)))
  (should (equal (waves-dashboard--findings-text
                  (waves-dashboard-wave--make :findings 1))
                 "1 finding")))

(ert-deftest waves-dashboard-phase-header-and-lines ()
  (let ((reviewing (wdt--phase-wave (list wdt--rs)))
        (reviewed (wdt--phase-wave (list wdt--rs wdt--rf)))
        (merging (wdt--phase-wave (list wdt--rs wdt--rf wdt--ms)))
        (merged (wdt--phase-wave (list wdt--ms wdt--mc))))
    (should (string-match-p " · in review since "
                            (waves-dashboard--header-title reviewing)))
    (should (string-match-p " · reviewed .* (3 findings, 2 fixed)\\'"
                            (waves-dashboard--header-title reviewed)))
    (should (string-match-p " · merging since "
                            (waves-dashboard--header-title merging)))
    (should (string-match-p " · merged .* (abc1234)\\'"
                            (waves-dashboard--header-title merged)))
    (should (equal (length (waves-dashboard--phase-lines reviewing)) 1))
    (should (equal (length (waves-dashboard--phase-lines merging)) 2))
    ;; Review skipped: only the merge line.
    (should (equal (length (waves-dashboard--phase-lines merged)) 1))
    (with-temp-buffer
      (vui--render-vnode (waves-dashboard--wave-vnode
                          merging nil #'ignore
                          (lambda (_ d) (cons d #'ignore))))
      (let ((text (buffer-string)))
        (should (string-match-p
                 "^    Review started .* · finished .* · 3 findings, 2 fixed$" text))
        (should (string-match-p "^    Merge started [^·\n]*$" text))
        ;; Phase lines come before the Dispatched subsection.
        (should (< (string-match "Review started" text)
                   (string-match "Dispatched" text)))))
    (with-temp-buffer
      (vui--render-vnode (waves-dashboard--wave-vnode
                          merged nil #'ignore
                          (lambda (_ d) (cons d #'ignore))))
      (should (string-match-p "^    Merge started .* · completed .* · abc1234$"
                              (buffer-string)))
      (should-not (string-match-p "Review" (buffer-string))))
    ;; A collapsed wave shows its header only.
    (with-temp-buffer
      (vui--render-vnode (waves-dashboard--wave-vnode
                          merging t #'ignore
                          (lambda (_ d) (cons d #'ignore))))
      (should-not (string-match-p "Review started" (buffer-string))))))

(ert-deftest waves-dashboard-phase-events ()
  (let* ((w (wdt--phase-wave (list wdt--rs wdt--rf wdt--ms wdt--mc)))
         (events (cl-remove-if-not
                  (lambda (e) (string-match-p "\\`\\(review\\|merge\\)-"
                                              (plist-get e :kind)))
                  (waves-dashboard--events (list w)))))
    (should (equal (mapcar (lambda (e) (list (plist-get e :kind) (plist-get e :text)))
                           events)
                   '(("review-started" "") ("review-finished" "3 findings, 2 fixed")
                     ("merge-started" "") ("merge-completed" "abc1234"))))
    (should (equal (plist-get (car events) :time)
                   (waves-dashboard--time "2026-10-16T10:40:00Z")))))

(ert-deftest waves-dashboard-phase-icons-distinct ()
  (let ((states (mapcar #'car waves-dashboard--states)))
    (should (equal states '(shipped merged merging reviewed in-review
                            done in-flight queued)))
    (dolist (emoji '(t nil))
      (let* ((waves-dashboard--emoji emoji)
             (icons (mapcar #'waves-dashboard--state-icon states)))
        (should (= (length (delete-dups (copy-sequence icons))) (length states)))))
    (let ((waves-dashboard--emoji nil))
      (should (equal (mapcar #'waves-dashboard--state-icon
                             '(in-review reviewed merging merged))
                     '("[in review]" "[reviewed]" "[merging]" "[merged]"))))))

(ert-deftest waves-dashboard-phase-requeued-and-collapse ()
  ;; demo-a is open in wave 1 and in a later wave 2.  A later wave still in
  ;; review has not finished, so demo-a moved on to it; a merged one has.
  (cl-flet ((model (kv)
              (waves-dashboard--model
               (list '((id . "demo-a") (status . "open") (labels "wave-1" "wave-2")))
               (append '((wave.1.dispatched . "2026-10-16T10:00:00Z")
                         (wave.2.dispatched . "2026-10-16T11:00:00Z"))
                       kv)
               nil nil (waves-dashboard--time "2026-10-16T12:00:00Z"))))
    (dolist (case '((wave.2.review.started . in-review)
                    (wave.2.review.finished . reviewed)
                    (wave.2.merge.started . merging)))
      (let* ((waves (model (list (cons (car case) "2026-10-16T11:30:00Z"))))
             (w1 (wdt--wave "1" waves)))
        (should (eq (waves-dashboard-wave-state (wdt--wave "2" waves)) (cdr case)))
        (should (equal (waves-dashboard-wave-requeued w1) '(("demo-a" . "2"))))))
    (let ((waves (model '((wave.2.merge.started . "2026-10-16T11:30:00Z")
                          (wave.2.merge.completed . "2026-10-16T11:40:00Z")))))
      (should-not (waves-dashboard-wave-requeued (wdt--wave "1" waves)))))
  ;; Merged waves count as finished for the expanded-shipped limit.
  (let ((waves-dashboard-expanded-shipped 1))
    (should (equal (waves-dashboard--default-collapsed
                    (list (waves-dashboard-wave--make :name "2" :state 'merged)
                          (waves-dashboard-wave--make :name "1" :state 'shipped)
                          (waves-dashboard-wave--make :name "3" :state 'in-review)))
                   '("1")))))

(ert-deftest waves-dashboard-phase-totals-labels ()
  (let ((lines (waves-dashboard--totals-lines
                (waves-dashboard--totals
                 (list (waves-dashboard-wave--make :name "1" :state 'in-review)
                       (waves-dashboard-wave--make :name "2" :state 'merged)))
                nil)))
    (should (string-match-p "2 waves (1 merged, 1 in review)" (car lines)))))
