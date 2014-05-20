; ACL2 Version 6.4 -- A Computational Logic for Applicative Common Lisp
; Copyright (C) 2014, Regents of the University of Texas

; This version of ACL2 is a descendent of ACL2 Version 1.9, Copyright
; (C) 1997 Computational Logic, Inc.  See the documentation topic NOTE-2-0.

; This program is free software; you can redistribute it and/or modify
; it under the terms of the LICENSE file distributed with ACL2.

; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; LICENSE for more details.

; Written by:  Matt Kaufmann               and J Strother Moore
; email:       Kaufmann@cs.utexas.edu      and Moore@cs.utexas.edu
; Department of Computer Science
; University of Texas at Austin
; Austin, TX 78712 U.S.A.

(in-package "ACL2")

; Section:  Proof Trees

; We develop proof trees in this file, rather than in prove.lisp, because
; print-summary calls print-proof-tree.

; A goal tree is a structure of the following form, with the fields indicated
; below.  We put the two non-changing fields at the end; note:

; ACL2 p>:sbt 4
;
; The Binary Trees with Four Tips
; 2.000  ((2 . 2) 2 . 2)
; 2.250  (1 2 3 . 3)

(defrec goal-tree (children processor cl-id . fanout) nil)

; Cl-id is a clause-id record for the name of the goal.

; Children is a list of goal trees whose final cdr is either nil or a positive
; integer.  In the latter case, this positive integer indicates the remaining
; number of children for which to build goal trees.

; Fanout is the original number of children.

; Processor is one of the processors from *preprocess-clause-ledge* (except for
; settled-down-clause, which has no use here), except that we have two special
; annotations and two "fictitious" processors.

; Instead of push-clause, we use (push-clause cl-id), where cl-id is the
; clause-id of the clause pushed (e.g., the clause-id corresponding to "*1").
; Except: (push-clause cl-id :REVERT) is used when we are reverting to the
; original goal, and in this case, cl-id always corresponds to *1; also,
; (push-clause cl-id :ABORT) is used when the proof is aborted by push-clause.

; Instead of a processor pr, we may have (pr :forced), which indicates that
; this processor forced assumptions (but remember, some of those might get
; proved during the final clean-up phase).  When we enter the next forcing
; round, we will "decorate" the above "processor" by adding a list of new goals
; created by that forcing: (pr :forced clause-id_1 ... clause-id_n).  As we go
; along we may prune away some of those new clause ids.

; Finally, occasionally the top-level node in a goal-tree is "fictitious", such
; as the one for "[1]Goal" if the first forcing round presented more than one
; forced goal, and such as any goal to be proved by induction.  In that case,
; the "processor" is one of the keyword labels :INDUCT or :FORCING-ROUND or a
; list headed by such keywords, e.g. if we want to say what induction scheme is
; being used.

; A proof tree is simply a non-empty list of goal trees.  The "current" goal
; tree is the CAR of the current proof tree; it's the one for the current
; forcing round or proof by induction.

; There is always a current proof tree, (@ proof-tree), except when we are
; inhibiting proof-tree output or are not yet in a proof.  The current goal in
; a proof is always the first one associated with the first subtree of the
; current goal-tree that has a non-nil final CDR, via a left-to-right
; depth-first traversal of that tree.  We keep the proof tree pruned, trimming
; away proved subgoals and their children.

; The proof tree is printed to the screen, enclosed in #\n\<0 ... #\n\>.  We
; start with # because that seems like a rare character, and we want to leave
; emacs as unburdened as possible in its use of string-matching.  And, we put a
; newline in front of \ because in ordinary PRINT-like (as opposed to
; PRINC-like) printing, as done by the prover, \ is always quoted and hence
; would not appear in a sequence such as <newline>\?, where ? is any character
; besides \.  Naturally, this output can be inhibited, simply by putting
; 'proof-tree on the state global variable inhibit-output-lst.  Mike Smith has
; built, and we have modified, a "filter" tool for redirecting such output in a
; nice form to appropriate emacs buffers.  People who do not want to use the
; emacs facility (or some other display utility) should probably inhibit
; proof-tree output using :stop-proof-tree.

(defun start-proof-tree-fn (remove-inhibit-p state)

; Note that we do not override existing values of the indicated state global
; variables.

  (if remove-inhibit-p
      (f-put-global 'inhibit-output-lst
                    (remove1-eq 'proof-tree
                                (f-get-global 'inhibit-output-lst state))
                    state)
    state))

#+acl2-loop-only
(defmacro start-proof-tree ()
  '(pprogn (start-proof-tree-fn t state)
           (fms "Proof tree output is now enabled.  Note that ~
                 :START-PROOF-TREE works by removing 'proof-tree from ~
                 the inhibit-output-lst; see :DOC ~
                 set-inhibit-output-lst.~%"
                nil
                (standard-co state)
                state
                nil)
           (value :invisible)))

#-acl2-loop-only
(defmacro start-proof-tree ()
  '(let ((state *the-live-state*))
     (fms "IT IS ILLEGAL to invoke (START-PROOF-TREE) from raw Lisp.  Please ~
           first enter the ACL2 command loop with (LP)."
          nil
          (proofs-co state)
          state
          nil)
     (values)))

(defmacro checkpoint-forced-goals (val)
  `(pprogn (f-put-global 'checkpoint-forced-goals ',val state)
           (value ',val)))

(defun stop-proof-tree-fn (state)
  (f-put-global 'inhibit-output-lst
                (add-to-set-eq 'proof-tree
                               (f-get-global 'inhibit-output-lst state))
                state))

(defmacro stop-proof-tree ()
  '(pprogn (stop-proof-tree-fn state)
           (fms "Proof tree output is now inhibited.  Note that ~
                 :STOP-PROOF-TREE works by adding 'proof-tree to the ~
                 inhibit-output-lst; see :DOC set-inhibit-output-lst.~%"
                nil
                (standard-co state)
                state
                nil)
           (value :invisible)))

(mutual-recursion

(defun insert-into-goal-tree-rec (cl-id processor n goal-tree)
  (let ((new-children (insert-into-goal-tree-lst
                       cl-id processor n
                       (access goal-tree goal-tree :children))))
    (and new-children
         (change goal-tree goal-tree
                 :children new-children))))

(defun insert-into-goal-tree-lst (cl-id processor n goal-tree-lst)
  (cond
   ((consp goal-tree-lst)
    (let ((new-child (insert-into-goal-tree-rec
                      cl-id processor n (car goal-tree-lst))))
      (if new-child
          (cons new-child (cdr goal-tree-lst))
        (let ((rest-children (insert-into-goal-tree-lst
                              cl-id processor n (cdr goal-tree-lst))))
          (if rest-children
              (cons (car goal-tree-lst) rest-children)
            nil)))))
   ((integerp goal-tree-lst)
    (cons (make goal-tree
                :cl-id cl-id
                :processor processor
                :children n
                :fanout (or n 0))
          (if (eql goal-tree-lst 1)
              nil
            (1- goal-tree-lst))))
   (t nil)))
)

(defun insert-into-goal-tree (cl-id processor n goal-tree)

; This function updates the indicated goal-tree by adding a new goal tree built
; from cl-id, processor, and n, in place of the first integer "children" field
; of a subgoal in a left-to-right depth-first traversal of the goal-tree.
; (Recall that an integer represents the number of unproved children remaining;
; hence the first integer found corresponds to the goal that corresponds to the
; parameters of this function.)  However, we return nil if no integer
; "children" field is found; similarly for the -rec and -lst versions, above.

; Note that n should be nil or a (strictly) positive integer.  Also note that
; when cl-id is *initial-clause-id*, then goal-tree doesn't matter (for
; example, it may be nil).

  (cond
   ((equal cl-id *initial-clause-id*)
    (make goal-tree
          :cl-id cl-id
          :processor processor
          :children n
          :fanout (or n 0)))
   (t (insert-into-goal-tree-rec cl-id processor n goal-tree))))

(defun set-difference-equal-changedp (l1 l2)

; Like set-difference-equal, but returns (mv changedp lst) where lst is the set
; difference and changedp is t iff the set difference is not equal to l1.

  (declare (xargs :guard (and (true-listp l1)
                              (true-listp l2))))
  (cond ((endp l1) (mv nil nil))
        (t (mv-let (changedp lst)
                   (set-difference-equal-changedp (cdr l1) l2)
                   (cond
                    ((member-equal (car l1) l2)
                     (mv t lst))
                    (changedp (mv t (cons (car l1) lst)))
                    (t (mv nil l1)))))))

(mutual-recursion

(defun prune-goal-tree (forcing-round dead-clause-ids goal-tree)

; Removes all proved goals from a goal tree, where all dead-clause-ids are
; considered proved.  Actually returns two values:  a new goal tree (or nil),
; and a new (extended) list of dead-clause-ids.

; Goals with processor (push-clause id . x) are handled similarly to forced
; goals, except that we know that there is a unique child.

; Note that a non-nil final cdr prevents a goal from being considered proved
; (unless its clause-id is dead, which shouldn't happen), which is appropriate.

  (let* ((processor (access goal-tree goal-tree :processor))
         (cl-id (access goal-tree goal-tree :cl-id))
         (goal-forcing-round (access clause-id cl-id :forcing-round)))
    (cond ((member-equal cl-id dead-clause-ids)
           (mv (er hard 'prune-goal-tree
                   "Surprise!  We didn't think this case could occur.")
               dead-clause-ids))
          ((and (not (= forcing-round goal-forcing-round))

; So, current goal is from a previous forcing round.

                (consp processor)
                (eq (cadr processor) :forced))

; So, processor is of the form (pr :forced clause-id_1 ... clause-id_n).

           (mv-let
            (changedp forced-clause-ids)
            (set-difference-equal-changedp (cddr processor) dead-clause-ids)
            (cond
             ((null forced-clause-ids)
              (mv nil (cons cl-id dead-clause-ids)))

; Notice that goal-tree may have children, even though it comes from an earlier
; forcing round, because it may have generated children that themselves did
; some forcing.

             (t
              (mv-let
               (children new-dead-clause-ids)
               (prune-goal-tree-lst
                forcing-round
                dead-clause-ids
                (access goal-tree goal-tree :children))
               (cond
                (changedp
                 (mv (change goal-tree goal-tree
                             :processor
                             (list* (car processor) :forced forced-clause-ids)
                             :children children)
                     new-dead-clause-ids))
                (t (mv (change goal-tree goal-tree
                               :children children)
                       new-dead-clause-ids))))))))
          ((and (consp processor)
                (eq (car processor) 'push-clause))
           (assert$
            (null (access goal-tree goal-tree :children))

; It is tempting also to assert (null (cddr processor)), i.e., that we have not
; reverted or aborted.  But that can fail for a branch of a disjunctive (:or)
; split.

            (if (member-equal (cadr processor) dead-clause-ids)
                (mv nil (cons cl-id dead-clause-ids))
              (mv goal-tree dead-clause-ids))))
          (t
           (mv-let (children new-dead-clause-ids)
                   (prune-goal-tree-lst forcing-round
                                        dead-clause-ids
                                        (access goal-tree goal-tree :children))
                   (cond
                    ((or children

; Note that the following test implies that we're in the current forcing round,
; and hence "decoration" (adding a list of new goals created by that forcing)
; has not yet been done.

                         (and (consp processor)
                              (eq (cadr processor) :forced)))
                     (mv (change goal-tree goal-tree
                                 :children children)
                         new-dead-clause-ids))
                    (t (mv nil (cons cl-id new-dead-clause-ids)))))))))

(defun prune-goal-tree-lst (forcing-round dead-clause-ids goal-tree-lst)
  (cond
   ((consp goal-tree-lst)
    (mv-let (x new-dead-clause-ids)
            (prune-goal-tree forcing-round dead-clause-ids (car goal-tree-lst))
            (if x
                (mv-let (rst newer-dead-clause-ids)
                        (prune-goal-tree-lst
                         forcing-round new-dead-clause-ids (cdr goal-tree-lst))
                        (mv (cons x rst)
                            newer-dead-clause-ids))
              (prune-goal-tree-lst
               forcing-round new-dead-clause-ids (cdr goal-tree-lst)))))
   (t (mv goal-tree-lst dead-clause-ids))))

)

(defun prune-proof-tree (forcing-round dead-clause-ids proof-tree)
  (if (null proof-tree)
      nil
    (mv-let (new-goal-tree new-dead-clause-ids)
            (prune-goal-tree forcing-round dead-clause-ids (car proof-tree))
            (if new-goal-tree
                (cons new-goal-tree
                      (prune-proof-tree forcing-round
                                        new-dead-clause-ids
                                        (cdr proof-tree)))
              (prune-proof-tree forcing-round
                                new-dead-clause-ids
                                (cdr proof-tree))))))

(defun print-string-repeat (increment level col channel state)
  (declare (type (signed-byte 30) col level))
  (the2s
   (signed-byte 30)
   (if (= level 0)
       (mv col state)
     (mv-letc (col state)
              (fmt1 "~s0"
                    (list (cons #\0 increment))
                    col channel state nil)
              (print-string-repeat increment (1-f level) col channel state)))))

(defconst *format-proc-alist*
  '((apply-top-hints-clause-or-hit . ":OR")
    (apply-top-hints-clause . "top-level-hints")
    (preprocess-clause . "preprocess")
    (simplify-clause . "simp")
    ;;settled-down-clause
    (eliminate-destructors-clause . "ELIM")
    (fertilize-clause . "FERT")
    (generalize-clause . "GEN")
    (eliminate-irrelevance-clause . "IRREL")
    ;;push-clause
    ))

(defun format-forced-subgoals (clause-ids col max-col channel state)

; Print the "(FORCED ...)" annotation, e.g., the part after "(FORCED" on this
; line:

;   0 |  Subgoal 3 simp (FORCED [1]Subgoal 1)

  (cond
   ((null clause-ids)
    (princ$ ")" channel state))
   (t (let ((goal-name (string-for-tilde-@-clause-id-phrase (car clause-ids))))
        (if (or (null max-col)

; We must leave room for final " ...)" if there are more goals, in addition to
; the space, the goal name, and the comma.  Otherwise, we need room for the
; space and the right paren.

                (if (null (cdr clause-ids))
                    (<= (+ 2 col (length goal-name)) max-col)
                  (<= (+ 7 col (length goal-name)) max-col)))
            (mv-let (col state)
                    (fmt1 " ~s0~#1~[~/,~]"
                          (list (cons #\0 goal-name)
                                (cons #\1 clause-ids))
                          col channel state nil)
                    (format-forced-subgoals
                     (cdr clause-ids) col max-col channel state))
          (princ$ " ...)" channel state))))))

(defun format-processor (col goal-tree channel state)
  (let ((proc (access goal-tree goal-tree :processor)))
    (cond
     ((consp proc)
      (cond
       ((eq (car proc) 'push-clause)
        (mv-let
         (col state)
         (fmt1 "~s0 ~@1"
               (list (cons #\0 "PUSH")
                     (cons #\1
                           (cond
                            ((eq (caddr proc) :REVERT)
                             "(reverting)")
                            ((eq (caddr proc) :ABORT)
                             "*ABORTING*")
                            (t
                             (tilde-@-pool-name-phrase
                              (access clause-id
                                      (cadr proc)
                                      :forcing-round)
                              (access clause-id
                                      (cadr proc)
                                      :pool-lst))))))
               col channel state nil)
         (declare (ignore col))
         state))
       ((eq (cadr proc) :forced)
        (mv-let (col state)
                (fmt1 "~s0 (FORCED"

; Note that (car proc) is in *format-proc-alist*, because neither push-clause
; nor either of the "fake" processors (:INDUCT, :FORCING-ROUND) forces in the
; creation of subgoals.

                      (list (cons #\0 (cdr (assoc-eq (car proc)
                                                     *format-proc-alist*))))
                      col channel state nil)
                (format-forced-subgoals
                 (cddr proc) col
                 (f-get-global 'proof-tree-buffer-width state)
                 channel state)))
       (t (let ((err (er hard 'format-processor
                         "Unexpected shape for goal-tree processor, ~x0"
                         proc)))
            (declare (ignore err))
            state))))
     (t (princ$ (or (cdr (assoc-eq proc *format-proc-alist*))
                    proc)
                channel state)))))

(mutual-recursion

(defun format-goal-tree-lst
  (goal-tree-lst level fanout increment checkpoints
                 checkpoint-forced-goals channel state)
  (cond
   ((null goal-tree-lst)
    state)
   ((atom goal-tree-lst)
    (mv-let (col state)
            (pprogn (princ$ "     " channel state)
                    (print-string-repeat
                     increment
                     (the-fixnum! level 'format-goal-tree-lst)
                     5 channel state))
            (mv-let (col state)
                    (fmt1 "<~x0 ~#1~[~/more ~]subgoal~#2~[~/s~]>~%"
                          (list (cons #\0 goal-tree-lst)
                                (cons #\1 (if (= fanout goal-tree-lst) 0 1))
                                (cons #\2 (if (eql goal-tree-lst 1)
                                              0
                                            1)))
                          col channel state nil)
                    (declare (ignore col))
                    state)))
   (t
    (pprogn
     (format-goal-tree
      (car goal-tree-lst) level increment checkpoints
      checkpoint-forced-goals channel state)
     (format-goal-tree-lst
      (cdr goal-tree-lst) level fanout increment checkpoints
      checkpoint-forced-goals channel state)))))

(defun format-goal-tree (goal-tree level increment checkpoints
                                   checkpoint-forced-goals channel state)
  (let* ((cl-id (access goal-tree goal-tree :cl-id))
         (pool-lst (access clause-id cl-id :pool-lst))
         (fanout (access goal-tree goal-tree :fanout))
         (raw-processor (access goal-tree goal-tree :processor))
         (processor (if (atom raw-processor)
                        raw-processor
                      (car raw-processor))))
    (mv-letc
     (col state)
     (pprogn (mv-letc
              (col state)
              (fmt1 "~#0~[c~/ ~]~c1 "
                    (list (cons #\0 (if (or (member-eq processor checkpoints)
                                            (and checkpoint-forced-goals
                                                 (consp raw-processor)
                                                 (eq (cadr raw-processor)
                                                     :forced)))
                                        0
                                      1))
                          (cons #\1 (cons fanout 3)))
                    0 channel state nil)
              (print-string-repeat increment
                                   (the-fixnum! level 'format-goal-tree)
                                   col channel state)))
     (mv-letc
      (col state)
      (if (and (null (access clause-id cl-id :case-lst))
               (= (access clause-id cl-id :primes) 0)
               pool-lst)
          (fmt1 "~@0 "
                (list (cons #\0 (tilde-@-pool-name-phrase
                                 (access clause-id cl-id :forcing-round)
                                 pool-lst)))
                col channel state nil)
        (fmt1 "~@0 "
              (list (cons #\0 (tilde-@-clause-id-phrase cl-id)))
              col channel state nil))
      (pprogn
       (format-processor col goal-tree channel state)
       (pprogn
        (newline channel state)
        (format-goal-tree-lst
         (access goal-tree goal-tree :children)
         (1+ level) fanout increment checkpoints checkpoint-forced-goals
         channel state)))))))

)

(defun format-proof-tree (proof-tree-rev increment checkpoints
                                         checkpoint-forced-goals channel state)

; Recall that most recent forcing rounds correspond to the goal-trees closest
; to the front of a proof-tree.  But here, proof-tree-rev is the reverse of a
; proof-tree.

  (if (null proof-tree-rev)
      state
    (pprogn (format-goal-tree
             (car proof-tree-rev) 0 increment checkpoints
             checkpoint-forced-goals channel state)
            (if (null (cdr proof-tree-rev))
                state
              (mv-let (col state)
                      (fmt1 "++++++++++++++++++++++++++++++~%"
                            (list (cons #\0 increment))
                            0 channel state nil)
                      (declare (ignore col))
                      state))
            (format-proof-tree
             (cdr proof-tree-rev) increment checkpoints
             checkpoint-forced-goals channel state))))

(defun print-proof-tree1 (ctx channel state)
  (let ((proof-tree (f-get-global 'proof-tree state)))
    (if (null proof-tree)
        (if (and (consp ctx) (eq (car ctx) :failed))
            state
          (princ$ "Q.E.D." channel state))
      (format-proof-tree (reverse proof-tree)
                         (f-get-global 'proof-tree-indent state)
                         (f-get-global 'checkpoint-processors state)
                         (f-get-global 'checkpoint-forced-goals state)
                         channel
                         state))))

(defconst *proof-failure-string*
  "******** FAILED ********~|")

(defun print-proof-tree-ctx (ctx channel state)
  (let* ((failed-p (and (consp ctx) (eq (car ctx) :failed)))
         (actual-ctx (if failed-p (cdr ctx) ctx)))
    (mv-let
     (erp val state)
     (state-global-let*
      ((fmt-hard-right-margin 1000 set-fmt-hard-right-margin)
       (fmt-soft-right-margin 1000 set-fmt-soft-right-margin))

; We need the event name to fit on a single line, hence the state-global-let*
; above.

      (mv-let (col state)
              (fmt-ctx actual-ctx 0 channel state)
              (mv-let
               (col state)
               (fmt1 "~|~@0"
                     (list (cons #\0
                                 (if failed-p *proof-failure-string* "")))
                     col channel state nil)
               (declare (ignore col))
               (value nil))))
     (declare (ignore erp val))
     state)))

(defconst *proof-tree-start-delimiter* "#<\\<0")

(defconst *proof-tree-end-delimiter* "#>\\>")

(defun print-proof-tree-finish (state)
  (if (f-get-global 'proof-tree-start-printed state)
      (pprogn (mv-let (col state)
                      (fmt1! "~s0"
                             (list (cons #\0 *proof-tree-end-delimiter*))
                             0 (proofs-co state) state nil)
                      (declare (ignore col))
                      (f-put-global 'proof-tree-start-printed nil state)))
    state))

(defun print-proof-tree (state)

; WARNING: Every call of print-proof-tree should be underneath some call of the
; form (io? ...).  We thus avoid enclosing the body below with (io? proof-tree
; ...).

  (let ((chan (proofs-co state))
        (ctx (f-get-global 'proof-tree-ctx state)))
    (pprogn
     (if (f-get-global 'window-interfacep state)
         state
       (pprogn
        (f-put-global 'proof-tree-start-printed t state)
        (mv-let (col state)
                (fmt1 "~s0"
                      (list (cons #\0 *proof-tree-start-delimiter*))
                      0 chan state nil)
                (declare (ignore col)) ;print-proof-tree-ctx starts with newline
                state)))
     (print-proof-tree-ctx ctx chan state)
     (print-proof-tree1 ctx chan state)
     (print-proof-tree-finish state))))

(mutual-recursion

(defun decorate-forced-goals-1 (goal-tree clause-id-list forced-clause-id)
  (let ((cl-id (access goal-tree goal-tree :cl-id))
        (new-children (decorate-forced-goals-1-lst
                       (access goal-tree goal-tree :children)
                       clause-id-list
                       forced-clause-id)))
    (cond
     ((member-equal cl-id clause-id-list)
      (let ((processor (access goal-tree goal-tree :processor)))
        (change goal-tree goal-tree
                :processor
                (list* (car processor) :forced forced-clause-id (cddr processor))
                :children new-children)))
     (t
      (change goal-tree goal-tree
              :children new-children)))))

(defun decorate-forced-goals-1-lst
  (goal-tree-lst clause-id-list forced-clause-id)
  (cond
   ((null goal-tree-lst)
    nil)
   ((atom goal-tree-lst)

; By the time we've gotten this far, we've gotten to the next forcing round,
; and hence there shouldn't be any children remaining to process.  Of course, a
; forced goal can generate forced subgoals, so we can't say that there are no
; children -- but we CAN say that there are none remaining to process.

    (er hard 'decorate-forced-goals-1-lst
        "Unexpected goal-tree in call ~x0"
        (list 'decorate-forced-goals-1-lst
              goal-tree-lst
              clause-id-list
              forced-clause-id)))
   (t (cons (decorate-forced-goals-1
             (car goal-tree-lst) clause-id-list forced-clause-id)
            (decorate-forced-goals-1-lst
             (cdr goal-tree-lst) clause-id-list forced-clause-id)))))

)

(defun decorate-forced-goals (forcing-round goal-tree clause-id-list-list n)

; See decorate-forced-goals-in-proof-tree.

  (if (null clause-id-list-list)
      goal-tree
    (decorate-forced-goals
     forcing-round
     (decorate-forced-goals-1 goal-tree
                              (car clause-id-list-list)
                              (make clause-id
                                    :forcing-round forcing-round
                                    :pool-lst nil
                                    :case-lst (and n (list n))
                                    :primes 0))
     (cdr clause-id-list-list)
     (and n (1- n)))))

(defun decorate-forced-goals-in-proof-tree
  (forcing-round proof-tree clause-id-list-list n)

; This function decorates the goal trees in proof-tree so that the appropriate
; previous forcing round's goals are "blamed" for the new forcing round goals.
; See also extend-proof-tree-for-forcing-round.

; At the top level, n is either an integer greater than 1 or else is nil.  This
; corresponds respectively to whether or not there is more than one goal
; produced by the forcing round.

  (if (null proof-tree)
      nil
    (cons (decorate-forced-goals
           forcing-round (car proof-tree) clause-id-list-list n)
          (decorate-forced-goals-in-proof-tree
           forcing-round (cdr proof-tree) clause-id-list-list n))))

(defun assumnote-list-to-clause-id-list (assumnote-list)
  (if (null assumnote-list)
      nil
    (cons (access assumnote (car assumnote-list) :cl-id)
          (assumnote-list-to-clause-id-list (cdr assumnote-list)))))

(defun assumnote-list-list-to-clause-id-list-list (assumnote-list-list)
  (if (null assumnote-list-list)
      nil
    (cons (assumnote-list-to-clause-id-list (car assumnote-list-list))
          (assumnote-list-list-to-clause-id-list-list (cdr assumnote-list-list)))))

(defun extend-proof-tree-for-forcing-round
  (forcing-round parent-clause-id clause-id-list-list state)

; This function pushes a new goal tree onto the global proof-tree.  However, it
; decorates the existing goal trees so that the appropriate previous forcing
; round's goals are "blamed" for the new forcing round goals.  Specifically, a
; previous goal with clause id in a member of clause-id-list-list is blamed for
; creating the appropriate newly-forced goal, with (car clause-id-list-list)
; associated with the highest-numbered (first) forced goal, etc.

  (cond
   ((null clause-id-list-list)

; then the proof is complete!

    state)
   (t
    (let ((n (length clause-id-list-list))) ;note n>0
      (f-put-global
       'proof-tree
       (cons (make goal-tree
                   :cl-id parent-clause-id
                   :processor :FORCING-ROUND
                   :children n
                   :fanout n)
             (decorate-forced-goals-in-proof-tree
              forcing-round
              (f-get-global 'proof-tree state)
              clause-id-list-list
              (if (null (cdr clause-id-list-list))
                  nil
                (length clause-id-list-list))))
       state)))))

(defun initialize-proof-tree1 (parent-clause-id x pool-lst forcing-round ctx
                                                state)

; X is from the "x" argument of waterfall.  Thus, if we are starting a forcing
; round then x is list of pairs (assumnote-lst . clause) where the clause-ids
; from the assumnotes are the names of goals from the preceding forcing round
; to "blame" for the creation of that clause.

  (pprogn

; The user might have started up proof trees with something like (assign
; inhibit-output-lst nil).  In that case we need to ensure that appropriate
; state globals are initialized.  Note that start-proof-tree-fn does not
; override existing bindings of those state globals (which the user may have
; deliberately set).

   (start-proof-tree-fn nil state)
   (f-put-global 'proof-tree-ctx ctx state)
   (cond
    ((and (null pool-lst)
          (eql forcing-round 0))
     (f-put-global 'proof-tree nil state))
    (pool-lst
     (f-put-global 'proof-tree
                   (cons (let ((n (length x)))
                           (make goal-tree
                                 :cl-id parent-clause-id
                                 :processor :INDUCT
                                 :children (if (= n 0) nil n)
                                 :fanout n))
                         (f-get-global 'proof-tree state))
                   state))
    (t
     (extend-proof-tree-for-forcing-round
      forcing-round parent-clause-id
      (assumnote-list-list-to-clause-id-list-list (strip-cars x))
      state)))))

(defun initialize-proof-tree (parent-clause-id x ctx state)

; X is from the "x" argument of waterfall.  See initialize-proof-tree1.

; We assume (not (output-ignored-p 'proof-tree state)).

  (let ((pool-lst (access clause-id parent-clause-id :pool-lst))
        (forcing-round (access clause-id parent-clause-id
                               :forcing-round)))
    (pprogn
     (io? proof-tree nil state
          (ctx forcing-round pool-lst x parent-clause-id)
          (initialize-proof-tree1 parent-clause-id x pool-lst forcing-round ctx
                                  state))
     (io? prove nil state
          (forcing-round pool-lst)
          (cond ((intersectp-eq '(prove proof-tree)
                                (f-get-global 'inhibit-output-lst state))
                 state)
                ((and (null pool-lst)
                      (eql forcing-round 0))
                 (fms "<< Starting proof tree logging >>~|"
                      nil (proofs-co state) state nil))
                (t state))))))

(defconst *star-1-clause-id*
  (make clause-id
        :forcing-round 0
        :pool-lst '(1)
        :case-lst nil
        :primes 0))

(mutual-recursion

(defun revert-goal-tree-rec (cl-id revertp goal-tree)

; See revert-goal-tree.  This nest also returns a value cl-id-foundp, which is
; nil if the given cl-id was not found in goal-tree or any subsidiary goal
; trees, else :or-found if cl-id is found under a disjunctive split, else t.

  (let ((processor (access goal-tree goal-tree :processor)))
    (cond
     ((and (consp processor)
           (eq (car processor) 'push-clause))
      (mv (equal cl-id (access goal-tree goal-tree :cl-id))
          (if revertp
              (change goal-tree goal-tree
                      :processor
                      (list 'push-clause *star-1-clause-id* :REVERT))
            goal-tree)))
     (t (mv-let (cl-id-foundp new-children)
                (revert-goal-tree-lst (eq processor
                                          'apply-top-hints-clause-or-hit)
                                      cl-id
                                      revertp
                                      (access goal-tree goal-tree :children))
                (mv cl-id-foundp
                    (change goal-tree goal-tree :children new-children)))))))

(defun revert-goal-tree-lst (or-p cl-id revertp goal-tree-lst)

; Or-p is true if we want to limit changes to the member of goal-tree-lst that
; is, or has a subsidiary, goal-tree for cl-id.

  (cond
   ((atom goal-tree-lst)
    (mv nil nil))
   (t (mv-let (cl-id-foundp new-goal-tree)
              (revert-goal-tree-rec cl-id revertp (car goal-tree-lst))
              (cond ((or (eq cl-id-foundp :or-found)
                         (and cl-id-foundp or-p))
                     (mv :or-found
                         (cons new-goal-tree (cdr goal-tree-lst))))
                    (t (mv-let (cl-id-foundp2 new-goal-tree-lst)
                               (revert-goal-tree-lst or-p
                                                     cl-id
                                                     revertp
                                                     (cdr goal-tree-lst))
                               (mv (or cl-id-foundp2 cl-id-foundp)
                                   (cons (if (eq cl-id-foundp2 :or-found)
                                             (car goal-tree-lst)
                                           new-goal-tree)
                                         new-goal-tree-lst)))))))))

)

(defun revert-goal-tree (cl-id revertp goal-tree)

; If there are no disjunctive (:or) splits, this function replaces every final
; cdr of any :children field of each subsidiary goal tree (including goal-tree)
; by nil, for other than push-clause processors, indicating that there are no
; children left to consider proving.  If revertp is true, it also replaces each
; (push-clause *n) with (push-clause *star-1-clause-id* :REVERT), meaning that
; we are reverting.

; The spec in the case of disjunctive splits is similar, except that if cl-id
; is under such a split, then the changes described above are limited to the
; innermost disjunct containing cl-id.

  (mv-let (cl-id-foundp new-goal-tree)
          (revert-goal-tree-rec cl-id revertp goal-tree)
          (assert$ cl-id-foundp
                   new-goal-tree)))

; The pool is a list of pool-elements, as shown below.  We explain
; in push-clause.

(defrec pool-element (tag clause-set . hint-settings) t)

(defun pool-lst1 (pool n ans)
  (cond ((null pool) (cons n ans))
        ((eq (access pool-element (car pool) :tag)
             'to-be-proved-by-induction)
         (pool-lst1 (cdr pool) (1+ n) ans))
        (t (pool-lst1 (cdr pool) 1 (cons n ans)))))

(defun pool-lst (pool)

; Pool is a pool as constructed by push-clause.  That is, it is a list
; of pool-elements and the tag of each is either 'to-be-proved-by-
; induction or 'being-proved-by-induction.  Generally when we refer to
; a pool-lst we mean the output of this function, which is a list of
; natural numbers.  For example, '(3 2 1) is a pool-lst and *3.2.1 is
; its printed representation.

; If one thinks of the pool being divided into gaps by the
; 'being-proved-by-inductions (with gaps at both ends) then the lst
; has as many elements as there are gaps and the ith element, k, in
; the lst tells us there are k-1 'to-be-proved-by-inductions in the
; ith gap.

; Warning: It is assumed that the value of this function is always
; non-nil.  See the use of "jppl-flg" in the waterfall and in
; pop-clause.

  (pool-lst1 pool 1 nil))

(defun increment-proof-tree
  (cl-id ttree processor clause-count new-hist signal pspv state)

; Modifies the global proof-tree so that it incorporates the given cl-id, which
; creates n child goals via processor.  Also prints out the proof tree.

  (if (or (eq processor 'settled-down-clause)
          (and (consp new-hist)
               (consp (access history-entry (car new-hist)
                              :processor))))
      state
    (let* ((forcing-round (access clause-id cl-id :forcing-round))
           (aborting-p (and (eq signal 'abort)
                            (not (equal (tagged-objects 'abort-cause ttree)
                                        '(revert)))))
           (clause-count
            (cond ((eq signal 'or-hit)
                   (assert$
                    (eq processor 'apply-top-hints-clause)
                    (length (nth 2 (tagged-object :or ttree)))))
                  (t clause-count)))
           (processor
            (cond
             ((tagged-objectsp 'assumption ttree)
              (assert$ (and (not (eq processor 'push-clause))
                            (not (eq signal 'or-hit)))
                       (list processor :forced)))
             ((eq processor 'push-clause)
              (list* 'push-clause
                     (make clause-id
                           :forcing-round forcing-round
                           :pool-lst
                           (pool-lst
                            (cdr (access prove-spec-var pspv
                                         :pool)))
                           :case-lst nil
                           :primes 0)
                     (if aborting-p '(:ABORT) nil)))
             ((eq signal 'or-hit)
              'apply-top-hints-clause-or-hit)
             (t processor)))
           (starting-proof-tree (f-get-global 'proof-tree state))
           (new-goal-tree
            (insert-into-goal-tree cl-id
                                   processor
                                   (if (eql clause-count 0)
                                       nil
                                     clause-count)
                                   (car starting-proof-tree))))
      (pprogn
       (if new-goal-tree
           (f-put-global 'proof-tree
                         (if (and (consp processor)
                                  (eq (car processor) 'push-clause)
                                  (eq signal 'abort)
                                  (not aborting-p))
                             (if (and (= forcing-round 0)
                                      (null (cdr starting-proof-tree)))
                                 (list (revert-goal-tree cl-id t new-goal-tree))
                               (er hard 'increment-proof-tree
                                   "Internal Error: Attempted to ``revert'' ~
                                    the proof tree with forcing round ~x0 and ~
                                    proof tree of length ~x1.  This reversion ~
                                    should only have been tried with forcing ~
                                    round 0 and proof tree of length 1.  ~
                                    Please contact the ACL2 implementors."
                                   forcing-round
                                   (length starting-proof-tree)))
                           (prune-proof-tree
                            forcing-round nil
                            (cons (if (eq signal 'abort)
                                      (revert-goal-tree cl-id
                                                        nil
                                                        new-goal-tree)
                                    new-goal-tree)
                                  (cdr starting-proof-tree))))
                         state)
         (prog2$ (er hard 'increment-proof-tree
                     "Found empty goal tree from call ~x0"
                     (list 'insert-into-goal-tree
                           cl-id
                           processor
                           (if (= clause-count 0)
                               nil
                             clause-count)
                           (car starting-proof-tree)))
                 state))
       (print-proof-tree state)))))

(defun goal-tree-with-cl-id (cl-id goal-tree-lst)
  (cond ((atom goal-tree-lst)
         nil)
        ((equal cl-id (access goal-tree (car goal-tree-lst) :cl-id))
         (car goal-tree-lst))
        (t (goal-tree-with-cl-id cl-id (cdr goal-tree-lst)))))

(mutual-recursion

(defun goal-tree-choose-disjunct-rec (cl-id disjunct-cl-id goal-tree)

; This is the recursive version of goal-tree-choose-disjunct.  It either
; returns (mv nil goal-tree) without any change to the given goal-tree, or else
; it returns (mv t new-goal-tree) where new-goal-tree is not equal to
; goal-tree.

  (let ((children (access goal-tree goal-tree :children)))
    (cond
     ((equal cl-id (access goal-tree goal-tree :cl-id))
      (assert$
       (eq (access goal-tree goal-tree :processor)
           'apply-top-hints-clause-or-hit)
       (let ((child (goal-tree-with-cl-id disjunct-cl-id children)))
         (mv t
             (cond (child
                    (change goal-tree goal-tree
                            :children (list child)))
                   (t ; child was proved
                    (change goal-tree goal-tree
                            :children nil)))))))
     ((atom children) (mv nil goal-tree)) ; optimization
     (t (mv-let
         (found new-children)
         (goal-tree-choose-disjunct-lst cl-id disjunct-cl-id children)
         (cond (found (mv t (change goal-tree goal-tree
                                    :children new-children)))
               (t (mv nil goal-tree))))))))

(defun goal-tree-choose-disjunct-lst (cl-id disjunct-cl-id goal-tree-lst)
  (cond ((consp goal-tree-lst)
         (mv-let (found new-goal-tree)
                 (goal-tree-choose-disjunct-rec
                  cl-id disjunct-cl-id (car goal-tree-lst))
                 (cond (found (mv t (cons new-goal-tree (cdr goal-tree-lst))))
                       (t (mv-let (found new-goal-tree-lst)
                                  (goal-tree-choose-disjunct-lst
                                   cl-id disjunct-cl-id (cdr goal-tree-lst))
                                  (cond (found (mv t (cons (car goal-tree-lst)
                                                           new-goal-tree-lst)))
                                        (t (mv nil goal-tree-lst))))))))
        (t (mv nil goal-tree-lst))))
)

(defun goal-tree-choose-disjunct (cl-id disjunct-cl-id goal-tree)

; Replace the subtree at the goal-tree with the given cl-id with the subtree at
; its child having the given disjunct-cl-id, but eliminating the extra "D" case
; from every clause id in that subtree.

  (mv-let (foundp new-goal-tree)
          (goal-tree-choose-disjunct-rec cl-id disjunct-cl-id goal-tree)
          (assert$ foundp
                   new-goal-tree)))

(defun install-disjunct-into-proof-tree (cl-id disjunct-cl-id state)

; Replace disjunct-cl-id by cl-id in the global proof tree, discarding the
; other disjunctive cases under cl-id.

  (let ((proof-tree (f-get-global 'proof-tree state)))
    (assert$
     (consp proof-tree)
     (pprogn (f-put-global
              'proof-tree
              (prune-proof-tree
               (access clause-id cl-id :forcing-round)
               nil
               (cons (goal-tree-choose-disjunct cl-id disjunct-cl-id (car proof-tree))
                     (cdr proof-tree)))
              state)
             (print-proof-tree state)))))

; Logical Names

; Logical names are names introduced by the event macros listed in
; primitive-event-macros, e.g., they are the names of functions,
; macros, theorems, packages, etc.  Logical names have two main uses
; in this system.  The first is in theory expressions, where logical
; names are used to denote times in the past, i.e., "Give me the list
; of all rules enabled when nm was introduced."  The second is in the
; various keyword commands available to the user to enquire about his
; current state, i.e., "Show me the history around the time nmwas
; introduced."

; The latter use involves the much more sophisticated notion of
; commands as well as that of events.  We will deal with it later.

; We make special provisions to support the mapping from a logical
; name to the world at the time that name was introduced.  At the
; conclusion of the processing of an event, we set the 'global-value
; of 'event-landmark to an "event tuple."  This happens in stop-event.
; Among other things, an event tuple lists the names introduced by the
; event.  The successive settings of 'event-landmark are all visible
; on the world and thus effectively divide the world up into "event
; blocks."  Because the setting of 'event-landmark is the last thing
; we do for an event, the world at the termination of a given event is
; the world whose car is the appropriate event tuple.  So one way to
; find the world is scan down the current world, looking for the
; appropriate event landmark.

; This however is slow, because often the world is not in physical
; memory and must be paged in.  We therefore have worked out a scheme
; to support the faster lookup of names.  We could have stored the
; appropriate world on the property list of each symbolic name.  We
; did not want to do this because it might cause consternation when a
; user looked at the properties.  So we instead associate a unique
; nonnegative integer with each event and provide a mapping from those
; "absolute event numbers" to worlds.  We store the absolute event
; number of each symbolic name on the property list of the name (in
; stop-event).  The only other logical names are the strings that name
; packages.  We find them by searching through the world.

(defun logical-namep (name wrld)

; Returns non-nil if name is a logical name, i.e., a symbolic or
; string name introduced by an event, or the keyword :here meaning the
; most recent event.

  (cond ((symbolp name)
         (cond ((eq name :here) (not (null wrld)))
               (t (getprop name 'absolute-event-number nil
                           'current-acl2-world wrld))))
        ((and (stringp name)
              (find-non-hidden-package-entry
               name (global-val 'known-package-alist wrld)))
         t)
        (t nil)))

; Logical-name-type has been moved up to translate.lisp in support of
; chk-all-but-new-name, which supports handling of flet by translate11.

(defun logical-name-type-string (typ)
  (case typ
        (package "package")
        (function "function")
        (macro "macro")
        (const "constant")
        (stobj "single-threaded object")
        (stobj-live-var "single-threaded object holder")
        (theorem "theorem")
        (theory "theory")
        (label "label")
        (t (symbol-name typ))))

; Event Tuples

; Every time an event occurs we store a new 'global-value for the
; variable 'event-landmark in stop-event.  The value of
; 'event-landmark is an "event tuple."  Abstractly, an event tuple
; contains the following fields:

; n:     the absolute event number
; d:     the embedded event depth (the number of events containing the event)
; form:  the form evaluated that created the event.  (This is often a form
;        typed by the user but might have been a form generated by a macro.
;        The form may be a call of a primitive event macro, e.g., defthm,
;        or may be itself a macro call, e.g., prove-lemma.)
; type:  the name of the primitive event macro we normally use, e.g.,
;        defthm, defuns, etc.
; namex: the name or names of the functions, rules, etc., introduced by
;        the event.  This may be a single object, e.g., 'APP, or "MY-PKG",
;        or may be a true list of objects, e.g., '(F1 F2 F3) as in the case
;        of a mutually recursive clique.  0 (zero) denotes the empty list of
;        names.  The unusual event enter-boot-strap-mode has a namex containing
;        both symbols and strings.
; symbol-class:
;        One of nil, :program, :ideal, or :compliant-common-lisp, indicating
;        the symbol-class of the namex.  (All names in the namex have the same
;        symbol-class.)

; All event tuples are constructed by make-event-tuple, below.  By searching
; for all calls of that function you will ascertain all possible event types
; and namex combinations.  You will find the main call in add-event-landmark,
; which is used to store an event landmark in the world.  There is another call
; in primordial-world-globals, where the bogus initial value of the
; 'event-landmark 'global-value is created with namex 0 and event type nil.
; Add-event-landmark is called in install-event, which is the standard (only)
; way to finish off an ACL2 event.  If you search for calls of install-event
; you will find the normal combinations of event types and namex.  There are
; two other calls of add-event-landmark.  One, in in primordial-world where it
; is called to create the enter-boot-strap-mode event type landmark with namex
; consisting of the primitive functions and known packages.  The other, in
; end-prehistoric-world, creates the exit-boot-strap-mode event type landmark
; with namex 0.

; As of this writing the complete list of type and namex pairs
; is shown below, but the algorithm described above will generate
; it for you if you wish to verify this.

;               type                namex
;           enter-boot-strap-mode    *see below
;           verify-guards            0 (no names introduced)
;           defun                    fn
;           defuns                   (fn1 ... fnk)
;           defaxiom                 name
;           defthm                   name
;           defconst                 name
;           defstobj                 (name the-live-var fn1 ... fnk)
;             [Note: defstobj is the type used for both defstobj and
;              defabsstobj events.]
;           defmacro                 name
;           defpkg                   "name"
;           deflabel                 name
;           deftheory                name
;           in-theory                0 (no name introduced)
;           in-arithmetic-theory     0 (no name introduced)
;           push-untouchable         0
;           regenerate-tau-database  0 (no name introduced)
;           remove-untouchable       0
;           reset-prehistory         0
;           set-body                 0 (no name introduced)
;           table                    0 (no name introduced)
;           encapsulate              (fn1 ... fnk) - constrained fns
;           include-book             "name"
;           exit-boot-strap-mode     0

; *Enter-boot-strap-mode introduces the names in *primitive-formals-
; and-guards* and *initial-known-package-alist*.  So its namex is a
; proper list containing both symbols and strings.

; To save space we do not actually represent each event tuple as a 6-tuple but
; have several different forms.  The design of our forms makes the following
; assumptions, aimed at minimizing the number of conses in average usage.  (1)
; Most events are not inside other events, i.e., d is often 0.  (2) Most events
; use the standard ACL2 event macros, e.g., defun and defthm rather than user
; macros, e.g., DEFN and PROVE-LEMMA.  (3) Most events are introduced with the
; :program symbol-class.  This last assumption is just the simple observation
; that until ACL2 is reclassified from :program to :logic, the ACL2
; system code will outweigh any application.

(defun signature-fns (signatures)

; Assuming that signatures has been approved by chk-signatures, we
; return a list of the functions signed.  Before we added signatures
; of the form ((fn * * STATE) => *) this was just strip-cars.
; Signatures is a list of elements, each of which is either of the
; form ((fn ...) => val) or of the form (fn ...).

  (cond ((endp signatures) nil)
        ((consp (car (car signatures)))
         (cons (car (car (car signatures)))
               (signature-fns (cdr signatures))))
        (t (cons (car (car signatures))
                 (signature-fns (cdr signatures))))))

(defun make-event-tuple (n d form ev-type namex symbol-class)

; An event tuple is always a cons.  Except in the initial case created by
; primordial-world-globals, the car is always either a natural (denoting n and
; implying d=0) or a cons of two naturals, n and d.  Its cadr is either a
; symbol, denoting its type and signalling that the cdr is the form, the
; symbol-class is :program and that the namex can be recovered from the form,
; or else the cadr is the pair (ev-type namex . symbol-class) signalling that
; the form is the cddr.

; Generally, the val encodes:
;  n - absolute event number
;  d - embedded event depth
;  form - form that created the event
;  ev-type - name of the primitive event macro we use, e.g., defun, defthm, defuns
;  namex - name or names introduced (0 is none)
;  symbol-class - of names (or nil)

; In what we expect is the normal case, where d is 0 and the form is one of our
; standard ACL2 event macros, this concrete representation costs one cons.  If
; d is 0 but the user has his own event macros, it costs 3 conses.

; Warning: If we change the convention that n is the car of a concrete event
; tuple if the car is an integer, then change the default value given getprop
; in max-absolute-event-number.

  (cons (if (= d 0) n (cons n d))
        (if (and (eq symbol-class :program)
                 (consp form)
                 (or (eq (car form) ev-type)
                     (and (eq ev-type 'defuns)
                          (eq (car form) 'mutual-recursion)))
                 (equal namex
                        (case (car form)
                              (defuns (strip-cars (cdr form)))
                              (mutual-recursion (strip-cadrs (cdr form)))
                              ((verify-guards in-theory
                                              in-arithmetic-theory
                                              regenerate-tau-database
                                              push-untouchable
                                              remove-untouchable
                                              reset-prehistory
                                              set-body
                                              table)
                               0)
                              (encapsulate (signature-fns (cadr form)))
                              (otherwise (cadr form)))))
            form
          (cons (cons ev-type
                      (cons namex symbol-class))
                form))))

(defun access-event-tuple-number (x)

; Warning: If we change the convention that n is (car x) when (car x)
; is an integerp, then change the default value given getprop in
; max-absolute-event-number.

  (if (integerp (car x)) (car x) (caar x)))

(defun access-event-tuple-depth (x)
  (if (integerp (car x)) 0 (cdar x)))

(defun access-event-tuple-type (x)
  (cond ((symbolp (cdr x)) ;eviscerated event
         nil)
        ((symbolp (cadr x))
         (if (eq (cadr x) 'mutual-recursion)
             'defuns
           (cadr x)))
        (t (caadr x))))

(defun access-event-tuple-namex (x)

; Note that namex might be 0, a single name, or a list of names.  Included in
; the last case is the possibility of the list being nil (as from an
; encapsulate event introducing no constrained functions).

  (cond
   ((symbolp (cdr x)) ;eviscerated event
    nil)
   ((symbolp (cadr x))
    (case (cadr x)
          (defuns (strip-cars (cddr x)))
          (mutual-recursion (strip-cadrs (cddr x)))
          ((verify-guards in-theory
                          in-arithmetic-theory
                          regenerate-tau-database
                          push-untouchable remove-untouchable reset-prehistory
                          set-body table)
           0)
          (encapsulate (signature-fns (caddr x)))
          (t (caddr x))))
   (t (cadadr x))))

(defun access-event-tuple-form (x)
  (if (symbolp (cadr x))
      (cdr x)
    (cddr x)))

(defun access-event-tuple-symbol-class (x)
  (if (symbolp (cadr x))
      :program
    (cddadr x)))

; Command Tuples

; When LD has executed a world-changing form, it stores a "command tuple" as
; the new 'global-value of 'command-landmark.  These landmarks divide the world
; up into "command blocks" and each command block contains one or or event
; blocks.  Command blocks are important when the user queries the system about
; his current state, wishes to undo, etc.  Commands are enumerated sequentially
; from 0 with "absolute command numbers."

; We define command tuples in a way analogous to event tuples, although
; commands are perhaps simpler because most of their characteristics are
; inherited from the event tuples in the block.  We must store the current
; default-defun-mode so that we can offer to redo :program functions after ubt.
; (A function is offered for redoing if its defun-mode is :program.  But the
; function is redone by executing the command that created it.  The command may
; recreate many functions and specify a :mode for each.  We must re-execute the
; command with the same default-defun-mode we did last to be sure that the
; functions it creates have the same defun-mode as last time.)

(defrec command-tuple

; Warning: Keep this in sync with the definitions of
; safe-access-command-tuple-number and pseudo-command-landmarkp in community
; book books/system/pseudo-good-worldp.lisp, and function
; safe-access-command-tuple-form in the ACL2 sources.

; See make-command-tuple for a discussion of defun-mode/form.

; If form is an embedded event form, then last-make-event-expansion is nil
; unless form contains a call of make-event whose :check-expansion field is not
; a cons, in which case last-make-event-expansion is the result of removing all
; make-event calls from form.

  (number defun-mode/form cbd . last-make-event-expansion)
  t)

(defun make-command-tuple (n defun-mode form cbd last-make-event-expansion)

; Defun-Mode is generally the default-defun-mode of the world in which this
; command is being executed.  But there are two possible exceptions.  See
; add-command-tuple.

; We assume that most commands are executed with defun-mode :program.  So we
; optimize our representation of command tuples accordingly.  No form that
; creates a function can have a keyword as its car.

  (make command-tuple
        :number n
        :defun-mode/form (if (eq defun-mode :program)
                             form
                           (cons defun-mode form))
        :cbd cbd
        :last-make-event-expansion last-make-event-expansion))

(defun access-command-tuple-number (x)
  (access command-tuple x :number))

(defun access-command-tuple-defun-mode (x)
  (let ((tmp (access command-tuple x :defun-mode/form)))
    (if (keywordp (car tmp))
        (car tmp)
      :program)))

(defun access-command-tuple-form (x)

; See also safe-access-command-tuple-form for a safe version (i.e., with guard
; t).

  (let ((tmp (access command-tuple x :defun-mode/form)))
    (if (keywordp (car tmp))
        (cdr tmp)
      tmp)))

(defun safe-access-command-tuple-form (x)

; This is just a safe version of access-command-tuple-form.

  (declare (xargs :guard t))
  (let ((tmp (and (consp x)
                  (consp (cdr x))
                  (access command-tuple x :defun-mode/form))))
    (if (and (consp tmp)
             (keywordp (car tmp)))
        (cdr tmp)
      tmp)))

(defun access-command-tuple-last-make-event-expansion (x)
  (access command-tuple x :last-make-event-expansion))

(defun access-command-tuple-cbd (x)
  (access command-tuple x :cbd))

; Absolute Event and Command Numbers

(defun max-absolute-event-number (wrld)

; This is the maximum absolute event number in use at the moment.  It
; is just the number found in the most recently completed event
; landmark.  We initialize the event-landmark with number -1 (see
; primordial-world-globals) so that next-absolute-event-number returns
; 0 the first time.

  (access-event-tuple-number (global-val 'event-landmark wrld)))

(defun next-absolute-event-number (wrld)
  (1+ (max-absolute-event-number wrld)))

(defun max-absolute-command-number (wrld)

; This is the largest absolute command number in use in wrld.  We
; initialize it to -1 (see primordial-world-globals) so that
; next-absolute-command-number works.

  (access-command-tuple-number (global-val 'command-landmark wrld)))

(defun next-absolute-command-number (wrld)
  (1+ (max-absolute-command-number wrld)))

; Scanning to find Landmarks

(defun scan-to-event (wrld)

; We roll back wrld to the first (list order traversal) event landmark
; on it.

  (cond ((null wrld) wrld)
        ((and (eq (caar wrld) 'event-landmark)
              (eq (cadar wrld) 'global-value))
         wrld)
        (t (scan-to-event (cdr wrld)))))

(defun scan-to-command (wrld)

; Scan to the next binding of 'command-landmark.

  (cond ((null wrld) nil)
        ((and (eq (caar wrld) 'command-landmark)
              (eq (cadar wrld) 'global-value))
         wrld)
        (t (scan-to-command (cdr wrld)))))

(defun scan-to-landmark-number (flg n wrld)

; We scan down wrld looking for a binding of 'event-landmark with n as
; its number or 'command-landmark with n as its number, depending on
; whether flg is 'event-landmark or 'command-landmark.

  #+acl2-metering
  (setq meter-maid-cnt (1+ meter-maid-cnt))
  (cond ((null wrld)
         (er hard 'scan-to-landmark-number
             "We have scanned the world looking for absolute ~
              ~#0~[event~/command~] number ~x1 and failed to find it. ~
               There are two likely errors.  Either ~#0~[an event~/a ~
              command~] with that number was never stored or the ~
              index has somehow given us a tail in the past rather ~
              than the future of the target world."
             (if (equal flg 'event-landmark) 0 1)
             n))
        ((and (eq (caar wrld) flg)
              (eq (cadar wrld) 'global-value)
              (= n (if (eq flg 'event-landmark)
                       (access-event-tuple-number (cddar wrld))
                       (access-command-tuple-number (cddar wrld)))))
         #+acl2-metering
         (meter-maid 'scan-to-landmark-number 500 flg n)
         wrld)
        (t (scan-to-landmark-number flg n (cdr wrld)))))

; The Event and Command Indices

; How do we convert an absolute event number into the world created by
; that event?  The direct way to do this is to search the world for
; the appropriate binding of 'event-landmark.  To avoid much of this
; search, we keep a map from some absolute event numbers to the
; corresponding tails of world.

; Rather than store an entry for each event number we will store one
; for every 10th.  Actually, *event-index-interval* determines the
; frequency.  This is a completely arbitrary decision.  A typical :ppe
; or :ubt will request a tail within 5 event of a saved one, on the
; average.  At 8 properties per event (the bootstrap right now is
; running 7.4 properties per event), that's about 40 tuples, each of
; the form (name prop . val).  We will always look at name and
; sometimes (1/8 of the time) look at prop and the car of val, which
; says we'll need to swap in about 40+40+1/8(40 + 40) = 90 conses.  We
; have no idea how much this costs (and without arguments about
; locality, it might be as bad as 90 pages!), but it seems little
; enough.  In any case, this analysis suggests that the decision to
; save every nth world will lead to swapping in only 9n conses.

; Assuming that a big proof development costs 3000 events (that's
; about the size of the Piton proof) and that the initial bootstrap is
; about 2000 (right now it is around 1700), we imagine that we will be
; dealing with 5000 events.  So our map from event numbers to
; tails of world will contain about 500 entries.  Of interest here is
; the choice of representation for that map.

; The requirement is that it be a map from the consecutive positive
; integers to tails of world (or nil for integers not yet claimed).
; It should operate comfortably with 500 entries.  It will be the
; value of the world global, 'event-index, and every time we add a
; new entry (i.e., every 10 events), we will rebind that global.
; Thus, by the time the table has 500 entries we will also be holding
; onto the 499 old versions of the table as well.

; Three representations came immediately to mind: a linear array, an
; association list, and a balanced binary tree.  A fourth was invented
; to solve the problem.  We discuss all four here.

; Linear Array.  If the event-index is an array then it will be
; extremely efficient to "search".  We will have to grow the array as
; we go, as we do in load-theory-into-enabled-structure.  So by the
; time the array has 500 entries the underlying Common Lisp array will
; probably contain around 750 words.  The alist version of the array
; will be of length 500 (ignoring the :HEADER) and consume 1000
; conses.  So in all we'll have about 1750 words tied up in this
; structure.  Old versions of the table will share the alist
; representation and cost little.  However, we imagine keeping only
; one Common Lisp array object and it will always hold the compressed
; version of the latest index.  So old versions of the index will be
; "out of date" and will have to be recompressed upon recovery from a
; :ubt, as done by recompress-global-enabled-structure.  This
; complicates the array representation and we have decided to dismiss
; it.

; Alist.  If the event-index is an alist it will typically be 500
; long and contain 1000 conses which are all perfectly shared with old
; copies.  Adding new entries is very fast, i.e., 2 conses.  Lookup is
; relatively slow: .004 seconds, average with an alist of size 500.
; For comparison purposes, we imagine the following scenario: The user
; starts with a world containing 2000 bootstrap events.  He adds
; another 3000 events of his own.  Every event, however, provokes
; him to do 10 :ppes to look at old definitions.  (We are purposefully
; biasing the scenario toward fast lookup times.)  Given the
; convention of saving every 10th tail of world in the index, the
; scenario becomes: The user starts with a index containing 200
; entries.  He grows it to 500 entries.  However, between each growth
; step he inspects 100 entries spread more or less evenly throughout
; the interval.  If the index is represented by an alist, how long
; does this scenario take?  Answer: 77 seconds (running AKCL on a Sun
; 360 with 20Mb).

; Balanced Binary Tree.  We have done an extensive study of the use of
; balanced binary trees (bbts) for this application.  Using bbts, the
; scenario above requires only 13 seconds.  However, bbts use a lot
; more space.  In particular, the bbt for 500 entries consumes 2000
; conses (compared to the alist's 1000 conses).  Worse, the bbt for
; 500 shares little of the structure for 499, while the alist shares
; it all.  (We did our best with structure sharing between successive
; bbts, it's just that rebalancing the tree after an addition
; frequently destroys the possibility for sharing.  Of the 2000 conses
; in the 500 entry bbt, 1028 are new and the rest are shared with the
; 499 bbt.)  In particular, to keep all 500 of the bbts will cost us
; 156,000 conses.  By contrast, the entire world after a bootstrap
; currently costs about 418,000 conses.

; So we need a representation that shares structure and yet is
; efficiently accessed.  Why are alists so slow?  Because we have to
; stop at every entry and ask "is this the one?"  But that is silly
; because we know that if we're looking for 2453 and we see 3000 then
; we have to skip down 547.  That is, our values are all associated
; with consecutive integer indices and the alist is ordered.  But we
; could just use a positional indexing scheme.

; Zap Table.  A zap table is a linear list of values indexed by
; 0-based positions STARTING FROM THE RIGHT.  To enable us to count
; from the right we include, as the first element in the list, the
; maximum index.  For example, the zap table that maps each of the
; integers from 0 to 9 to itself is: (9 9 8 7 6 5 4 3 2 1 0).  To add
; a new (10th) value to the table, we increment the car by 1 and cons
; the new value to the cdr.  Thus, we spend two conses per entry and
; share all other structure.  To fetch the ith entry we compute how
; far down the list it is with arithmetic and then retrieve it with
; nth.  To our great delight this scheme carries out our scenario in
; 13 seconds, as fast as balanced binary trees, but shares as much
; structure as alists.  This is the method we use.

(defun add-to-zap-table (val zt)

; Given a zap table, zt, that associates values to the indices
; 0 to n, we extend the table to associate val to n+1.

  (cond ((null zt) (list 0 val))
        (t (cons (1+ (car zt)) (cons val (cdr zt))))))

(defun fetch-from-zap-table (n zt)

; Retrieve the value associated with n in the zap table zt, or
; nil if there is no such association.

  (cond ((null zt) nil)
        ((> n (car zt)) nil)
        (t (nth (- (car zt) n) (cdr zt)))))

; These 7 lines of code took 3 days to write -- because we first
; implemented balanced binary trees and did the experiments described
; above.

; Using zap tables we'll keep an index mapping absolute event numbers
; to tails of world.  We'll also keep such an index for commands typed
; by the user at the top-level of the ld loop.  The following two
; constants determine how often we save events and commands in their
; respective indices.

(defconst *event-index-interval* 10)
(defconst *command-index-interval* 10)

(defun update-world-index (flg wrld)

; Flg is either 'COMMAND or 'EVENT and indicates which of the two
; indices we are to update.

; In the comments below, we assume flg is 'EVENT.

; This function is called every time we successfully complete the
; processing of an event.  We here decide if it is appropriate
; to save a pointer to the resulting world, wrld.  If so, we update
; the event-index.  If not, we do nothing.  Our current algorithm
; is to save every *event-index-interval*th world.  That is, if
; *event-index-interval* is 10 then we save the worlds whose
; max-absolute-event-numbers are 0, 10, 20, etc., into slots 0, 1, 2,
; etc. of the index.

  (cond
   ((eq flg 'EVENT)
    (let ((n (max-absolute-event-number wrld)))
      (cond ((= (mod n *event-index-interval*) 0)
             (let ((event-index (global-val 'event-index wrld)))

; Things will get very confused if we ever miss a multiple of "10."
; For example, if some bug in the system causes us never to call this
; function on a world with absolute-event-number 10, say, then the
; next multiple we do call it on, e.g., 20, will be stored in the
; slot for 10 and things will be royally screwed.  So just to be
; rugged we will confirm the correspondence between what we think
; we're adding and where it will go.

               (cond ((= (floor n *event-index-interval*)
                         (if (null event-index)
                             0
                             (1+ (car event-index))))
                      (global-set 'event-index
                                  (add-to-zap-table wrld event-index)
                                  wrld))
                     (t (er hard 'update-world-index
                            "The event-index and the maximum absolute ~
                             event number have gotten out of sync!  ~
                             In particular, the next available index ~
                             is ~x0 but the world has event number ~
                             ~x1, which requires index ~x2."
                            (if (null event-index)
                                0
                                (1+ (car event-index)))
                            n
                            (floor n *event-index-interval*))))))
            (t wrld))))
   (t
    (let ((n (max-absolute-command-number wrld)))
      (cond ((= (mod n *command-index-interval*) 0)
             (let ((command-index (global-val 'command-index wrld)))
               (cond ((= (floor n *command-index-interval*)
                         (if (null command-index)
                             0
                             (1+ (car command-index))))
                      (global-set 'command-index
                                  (add-to-zap-table wrld command-index)
                                  wrld))
                     (t (er hard 'update-world-index
                            "The command-index and the maximum ~
                             absolute command number have gotten out ~
                             of sync!  In particular, the next ~
                             available index is ~x0 but the world has ~
                             command number ~x1, which requires index ~
                             ~x2."
                            (if (null command-index)
                                0
                                (1+ (car command-index)))
                            n
                            (floor n *command-index-interval*))))))
            (t wrld))))))

(defun lookup-world-index1 (n interval index wrld)

; Let index be a zap table that maps the integers 0 to k to worlds.
; Instead of numbering those worlds 0, 1, 2, ..., number them 0,
; 1*interval, 2*interval, etc.  So for example, if interval is 10 then
; the worlds are effectively numbered 0, 10, 20, ...  Now n is some
; world number (but not necessarily a multiple of interval).  We wish
; to find the nearest world in the index that is in the future of the
; world numbered by n.

; For example, if n is 2543 and interval is 10, then we will look for
; world 2550, which will be found in the table at 255.  Of course, the
; table might not contain an entry for 255 yet, in which case we return
; wrld.

  (let ((i (floor (+ n (1- interval))
                  interval)))
    (cond ((or (null index)
               (> i (car index)))
           wrld)
          (t (fetch-from-zap-table i index)))))

(defun lookup-world-index (flg n wrld)

; This is the general-purpose function that takes an arbitrary
; absolute command or event number (flg is 'COMMAND or 'EVENT) and
; returns the world that starts with the indicated number.

  (cond ((eq flg 'event)
         (let ((n (min (max-absolute-event-number wrld)
                       (max n 0))))
           (scan-to-landmark-number 'event-landmark
                                    n
                                    (lookup-world-index1
                                     n
                                     *event-index-interval*
                                     (global-val 'event-index wrld)
                                     wrld))))
        (t
         (let ((n (min (max-absolute-command-number wrld)
                       (max n 0))))
           (scan-to-landmark-number 'command-landmark
                                    n
                                    (lookup-world-index1
                                     n
                                     *command-index-interval*
                                     (global-val 'command-index wrld)
                                     wrld))))))

; Maintaining the Invariants Associated with Logical Names and Events

(defun store-absolute-event-number (namex n wrld boot-strap-flg)

; Associated with each symbolic logical name is the
; 'absolute-event-number.  This function is responsible for storing
; that property.  Namex is either 0, denoting the empty set, an atom,
; denoting the singleton set containing that atom, or a true-list of
; atoms denoting the corresponding set.

; It is convenient to store the 'predefined property here as well.

  (cond ((equal namex 0)
         wrld)
        ((atom namex)

; If namex is "MY-PKG" we act as though it were the empty list.

         (cond ((symbolp namex)
                (putprop namex 'absolute-event-number n
                         (cond (boot-strap-flg
                                (putprop namex 'predefined t wrld))
                               (t wrld))))
               (t wrld)))
        (t (store-absolute-event-number
            (or (cdr namex) 0)
            n
            (if (stringp (car namex))
                wrld
              (putprop (car namex) 'absolute-event-number n
                       (cond (boot-strap-flg
                              (putprop (car namex) 'predefined t wrld))
                             (t wrld))))
            boot-strap-flg))))

(defun the-namex-symbol-class1 (lst wrld symbol-class1)
  (cond ((null lst) symbol-class1)
        ((stringp (car lst))
         (the-namex-symbol-class1 (cdr lst) wrld symbol-class1))
        (t (let ((symbol-class2 (symbol-class (car lst) wrld)))
             (cond ((eq symbol-class1 nil)
                    (the-namex-symbol-class1 (cdr lst) wrld symbol-class2))
                   ((eq symbol-class2 nil)
                    (the-namex-symbol-class1 (cdr lst) wrld symbol-class1))
                   ((eq symbol-class1 symbol-class2)
                    (the-namex-symbol-class1 (cdr lst) wrld symbol-class1))
                   (t (er hard 'the-namex-symbol-class
                          "The symbolp elements of the namex argument ~
                           to add-event-landmark are all supposed to ~
                           have the same symbol-class, but the first ~
                           one we found with a symbol-class had class ~
                           ~x0 and now we've found another with ~
                           symbol-class ~x1.  The list of elements, ~
                           starting with the one that has ~
                           symbol-class ~x0 is ~x2."
                          symbol-class2 symbol-class1 lst)))))))

(defun the-namex-symbol-class (namex wrld)
  (cond ((equal namex 0) nil)
        ((atom namex)
         (cond ((symbolp namex)
                (symbol-class namex wrld))
               (t nil)))
        (t (the-namex-symbol-class1 namex wrld nil))))

(defun add-event-landmark (form ev-type namex wrld boot-strap-flg)

; We use a let* below and a succession of worlds just to make clear
; the order in which we store the various properties.  We update the
; world index before putting the current landmark on it.  This
; effectively adds the previous landmark to the index if it was a
; multiple of our interval.  We do this just so that the
; event-landmark we are about to lay down is truly the last thing we
; do.  Reflection on this issue leads to the conclusion that it is not
; really important whether the index entry is inside or outside of the
; landmark, in the case of event-landmarks.

  (let* ((n (next-absolute-event-number wrld))
         (wrld1 (store-absolute-event-number namex n wrld boot-strap-flg))
         (wrld2 (update-world-index 'event wrld1))
         (wrld3
           (global-set 'event-landmark
                       (make-event-tuple n
                                         (length (global-val
                                                  'embedded-event-lst
                                                  wrld))
                                         form
                                         ev-type
                                         namex
                                         (the-namex-symbol-class namex wrld2))
                       wrld2)))
    wrld3))

; Decoding Logical Names

(defun scan-to-defpkg (name wrld)

; We wish to give meaning to stringp logical names such as "MY-PKG".  We do it
; in an inefficient way: we scan the whole world looking for an event tuple of
; type DEFPKG and namex name.  We know that name is a known package and that it
; is not one in *initial-known-package-alist*.

  (cond ((null wrld) nil)
        ((and (eq (caar wrld) 'event-landmark)
              (eq (cadar wrld) 'global-value)
              (eq (access-event-tuple-type (cddar wrld)) 'DEFPKG)
              (equal name (access-event-tuple-namex (cddar wrld))))
         wrld)
        (t (scan-to-defpkg name (cdr wrld)))))

(defun scan-to-include-book (full-book-name wrld)

; We wish to give meaning to stringp logical names such as "arith".  We
; do it in an inefficient way: we scan the whole world looking for an event
; tuple of type INCLUDE-BOOK and namex full-book-name.

  (cond ((null wrld) nil)
        ((and (eq (caar wrld) 'event-landmark)
              (eq (cadar wrld) 'global-value)
              (eq (access-event-tuple-type (cddar wrld)) 'include-book)
              (equal full-book-name (access-event-tuple-namex (cddar wrld))))
         wrld)
        (t (scan-to-include-book full-book-name (cdr wrld)))))

(defun assoc-equal-cadr (x alist)
  (cond ((null alist) nil)
        ((equal x (cadr (car alist))) (car alist))
        (t (assoc-equal-cadr x (cdr alist)))))

(defun multiple-assoc-terminal-substringp1 (x i alist)
  (cond ((null alist) nil)
        ((terminal-substringp x (caar alist) i (1- (length (caar alist))))
         (cons (car alist) (multiple-assoc-terminal-substringp1 x i (cdr alist))))
        (t (multiple-assoc-terminal-substringp1 x i (cdr alist)))))

(defun multiple-assoc-terminal-substringp (x alist)

; X and the keys of the alist are presumed to be strings.  This function
; compares x to the successive keys in the alist, succeeding on any key that
; contains x as a terminal substring.  Unlike assoc, we return the list of all
; pairs in the alist with matching keys.

  (multiple-assoc-terminal-substringp1 x (1- (length x)) alist))

(defun possibly-add-lisp-extension (str)

; String is a string.  If str ends in .lisp, return it.  Otherwise, tack .lisp
; onto the end and return that.

  (let ((len (length str)))
    (cond
     ((and (> len 5)
           (eql (char str (- len 5)) #\.)
           (eql (char str (- len 4)) #\l)
           (eql (char str (- len 3)) #\i)
           (eql (char str (- len 2)) #\s)
           (eql (char str (- len 1)) #\p))
      str)
     (t (string-append str ".lisp")))))

(defun decode-logical-name (name wrld)

; Given a logical name, i.e., a symbol with an 'absolute-event-number property
; or a string naming a defpkg or include-book, we return the tail of wrld
; starting with the introductory event.  We return nil if name is illegal.

  (cond
   ((symbolp name)
    (cond ((eq name :here)
           (scan-to-event wrld))
          (t
           (let ((n (getprop name 'absolute-event-number nil
                             'current-acl2-world wrld)))
             (cond ((null n) nil)
                   (t (lookup-world-index 'event n wrld)))))))
   ((stringp name)

; Name may be a package name or a book name.

    (cond
     ((find-non-hidden-package-entry name
                                     (global-val 'known-package-alist wrld))
      (cond ((find-package-entry name *initial-known-package-alist*)

; These names are not DEFPKGd and so won't be found in a scan.  They
; are introduced by absolute event number 0.

             (lookup-world-index 'event 0 wrld))
            (t (scan-to-defpkg name wrld))))
     (t (let ((hits (multiple-assoc-terminal-substringp
                     (possibly-add-lisp-extension name)
                     (global-val 'include-book-alist wrld))))

; Hits is a subset of the include-book-alist.  The form of each
; element is (full-book-name user-book-name familiar-name
; cert-annotations . ev-lst-chk-sum).

          (cond
           ((and hits (null (cdr hits)))
            (scan-to-include-book (car (car hits)) wrld))
           (t nil))))))
   (t nil)))

(defun er-decode-logical-name (name wrld ctx state)

; Like decode-logical-name but causes an error rather than returning nil.

  (let ((wrld1 (decode-logical-name name wrld)))
    (cond
     ((null wrld1)
      (let ((hits (and (stringp name)
                       (not (find-non-hidden-package-entry
                             name
                             (global-val 'known-package-alist wrld)))
                       (multiple-assoc-terminal-substringp
                        (possibly-add-lisp-extension name)
                        (global-val 'include-book-alist wrld)))))

; Hits is a subset of the include-book-alist.  The form of each
; element is (full-book-name user-book-name familiar-name
; cert-annotations . ev-lst-chk-sum).

        (cond
         ((and hits (cdr hits))
          (er soft ctx
              "More than one book matches the name ~x0, in particular ~&1.  We ~
               therefore consider ~x0 not to be a logical name and insist ~
               that you use an unambiguous form of it.  See :DOC logical-name."
              name
              (strip-cars hits)))
         (t (er soft ctx
                "The object ~x0 is not a logical name.  See :DOC logical-name."
                name)))))
     (t (value wrld1)))))

(defun renew-lemmas (fn lemmas)

; We copy lemmas, which is a list of rewrite rules, deleting those whose
; runes have fn as their base symbol.  These are, we believe, all and only
; the rules stored by the event which introduced fn.

  (cond ((null lemmas) nil)
        ((eq (base-symbol (access rewrite-rule (car lemmas) :rune)) fn)
         (renew-lemmas fn (cdr lemmas)))
        (t (cons (car lemmas) (renew-lemmas fn (cdr lemmas))))))

(defun renew-name/erase (name old-getprops wrld)

; Name is a symbol, old-getprops is the list returned by getprops on name,
; i.e., an alist dotting properties to values.  We map over that list and
; "unbind" every property of name in wrld.  We do not touch 'GLOBAL-VALUE
; because that is not a property affected by an event (consider what would
; happen if the user defined and then redefined COMMAND-LANDMARK).  Similarly,
; we do not touch 'table-alist or 'table-guard.  See the list of properties
; specially excepted by new-namep.

  (cond
   ((null old-getprops) wrld)
   (t (renew-name/erase
       name
       (cdr old-getprops)
       (if (member-eq (caar old-getprops)
                      '(global-value table-alist table-guard))
           wrld
           (putprop name
                    (caar old-getprops)
                    *acl2-property-unbound*
                    wrld))))))

;; RAG - Hmmm, this code assumes it knows all of the properties stored
;; on a function symbol.  Sad.  I added 'CLASSICALP to the list.

(defun renew-name/overwrite (name old-getprops wrld)

; Name is a function symbol, old-getprops is the list returned by getprops on
; name, i.e., an alist dotting properties to values.  We map over that list and
; "unbind" those properties of name in wrld that were stored by the event
; introducing name.

; Note: Even when the ld-redefinition-action specifies :overwrite we sometimes
; change it to :erase (see maybe-coerce-overwrite-to-erase).  Thus, this
; function is actually only called on function symbols, not constants or stobjs
; or stobj-live-vars.  The erase version, above, is called on those redefinable
; non-functions.

; Finally, we back up our claim that name must be a function symbol.  The
; reason is that renew-name is the only place that calls renew-name/overwrite
; and it only does that when the renewal-mode is :overwrite or
; :reclassifying-overwrite.  Now renew-name is only called by
; chk-redefineable-namep which sets the renewal-mode using
; redefinition-renewal-mode.

; Finally, if you inspect redefinition-renewal-mode you can see that it only
; returns :overwrite or :reclassifying-overwrite on functions.  The proof of
; this for the :overwrite cases is tedious but pretty straightforward.  Most
; branches through redefinition-renewal-mode signal an error prohibiting the
; redefinition attempt, a few explicitly return :erase, and the normal cases in
; which :overwrite could be returned are all coming out of calls to
; maybe-coerce-overwrite-to-erase, which returns :erase unless the old and new
; type of the event is FUNCTION.

; The harder part of the proof (that only functions get renewal-mode :overwrite
; or :reclassifying-overwrite) is when we return :reclassifying-overwrite.
; Whether redefinition-renewal-mode does that depends on the argument
; reclassifyingp supplied by chk-redefineable-namep, which in turn depends on
; what value of reclassifyingp is supplied to chk-redefineable-namep by its
; only caller, chk-just-new-name, which in turn just passes in the value it is
; supplied by its callers, of which there are many.  However, all but
; chk-acceptable-defuns1 supply reclassifyingp of nil.

; So we know that we reclassify only function symbols and we know that only
; function symbols get :overwrite or :reclassifying-overwrite for their
; renewal-modes.

  (cond
   ((null old-getprops) wrld)
   ((eq (caar old-getprops) 'redefined)
    (renew-name/overwrite
     name
     (cdr old-getprops)
     wrld))
   ((member-eq (caar old-getprops)
               '(FORMALS
                 STOBJS-IN
                 STOBJS-OUT
                 SYMBOL-CLASS
                 NON-EXECUTABLEP
                 SIBLINGS
                 LEVEL-NO
                 TAU-PAIR
                 QUICK-BLOCK-INFO
                 PRIMITIVE-RECURSIVE-DEFUNP
                 CONSTRAINEDP
                 HEREDITARILY-CONSTRAINED-FNNAMES
                 #+:non-standard-analysis CLASSICALP
                 DEF-BODIES
                 NTH-UPDATE-REWRITER-TARGETP
                 INDUCTION-MACHINE
                 JUSTIFICATION
                 UNNORMALIZED-BODY
                 CONSTRAINT-LST
                 RECURSIVEP
                 TYPE-PRESCRIPTIONS
                 GUARD
                 SPLIT-TYPES-TERM
                 INVARIANT-RISK
                 ABSOLUTE-EVENT-NUMBER

; It is tempting to add CONGRUENT-STOBJ-REP to this list.  But it is a property
; of stobjs, not functions, so that isn't necessary.

; Note: If you delete RUNIC-MAPPING-PAIRS from this list you must reconsider
; functions like current-theory-fn which assume that if a name has the
; REDEFINED property then its runic-mapping-pairs has been set to
; *acl2-property-unbound*.

                 RUNIC-MAPPING-PAIRS

; This property is stored by defstobj on all supporting functions.

                 STOBJ-FUNCTION))

; The properties above are stored by the defun, constrain or defstobj
; that introduced name and we erase them.

    (renew-name/overwrite
     name
     (cdr old-getprops)
     (putprop name
              (caar old-getprops)
              *acl2-property-unbound*
              wrld)))
   ((eq (caar old-getprops) 'lemmas)

; We erase from the lemmas property just those rules stored by the introductory event.

    (renew-name/overwrite
     name
     (cdr old-getprops)
     (putprop name
              'lemmas
              (renew-lemmas name
                            (getprop name 'lemmas nil 'current-acl2-world wrld))
              wrld)))
   ((member-eq (caar old-getprops)

; As of this writing, the property in question must be one of the following,
; since name is a function symbol.  Note that these are not created by the
; introductory event of name (which must have been a defun or constrain) and
; hence are left untouched here.

               '(GLOBAL-VALUE
                 LINEAR-LEMMAS
                 FORWARD-CHAINING-RULES
                 ELIMINATE-DESTRUCTORS-RULE
                 COARSENINGS
                 CONGRUENCES
                 PEQUIVS
                 INDUCTION-RULES
                 DEFCHOOSE-AXIOM
                 TABLE-GUARD ; functions names can also be table names
                 TABLE-ALIST ; functions names can also be table names
                 PREDEFINED
                 DEFAXIOM-SUPPORTER
                 ATTACHMENT ; see Essay on Defattach re: :ATTACHMENT-DISALLOWED
                 CLAUSE-PROCESSOR
                 TAU-PAIR-SAVED
                 POS-IMPLICANTS
                 NEG-IMPLICANTS
                 UNEVALABLE-BUT-KNOWN
                 SIGNATURE-RULES-FORM-1
                 SIGNATURE-RULES-FORM-2
                 BIG-SWITCH
                 TAU-BOUNDERS-FORM-1
                 TAU-BOUNDERS-FORM-2
                 ))
   (renew-name/overwrite
    name
    (cdr old-getprops)
    wrld))
  (t
   (illegal 'renew-name/overwrite
            "We thought we knew all the properties stored by events ~
             introducing redefinable function names, but we don't know about ~
             the property ~x0."
            (list (cons #\0 (caar old-getprops)))))))

(defun renew-name (name renewal-mode wrld)

; We make it sort of appear as though name is sort of new in wrld.  Ah, to be
; young again...  We possibly erase all properties of name (depending on the
; renewal-mode, which must be :erase, :overwrite or :reclassifying-overwrite),
; and we put a 'redefined property on name.  Note that we always put the
; 'redefined property, even if name already has that property with that value,
; because one of our interests in this property is in stop-event, which uses it
; to identify which names have been redefined in this event.

; The value of the 'redefined property is (renewal-mode . old-sig),
; where old-sig is either the internal form signature of name if name
; is function and is otherwise nil.

; By storing the renewal-mode we make it possible to recover exactly how the
; final world was obtained from the initial one.  For purposes of renewal, we
; treat renewal-mode :reclassifying-overwrite as :overwrite; the only
; difference is that we store the :reclassifying-overwrite in the 'redefined
; property.  The only time :reclassifying-overwrite is the renewal-mode is when
; a :program function is being reclassified to an identical-defp :logic
; function.

  (putprop name 'redefined
           (cons renewal-mode
                 (cond ((and (symbolp name)
                             (function-symbolp name wrld))
                        (list name
                              (formals name wrld)
                              (stobjs-in name wrld)
                              (stobjs-out name wrld)))
                       (t nil)))
           (cond
            ((eq renewal-mode :erase)
             (renew-name/erase name
                               (getprops name 'current-acl2-world wrld)
                               wrld))
            ((or (eq renewal-mode :overwrite)
                 (eq renewal-mode :reclassifying-overwrite))
             (renew-name/overwrite name
                                   (getprops name 'current-acl2-world wrld)
                                   wrld))
            (t wrld))))

(defun renew-names (names renewal-mode wrld)
  (cond ((endp names) wrld)
        (t (renew-names (cdr names)
                        renewal-mode
                        (renew-name (car names) renewal-mode wrld)))))

(defun collect-redefined (wrld ans)

; We return a list of all redefined names down to the next event-landmark
; except those redefined in the :reclassifying-overwrite mode.  (Quoting from a
; comment in renew-name: The only time :reclassifying-overwrite is the
; renewal-mode is when a :program function is being reclassified to an
; identical-defp :logic function.)

  (cond ((or (null wrld)
             (and (eq (caar wrld) 'event-landmark)
                  (eq (cadar wrld) 'global-value)))
         ans)
        ((and (eq (cadar wrld) 'redefined)
              (consp (cddar wrld))
              (not (eq (car (cddar wrld)) :reclassifying-overwrite)))
         (collect-redefined
          (cdr wrld)
          (cons (caar wrld) ans)))
        (t (collect-redefined (cdr wrld) ans))))

(defun scrunch-eq (lst)
  (cond ((null lst) nil)
        ((member-eq (car lst) (cdr lst)) (scrunch-eq (cdr lst)))
        (t (cons (car lst) (scrunch-eq (cdr lst))))))

(defun print-redefinition-warning (wrld ctx state)

; If the 'ld-redefinition-action of state says we should :warn and some names
; were redefined, then we print a warning.  See :DOC ld-redefinition-action.
; Note that if the action specifies :warn and a system function is
; redefined, then a query is made.  Provided the user approves, the system
; function is redefined and then this warning is printed because the action
; says :warn.  This is a bit odd since we try, in general, to avoid warning
; if we have querried.  But we don't want to have to determine now if the
; redefined names are system functions, so we warn regardless.

  (cond
   ((warning-disabled-p "Redef")
    state)
   ((let ((act (f-get-global 'ld-redefinition-action state)))
      (and (consp act)
           (or (eq (car act) :warn)
               (eq (car act) :warn!))))
    (let ((redefs
           (scrunch-eq
            (reverse
             (collect-redefined
              (cond ((and (consp wrld)
                          (eq (caar wrld) 'event-landmark)
                          (eq (cadar wrld) 'global-value))
                     (cdr wrld))
                    (t (er hard 'print-redefinition-warning
                           "This function is supposed to be called on a world ~
                             that starts at an event landmark, but this world ~
                             starts with (~x0 ~x1 . val)."
                           (caar wrld)
                           (cadar wrld))))
              nil)))))
      (cond (redefs
             (warning$ ctx ("Redef") "~&0 redefined.~%" redefs))
            (t state))))
   (t state)))

(defun initialize-summary-accumulators (state)

; This function is the standard way to start an ACL2 event.  We push a 0 onto
; each of the timers, thus protecting the times accumulated by any superior
; (e.g., an encapsulate) and initializing an accumulator for this event.  The
; accumulated times AND warnings are printed by print-time-summary.

; Note that some state globals also need to be initialized when starting an
; event, but that is accomplished using the macro save-event-state-globals.

  #+(and (not acl2-loop-only) acl2-rewrite-meter) ; for stats on rewriter depth
  (setq *rewrite-depth-max* 0)

  (progn$

; If these time-tracker calls are changed, update :doc time-tracker
; accordingly.

   (time-tracker :tau :end) ; in case interrupt prevented preceding summary
   (time-tracker :tau :init
                 :times '(1 5)
                 :interval 10
                 :msg (concatenate
                       'string
                       (if (f-get-global 'get-internal-time-as-realtime
                                         state)
                           "Elapsed realtime"
                         "Elapsed runtime")
                       " in tau is ~st secs; see :DOC time-tracker-tau.~|~%"))
   (pprogn (cond ((null (cdr (get-timer 'other-time state))) ; top-level event
                  (mv-let (x state)
                          (main-timer state)
                          (declare (ignore x))
                          state))
                 (t ; inbetween events
                  (increment-timer 'other-time state)))
           (push-timer 'other-time 0 state)
           (push-timer 'prove-time 0 state)
           (push-timer 'print-time 0 state)
           (push-timer 'proof-tree-time 0 state)
           (push-warning-frame state))))

(defun print-warnings-summary (state)
  (mv-let
   (warnings state)
   (pop-warning-frame t state)
   (io? summary nil state
        (warnings)
        (cond ((member-eq 'warnings
                          (f-get-global 'inhibited-summary-types
                                        state))
               state)
              ((null warnings)
               state)
              (t
               (let ((channel (proofs-co state)))
                 (mv-let
                  (col state)
                  (fmt1 "Warnings:  ~*0~%"
                        (list (cons #\0
                                    (list "None" "~s*" "~s* and " "~s*, "
                                          warnings)))
                        0 channel state nil)
                  (declare (ignore col))
                  state)))))))

(defun print-time-summary (state)

; Print the time line, e.g.,

;Time:  0.15 seconds (prove: 0.00, print: 0.02, other: 0.13)

; assuming that the cursor is at the left margin.

; Once upon a time we considered extending fmt so that it knew how to
; print timers.  However, fmt needs to know which column it is left in
; and returns that to the user.  Thus, if fmt printed a timer (at
; least in the most convenient way) the user could detect the number
; of digits in it.  So we are doing it this way.

  (pprogn
   (let ((skip-proof-tree-time

; Note that get-timer is untouchable, and :pso calls trans-eval, hence
; translate1; so we must bind skip-proof-tree-time up here, not under the io?
; call below.

          (and (member-eq 'proof-tree (f-get-global 'inhibit-output-lst state))
               (= (car (get-timer 'proof-tree-time state)) 0))))
     (io? summary nil state
          (skip-proof-tree-time)
          (cond
           ((member-eq 'time
                       (f-get-global 'inhibited-summary-types
                                     state))
            state)
           (t
            (let ((channel (proofs-co state)))
              (pprogn
               (princ$ "Time:  " channel state)
               (push-timer 'total-time 0 state)
               (add-timers 'total-time 'prove-time state)
               (add-timers 'total-time 'print-time state)
               (add-timers 'total-time 'proof-tree-time state)
               (add-timers 'total-time 'other-time state)
               (print-timer 'total-time channel state)
               (pop-timer 'total-time nil state)
               (princ$ " seconds (prove: " channel state)
               (print-timer 'prove-time channel state)
               (princ$ ", print: " channel state)
               (print-timer 'print-time channel state)
               (if skip-proof-tree-time
                   state
                 (pprogn (princ$ ", proof tree: " channel state)
                         (print-timer 'proof-tree-time channel state)))
               (princ$ ", other: " channel state)
               (print-timer 'other-time channel state)
               (princ$ ")" channel state)
               (newline channel state)))))))

; The function initialize-summary-accumulators makes corresponding calls of
; push-timer, not under an io? call.  So the balancing calls of pop-timer below
; also are not under an io? call.

   (pop-timer 'prove-time t state)
   (pop-timer 'print-time t state)
   (pop-timer 'proof-tree-time t state)
   (pop-timer 'other-time t state)))

(defun prover-steps (state)

; Returns nil if no steps were taken (or if state global 'last-step-limit is
; nil, though that may be impossible).  Otherwise returns the (positive) number
; of steps taken, with one exception: If the number of steps exceeded the
; starting limit, then we return the negative of the starting limit.

  (let* ((rec (f-get-global 'step-limit-record state))
         (start (assert$ rec
                         (access step-limit-record rec :start)))
         (last-limit (assert$ start
                              (f-get-global 'last-step-limit state))))
    (cond ((and last-limit
                (not (int= start last-limit)))
           (cond ((eql last-limit -1)   ; more than start steps
                  (assert$ (natp start) ; else start <= -2; impossible
                           (- start)))
                 (t (- start last-limit))))
          (t nil))))

(defun print-steps-summary (steps state)
  (cond
   ((null steps) state)
   (t (io? summary nil state
           (steps)
           (cond
            ((member-eq 'steps
                        (f-get-global 'inhibited-summary-types
                                      state))
             state)
            (t (let ((channel (proofs-co state)))
                 (pprogn (princ$ "Prover steps counted:  " channel state)
                         (cond ((<= steps 0)
                                (pprogn
                                 (princ$ "More than " channel state)
                                 (princ$ (- steps) channel state)))
                               (t (princ$ steps channel state)))
                         (newline channel state)))))))))

(defun print-rules-summary (state)
  (let ((acc-ttree (f-get-global 'accumulated-ttree state)))
    (mv-let
     (col state)
     (io? summary nil (mv col state)
          (acc-ttree)
          (let ((channel (proofs-co state)))
            (cond ((member-eq 'rules
                              (f-get-global 'inhibited-summary-types
                                            state))
                   (mv 0 state))
                  (t
                   (let ((runes (merge-sort-runes
                                 (all-runes-in-ttree acc-ttree nil))))
                     (fmt1 "Rules: ~y0~|"
                           (list (cons #\0 runes))
                           0 channel state nil)))))
          :default-bindings ((col 0)))
     (declare (ignore col))
     (pprogn (f-put-global 'accumulated-ttree nil state)

; Since we've already printed the appropriate rules, there is no need to print
; them again the next time we want to print rules.  That is why we set the
; accumulated-ttree to nil here.  If we ever want certify-book, say, to be able
; to print rules when it fails, then we should use a stack of ttrees rather
; than a single accumulated-ttree.

             state))))

#+acl2-rewrite-meter
(defun merge-cdr-> (l1 l2)
  (cond ((null l1) l2)
        ((null l2) l1)
        ((> (cdr (car l1)) (cdr (car l2)))
         (cons (car l1) (merge-cdr-> (cdr l1) l2)))
        (t (cons (car l2) (merge-cdr-> l1 (cdr l2))))))

#+acl2-rewrite-meter
(defun merge-sort-cdr-> (l)
  (cond ((null (cdr l)) l)
        (t (merge-cdr-> (merge-sort-cdr-> (evens l))
                        (merge-sort-cdr-> (odds l))))))

(defconst *gag-prefix* "([ ")
(defconst *gag-suffix* (msg "])~|"))

(defun gag-start-msg (cl-id pool-name)
  (msg "~@0A key checkpoint~#1~[ while proving ~@2 ~
        (descended from ~@3)~/~]:"
       *gag-prefix*
       (if cl-id 0 1)
       pool-name
       (and cl-id (tilde-@-clause-id-phrase cl-id))))

(defun print-gag-info (info state)
  (fms "~@0~%~Q12~|"
       (list (cons #\0 (tilde-@-clause-id-phrase
                        (access gag-info info :clause-id)))
             (cons #\1 (prettyify-clause
                        (access gag-info info :clause)
                        (let*-abstractionp state)
                        (w state)))
             (cons #\2 (term-evisc-tuple nil state)))
       (proofs-co state) state nil))

(defun set-checkpoint-summary-limit-fn (val state)
  (if (or (eq val nil)
          (eq val t)
          (natp val)
          (and (consp val)
               (or (null (car val))
                   (natp (car val)))
               (or (null (cdr val))
                   (natp (cdr val)))))
      (let ((val (if (natp val)
                     (cons val val)
                   val)))
        (pprogn (f-put-global 'checkpoint-summary-limit val state)
                (value val)))
    (er soft 'set-checkpoint-summary-limit
        "Illegal value, ~x0, for checkpoint-summary-limit; see :DOC ~
         set-checkpoint-summary-limit."
        val)))

(defmacro set-checkpoint-summary-limit (val)
  (let ((x (if (and (consp val)
                    (eq (car val) 'quote))
               val
             (list 'quote val))))
    `(set-checkpoint-summary-limit-fn ,x state)))

(defun print-gag-stack-rev (lst limit orig-limit msg chan state)

; Lst is the reverse of the :abort-stack, :top-stack, or :sub-stack field of a
; gag-state.

  (cond ((endp lst) state)
        ((eql limit 0)
         (fms "Note: ~#2~[Not shown~/There~] ~#0~[is~#2~[ the~/~] ~n1~#2~[~/ ~
               additional~] key checkpoint~/are~#2~[ the~/~] ~n1~#2~[~/ ~
               additional~] key checkpoints~] ~@3.  See :DOC ~
               set-checkpoint-summary-limit to ~#4~[change the number ~
               printed~/print this key checkpoint~/print some or all of these ~
               key checkpoints~].~|"
              (list (cons #\0 lst)
                    (cons #\1 (length lst))
                    (cons #\2 (if (eql orig-limit 0) 0 1))
                    (cons #\3 msg)
                    (cons #\4 (cond ((not (eql orig-limit 0)) 0)
                                    ((null (cdr lst)) 1)
                                    (t 2))))
              chan state nil))
        (t (pprogn (print-gag-info (car lst) state)
                   (print-gag-stack-rev (cdr lst) (and limit (1- limit))
                                        orig-limit msg chan state)))))

(defun maybe-print-nil-goal-generated (gag-state chan state)
  (cond ((eq (access gag-state gag-state :abort-stack)
             'empty-clause)
         (fms "[NOTE: A goal of ~x0 was generated.  See :DOC nil-goal.]~|"
              (list (cons #\0 nil))
              chan state nil))
        (t (newline chan state))))

(defun print-gag-state1 (gag-state state)
  (cond
   ((eq (f-get-global 'checkpoint-summary-limit state) t)
    state)
   (gag-state
    (let* ((chan (proofs-co state))
           (abort-stack
            (access gag-state gag-state :abort-stack))
           (top-stack0 (access gag-state gag-state :top-stack))
           (top-stack (if (consp abort-stack) abort-stack top-stack0))
           (sub-stack (access gag-state gag-state :sub-stack))
           (some-stack (or sub-stack

; We use top-stack0 here instead of top-stack because if the only non-empty
; stack is the :abort-stack, then presumably the proof completed modulo :by
; hints that generated :bye tags in the ttree.

                           top-stack0))
           (forcing-round-p
            (and some-stack
                 (let ((cl-id (access gag-info (car some-stack)
                                      :clause-id)))
                   (not (eql 0 (access clause-id cl-id
                                       :forcing-round)))))))
      (cond
       (some-stack
        (pprogn
         (fms "---~|The key checkpoint goal~#0~[~/s~], below, may help you to ~
               debug this failure.  See :DOC failure and see :DOC ~
               set-checkpoint-summary-limit.~@1~|---~|"
              (list (cons #\0
                          (if (or (and top-stack sub-stack)
                                  (cdr top-stack)
                                  (cdr sub-stack))
                              1
                            0))
                    (cons #\1
                          (if forcing-round-p
                              "  Note that at least one checkpoint is in a ~
                               forcing round, so you may want to see a full ~
                               proof."
                            "")))
              chan state nil)
         (cond (top-stack
                (let ((limit (car (f-get-global
                                   'checkpoint-summary-limit
                                   state))))
                  (pprogn
                   (fms "*** Key checkpoint~#0~[~/s~] ~#1~[before reverting ~
                         to proof by induction~/at the top level~]: ***"
                        (list (cons #\0 top-stack)
                              (cons #\1 (if (consp abort-stack) 0 1)))
                        chan state nil)
                   (cond
                    (sub-stack (newline chan state))
                    (t (maybe-print-nil-goal-generated gag-state chan state)))
                   (print-gag-stack-rev
                    (reverse top-stack)
                    limit limit "before induction" chan
                    state))))
               (t state))
         (cond (sub-stack
                (let ((limit (cdr (f-get-global
                                   'checkpoint-summary-limit
                                   state))))
                  (pprogn
                   (fms "*** Key checkpoint~#0~[~/s~] under a top-level ~
                         induction ***"
                        (list (cons #\0 sub-stack))
                        chan state nil)
                   (maybe-print-nil-goal-generated gag-state chan state)
                   (print-gag-stack-rev
                    (reverse sub-stack)
                    limit
                    limit
                    "under a top-level induction"
                    chan
                    state))))
               (t state))))
       (t ; no checkpoints; aborted
        (fms #-acl2-par
             "*** Note: No checkpoints to print. ***~|"
             #+acl2-par
             "*** Note: No checkpoints from gag-mode to print. ***~|"
             nil chan state nil)))))
   (t ; no checkpoints; proof never started
    state)))

(defun erase-gag-state (state)

; Avoid repeated printing of the gag state, e.g. for a theorem under several
; levels of encapsulate or under certify-book.  We set 'gag-state here rather
; than directly inside print-gag-state because gag-state is untouchable and
; translate11 is called on in the process of running :psog.

  (pprogn (f-put-global 'gag-state-saved (f-get-global 'gag-state state) state)
          (f-put-global 'gag-state nil state)))

(defun print-gag-state (state)
  (io? error nil state
       ()
       (let ((gag-state (f-get-global 'gag-state state)))
         (pprogn (erase-gag-state state)
                 (print-gag-state1 gag-state state)))))

#+acl2-par
(defun clause-id-is-top-level (cl-id)
  (and (null (access clause-id cl-id :pool-lst))
       (equal (access clause-id cl-id :forcing-round) 0)))

#+acl2-par
(defun clause-id-is-induction-round (cl-id)
  (and (access clause-id cl-id :pool-lst)
       (equal (access clause-id cl-id :forcing-round) 0)))

#+acl2-par
(defun clause-id-is-forcing-round (cl-id)

; Note that we do not have a recognizer for inductions that occur while
; forcing.

  (not (equal (access clause-id cl-id :forcing-round) 0)))

#+acl2-par
(defun print-acl2p-checkpoints1 (checkpoints top-level-banner-printed
                                             induction-banner-printed
                                             forcing-banner-printed)
  (declare (ignorable top-level-banner-printed induction-banner-printed
                      forcing-banner-printed))
  (cond
   ((atom checkpoints)
    nil)
   (t (let* ((cl-id (caar checkpoints))
             (prettyified-clause (cdar checkpoints))
             (top-level-banner-printed
              (or top-level-banner-printed
                  (if (and (not top-level-banner-printed)
                           (clause-id-is-top-level cl-id))
                      (prog2$ (cw "~%*** ACL2(p) key checkpoint[s] at the ~
                                   top level: ***~%")
                              t)
                    top-level-banner-printed)))
             (induction-banner-printed
              (or induction-banner-printed
                  (if (and (not induction-banner-printed)
                           (clause-id-is-induction-round cl-id))
                      (prog2$ (cw "~%*** ACL2(p) key checkpoint[s] under ~
                                   induction: ***~%")
                              t)
                    induction-banner-printed)))

             (forcing-banner-printed
              (or forcing-banner-printed
                  (if (and (not forcing-banner-printed)
                           (clause-id-is-forcing-round cl-id))
                      (prog2$ (cw "~%*** ACL2(p) key checkpoint[s] under a ~
                                   forcing round: ***~%")
                              t)
                    forcing-banner-printed))))
        (progn$ (cw "~%~s0~%"
                    (string-for-tilde-@-clause-id-phrase cl-id))
                (cw "~x0~%" prettyified-clause)
                (print-acl2p-checkpoints1 (cdr checkpoints)
                                          top-level-banner-printed
                                          induction-banner-printed
                                          forcing-banner-printed))))))

#+acl2-par
(deflock *acl2p-checkpoint-saving-lock*)

#+acl2-par
(defun erase-acl2p-checkpoints-for-summary (state)
  (with-acl2p-checkpoint-saving-lock
   (f-put-global 'acl2p-checkpoints-for-summary nil state)))

#+acl2-par
(defun print-acl2p-checkpoints (state)
  (with-acl2p-checkpoint-saving-lock

; Technically, this lock acquisition is unnecessary, because we only print
; acl2p checkpoints after we have finished the waterfall (ACL2(p) is operating
; with only a single thread at that point).  However, we go ahead and do it
; anyway, as an example of good programming practice.

   (prog2$
    (if (and (f-get-global 'waterfall-parallelism state)
             (f-get-global 'acl2p-checkpoints-for-summary state))
        (prog2$
         (cw "~%~%Printing the ACL2(p) key checkpoints that were encountered ~
              during the proof attempt (and pushed for induction or ~
              sub-induction).  Note that some of these checkpoints may have ~
              been later proven by induction or sub-induction.  Thus, you ~
              must decide for yourself which of these checkpoints are ~
              relevant to debugging your proof.~%~%")
         (print-acl2p-checkpoints1
          (reverse (f-get-global 'acl2p-checkpoints-for-summary
                                 state))
          nil nil nil))
      nil)

; At first we followed the precedent set by erase-gag-state and tried only
; clearing the set of ACL2(p) checkpoints to print whenever this function is
; called.  However, we noticed that succesful proof attempts then do not clear
; the saved checkpoints.  As such, we also clear the checkpoints in defthm-fn1.

    (erase-acl2p-checkpoints-for-summary state))))

(defun character-alistp (x)
  (declare (xargs :guard t))
  (cond ((atom x) (eq x nil))
        (t (and (consp (car x))
                (characterp (car (car x)))
                (character-alistp (cdr x))))))

(defun tilde-@p (arg)
  (declare (xargs :guard t))
  (or (stringp arg)
      (and (consp arg)
           (stringp (car arg))
           (character-alistp (cdr arg)))))

(defun print-failure (erp ctx state)
  (pprogn (print-gag-state state)
          #+acl2-par
          (print-acl2p-checkpoints state)
          (io? error nil state
               (ctx erp)
               (let ((channel (proofs-co state)))
                 (pprogn
                  (error-fms-channel nil ctx "~@0See :DOC failure."
                                     (list (cons #\0
                                                 (if (tilde-@p erp)
                                                     erp
                                                   "")))
                                     channel state)
                  (newline channel state)
                  (fms *proof-failure-string* nil channel state nil))))))

(defstub initialize-event-user (ctx qbody state) state)

(defstub finalize-event-user (ctx qbody state) state)

(defun lmi-seed (lmi)

; The "seed" of an lmi is either a symbolic name or else a term.  In
; particular, the seed of a symbolp lmi is the lmi itself, the seed of
; a rune is its base symbol, the seed of a :theorem is the term
; indicated, and the seed of an :instance or :functional-instance is
; obtained recursively from the inner lmi.

; Warning: If this is changed so that runes are returned as seeds, it
; will be necessary to change the use of filter-atoms below.

  (cond ((atom lmi) lmi)
        ((eq (car lmi) :theorem) (cadr lmi))
        ((or (eq (car lmi) :instance)
             (eq (car lmi) :functional-instance))
         (lmi-seed (cadr lmi)))
        (t (base-symbol lmi))))

(defun lmi-techs (lmi)
  (cond
   ((atom lmi) nil)
   ((eq (car lmi) :theorem) nil)
   ((eq (car lmi) :instance)
    (add-to-set-equal "instantiation" (lmi-techs (cadr lmi))))
   ((eq (car lmi) :functional-instance)
    (add-to-set-equal "functional instantiation" (lmi-techs (cadr lmi))))
   (t nil)))

(defun lmi-seed-lst (lmi-lst)
  (cond ((null lmi-lst) nil)
        (t (add-to-set-eq (lmi-seed (car lmi-lst))
                          (lmi-seed-lst (cdr lmi-lst))))))

(defun lmi-techs-lst (lmi-lst)
  (cond ((null lmi-lst) nil)
        (t (union-equal (lmi-techs (car lmi-lst))
                        (lmi-techs-lst (cdr lmi-lst))))))

(defun filter-atoms (flg lst)

; If flg=t we return all the atoms in lst.  If flg=nil we return all
; the non-atoms in lst.

  (cond ((null lst) nil)
        ((eq (atom (car lst)) flg)
         (cons (car lst) (filter-atoms flg (cdr lst))))
        (t (filter-atoms flg (cdr lst)))))

(defun print-runes-summary (ttree channel state)

; This should be called under (io? summary ...).

  (let ((runes (merge-sort-runes
                (all-runes-in-ttree ttree nil))))
    (mv-let (col state)
            (fmt1 "Rules: ~y0~|"
                  (list (cons #\0 runes))
                  0 channel state nil)
            (declare (ignore col))
            state)))

(defun use-names-in-ttree (ttree)
  (let* ((objs (tagged-objects :USE ttree))
         (lmi-lst (append-lst (strip-cars (strip-cars objs))))
         (seeds (lmi-seed-lst lmi-lst))
         (lemma-names (filter-atoms t seeds)))
    (sort-symbol-listp lemma-names)))

(defun by-names-in-ttree (ttree)
  (let* ((objs (tagged-objects :BY ttree))
         (lmi-lst (append-lst (strip-cars objs)))
         (seeds (lmi-seed-lst lmi-lst))
         (lemma-names (filter-atoms t seeds)))
    (sort-symbol-listp lemma-names)))

(defrec clause-processor-hint
  (term stobjs-out . verified-p)
  nil)

(defun clause-processor-fns (cl-proc-hints)
  (cond ((endp cl-proc-hints) nil)
        (t (cons (ffn-symb (access clause-processor-hint
                                   (car cl-proc-hints)
                                   :term))
                 (clause-processor-fns (cdr cl-proc-hints))))))

(defun cl-proc-names-in-ttree (ttree)
  (let* ((objs (tagged-objects :CLAUSE-PROCESSOR ttree))
         (cl-proc-hints (strip-cars objs))
         (cl-proc-fns (clause-processor-fns cl-proc-hints)))
    (sort-symbol-listp cl-proc-fns)))

(defun print-hint-events-summary (ttree channel state)

; This should be called under (io? summary ...).

  (flet ((make-rune-like-objs (kwd lst)
                              (and lst ; optimization for common case
                                   (pairlis$ (make-list (length lst)
                                                        :INITIAL-ELEMENT kwd)
                                             (pairlis$ lst nil)))))
    (let* ((use-lst (use-names-in-ttree ttree))
           (by-lst (by-names-in-ttree ttree))
           (cl-proc-lst (cl-proc-names-in-ttree ttree))
           (lst (append (make-rune-like-objs :BY by-lst)
                        (make-rune-like-objs :CLAUSE-PROCESSOR cl-proc-lst)
                        (make-rune-like-objs :USE use-lst))))
      (cond (lst (mv-let (col state)
                         (fmt1 "Hint-events: ~y0~|"
                               (list (cons #\0 lst))
                               0 channel state nil)
                         (declare (ignore col))
                         state))
            (t state)))))

(defun print-splitter-rules-summary (cl-id clauses ttree channel state)

; When cl-id is nil, we are printing for the summary, and clauses is ignored.
; Otherwise we are printing during a proof under waterfall-msg1, for gag-mode.

  (let ((if-intro (merge-sort-runes
                   (tagged-objects 'splitter-if-intro ttree)))
        (case-split (merge-sort-runes
                     (tagged-objects 'splitter-case-split ttree)))
        (immed-forced (merge-sort-runes
                       (tagged-objects 'splitter-immed-forced ttree))))
    (cond ((or if-intro case-split immed-forced)
           (with-output-lock ; only necessary if cl-id is non-nil
            (pprogn
             (cond (cl-id (newline channel state))
                   (t state))
             (mv-let
              (col state)
              (fmt1 "Splitter ~s0 (see :DOC splitter)~@1~s2~|~@3~@4~@5"
                    (list
                     (cons #\0 (if cl-id "note" "rules"))
                     (cons #\1
                           (if cl-id

; Since we are printing during a proof (see comment above) but not already
; printing the clause-id, we do so now.  This is redundant if (f-get-global
; 'print-clause-ids state) is true, but necessary when parallelism is enabled
; for #+acl2-par, and anyhow, adds a bit of clarity.

; We leave it to waterfall-msg1 to track print-time, so we avoid calling
; waterfall-print-clause-id.

                               (msg " for ~@0 (~x1 subgoal~#2~[~/s~])"
                                    (tilde-@-clause-id-phrase cl-id)
                                    (length clauses)
                                    clauses)
                             ""))
                     (cons #\2 (if cl-id "." ":"))
                     (cons #\3
                           (cond
                            (case-split (msg "  case-split: ~y0"
                                             case-split))
                            (t "")))
                     (cons #\4
                           (cond
                            (immed-forced (msg "  immed-forced: ~y0"
                                               immed-forced))
                            (t "")))
                     (cons #\5
                           (cond
                            (if-intro (msg "  if-intro: ~y0"
                                           if-intro))
                            (t ""))))
                    0 channel state nil)
              (declare (ignore col))
              (cond (cl-id (newline channel state))
                    (t state))))))
          (t state))))

(defun print-rules-and-hint-events-summary (state)
  (pprogn
   (io? summary nil state
        ()
        (let ((channel (proofs-co state))
              (acc-ttree (f-get-global 'accumulated-ttree state))
              (inhibited-summary-types (f-get-global 'inhibited-summary-types
                                                     state)))
          (pprogn
           (cond ((member-eq 'rules inhibited-summary-types)
                  state)
                 (t (print-runes-summary acc-ttree channel state)))
           (cond ((member-eq 'hint-events inhibited-summary-types)
                  state)
                 (t (print-hint-events-summary acc-ttree channel state)))
           (cond ((member-eq 'splitter-rules inhibited-summary-types)
                  state)
                 (t (print-splitter-rules-summary nil nil acc-ttree channel
                                                  state))))))

; Since we've already printed from the accumulated-ttree, there is no need to
; print again the next time we want to print rules or hint-events.  That is why
; we set the accumulated-ttree to nil here.  If we ever want certify-book, say,
; to be able to print rules and hint-events when it fails, then we should use a
; stack of ttrees rather than a single accumulated-ttree.

   (f-put-global 'accumulated-ttree nil state)))

(defun last-prover-steps (state)
  (f-get-global 'last-prover-steps state))

(defun print-summary (erp noop-flg ctx state)

; This function prints the Summary paragraph.  Part of that paragraph includes
; the timers.  Time accumulated before entry to this function is charged to
; 'other-time.  We then pop the timers, adding their accumulations to the newly
; exposed time.  This has the effect of charging superior events for the time
; used by their inferiors.

; For simplicity, we do the above and all other computations even if we are not
; to print the summary or parts of it.  For example, we handle
; pop-warning-frame regardless of whether or not we print the warning summary.

; If erp is non-nil, the "event" caused an error and we do not scan for
; redefined names but we do print the failure string.  If noop-flg is t then
; the installed world did not get changed by the "event" (e.g., the "event" was
; redundant or was not really an event but was something like a call of (thm
; ...)) and we do not scan the most recent event block for redefined names.

; If erp is a message, as recognized by tilde-@p, then that message will be
; printed by the call below of print-failure.

  #+(and (not acl2-loop-only) acl2-rewrite-meter) ; for stats on rewriter depth
  (cond ((atom ctx))
        ((symbolp (cdr ctx))
         (cond ((not (eql *rewrite-depth-max* 0))
                (setq *rewrite-depth-alist*
                      (cons (cons (intern (symbol-name (cdr ctx)) "ACL2")

; We intern into the ACL2 package so that our tools can read this alist back in
; without needing a DEFPKG to be executed first.  The name is really all we
; care about here anyhow; all we would do with it is to search for it in the
; indicated file.

                                  *rewrite-depth-max*)
                            *rewrite-depth-alist*))
                (setq *rewrite-depth-max* 0))))
        ((eq (car ctx) 'certify-book)
         (let* ((bookname (extend-pathname
                           (f-get-global 'connected-book-directory state)
                           (cdr ctx)
                           state))
                (filename (concatenate 'string bookname ".lisp")))
           (with-open-file
            (str filename
                 :direction :output
                 :if-exists :rename-and-delete)
            (format str
                    "~s~%"
                    (cons filename
                          (merge-sort-cdr-> *rewrite-depth-alist*)))))
         (setq *rewrite-depth-alist* nil)))

  #-acl2-loop-only (dmr-flush)

  (let ((wrld (w state))
        (steps (prover-steps state)))
    (pprogn
     (f-put-global 'last-prover-steps steps state)
     (cond
      ((or (ld-skip-proofsp state)
           (output-ignored-p 'summary state))
       (pprogn (increment-timer 'other-time state)
               (if (or erp noop-flg)
                   state
                 (print-redefinition-warning wrld ctx state))
               (pop-timer 'prove-time t state)
               (pop-timer 'print-time t state)
               (pop-timer 'proof-tree-time t state)
               (pop-timer 'other-time t state)
               (mv-let (warnings state)
                       (pop-warning-frame nil state)
                       (declare (ignore warnings))
                       state)))
      (t

; Even if 'summary is inhibited, we still use io? below, and inside some
; functions below, because of its window hacking and saved-output functions.

       (pprogn
        (increment-timer 'other-time state)
        (if (or erp noop-flg)
            state
          (print-redefinition-warning wrld ctx state))
        (pprogn
         (io? summary nil state
              ()
              (let ((channel (proofs-co state)))
                (cond ((member-eq 'header
                                  (f-get-global 'inhibited-summary-types
                                                state))
                       state)
                      (t
                       (pprogn (newline channel state)
                               (princ$ "Summary" channel state)
                               (newline channel state))))))
         (io? summary nil state
              (ctx)
              (let ((channel (proofs-co state)))
                (cond ((member-eq 'form
                                  (f-get-global 'inhibited-summary-types
                                                state))
                       state)
                      (t
                       (mv-let
                        (col state)
                        (fmt1 "Form:  " nil 0 channel state nil)
                        (mv-let
                         (col state)
                         (fmt-ctx ctx col channel state)
                         (declare (ignore col))
                         (newline channel state))))))))
        (print-rules-and-hint-events-summary state) ; call of io? is inside
        (pprogn (print-warnings-summary state)
                (print-time-summary state)
                (print-steps-summary steps state)
                (progn$

; If the time-tracker call below is changed, update :doc time-tracker
; accordingly.

                 (time-tracker
                  :tau :print?
                  :min-time 1
                  :msg
                  (concatenate
                   'string
                   "For the proof above, the total "
                   (if (f-get-global 'get-internal-time-as-realtime
                                     state)
                       "realtime"
                     "runtime")
                   " spent in the tau system was ~st seconds.  See :DOC ~
                    time-tracker-tau.~|~%"))

; At one time we put (time-tracker :tau :end) here.  But in community book
; books/hints/basic-tests.lisp, the recursive proof attempt failed just below
; (add-custom-keyword-hint :recurse ...), apparently because the time-tracker
; wasn't initialized for tag :tau when the proof resumed.  It's harmless anyhow
; to avoid :end here; after all, we invoke :end before invoking :init anyhow,
; in case the proof was aborted without printing this part of the summary.

                 state))
        (cond (erp
               (pprogn
                (print-failure erp ctx state)
                (cond
                 ((f-get-global 'proof-tree state)
                  (io? proof-tree nil state
                       (ctx)
                       (pprogn (f-put-global 'proof-tree-ctx
                                             (cons :failed ctx)
                                             state)
                               (print-proof-tree state))))
                 (t state))))
              (t (pprogn
                  #+acl2-par
                  (erase-acl2p-checkpoints-for-summary state)
                  state)))
        (f-put-global 'proof-tree nil state)))))))

(defun with-prover-step-limit-fn (limit form no-change-flg)

; See the Essay on Step-limits.

  (let ((protected-form
         `(state-global-let*
           ((step-limit-record
             (make step-limit-record
                   :start wpsl-limit
                   :strictp wpsl-strictp
                   :sub-limit nil)))
           (check-vars-not-free (wpsl-limit wpsl-strictp)
                                ,form))))
    `(mv-let
      (wpsl-limit wpsl-strictp) ; for child environment
      (let ((limit ,limit))
        (cond ((or (null limit)
                   (eql limit *default-step-limit*))
               (mv *default-step-limit* nil))
              ((eq limit :start)

; We inherit the  limit and strictness from the parent environment.

; Warning: Keep the following code in sync with initial-step-limit.

               (let ((rec (f-get-global 'step-limit-record state)))
                 (cond (rec (mv (or (access step-limit-record rec :sub-limit)
                                    (f-get-global 'last-step-limit state))

; Warning: Keep the following case in sync with step-limit-strictp.

                                (access step-limit-record rec :strictp)))
                       (t (let ((limit (step-limit-from-table (w state))))
                            (mv limit
                                (< limit *default-step-limit*)))))))
              ((and (natp limit)
                    (< limit *default-step-limit*))
               (mv limit t))
              (t (mv 0 ; arbitrary
                     (er hard! 'with-prover-step-limit
                         "Illegal value for ~x0, ~x1.  See :DOC ~
                          with-prover-step-limit."
                         'with-prover-step-limit
                         limit)))))
      ,(cond
        (no-change-flg
         `(state-global-let*
           ((last-step-limit wpsl-limit))
           ,protected-form))
        (t
         `(let ((wpsl-old-limit ; existing value of last-step-limit
                 (f-get-global 'last-step-limit state)))
            (pprogn
             (f-put-global 'last-step-limit wpsl-limit state) ; new step-limit
             (mv-let
              (erp val state)
              (check-vars-not-free (wpsl-old-limit)
                                   ,protected-form)
              (let* ((steps-taken

; Even if the value of 'last-step-limit is -1, the following difference
; correctly records the number of prover steps taken, where we consider it a
; step to cause an error at the transition in step-limit from 0 to -1.  After
; all, the sub-event will say "more than", which assumes that this final step
; is counted.

                      (- wpsl-limit (f-get-global 'last-step-limit state)))
                     (new-step-limit (cond
                                      ((< wpsl-old-limit steps-taken)
                                       -1)
                                      (t (- wpsl-old-limit steps-taken)))))
                (pprogn
                 (f-put-global 'last-step-limit new-step-limit state)
                 (cond
                  (erp (mv erp val state))

; Next we consider the case that the step-limit is exceeded after completion of
; a sub-event of a compound event, for example, between the two defthm events
; below.

; (set-prover-step-limit 100)
; (encapsulate
;  ()
;  (with-prover-step-limit 500
;                          (defthm foo
;                            (equal (append (append x y) z)
;                                   (append x y z))))
;  (defthm bar (equal (car (cons x y)) x)))

                  ((and (eql new-step-limit -1)
                        (step-limit-strictp state))
                   (step-limit-error t))
                  (t (value val)))))))))))))

#+acl2-loop-only
(defmacro with-prover-step-limit (limit form
                                        &optional (actual-form 'nil
                                                               actual-form-p))

; Warning: Do not attempt to move the extra flag argument to the normal last
; position one might expect of an optional argument, without considering the
; need to change several functions (e.g., chk-embedded-event-form,
; elide-locals-rec, and destructure-expansion) that currently treat
; with-prover-step-limit as with-output is treated: expecting the event form to
; be in the last position.

; See the Essay on Step-limits.

; Form should evaluate to an error triple.  A value of :START for limit says
; that we use the current limit, i.e., the value of state global
; 'last-step-limit if the value of state global 'step-limit-record is not nil,
; else the value from the acl2-defaults-table; see initial-step-limit.

  (declare (xargs :guard (or (not actual-form-p)
                             (booleanp form))))
  (cond (actual-form-p
         (with-prover-step-limit-fn limit actual-form form))
        (t
         (with-prover-step-limit-fn limit form nil))))

#-acl2-loop-only
(defmacro with-prover-step-limit (limit form
                                        &optional (actual-form 'nil
                                                               actual-form-p))
  (declare (ignore limit))
  (cond (actual-form-p actual-form)
        (t form)))

(defmacro with-prover-step-limit! (limit form &optional no-change-flg)
  (declare (xargs :guard (booleanp no-change-flg)))
  (with-prover-step-limit-fn limit form no-change-flg))

; Start development of with-ctx-summarized.  But first we need to define
; set-w!.

; Essay on the proved-functional-instances-alist

; The world global 'proved-functional-instances-alist caches information about
; theorems proved on behalf of functional instantiation, in order to avoid the
; cost of re-proving such theorems.  In this Essay we track the flow of
; information to and from that world global.

; The above world global is a list of the following records.

(defrec proved-functional-instances-alist-entry

; Constraint-event-name is the name of an event such that the functional
; instance of that event's constraint (i.e., function's constraint or axiom's
; 'theorem property) by restricted-alist was proved on behalf of the event
; named behalf-of-event-name.  Note that behalf-of-event-name could be 0, e.g.,
; for a verify-guards event.  We arrange that restricted-alist is sorted; see
; the comment in event-responsible-for-proved-constraint.

  (constraint-event-name restricted-alist . behalf-of-event-name)
  t)

; In a nutshell, these records have the following life cycle:
; (1) They are created by hint translation, appealing to the existing value of
;     world global 'proved-functional-instances-alist to prune the list.
; (2) They go into tag-trees when hints are applied; see calls of
;     add-to-tag-tree with tags :use and :by in apply-use-hint-clauses and
;     apply-top-hints-clause1, respectively.
; (3) They are extracted from those tag-trees when events are installed.

; We focus now on (1).  Hint translation creates these records with functions
; translate-use-hint and translate-by-hint.  Translate-use-hint returns an
; object of the form

; (lmi-lst (hyp1 ... hypn) cl k event-names new-entries)

; while translate-by-hint returns an object of the form
;
; (lmi-lst thm-cl-set constraint-cl k event-names new-entries).

; In each case, new-entries is a list of
; proved-functional-instances-alist-entry records created by
; translate-lmi/functional-instance; just follow the call tree down from
; translate-use-hint or translate-by-hint to translate-lmi and then
; translate-lmi/functional-instance.  But following the call tree further, we
; see that new-entries ultimately comes from relevant-constraints, which in
; turn passes along the new-entries created by relevant-constraints1-axioms and
; relevant-constraints1.  These two functions use the already-existing records
; from world global 'proved-functional-instances-alist to prune the set of
; generated constraints (and save the behalf-of-event-name fields justifying
; such pruning for a suitable message -- see the call of tilde-@-lmi-phrase in
; apply-top-hints-clause-msg1).  These same two functions
; (relevant-constraints1-axioms and relevant-constraints1) also return a list
; of new proved-functional-instances-alist-entry records.

; The records created as above are missing the :behalf-of-event-name field
; (i.e., its value is nil), and that is how they go into tag-trees as
; components of values associated with :use and :by tags.  That missing field
; is eventually filled in by
; supply-name-for-proved-functional-instances-alist-entry in
; proved-functional-instances-from-tagged-objects, which is called by
; install-event in order to update world global
; 'proved-functional-instances-alist.

; End of Essay on the proved-functional-instances-alist

(defun supply-name-for-proved-functional-instances-alist-entry (name lst)
  (cond
   ((endp lst) nil)
   (t (cons (change proved-functional-instances-alist-entry (car lst)
                    :behalf-of-event-name name)
            (supply-name-for-proved-functional-instances-alist-entry name (cdr lst))))))

(defun proved-functional-instances-from-tagged-objects (name lst)

; For context, see the Essay on the proved-functional-instances-alist.

; Returns a list of proved-functional-instances-alist-entry records.  Lst is a
; list of values generated by calls

; (cdr (assoc-eq key (access prove-spec-var pspv :hint-settings)))

; where key is :use or :by, and where each member of lst is a value returned by
; translate-use-hint and translate-by-hint,

; (list x0 x1 x2 x3 x4 new-entries)

; -- although in the case of :by, this value could be an atom.

  (cond
   ((null lst) nil)
   ((atom (cdr (car lst)))
    (proved-functional-instances-from-tagged-objects name (cdr lst)))
   (t (append (supply-name-for-proved-functional-instances-alist-entry
               name (nth 5 (car lst)))
              (proved-functional-instances-from-tagged-objects
               name (cdr lst))))))

; Statistical and related information related to image size.
;
; Here is some information collected while first creating a small version near
; the completion of Version 1.8.
;
; At one point we had the following size statistic, using GCL 2.0:
;
; -rwxrwxr-x  1 kaufmann 13473876 May  1 11:27 small-saved_acl2
;
; We were able to account for nearly all of this 13.5 megabytes by the following
; reckoning.  Some associated code follows.
;
;  3.2    Raw GCL 2.0
;  2.9    Additional space from loading ACL2 object files
;         [note:  not much more than Nqthm, less than Pc-Nqthm!]
;  3.7    Conses (327648) from (count-objects (w state)), less those that
;         are from constants: (* 12 (- 327648 (- 21040 145))).  Note:
;         36,236 = (length (w state))
;  0.9    Extra conses (72888) generated by (get sym *CURRENT-ACL2-WORLD-KEY*);
;         see code below.  The first few such numbers, in order, are:
;         ((4207 . EVENT-LANDMARK) (3806 . COMMAND-LANDMARK)
;          (3734 . CLTL-COMMAND) (424 . EVENT-INDEX) (384 . COMMAND-INDEX)
;          (103 . PC-COMMAND-TABLE) (76 . PRIN1-WITH-SLASHES1) (75 . NTH)
;          (74 . NONCONSTRUCTIVE-AXIOM-NAMES) (72 . UPDATE-NTH))
;  0.3    Extra conses (23380) generated on symbol-plists; see code below
;  0.9    Mystery conses, (- 5.8 (+ 3.7 0.9 0.3)).  Where does 5.8 come from?
;         It's (* SYSTEM:LISP-PAGESIZE (- 1617 200)), where 1617 is the number
;         of cons pages in the ACL2 image and 200 is the number in an image
;         obtained by loading the .o files.
;  0.7    Extra cell space, other than cons, over the image obtained from .o
;         files only (including string, fixnum, ..., arrays for enabled
;         structures and type-set tables, ...):
;         (* SYSTEM:LISP-PAGESIZE
;            (- (+ 34 162 1 2 73 6 20)
;               (+  3  74 1 1 27 6 18)))
;  0.4    Other extra space, which is probably NOT related to TMP1.o space
;         (because presumably that space doesn't show up in (room)):
;         (* SYSTEM:LISP-PAGESIZE
;            (- (+ 6 107)
;               (+ 1 11)))
;  0.4    TMP1.o size calculated by:  (- 12195924 11823188), the difference
;         in sizes of two images built using (acl2::load-acl2 t) followed by
;         (initialize-acl2 nil nil t), but using a patch the second time that
;         avoided loading TMP1.o.
; ---
; 13.4    Total
;
; NOTE:  From
;
; ACL2>(length (w state))
; 36351
;
; we suspect that it would not be easy to significantly reduce the figure from
; (count-objects (w state)) above.
;
; Some relevant code:
;
; ;;;;;;;;;;;;;;; count.lisp
;
; (eval-when (load)
;            (si::allocate 'fixnum 100)))
;
; (defvar *monitor-count* nil)
;
; (defvar *string-count*
;   (make-array$ '(1) :initial-element (the fixnum 0) :element-type 'fixnum))
;
; (defvar *cons-count*
;   (make-array$ '(1) :initial-element (the fixnum 0) :element-type 'fixnum))
;
; (defvar *count-hash-table*
;   (make-hash-table :test 'eq :size 500000))
;
; (defun increment-string-count (len)
;   (declare (type fixnum len))
;   (cond ((and *monitor-count*
;               (= (the fixnum
;                    (logand (the fixnum (aref *string-count* 0))
;                            (the fixnum 4095)))
;                  0))
;          (format t "String count: ~s" (aref *string-count* 0))))
;   (setf (aref (the (array fixnum (1)) *string-count*)
;               0)
;         (the fixnum (1+ (the fixnum
;                              (+ (the fixnum len)
;                                 (the fixnum (aref *string-count* 0)))))))
;   t)
;
; (defun increment-cons-count ()
;   (cond ((and *monitor-count*
;               (= (the fixnum
;                    (logand (the fixnum (aref *cons-count* 0))
;                            (the fixnum 4095)))
;                  0))
;          (format t "Cons count: ~s" (aref *cons-count* 0))))
;   (setf (aref (the (array fixnum (1)) *cons-count*)
;               0)
;         (the fixnum (+ 1 (the fixnum (aref *cons-count* 0)))))
;   t)
;
; (defvar *acl2-strings*)
;
; (defun count-objects1 (x)
;   (cond
;    ((consp x)
;     (cond
;      ((gethash x *count-hash-table*)
;       nil)
;      (t
;       (increment-cons-count)
;       (setf (gethash x *count-hash-table*) t)
;       (count-objects1 (car x))
;       (count-objects1 (cdr x)))))
;    ((stringp x)
;     (or (gethash x *count-hash-table*)
;         (progn (increment-string-count (the fixnum (length x)))
;                (setq *acl2-strings* (cons x *acl2-strings*))
;                (setf (gethash x *count-hash-table*) t))))))
;
; (defun count-objects (x &optional clear)
;   (setq *acl2-strings* nil)
;   (setf (aref *cons-count* 0) 0)
;   (setf (aref *string-count* 0) 0)
;   (when clear
;     (clrhash *count-hash-table*))
;   (count-objects1 x)
;   (list 'cons-count (aref *cons-count* 0)
;         'string-count (aref *string-count* 0)))
;
; ;;;;;;;;;;;;;;; end of count.lisp
;
; (compile
;  (defun extra-count (&aux ans)
;    ;;  (count-objects (w state)) already done
;    (do-symbols (sym "ACL2")
;      (let ((temp (get sym *CURRENT-ACL2-WORLD-KEY*)))
;        (cond (temp
;               (let ((count (count-objects temp)))
;                 (cond
;                  (count (push (cons sym count) ans))))))))
;    ans))
;
; (progn (setq new-alist
;              (stable-sort
;               (loop for x in (extra-count)
;                     collect (cons (caddr x) (car x)))
;               (function (lambda (x y) (> (car x) (car y))))))
;        17)
;
; (loop for x in new-alist
;       sum (car x))
;
; ACL2>(take 10 new-alist)
; ((4207 . EVENT-LANDMARK) (3806 . COMMAND-LANDMARK)
;  (3734 . CLTL-COMMAND) (424 . EVENT-INDEX) (384 . COMMAND-INDEX)
;  (103 . PC-COMMAND-TABLE) (76 . PRIN1-WITH-SLASHES1) (75 . NTH)
;  (74 . NONCONSTRUCTIVE-AXIOM-NAMES) (72 . UPDATE-NTH))
;
; ACL2>(length new-alist)
; 3835
;
; Note that the symbol-plists also take up space.
;
; (compile
;  (defun more-count (&aux ans)
;    ;;  (count-objects (w state)) already done
;    (do-symbols (sym "ACL2")
;      (let ((temp (symbol-plist sym)))
;        (cond (temp
;               (let ((count (count-objects temp)))
;                 (cond
;                  (count (push (cons (cadr count) sym) ans))))))))
;    ans))
;
; (progn (setq more-alist
;              (stable-sort
;               (more-count)
;               (function (lambda (x y) (> (car x) (car y))))))
;        17)
;
; ACL2>(car more-alist)
; (180 . AREF)
;
; ACL2>(loop for x in more-alist sum (car x))
; [lots of GCs]
; 38657
; [Note:  Was 7607 using LISP package in raw GCL.]
;
; Note:  There are 3835 symbols for which ACL2 causes at least two conses on
; their symbol-plist, in the following sense.
;
; (let ((temp 0))
;        (do-symbols (x "ACL2")
;          (when (get x *CURRENT-ACL2-WORLD-KEY*)
;            (setq temp (1+ temp))))
;        temp)
;
; But that still leaves (- 38657 (+ 7607 (* 2 3835))) = 23380 conses not
; accounted for.  That's 281K of memory for "phantom" symbol-plist conses?
;
; Consider just those conses in (w state) other than 'const conses, since (except
; for the cell used to extend (w state)) these are part of the load image.
;
; (compile (defun foo ()
;            (let ((temp (loop for trip in (w state)
;                              when (eq (cadr trip) 'const)
;                              collect trip)))
;              (list (length temp) (count-objects temp)))))
; (foo)
; -->
; (145 (CONS-COUNT 21040 STRING-COUNT 5468))
;
; End of statistical and related information related to image size.

(defun add-command-landmark (defun-mode form cbd last-make-event-expansion
                              wrld)

; As with add-event-landmark above, we first update the world index
; and then add the command-landmark.  However, here it is crucial that
; the index be inside the landmark, i.e., that the landmark happen
; last.  Suppose we put the landmark down first and then added the
; index for that landmark.  If we later did a :ubt of the subsequent
; command, we would kill the index entry.  No harm would come then.
; But n commands later we would find the index out of sync with the
; maximum command number.  The problem is that :ubt keys on
; 'command-landmark and we ought to keep them outside everything else.

; The function maybe-add-command-landmark, which ld-loop uses to add
; command-landmarks in response to user commands, relies upon the fact
; that well-formed worlds always contain a command-landmark as their
; first element.

; Defun-Mode is generally the default-defun-mode of the world in which this
; form is being executed.  But there are two possible exceptions.  When we add
; the command landmarks for enter-boot-strap-mode and exit-boot-strap-mode we
; just use the defun-mode :logic.  That happens to be correct for
; exit-boot-strap-mode, but is wrong for enter-boot-strap-mode, which today is
; being executed with default-defun-mode :program.  But it is irrelevant
; because neither of those two commands are sensitive to the
; default-defun-mode.

  (global-set 'command-landmark
              (make-command-tuple
               (next-absolute-command-number wrld)
               defun-mode
               form
               cbd
               last-make-event-expansion)
              (update-world-index 'command wrld)))

(defun find-longest-common-retraction1 (wrld1 wrld2)
  (cond ((equal wrld1 wrld2) wrld1)
        (t (find-longest-common-retraction1
            (scan-to-command (cdr wrld1))
            (scan-to-command (cdr wrld2))))))

(defun find-longest-common-retraction1-event (wrld1 wrld2)
  (cond ((equal wrld1 wrld2) wrld1)
        (t (find-longest-common-retraction1
            (scan-to-event (cdr wrld1))
            (scan-to-event (cdr wrld2))))))

(defun find-longest-common-retraction (event-p wrld1 wrld2)

; Wrld1 and wrld2 are two worlds.  We find and return a wrld3 that
; concludes with a command-landmark such that both wrld1 and wrld2 are
; extensions of wrld3.  Of course, nil would do, but we find the
; longest.

  (cond
   (event-p
    (let* ((n (min (max-absolute-event-number wrld1)
                   (max-absolute-event-number wrld2))))
      (find-longest-common-retraction1-event
       (scan-to-landmark-number 'event-landmark n wrld1)
       (scan-to-landmark-number 'event-landmark n wrld2))))
   (t
    (let* ((n (min (max-absolute-command-number wrld1)
                   (max-absolute-command-number wrld2))))
      (find-longest-common-retraction1
       (scan-to-landmark-number 'command-landmark n wrld1)
       (scan-to-landmark-number 'command-landmark n wrld2))))))

(defun install-global-enabled-structure (wrld state)
  (cond
   ((null wrld) ; see initial call of set-w in enter-boot-strap-mode
    state)
   (t
    (let* ((augmented-theory (global-val 'current-theory-augmented wrld))
           (ens (f-get-global 'global-enabled-structure state))
           (theory-array (access enabled-structure ens :theory-array))
           (current-theory-index (global-val 'current-theory-index wrld))
           (eq-theories (equal augmented-theory (cdr theory-array))))
      (cond ((and eq-theories
                  (eql current-theory-index
                       (access enabled-structure ens :index-of-last-enabling)))
             state)
            ((and eq-theories
                  (< current-theory-index
                     (car (dimensions (access enabled-structure ens
                                              :array-name)
                                      theory-array))))
             (f-put-global 'global-enabled-structure
                           (change enabled-structure ens
                                   :index-of-last-enabling
                                   current-theory-index)
                           state))
            (t
             (mv-let (erp new-ens state)
                     (load-theory-into-enabled-structure
                      :no-check augmented-theory t
                      ens nil current-theory-index wrld
                      'irrelevant-ctx state)
                     (assert$ (null erp)
                              (f-put-global 'global-enabled-structure
                                            new-ens
                                            state)))))))))

#+(and (not acl2-loop-only) hons)
(defvar *defattach-fns*)

(defun set-w (flg wrld state)

; Ctx is ignored unless we are extending the current ACL2 world, in which case
; if ctx is not nil, there will be a check on the new theory from a call of
; maybe-warn-about-theory.

; This is the only way in ACL2 (as opposed to raw Common Lisp) to
; install wrld as the current-acl2-world.  Flg must be either
; 'extension or 'retraction.  Logically speaking, all this function
; does is set the state global value of 'current-acl2-world in state
; to be wrld and possibly set current-package to "ACL2".  Practically,
; speaking however, it installs wrld on the symbol-plists in Common
; Lisp.  However, wrld must be an extension or retraction, as
; indicated, of the currently installed ACL2 world.

; Statement of Policy regarding Erroneous Events and
; Current ACL2 World Installation:

; Any event which causes an error must leave the current-acl2-world of
; state unchanged.  That is, if you extend the world in an event, you
; must revert on error back to the original world.  Once upon a time
; we enforced this rule in LD, simply by reverting the world on every
; erroneous command.  But then we made that behavior conditional on
; the LD special ld-error-triples.  If ld-error-triples is nil, then
; (mv t nil state) is not treated as an error by LD.  Hence, an
; erroneous DEFUN, say, evaluated with ld-error-triples nil, does not
; cause LD to revert.  Therefore, DEFUN must manage the reversion
; itself.

  #+acl2-loop-only
  (declare (xargs :guard
                  (and (or (eq flg 'extension)
                           (eq flg 'retraction))
                       (plist-worldp wrld)
                       (known-package-alistp
                        (getprop 'known-package-alist 'global-value nil
                                 'current-acl2-world
                                 wrld))
                       (symbol-alistp
                        (getprop 'acl2-defaults-table 'table-alist nil
                                 'current-acl2-world
                                 wrld))
                       (state-p state))))

  #+acl2-loop-only
  (pprogn
   (f-put-global 'current-acl2-world

; Here comes a slimy trick to avoid compiler warnings.

                 (prog2$ flg wrld)
                 state)
   (install-global-enabled-structure wrld state)
   (cond ((find-non-hidden-package-entry (current-package state)
                                         (known-package-alist state))
          state)
         (t (f-put-global 'current-package "ACL2" state))))
  #-acl2-loop-only
  (cond ((live-state-p state)
         (cond ((and *wormholep*
                     (not (eq wrld (w *the-live-state*))))
                (push-wormhole-undo-formi 'cloaked-set-w! (w *the-live-state*)
                                          nil)))
         (let (#+hons (*defattach-fns* nil))
           (cond ((eq flg 'extension)
                  (extend-world1 'current-acl2-world wrld)
                  state)
                 (t
                  (retract-world1 'current-acl2-world wrld)
                  state))))
        (t (f-put-global 'current-acl2-world wrld state)
           (install-global-enabled-structure wrld state)
           (cond ((find-non-hidden-package-entry (current-package state)
                                                 (known-package-alist state))
                  state)
                 (t (f-put-global 'current-package "ACL2" state))))))

(defun set-w! (wrld state)

; This function makes wrld the current-acl2-world, but doesn't require
; that wrld be either an 'extension or a 'retraction of the current
; one.  Note that any two worlds, wrld1 and wrld2, can be related by a
; retraction followed by an extension: retract wrld1 back to the first
; point at which it is a tail of wrld2, and then extend that world to
; wrld2.  That is what we do.

  (let ((w (w state)))
    (cond ((equal wrld w)
           state)
          (t
           (pprogn (set-w 'retraction
                          (find-longest-common-retraction

; It is important to use events rather than commands here when certifying or
; including a book.  Otherwise, when make-event expansion extends the world, we
; will have to revert back to the beginning of the most recent top-level
; command and install the world from there.  With a large number of such
; make-event forms, such quadratic behavior could be unfortunate.  And, the
; community book books/make-event/stobj-test.lisp illustrates that if after
; make-event expansion we revert to the beginning of the book being certified,
; we could lose the setting of a stobj in that expansion.

; But really, there seems no point in using command landmarks here (as we
; always did until adding this use of event landmarks in Version_3.1).  After
; all, why back up all the way to a command landmark?  (With a different scheme
; we can imagine a reason; we'll get to that at the end of this long comment.)
; Moreover, if installation of an event were to consult the installed world, it
; would be important that all previous events have already been installed.  For
; example, in the hons version of v3-6-1, the following example caused a hard
; error, as shown and explained below.

; (defun foo (x)
;   (declare (xargs :guard t))
;   (cons x x))
;
; (progn
;   (defun foo-cond (x)
;     (declare (ignore x)
;              (xargs :guard 't))
;     nil)
;   (memoize 'foo :condition-fn 'foo-cond)
;   (progn
;     (deflabel some-label)
;     (defthm non-thm (equal x y))))

; HARD ACL2 ERROR in SCAN-TO-LANDMARK-NUMBER:  We have scanned the world
; looking for absolute event number 6463 and failed to find it....

; How could this have happened?  First note that the cltl-command for memoize
; invoked function cltl-def-from-name, which was looking in the installed world
; for the definition of foo-cond.  But the world containing that 'cltl-command
; had not yet been installed in the state, because extend-world1 only installs
; the world after processing all the new trips.  So when the defthm failed, its
; revert-world-on-error first retracted the world all the way back to just
; after the command for foo (not to just after the deflabel).  The above error
; occurred because the attempt to fetch the cltl definition of foo-cond was
; passed the installed world: the world just after the introduction of foo.
; Now we don't get that error: instead we only roll back to the event landmark
; for the deflabel, and then we back out gracefully.  Actually, we have also
; changed the implementation of memoize to avoid looking in the installed world
; for the cltl definition.  But we still like using event landmarks, which can
; result in a lot less processing of world triples since we are not backing up
; all the way to a command landmark.

; Finally we address the "different scheme" promised above for the use of
; comman landmarks.  In a chat with Sol Swords we came to realize that it would
; likely be more efficient to pop all the way back to the last command, and not
; extend that command world at all.  (Recall that each command is protected by
; ld-read-eval-print.)  For example, with the failure of non-thm above, its
; revert-world-on-error puts us at just after the deflabel; then the
; revert-world-on-error for the inner progn puts us at just after the memoize;
; and finally, the revert-world-on-error of the outer progn puts us just after
; the command introducing foo.  Why not just revert directly to that final
; world?  We could, but the current scheme has stood the test of time as being
; robust and efficient, albeit using command landmarks instead of event
; landmarks (and the latter should help performance rather than hurt it).  But
; here is a more compelling reason not to try such a scheme.  At the time a
; form fails, it is hard to know whether the error really cannot be tolerated
; and should pop us out to the start of the command.  Consider for example
; something like:

;    (progn
;      (defun h1 (x) x)
;      (make-event (mv-let (erp val state)
;                          (defthm my-bad (equal t nil))
;                          (declare (ignore erp val))
;                          (value '(value-triple nil))))
;      (defun h2 (x) (h1 x)))

; This event succeeds, and we want that to continue to be the case.  It is hard
; to see how that could work if we were left in the world before h1 when the
; make-event failed.

; Old code, using event landmarks (rather than command landmarks) only in the
; indicated situations:

;                          (or (f-get-global 'certify-book-info state)
;                              (global-val 'include-book-path w))

                           t ; always use event landmarks (see comments above)
                           wrld
                           w)
                          state)
                   (set-w 'extension
                          wrld
                          state))))))

(defmacro save-event-state-globals (form)

; Form should evaluate to an error triple.

; We assign to saved-output-reversed, rather than binding it, so that saved
; output for gag-mode replay (using pso or psog) is available outside the scope
; of with-ctx-summarized.

  `(state-global-let*
    ((accumulated-ttree nil)
     (gag-state nil)
     (print-base 10 set-print-base)
     (print-radix nil set-print-radix)
     (proof-tree-ctx nil)
     (saved-output-p
      (not (member-eq 'PROVE
                      (f-get-global 'inhibit-output-lst state)))))
    (pprogn (f-put-global 'saved-output-reversed nil state)
            (with-prover-step-limit! :START ,form))))

(defun attachment-alist (fn wrld)
  (let ((prop (getprop fn 'attachment nil 'current-acl2-world wrld)))
    (and prop
         (cond ((symbolp prop)
                (getprop prop 'attachment nil 'current-acl2-world wrld))
               ((eq (car prop) :attachment-disallowed)
                prop) ; (cdr prop) follows "because", e.g., (msg "it is bad")
               (t prop)))))

(defun attachment-pair (fn wrld)
  (let ((attachment-alist (attachment-alist fn wrld)))
    (and attachment-alist
         (not (eq (car attachment-alist) :attachment-disallowed))
         (assoc-eq fn attachment-alist))))

(defconst *protected-system-state-globals*
  (let ((val
         (set-difference-eq
          (union-eq (strip-cars *initial-ld-special-bindings*)
                    (strip-cars *initial-global-table*))
          '(acl2-raw-mode-p            ;;; keep raw mode status
            bddnotes                   ;;; for feedback after expansion failure

; We handle world and enabled structure installation ourselves, with set-w! and
; revert-world-on-error.  We do not want to rely just on state globals because
; the world protection/modification functions do pretty fancy things.

            current-acl2-world global-enabled-structure
            inhibit-output-lst         ;;; allow user to modify this in a book
            inhibited-summary-types    ;;; allow user to modify this in a book
            keep-tmp-files             ;;; allow user to modify this in a book
            make-event-debug           ;;; allow user to modify this in a book
            saved-output-token-lst     ;;; allow user to modify this in a book
            print-clause-ids           ;;; allow user to modify this in a book
            fmt-soft-right-margin      ;;; allow user to modify this in a book
            fmt-hard-right-margin      ;;; allow user to modify this in a book
            compiler-enabled           ;;; allow user to modify this in a book
            port-file-enabled          ;;; allow user to modify this in a book
            parallel-execution-enabled ;;; allow user to modify this in a book
            waterfall-parallelism      ;;; allow user to modify this in a book
            waterfall-parallelism-timing-threshold ;;; see just above
            waterfall-printing         ;;; allow user to modify this in a book
            waterfall-printing-when-finished ;;; see just above
            saved-output-reversed      ;;; for feedback after expansion failure
            saved-output-p             ;;; for feedback after expansion failure
            ttags-allowed              ;;; propagate changes outside expansion
            ld-evisc-tuple             ;;; see just above
            term-evisc-tuple           ;;; see just above
            abbrev-evisc-tuple         ;;; see just above
            gag-mode-evisc-tuple       ;;; see just above
            slow-array-action          ;;; see just above
            iprint-ar                  ;;; see just above
            iprint-soft-bound          ;;; see just above
            iprint-hard-bound          ;;; see just above
            writes-okp                 ;;; protected a different way (see
                                       ;;;   protect-system-state-globals)
            show-custom-keyword-hint-expansion
            trace-specs                ;;; keep in sync with functions that are
                                       ;;;   actually traced, e.g. trace! macro
            timer-alist                ;;; preserve accumulated summary info
            main-timer                 ;;; preserve accumulated summary info
            verbose-theory-warning     ;;; for warning on disabled mv-nth etc.
            more-doc-state             ;;; for proof-checker :more command
            pc-ss-alist                ;;; for saves under :instructions hints
            last-step-limit            ;;; propagate step-limit past expansion
            illegal-to-certify-message ;;; needs to persist past expansion
            splitter-output            ;;; allow user to modify this in a book
            top-level-errorp           ;;; allow TOP-LEVEL errors to propagate
            ))))
    val))

(defun state-global-bindings (names)
  (cond ((endp names)
         nil)
        (t (cons `(,(car names) (f-get-global ',(car names) state))
                 (state-global-bindings (cdr names))))))

(defmacro protect-system-state-globals (form)

; Form must return an error triple.  This macro not only reverts built-in state
; globals after evaluating form, but it also disables the opening of output
; channels.

  `(state-global-let*
    ,(cons `(writes-okp nil)
           (state-global-bindings *protected-system-state-globals*))
    ,form))

(defun formal-value-triple (erp val)

; Keep in sync with formal-value-triple@par.

; Returns a form that evaluates to the error triple (mv erp val state).

  (fcons-term* 'cons erp
               (fcons-term* 'cons val
                            (fcons-term* 'cons 'state *nil*))))

#+acl2-par
(defun formal-value-triple@par (erp val)

; Keep in sync with formal-value-triple.

  (fcons-term* 'cons erp
               (fcons-term* 'cons val *nil*)))

(defun@par translate-simple-or-error-triple (uform ctx wrld state)

; First suppose either #-acl2-par or else #+acl2-par with waterfall-parallelism
; disabled.  Uform is an untranslated term that is expected to translate either
; to an error triple or to an ordinary value.  In those cases we return an
; error triple whose value component is the translated term or, respectively,
; the term representing (mv nil tterm state) where tterm is the translated
; term.  Otherwise, we return a soft error.

; Now consider the case of #+acl2-par with waterfall-parallelism enabled.
; Uform is an untranslated term that is expected to translate to an ordinary
; value.  In this case, we return an error pair (mv nil val) where val is the
; translated term.  Otherwise, uform translates into an error pair (mv t nil).

  (mv-let@par
   (erp term bindings state)
   (translate1@par uform
                   :stobjs-out ; form must be executable
                   '((:stobjs-out . :stobjs-out))
                   '(state) ctx wrld state)
   (cond
    (erp (mv@par t nil state))
    (t
     (let ((stobjs-out (translate-deref :stobjs-out bindings)))
       (cond
        ((equal stobjs-out '(nil)) ; replace term by (value@par term)
         (value@par (formal-value-triple@par *nil* term)))
        ((equal stobjs-out *error-triple-sig*)
         (serial-first-form-parallel-second-form@par
          (value@par term)

; #+ACL2-PAR note: This message is used to check that computed hints and custom
; keyword hints (and perhaps other hint mechanisms too) do not modify state.
; Note that not all hint mechanisms rely upon this check.  For example,
; apply-override-hint@par and eval-clause-processor@par perform their own
; checks.

; Parallelism wart: it should be possible to return (value@par term) when
; waterfall-parallelism-hacks-enabled is non-nil.  This would allow more types
; of hints to fire when waterfall-parallelism-hacks are enabled.

          (er@par soft ctx
            "Since we are translating a form in ACL2(p) intended to be ~
             executed with waterfall parallelism enabled, the form ~x0 was ~
             expected to represent an ordinary value, not an error triple (mv ~
             erp val state), as would be acceptable in a serial execution of ~
             ACL2.  Therefore, the form returning a tuple of the form ~x1 is ~
             an error.  See :DOC unsupported-waterfall-parallelism-features ~
             and :DOC error-triples-and-parallelism for further explanation."
            uform
            (prettyify-stobj-flags stobjs-out))))
        #+acl2-par
        ((serial-first-form-parallel-second-form@par
          nil
          (and

; The test of this branch is never true in the non-@par version of the
; waterfall.  We need this test for custom-keyword-hints, which are evaluated
; using the function eval-and-translate-hint-expression[@par].  Since
; eval-and-translate-hint-expression[@par] calls
; translate-simple-or-error-triple[@par] to check the return signature of the
; custom hint, we must not cause an error when we encounter this legitimate
; use.

; Parallelism wart: consider eliminating the special case below, given the spec
; for translate-simple-or-error-triple[@par] in the comment at the top of this
; function.  This could be achieved by doing the test below before calling
; translate-simple-or-error-triple@par, either inline where we now call
; translate-simple-or-error-triple@par or else with a wrapper that handles this
; special case before calling translate-simple-or-error-triple@par.

           (equal stobjs-out *cmp-sig*)
           (eq (car uform) 'custom-keyword-hint-interpreter@par)))
         (value@par term))
        (t (serial-first-form-parallel-second-form@par
            (er soft ctx
                "The form ~x0 was expected to represent an ordinary value or ~
                 an error triple (mv erp val state), but it returns a tuple ~
                 of the form ~x1."
                uform
                (prettyify-stobj-flags stobjs-out))
            (er@par soft ctx
              "The form ~x0 was expected to represent an ordinary value, but ~
               it returns a tuple of the form ~x1.  Note that error triples ~
               are not allowed in this feature in ACL2(p) (see :doc ~
               error-triples-and-parallelism)"
              uform
              (prettyify-stobj-flags stobjs-out))))))))))

(defun xtrans-eval (uterm alist trans-flg ev-flg ctx state aok)

; NOTE: Do not call this function with er-let* if ev-flg is nil.  Use mv-let
; and check erp manually.  See the discussion of 'wait below.

; Ignore trans-flg and ev-flg for the moment (or imagine their values are t).
; Then the spec of this function is as follows:

; Uterm is an untranslated term with an output signature of * or (mv * *
; state).  We translate it and eval it under alist (after extending alist with
; state bound to the current state) and return the resulting error triple or
; signal a translate or evaluation error.  We restore the world and certain
; state globals (*protected-system-state-globals*) after the evaluation.

; If trans-flg is nil, we do not translate.  We *assume* uterm is a
; single-threaded translated term with output signature (mv * * state)!

; Ev-flg is either t or nil.  If ev-flg is nil, we are to evaluate uterm only
; if all of its free vars are bound in the evaluation environment.  If ev-flg
; is nil and we find that a free variable of uterm is not bound, we return a
; special error triple, namely (mv t 'wait state) indicating that the caller
; should wait until it can get all the vars bound.  On the other hand, if
; ev-flg is t, it means eval the translated uterm, which will signal an error
; if there is an unbound var.

; Note that we do not evaluate in safe-mode.  Perhaps we should.  However, we
; experimented by timing certification for community books directory
; books/hints/ without and with safe-mode, and found times of 13.5 and 16.4
; user seconds, respectively.  That's not a huge penalty for safe-mode but it's
; not small, either, so out of concern for scalability we will avoid safe-mode
; for now.

  (er-let* ((term
             (if trans-flg
                 (translate-simple-or-error-triple uterm ctx (w state) state)
               (value uterm))))
    (cond
     ((or ev-flg
          (subsetp-eq (all-vars term)
                      (cons 'state (strip-cars alist))))

; We are to ev the term. But first we protect ourselves by arranging
; to revert the world and restore certain state globals.

      (let ((original-world (w state)))
        (er-let*
          ((val
            (acl2-unwind-protect
             "xtrans-eval"
             (protect-system-state-globals
              (mv-let (erp val latches)
                      (ev term
                          (cons (cons 'state
                                      (coerce-state-to-object state))
                                alist)
                          state
                          (list (cons 'state
                                      (coerce-state-to-object state)))
                          nil
                          aok)
                      (let ((state (coerce-object-to-state
                                    (cdr (car latches)))))
                        (cond
                         (erp

; An evaluation error occurred.  This could happen if we encountered
; an undefined (but constrained) function.  We print the error
; message.

                          (er soft ctx "~@0" val))
                         (t

; Val is the list version of (mv erp' val' state) -- and it really is
; state in that list (typically, the live state).  We assume that if
; erp' is non-nil then the evaluation also printed the error message.
; We return an error triple.

                          (mv (car val)
                              (cadr val)
                              state))))))
             (set-w! original-world state)
             (set-w! original-world state))))
          (value val))))
     (t

; In this case, ev-flg is nil and there are variables in tterm that are
; not bound in the environment.  So we tell our caller to wait to ev the
; term.

      (mv t 'wait state)))))

#+acl2-par
(defun xtrans-eval-with-ev-w (uterm alist trans-flg ev-flg ctx state aok)

; See xtrans-eval documentation.

; This function was originally introduced in support of the #+acl2-par version.
; We could have named it "xtrans-eval@par".  However, this function seems
; worthy of having its own name, suggestive of what it is: a version of
; xtrans-eval that uses ev-w for evaluation rather than using ev.  The extra
; function call adds only trivial cost.

  (er-let*@par
   ((term
     (if trans-flg

; #+ACL2-PAR note: As of August 2011, there are two places that call
; xtrans-eval@par with the trans-flg set to nil: apply-override-hint@par and
; eval-and-translate-hint-expression@par.  In both of these cases, we performed
; a manual inspection of the code (aided by testing) to determine that if state
; can be modified by executing uterm, that the user will receive an error
; before even reaching this call of xtrans-eval@par.  In this way, we guarantee
; that the invariant for ev-w (that uterm does not modify state) is maintained.

         (translate-simple-or-error-triple@par uterm ctx (w state) state)
       (value@par uterm))))
   (cond
    ((or ev-flg
         (subsetp-eq (all-vars term)
                     (cons 'state (strip-cars alist))))

; #+ACL2-PAR note: we currently discard any changes to the world of the live
; state.  But if we restrict to terms that don't modify state, as discussed in
; the #+ACL2-PAR note above, then there is no issue because state hasn't
; changed.  Otherwise, if we cheat, the world could indeed change out from
; under us, which is just one example of the evils of cheating by modifying
; state under the hood.

     (er-let*-cmp
      ((val
        (mv-let (erp val)
                (ev-w term
                      (cons (cons 'state
                                  (coerce-state-to-object state))
                            alist)
                      (w state)
                      (user-stobj-alist state)
                      (f-get-global 'safe-mode state)
                      (gc-off state)
                      nil
                      aok)
                (cond
                 (erp

; An evaluation error occurred.  This could happen if we encountered
; an undefined (but constrained) function.  We print the error
; message.

                  (er@par soft ctx "~@0" val))
                 (t

; Val is the list version of (mv erp' val' state) -- and it really is
; state in that list (typically, the live state).  We assume that if
; erp' is non-nil then the evaluation also printed the error message.
; We return an error triple.

                  (mv (car val)
                      (cadr val)))))))
      (value@par val)))
    (t

; In this case, ev-flg is nil and there are variables in tterm that are
; not bound in the environment.  So we tell our caller to wait to ev the
; term.

     (mv t 'wait)))))

#+acl2-par
(defun xtrans-eval@par (uterm alist trans-flg ev-flg ctx state aok)
  (xtrans-eval-with-ev-w uterm alist trans-flg ev-flg ctx state aok))

(defmacro xtrans-eval-state-fn-attachment (form ctx)

; We call xtrans-eval on (pprogn (fn state) (value nil)), unless we are in the
; boot-strap or fn is unattached, in which cases we return (value nil).

; Note that arguments trans-flg and aok are t in our call of xtrans-eval.

  (declare (xargs :guard (and (true-listp form)
                              (symbolp (car form)))))
  `(let ((form ',form)
         (fn ',(car form))
         (ctx ,ctx)
         (wrld (w state)))
     (cond ((or (global-val 'boot-strap-flg wrld)
                (null (attachment-pair fn wrld)))
            (value nil))
           (t (let ((form (list 'pprogn
                                (append form '(state))
                                '(value nil))))
                (mv-let (erp val state)
                        (xtrans-eval form
                                     nil ; alist
                                     t   ; trans-flg
                                     t   ; ev-flg
                                     ctx
                                     state
                                     t ; aok
                                     )
                        (cond (erp (er soft ctx
                                       "The error above occurred during ~
                                        evaluation of ~x0."
                                       form))
                              (t (value val)))))))))

(defmacro with-ctx-summarized (ctx body)

; A typical use of this macro by an event creating function is:

; (with-ctx-summarized (cons 'defun name)
;   (er-progn ...
;             (er-let* (... (v form) ...)
;             (install-event ...))))

; Note that with-ctx-summarized binds the variables ctx and saved-wrld, which
; thus can be used in body.

; If body changes the installed world then the new world must end with an
; event-landmark (we cause an error otherwise).  The segment of the new world
; back to the previous event-landmark is scanned for redefined names and an
; appropriate warning message is printed, as per ld-redefinition-action.

; The most obvious way to satisfy this restriction on world is for each
; branch through body to (a) stop with stop-redundant-event, (b) signal an
; error, or (c) conclude with install-event.  Two of our current uses of this
; macro do not follow so simple a paradigm.  In include-book-fn we add many
; events (in process-embedded-events) but we do conclude with an install-event
; which couldn't possibly redefine any names because no names are defined in
; the segment from the last embedded event to the landmark for the include-book
; itself.  In certify-book-fn we conclude with an include-book-fn.  So in both
; of those cases the scan for redefined names ends quickly (without going into
; the names possibly redefined in the embedded events) and finds nothing to
; report.

; This macro initializes the timers for an event and then executes the supplied
; body, which should return an error triple.  Whether an error is signalled or
; not, the macro prints the summary and then pass the error triple on up.  The
; stats must be available from the state.  In particular, we print redefinition
; warnings that are recovered from the currently installed world in state and
; we print the runes from 'accumulated-ttree.

  `(let ((ctx ,ctx)
         (saved-wrld (w state)))
     (pprogn (initialize-summary-accumulators state)
             (mv-let
              (erp val state)
              (save-event-state-globals
               (mv-let (erp val state)
                       (pprogn
                        (push-io-record
                         :ctx
                         (list 'mv-let
                               '(col state)
                               '(fmt "Output replay for: "
                                     nil (standard-co state) state nil)
                               (list 'mv-let
                                     '(col state)
                                     (list 'fmt-ctx
                                           (list 'quote ctx)
                                           'col
                                           '(standard-co state)
                                           'state)
                                     '(declare (ignore col))
                                     '(newline (standard-co state) state)))
                         state)
                        (er-progn
                         (xtrans-eval-state-fn-attachment
                          (initialize-event-user ',ctx ',body)
                          ctx)
                         ,body))
                       (pprogn
                        (print-summary erp
                                       (equal saved-wrld (w state))
                                       ctx state)
                        (er-progn
                         (xtrans-eval-state-fn-attachment
                          (finalize-event-user ',ctx ',body)
                          ctx)
                         (mv erp val state)))))

; In the case of a compound event such as encapsulate, we do not want to save
; io? forms for proof replay that were generated after a failed proof attempt.
; Otherwise, if we do not set the value of 'saved-output-p below to nil, then
; replay from an encapsulate with a failed defthm will pop warnings more often
; than pushing them (resulting in an error from pop-warning-frame).  This
; failure (without setting 'saved-output-p below) happens because the pushes
; are only from io? forms saved inside the defthm, yet we were saving the
; pops from the enclosing encapsulate.

              (pprogn (f-put-global 'saved-output-p nil state)
                      (mv erp val state))))))

(defmacro revert-world-on-error (form)

; With this macro we can write (revert-world-on-error &) and if &
; causes an error the world will appear unchanged (because we revert
; back to the world of the initial state).  The local variable used to
; save the old world is a long ugly name only because we prohibit its
; use in ,form.  (Historical Note: Before the introduction of
; acl2-unwind-protect we had to use raw lisp to handle this and the
; handling of that special variable was very subtle.  Now it is just
; an ordinary local of the let.)

  `(let ((revert-world-on-error-temp (w state)))
     (acl2-unwind-protect
      "revert-world-on-error"
      (check-vars-not-free (revert-world-on-error-temp) ,form)
      (set-w! revert-world-on-error-temp state)
      state)))

(defun@par chk-theory-expr-value1 (lst wrld expr macro-aliases ctx state)

; A theory expression must evaluate to a common theory, i.e., a
; truelist of rule name designators.  A rule name designator, recall,
; is something we can interpret as a set of runes and includes runes
; themselves and the base symbols of runes, such as APP and
; ASSOC-OF-APP.  We already have a predicate for this concept:
; theoryp.  This checker checks for theoryp but with better error
; reporting.

  (cond ((atom lst)
         (cond ((null lst)
                (value@par nil))
               (t (er@par soft ctx
                    "The value of the alleged theory expression ~x0 is not a ~
                     true list and, hence, is not a legal theory value.  In ~
                     particular, the final non-consp cdr is the atom ~x1.  ~
                     See :DOC theories."
                    expr lst))))
        ((rule-name-designatorp (car lst) macro-aliases wrld)
         (chk-theory-expr-value1@par (cdr lst) wrld expr macro-aliases ctx
                                     state))
        (t (er@par soft ctx
             "The value of the alleged theory expression ~x0 includes the ~
              element ~x1, which we do not know how to interpret as a rule ~
              name.  See :DOC theories and :DOC rune."
             expr (car lst)))))

(defun@par chk-theory-expr-value (lst wrld expr ctx state)

; This checker ensures that expr, whose value is lst, evaluated to a theoryp.
; Starting after Version_3.0.1 we no longer check the theory-invariant table,
; because the ens is not yet available at this point.

  (chk-theory-expr-value1@par lst wrld expr (macro-aliases wrld) ctx state))

(defun theory-fn-translated-callp (x)

; We return t or nil.  If t, then we know that the term x evaluates to a runic
; theory.  See also theory-fn-callp.

  (and (nvariablep x)
       (not (fquotep x))
       (member-eq (car x)
                  '(current-theory-fn
                    e/d-fn
                    executable-counterpart-theory-fn
                    function-theory-fn
                    intersection-theories-fn
                    set-difference-theories-fn
                    theory-fn
                    union-theories-fn
                    universal-theory-fn))
       t))

(defun eval-theory-expr (expr ctx wrld state)

; returns a runic theory

; Keep in sync with eval-theory-expr@par.

  (cond ((equal expr '(current-theory :here))
         (mv-let (erp val latches)
                 (ev '(current-theory-fn ':here world)
                     (list (cons 'world wrld))
                     state nil nil t)
                 (declare (ignore latches))
                 (mv erp val state)))
        (t (er-let*
            ((trans-ans
              (state-global-let*
               ((guard-checking-on t) ; see the Essay on Guard Checking
;               ;;; (safe-mode t) ; !! long-standing "experimental" deletion
                )
               (simple-translate-and-eval
                expr
                (list (cons 'world wrld))
                nil
                "A theory expression" ctx wrld state t))))

; Trans-ans is (term . val).

            (cond ((theory-fn-translated-callp (car trans-ans))
                   (value (cdr trans-ans)))
                  (t
                   (er-progn
                    (chk-theory-expr-value (cdr trans-ans) wrld expr ctx state)
                    (value (runic-theory (cdr trans-ans) wrld)))))))))

#+acl2-par
(defun eval-theory-expr@par (expr ctx wrld state)

; returns a runic theory

; Keep in sync with eval-theory-expr.

  (cond ((equal expr '(current-theory :here))
         (mv-let (erp val)
                 (ev-w '(current-theory-fn ':here world)
                       (list (cons 'world wrld))
                       (w state)
                       (user-stobj-alist state)
                       (f-get-global 'safe-mode state)
                       (gc-off state)
                       nil t)
                 (mv erp val)))
        (t (er-let*@par
            ((trans-ans
              (simple-translate-and-eval@par
               expr
               (list (cons 'world wrld))
               nil
               "A theory expression" ctx wrld state t

; The following arguments are intended to match the safe-mode and gc-off values
; from the state in eval-theory-expr at the call there of
; simple-translate-and-eval.  Since there is a superior state-global-let*
; binding guard-checking-on to t, we bind our gc-off argument below to what
; would be the value of (gc-off state) in that function, which is nil.

               (f-get-global 'safe-mode state)
               nil)))

; Trans-ans is (term . val).

            (cond ((theory-fn-translated-callp (car trans-ans))
                   (value@par (cdr trans-ans)))
                  (t
                   (er-progn@par
                    (chk-theory-expr-value@par (cdr trans-ans) wrld expr ctx state)
                    (value@par (runic-theory (cdr trans-ans) wrld)))))))))

(defun append-strip-cdrs (x y)

; This is (append (strip-cdrs x) y).

  (cond ((null x) y)
        (t (cons (cdr (car x)) (append-strip-cdrs (cdr x) y)))))

(defun no-rune-based-on (runes symbols)
  (cond ((null runes) t)
        ((member-eq (base-symbol (car runes)) symbols)
         nil)
        (t (no-rune-based-on (cdr runes) symbols))))

(defun revappend-delete-runes-based-on-symbols1 (runes symbols ans)

; We delete from runes all those with base-symbols listed in symbols
; and accumulate them in reverse order onto ans.

  (cond ((null runes) ans)
        ((member-eq (base-symbol (car runes)) symbols)
         (revappend-delete-runes-based-on-symbols1 (cdr runes) symbols ans))
        (t (revappend-delete-runes-based-on-symbols1 (cdr runes)
                                                     symbols
                                                     (cons (car runes) ans)))))

(defun revappend-delete-runes-based-on-symbols (runes symbols ans)

; In computing the useful theories we will make use of previously stored values
; of those theories.  However, those stored values might contain "runes" that
; are no longer runes because of redefinition.  The following function is used
; to delete from those non-runes, based on the redefined base symbols.

; This function returns the result of appending the reverse of ans to the
; result of removing runes based on symbols from the given list of runes.  It
; should return a runic theory.

  (cond ((or (null symbols) (no-rune-based-on runes symbols))

; This case is not only a time optimization, but it also allows sharing.  For
; example, runes could be the 'current-theory, and in this case we will just be
; extending that theory.

         (revappend ans runes))
        (t (reverse
            (revappend-delete-runes-based-on-symbols1 runes symbols ans)))))

(defun current-theory1 (lst ans redefined)

; Lst is a cdr of wrld.  We wish to return the enabled theory as of the time
; lst was wrld.  When in-theory is executed it stores the newly enabled theory
; under the 'global-value of the variable 'current-theory.  When new rule names
; are introduced, they are automatically considered enabled.  Thus, the enabled
; theory at any point is the union of the current value of 'current-theory and
; the names introduced since that value was set.  However, :REDEF complicates
; matters.  See universal-theory-fn1.

  (cond ((null lst)
         #+acl2-metering (meter-maid 'current-theory1 500)
         (reverse ans)) ; unexpected, but correct
        ((eq (cadr (car lst)) 'runic-mapping-pairs)
         #+acl2-metering (setq meter-maid-cnt (1+ meter-maid-cnt))
         (cond
          ((eq (cddr (car lst)) *acl2-property-unbound*)
           (current-theory1 (cdr lst) ans
                            (add-to-set-eq (car (car lst)) redefined)))
          ((member-eq (car (car lst)) redefined)
           (current-theory1 (cdr lst) ans redefined))
          (t
           (current-theory1 (cdr lst)
                            (append-strip-cdrs (cddr (car lst)) ans)
                            redefined))))
        ((and (eq (car (car lst)) 'current-theory)
              (eq (cadr (car lst)) 'global-value))

; We append the reverse of our accumulated ans to the appropriate standard
; theory, but deleting all the redefined runes.

         #+acl2-metering (meter-maid 'current-theory1 500)
         (revappend-delete-runes-based-on-symbols (cddr (car lst))
                                                  redefined ans))
        (t
         #+acl2-metering (setq meter-maid-cnt (1+ meter-maid-cnt))
         (current-theory1 (cdr lst) ans redefined))))

(defun first-n-ac-rev (i l ac)

; This is the same as first-n-ac, except that it reverses the accumulated
; result and traffics in fixnums -- more efficient if you want the reversed
; result.

  (declare (type (unsigned-byte 29) i)
           (xargs :guard (and (true-listp l)
                              (true-listp ac))))
  (cond ((zpf i)
         ac)
        (t (first-n-ac-rev (the (unsigned-byte 29)
                                (1- (the (unsigned-byte 29) i)))
                           (cdr l)
                           (cons (car l) ac)))))

(defun longest-common-tail-length-rec (old new acc)
  (declare (type (signed-byte 30) acc))
  #-acl2-loop-only
  (when (eq old new)
    (return-from longest-common-tail-length-rec (+ (length old) acc)))
  (cond ((endp old)
         (assert$ (null new)
                  acc))
        (t (longest-common-tail-length-rec (cdr old)
                                           (cdr new)
                                           (if (equal (car old) (car new))
                                               (1+f acc)
                                             0)))))

(defun longest-common-tail-length (old new)

; We separate out this wrapper function so that we don't need to be concerned
; about missing the #-acl2-loop-only case in the recursive computation, which
; could perhaps happen if we are in safe-mode and oneification prevents escape
; into Common Lisp.

  (longest-common-tail-length-rec old new 0))

(defun extend-current-theory (old-th new-th old-aug-th wrld)

; Logically this function just returns new-th.  However, the copy of new-th
; that is returned shares a maximal tail with old-th.  A second value similarly
; extends old-aug-th, under the assumption that old-aug-th is the
; augmented-theory corresponding to old-th; except, if old-aug-th is :none then
; the second value is undefined.

  (let* ((len-old (length old-th))
         (len-new (length new-th))
         (len-common
          (cond ((int= len-old len-new)
                 (longest-common-tail-length old-th new-th))
                ((< len-old len-new)
                 (longest-common-tail-length
                  old-th
                  (nthcdr (- len-new len-old) new-th)))
                (t
                 (longest-common-tail-length
                  (nthcdr (- len-old len-new) old-th)
                  new-th))))
         (take-new (- len-new len-common))
         (nthcdr-old (- len-old len-common))
         (new-part-of-new-rev
          (first-n-ac-rev (the-unsigned-byte! 29 take-new
                                              'extend-current-theory)
                          new-th
                          nil)))
    (mv (append (reverse new-part-of-new-rev)
                (nthcdr nthcdr-old old-th))
        (if (eq old-aug-th :none)
            :none
          (append (augment-runic-theory1 new-part-of-new-rev nil wrld nil)
                  (nthcdr nthcdr-old old-aug-th))))))

(defun update-current-theory (theory0 wrld)
  (mv-let (theory theory-augmented)
          (extend-current-theory

; It's not necessarily reasonable to assume that theory0 shares a lot of
; structure with the most recent value of 'current-theory.  But it could
; happen, so we take the opportunity to save space.  Consider the not uncommon
; case that theory0 is the value of (current-theory :here).  Theory0 may be eq
; to the value of 'current-theory, in which case this extend-current-theory
; call below will be cheap because it will just do a single eq test.  However,
; theory0 could be a copy of the most recent 'current-theory that doesn't share
; much structure with it, in which case it's a good thing that we are here
; calling extend-current-theory.

           (global-val 'current-theory wrld)
           theory0
           (global-val 'current-theory-augmented wrld)
           wrld)
          (global-set 'current-theory theory
                      (global-set 'current-theory-augmented theory-augmented
                                  (global-set 'current-theory-index
                                              (1- (get-next-nume wrld))
                                              wrld)))))

(defun put-cltl-command (cltl-cmd wrld wrld0)

; We extend wrld by noting cltl-cmd.  Wrld0 is supplied because it may more
; efficient for property lookup than wrld; it is critical therefore that wrld0
; and wrld have the same values of 'include-book-path,
; 'top-level-cltl-command-stack, and 'boot-strap-flg.

  (let ((wrld (if (or (global-val 'include-book-path wrld0)
                      (global-val 'boot-strap-flg wrld0))
                  wrld
                (global-set 'top-level-cltl-command-stack
                            (cons cltl-cmd
                                  (global-val 'top-level-cltl-command-stack
                                              wrld0))
                            wrld))))
    (global-set 'cltl-command cltl-cmd wrld)))

(defun strip-non-nil-base-symbols (runes acc)
  (cond ((endp runes) acc)
        (t (strip-non-nil-base-symbols
            (cdr runes)
            (let ((b (base-symbol (car runes))))
              (cond ((null b) acc)
                    (t (cons b acc))))))))

(defun install-proof-supporters (namex ttree wrld)

; This function returns an extension of wrld in which the world global
; 'proof-supporters-alist is extended by associating namex, when a symbol or
; list of symbols, with the list of names of events used in an admissibility
; proof.  This list is sorted (by symbol-<) and is based on event names
; recorded in ttree, including runes as well as events from hints of type :use,
; :by, or :clause-processor.  However, if the list of events is empty, then we
; do not extend wrld.  See :DOC dead-events.

  (let* ((use-lst (use-names-in-ttree ttree))
         (by-lst (by-names-in-ttree ttree))
         (cl-proc-lst (cl-proc-names-in-ttree ttree))
         (runes (all-runes-in-ttree ttree nil))
         (names (append use-lst by-lst cl-proc-lst
                        (strip-non-nil-base-symbols runes nil)))
         (sorted-names (and names ; optimization
                            (sort-symbol-listp
                             (cond ((symbolp namex)
                                    (cond ((member-eq namex names)

; For example, the :induction rune for namex, or a :use (or maybe even :by)
; hint specifying namex, can be used in the guard proof.

                                           (remove-eq namex names))
                                          (t names)))
                                   ((intersectp-eq namex names)
                                    (set-difference-eq names namex))
                                   (t names))))))
    (cond ((and (not (eql namex 0))
                sorted-names)
           (global-set 'proof-supporters-alist
                       (acons namex
                              sorted-names
                              (global-val 'proof-supporters-alist wrld))
                       wrld))
          (t wrld))))

(defun install-event (val form ev-type namex ttree cltl-cmd
                          chk-theory-inv-p ctx wrld state)

; This function is the way to finish off an ACL2 event.  Val is the value to be
; returned by the event (in the standard error flag/val/state three-valued
; result).  Namex is either 0, standing for the empty set of names, an atom,
; standing for the singleton set of names containing that atom, or a true list
; of symbols, standing for the set of names in the list.  Each symbol among
; these names will be given an 'absolute-event-number property.  In addition,
; we set 'event-landmark 'global-value to an appropriate event tuple, thus
; marking the world for this event.  Cltl-cmd is the desired value of the
; 'global-value for 'cltl-command (see below).  Chk-theory-inv-p is generally
; nil, but is non-nil if we are to check theory invariants, and is :PROTECT if
; the call is not already in the scope of a revert-world-on-error.  Wrld is the
; world produced by the ACL2 event and state is the current state, and before
; extending it as indicated above, we extend it if necessary by an appropriate
; record of the proof obligations discharged in support of functional
; instantiation, in order to avoid such proofs in later events.

; Ttree is the final ttree of the event.  We install it as 'accumulated-ttree
; so that the runes reported in the summary are guaranteed to be those of the
; carefully tracked ttree passed along through the proof.  It is possible that
; the 'accumulated-ttree already in state contains junk, e.g., perhaps we
; accumulated some runes from a branch of the proof we have since abandoned.
; We try to avoid this mistake, but just to be sure that a successful proof
; reports the runes that we really believe got used, we do it this way.

; We store the 'absolute-event-number property for each name.  We set
; 'event-landmark.  We store the cltl-cmd as the value of the variable
; 'cltl-command (if cltl-cmd is non-nil).  We update the event index.  We
; install the new world as the current ACL2 world in state.  Non-logical code
; in set-w notes the 'cltl-command requests in the world and executes
; appropriate raw Common Lisp for effect.  This function returns the triple
; indicating a non-erroneous return of val.

; The installation of the world into state causes "secret" side-effects on the
; underlying lisp state, as controlled by 'cltl-command.  Generally, the value
; is a raw lisp form to execute, e.g., (defconst name val).  But when the car
; of the form is DEFUNS the general form is (DEFUNS defun-mode-flg ignorep def1
; ...  defn).  The raw lisp form to execute is actually (DEFUNS def1'
; ... defn'), where the defi' are computed from the defi depending on
; defun-mode-flg and ignorep.  Defun-Mode-flg is either nil (meaning the
; function is :non-executable or the parent event is an encapsulate which is
; trying to define the executable counterparts of the constrained functions) or
; a defun-mode (meaning the parent event is an executable DEFUNS and the
; defun-mode is the defun-mode of the defined functions).  Ignorep is
; 'reclassifying, '(defstobj . stobj-name), or nil.  If ignorep is nil, we add
; each def and its *1* counterpart, after pushing the old bodies on the undo
; stack.  If ignorep is 'reclassifying (which means we are reclassifying a
; :program fn to a :logic fn without changing its definition -- which is
; probably hand coded ACL2 source), we define only the *1* counterparts after
; pushing only the *1* counterparts on the undo stack.  If ignorep is
; '(defstobj . stobj-name) we do not add the def or its *1* counterpart, but we
; do push both the main name and the *1* name.  This is because we know
; defstobj will supply a symbol-function for the main name and its *1*
; counterpart in a moment.  We use the stobj-name in the *1* body to compute
; the stobjs-in of the function.  See the comment in add-trip.

; One might ask why we make add-trip do the oneify to produce the *1* bodies,
; instead of compute them when we generate the CLTL-COMMAND.  The reason is
; that we use the 'cltl-command of a DEFUN as the only place we can recover the
; exact ACL2 defun command that got executed.  (Exception: in the case that the
; :defun-mode is nil, i.e., the definition is non-executable, we have replaced
; the body with a throw-raw-ev-fncall.)

  (let ((currently-installed-wrld (w state)))
    (mv-let
     (chk-theory-inv-p theory-invariant-table)
     (cond ((member-eq (ld-skip-proofsp state)
                       '(include-book include-book-with-locals))
            (mv nil nil))
           (t (let ((tbl (table-alist 'theory-invariant-table
                                      currently-installed-wrld)))
                (cond ((null tbl) ; avoid work of checking theory invariant
                       (mv nil nil))
                      (t (mv chk-theory-inv-p tbl))))))
     (let* ((new-proved-fnl-insts
             (proved-functional-instances-from-tagged-objects
              (cond ((atom namex)

; We deliberately include the case namex = 0 here.

                     namex)
                    (t (car namex)))
              (revappend (strip-cars (tagged-objects :use ttree))
                         (reverse ; for backwards compatibility with v4-2
                          (tagged-objects :by ttree)))))
            (wrld0 (if (or (ld-skip-proofsp state)
                           (and (atom namex) (not (symbolp namex))))
                       wrld
                     (install-proof-supporters namex ttree wrld)))
            (wrld1a (if (and (f-get-global 'in-local-flg state)
                             (f-get-global 'certify-book-info state)
                             (not ; not inside include-book
                              (global-val 'include-book-path wrld))
                             (not (global-val 'cert-replay wrld)))
                        (global-set 'cert-replay t wrld0)
                      wrld0))
            (wrld1 (if new-proved-fnl-insts
                       (global-set
                        'proved-functional-instances-alist
                        (append new-proved-fnl-insts
                                (global-val 'proved-functional-instances-alist
                                            wrld1a))
                        wrld1a)
                     wrld1a))

; We set world global 'skip-proofs-seen or 'redef-seen if ld-skip-proofsp or
; ld-redefinition-action (respectively) is non-nil and the world global is not
; already true.  This information is important for vetting a proposed
; certification world.  See the Essay on Soundness Threats.

            (wrld2 (cond
                    ((and (ld-skip-proofsp state)
                          (not (member-eq ev-type

; Comment on irrelevance of skip-proofs:

; The following event types do not generate any proof obligations, so for these
; it is irrelevant whether or not proofs are skipped.  Do not include defaxiom,
; or any other event that can have a :corollary rule class, since that can
; generate a proof obligation.  Also do not include encapsulate; even though it
; takes responsibility for setting skip-proofs-seen based on its first pass,
; nevertheless it does not account for a skip-proofs surrounding the
; encapsulate.  Finally, do not include defattach; the use of (skip-proofs
; (defattach f g)) can generate bogus data in world global
; 'proved-functional-instances-alist that can be used to prove nil later.

                                          '(include-book
                                            defchoose
                                            defconst
                                            defdoc
                                            deflabel
                                            defmacro
                                            defpkg
                                            defstobj
                                            deftheory
                                            in-arithmetic-theory
                                            in-theory
                                            push-untouchable
                                            regenerate-tau-database
                                            remove-untouchable
                                            reset-prehistory
                                            set-body
                                            table)))

; We include the following test so that we can distinguish between the
; user-specified skipping of proofs and legitimate skipping of proofs by the
; system, such as including a book.  Without the disjunct below, we fail to
; pick up a skip-proofs during the Pcertify step of provisional certification.
; Perhaps someday there will be other times a user-supplied skip-proofs form
; triggers setting of 'skip-proofs-seen even when 'skip-proofs-by-system is
; true; if that turns out to be too aggressive, we'll think about this then,
; but for now, we are happy to be conservative, making sure that
; skip-proofs-seen is set whenever we are inside a call of skip-proofs.


                          (or (f-get-global 'inside-skip-proofs state)
                              (not (f-get-global 'skip-proofs-by-system
                                                 state)))
                          (let ((old (global-val 'skip-proofs-seen wrld)))
                            (or (not old)

; In certify-book-fn we find a comment stating that "we are trying to record
; whether there was a skip-proofs form in the present book, not merely on
; behalf of an included book".  That is why here, we replace value
; (:include-book ...) for 'skip-proofs-seen.

                                (eq (car old) :include-book))))
                     (global-set 'skip-proofs-seen form wrld1))
                    (t wrld1)))
            (wrld3 (cond
                    ((and (ld-redefinition-action state)

; We tolerate redefinition inside a book, because there must have been a trust
; tag that allowed it.  We are only trying to protect against redefinition
; without a trust tag, especially in the certification world.  (Without a trust
; tag there cannot be any redefinition in a certified book anyhow.)

                          (not (global-val 'include-book-path wrld))
                          (not (global-val 'redef-seen wrld)))
                     (global-set 'redef-seen form wrld2))
                    (t wrld2)))
            (wrld4 (if cltl-cmd
                       (put-cltl-command cltl-cmd wrld3
                                         currently-installed-wrld)
                       wrld3)))
       (er-let*
         ((wrld5 (tau-visit-event t ev-type namex
                                  (tau-auto-modep wrld4)
                                  (ens state)
                                  ctx wrld4 state)))

; WARNING: Do not put down any properties here!  The cltl-command should be the
; last property laid down before the call of add-event-landmark.  We rely on
; this invariant when looking for 'redefined tuples in
; compile-uncompiled-defuns and compile-uncompiled-*1*-defuns.

         (let ((wrld6 (add-event-landmark form ev-type namex wrld5
                                          (global-val 'boot-strap-flg
                                                      currently-installed-wrld))))
           (pprogn
            (f-put-global 'accumulated-ttree ttree state)
            (cond
             ((eq chk-theory-inv-p :protect)
              (revert-world-on-error
               (let ((state (set-w 'extension wrld6 state)))
                 (er-progn
                  (chk-theory-invariant1 :install
                                         (ens state)
                                         theory-invariant-table
                                         nil ctx state)
                  (value val)))))
             (t (let ((state (set-w 'extension wrld6 state)))
                  (cond (chk-theory-inv-p
                         (er-progn
                          (chk-theory-invariant1 :install
                                                 (ens state)
                                                 theory-invariant-table
                                                 nil ctx state)
                          (value val)))
                        (t (value val)))))))))))))

(defun stop-redundant-event-fn (ctx state extra-msg)
  (let ((chan (proofs-co state)))
    (pprogn
     (cond ((ld-skip-proofsp state) state)
           (t (io? event nil state
                   (chan ctx extra-msg)
                   (mv-let
                    (col state)
                    (fmt "The event "
                         nil
                         chan
                         state
                         nil)
                    (mv-let
                     (col state)
                     (fmt-ctx ctx col chan state)
                     (mv-let
                      (col state)
                      (fmt1 " is redundant.  See :DOC ~
                             redundant-events.~#0~[~/  ~@1~]~%"
                            (list (cons #\0 (if (null extra-msg) 0 1))
                                  (cons #\1 extra-msg))
                            col
                            chan
                            state
                            nil)
                      (declare (ignore col))
                      state)))
                   :default-bindings ((col 0)))))
     (value :redundant))))

(defmacro stop-redundant-event (ctx state &optional extra-msg)
  `(stop-redundant-event-fn ,ctx ,state ,extra-msg))

; Examining the World

; The user must be given facilities for poking around the world.  To describe
; where in the world he wishes to look, we provide "landmark descriptors."
; A landmark descriptor, lmd, identifies a given landmark in the world.
; It does this by "decoding" to either (COMMAND-LANDMARK . n) or
; (EVENT-LANDMARK . n), where n is an absolute command or event number, as
; appropriate.  Then, using lookup-world-index, one can obtain the
; relevant world.  The language of lmds is designed to let the user
; poke conveniently given the way we have chosen to display worlds.
; Below is a typical display:

; d    1 (DEFUN APP (X Y) ...)
; d    2 (DEFUN REV (X) ...)
;      3 (ENCAPSULATE (((HD *) => *)) ...)
; D       (DEFTHM HD-CONS ...)
; D       (DEFTHM HD-ATOM ...)
;      4 (IN-THEORY #)

; Observe firstly that the commands are always displayed in chronological
; order.

; Observe secondly that user commands are numbered consecutively.  We
; adopt the policy that the commands are numbered from 1 starting with
; the first command after the boot-strap.  Negative integers number
; the commands in "pre-history."  These command numbers are not our
; absolute command numbers.  Indeed, until we have completed the
; boot-strapping we don't know what "relative" command number to
; assign to the chronologically first command in the boot-strap.  We
; therefore internally maintain only absolute command numbers and just
; artificially offset them by a certain baseline when we display them
; to the user.

(defrec command-number-baseline-info
  (current permanent-p . original)
  nil)

(defun absolute-to-relative-command-number (n wrld)
  (- n (access command-number-baseline-info
               (global-val 'command-number-baseline-info wrld)
               :current)))

(defun relative-to-absolute-command-number (n wrld)
  (+ n (access command-number-baseline-info
               (global-val 'command-number-baseline-info wrld)
               :current)))

(defun normalize-absolute-command-number (n wrld)

; We have arranged that the first value of this function is a flag, which is
; set iff n exceeds the maximum absolute command number in the current world.
; Our intention is to prevent expressions like
; :ubt (:here +1)
; from executing.

  (let ((m (max-absolute-command-number wrld)))
    (cond ((> n m) (mv t m))
          ((< n 0) (mv nil 0))
          (t (mv nil n)))))

; Observe thirdly that events that are not commands are unnumbered.
; They must be referred to by logical name.

; Command Descriptors (CD)

; The basic facilities for poking around the world will operate at the
; command level.  We will define a class of objects called "command
; descriptors" which denote command landmarks in the current world.
; We will provide a function for displaying an event and its command
; block, but that will come later.

; The legal command descriptors and their meaning are shown below.  N
; is an integer, name is a logical name, and cd is a command descriptor.

; :min   -- the chronologically first command of the boot

; :start -- 0 at startup, but always refers to (exit-boot-strap-mode), even
;           after a reset-prehistory command

; :max   -- the most recently executed command -- synonymous with :x

; n      -- the nth command landmark, as enumerated by relative command
;           numbers

; name   -- the command containing the event that introduced name

; (cd n) -- the command n removed from the one described by cd

; (:search pat cd1 cd2) -- search the interval from cd1 to cd2 for the first
;           command whose form (or one of whose event forms) matches pat.
;           By "match" we mean "contains all of the elements listed".
;           We search FROM cd1 TO cd2, which will search backwards
;           if cd2 > cd1.  The special case (:search pat) means
;           (:search pat :max 1).

; The search cd is implemented as follows:

(defun tree-occur (x y)

; Does x occur in the cons tree y?

  (cond ((equal x y) t)
        ((atom y) nil)
        (t (or (tree-occur x (car y))
               (tree-occur x (cdr y))))))

(defun cd-form-matchp (pat form)

; We determine whether the form matches pat.  We support only a
; rudimentary notion of matching right now: pat is a true list of
; objects and each must occur in form.

  (cond ((symbolp form) ;eviscerated
         nil)
        ((null pat) t)
        ((tree-occur (car pat) form)
         (cd-form-matchp (cdr pat) form))
        (t nil)))

(defun cd-some-event-matchp (pat wrld)

; This is an odd function.  At first, it was as simple predicate that
; determined whether some event form in the current command block
; matched pat.  It returned t or nil.  But then we changed it so that
; if it fails it returns the world as of the next command block.  So
; if it returns t, it succeeded; non-t means failure and tells where
; to start looking next.

  (cond ((null wrld) nil)
        ((and (eq (caar wrld) 'command-landmark)
              (eq (cadar wrld) 'global-value))
         wrld)
        ((and (eq (caar wrld) 'event-landmark)
              (eq (cadar wrld) 'global-value)
              (cd-form-matchp pat (access-event-tuple-form (cddar wrld))))
         t)
        (t (cd-some-event-matchp pat (cdr wrld)))))

(defun cd-search (pat earliestp start-wrld end-wrld)

; Start-wrld is a world containing end-wrld as a predecessor.  Both
; worlds start on a command landmark.  Pat is a true list of objects.
; Earliestp it t or nil initially, but in general is either nil, t, or
; the last successfully matched world seen.

; We search from start-wrld through end-wrld looking for a command
; world that matches pat in the sense that either the command form
; itself or one of the event forms in the command block contains all
; the elements of pat.  If earliestp is non-nil we return the
; chronologically earliest matching command world.  If earliestp is
; nil we return the chronologically latest matching command world.

  (cond ((equal start-wrld end-wrld)
         (cond
          ((or (cd-form-matchp pat
                               (access-command-tuple-form (cddar start-wrld)))
               (eq t (cd-some-event-matchp pat (cdr start-wrld))))
           start-wrld)
          ((eq earliestp t) nil)
          (t earliestp)))
        ((cd-form-matchp pat
                         (access-command-tuple-form (cddar start-wrld)))
         (cond
          (earliestp
           (cd-search pat
                      start-wrld
                      (scan-to-command (cdr start-wrld))
                      end-wrld))
          (t start-wrld)))
        (t (let ((wrld1 (cd-some-event-matchp pat (cdr start-wrld))))
             (cond ((eq wrld1 t)
                    (cond (earliestp
                           (cd-search pat
                                      start-wrld
                                      (scan-to-command (cdr start-wrld))
                                      end-wrld))
                          (t start-wrld)))
                   (t (cd-search pat earliestp wrld1 end-wrld)))))))

(defun superior-command-world (wrld1 wrld ctx state)

; Given a world, wrld1, and the current ACL2 world, we return the
; world as of the command that gave rise to wrld1.  We do this by
; scanning down wrld1 for the command landmark that occurred
; chronologically before it, increment the absolute command number
; found there by 1, and look that world up in the index.  If no such
; world exists then this function has been called in a peculiar way,
; such as (progn (defun fn1 nil 1) (pc 'fn1)) at the top-level.
; Observe that when pc is called, there is not yet a command superior
; to the event fn1.  Hence, when we scan down wrld1 (which starts at
; the event for fn1) we'll find the previous command number, and
; increment it to obtain a number that is too big.  When this happens,
; we cause a soft error.

  (let ((prev-cmd-wrld (scan-to-command wrld1)))
    (cond
     ((<= (1+ (access-command-tuple-number (cddar prev-cmd-wrld)))
          (max-absolute-command-number wrld))
      (value
       (lookup-world-index 'command
                           (if prev-cmd-wrld
                               (1+ (access-command-tuple-number
                                    (cddar prev-cmd-wrld)))
                               0)
                           wrld)))
     (t (er soft ctx
            "We have been asked to find the about-to-be-most-recent ~
             command landmark.  We cannot do that because that ~
             landmark hasn't been laid down yet!")))))

(defun er-decode-cd (cd wrld ctx state)
  (let ((msg "The object ~x0 is not a legal command descriptor.  See ~
              :DOC command-descriptor."))
    (cond
     ((or (symbolp cd)
          (stringp cd))
      (cond
       ((or (eq cd :max)
            (eq cd :x))
        (value (scan-to-command wrld)))
       ((eq cd :min) (value (lookup-world-index 'command 0 wrld)))
       ((eq cd :start)
        (value (lookup-world-index
                'command
                (access command-number-baseline-info
                        (global-val 'command-number-baseline-info wrld)
                        :original)
                wrld)))
       ((and (keywordp cd)
             (let ((str (symbol-name cd)))
               (and (eql (char str 0) #\X)
                    (eql (char str 1) #\-)
                    (mv-let (k pos)
                            (parse-natural nil str 2 (length str))
                            (and k
                                 (= pos (length str)))))))

; This little piece of code parses :x-123 into (:max -123).

        (er-decode-cd (list :max
                            (- (mv-let
                                (k pos)
                                (parse-natural nil (symbol-name cd) 2
                                               (length (symbol-name cd)))
                                (declare (ignore pos))
                                k)))
                      wrld ctx state))
       (t (er-let* ((ev-wrld (er-decode-logical-name cd wrld ctx state)))
                   (superior-command-world ev-wrld wrld ctx state)))))
     ((integerp cd)
      (mv-let (flg n)
              (normalize-absolute-command-number
               (relative-to-absolute-command-number cd wrld)
               wrld)
              (cond (flg (er soft ctx
                             "The object ~x0 is not a legal command descriptor ~
                              because it exceeds the current maximum command ~
                              number, ~x1."
                             cd
                             (absolute-to-relative-command-number n wrld)))
                    (t (value
                        (lookup-world-index 'command n wrld))))))
     ((and (consp cd)
           (true-listp cd))
      (case
       (car cd)
       (:SEARCH
        (cond
         ((and (or (= (length cd) 4)
                   (= (length cd) 2))
               (or (atom (cadr cd))
                   (true-listp (cadr cd))))
          (let* ((pat (if (atom (cadr cd))
                          (list (cadr cd))
                          (cadr cd))))
            (er-let* ((wrld1 (er-decode-cd (cond ((null (cddr cd)) :max)
                                                 (t (caddr cd)))
                                           wrld ctx state))
                      (wrld2 (er-decode-cd (cond ((null (cddr cd)) 0)
                                                 (t (cadddr cd)))
                                           wrld ctx state)))
                     (let ((ans
                            (cond
                             ((>= (access-command-tuple-number (cddar wrld1))
                                  (access-command-tuple-number (cddar wrld2)))
                              (cd-search pat nil wrld1 wrld2))
                             (t
                              (cd-search pat t wrld2 wrld1)))))
                       (cond
                        ((null ans)
                         (er soft ctx
                             "No command or event in the region from ~
                              ~x0 to ~x1 contains ~&2.  See :MORE-DOC ~
                              command-descriptor."
                             (cond ((null (cddr cd)) :x)
                                   (t (caddr cd)))
                             (cond ((null (cddr cd)) 0)
                                   (t (cadddr cd)))
                             pat
                             cd))
                        (t (value ans)))))))
         (t (er soft ctx msg cd))))
       (otherwise
        (cond
         ((and (consp (cdr cd))
               (integerp (cadr cd))
               (null (cddr cd)))
          (er-let* ((wrld1 (er-decode-cd (car cd) wrld ctx state)))
                   (mv-let (flg n)
                           (normalize-absolute-command-number
                            (+ (access-command-tuple-number
                                (cddar wrld1))
                               (cadr cd))
                            wrld)
                           (cond (flg (er soft ctx
                                          "The object ~x0 is not a legal ~
                                           command descriptor because it ~
                                           represents command number ~x1,  ~
                                           which exceeds the current maximum ~
                                           command number, ~x2."
                                          cd
                                          (absolute-to-relative-command-number
                                           (+ (access-command-tuple-number
                                               (cddar wrld1))
                                              (cadr cd))
                                           wrld)
                                          (absolute-to-relative-command-number
                                           n
                                           wrld)))
                                 (t (value (lookup-world-index 'command
                                                               n
                                                               wrld)))))))
         (t (er soft ctx msg cd))))))
     (t (er soft ctx msg cd)))))

; Displaying Events and Commands

; When we display an event we will also show the "context" in which
; it occurs, by showing the command block.  The rationale is that
; the user cannot undo back to any random event -- he must always
; undo an entire command block -- and thus our convention serves to
; remind him of what will fall should he undo the displayed event.
; Similarly, when we display a command we will sketch the events in
; its block, to remind him of all the effects of that command.

; The commands in the display will be numbered sequentially.  Command
; 1 will be the first command typed by the user after bootstrap.  Negative
; command numbers refer to prehistoric commands.

; Commands will be displayed in chronological order.  This means we
; must print them in the reverse of the order in which we encounter
; them in the world.  Actually, it is not exactly the reverse, because
; we wish to print commands, encapsulates, and include-books before
; their events, but they are stored on the world after their events.

; Because some events include others it is possible for the user to
; accidentally ask us to print out large blocks, even though the
; interval specified, e.g., commands 1 through 3, is small.  This
; means that a tail recursive implementation is desirable.  (We could
; print in reverse order by printing on the way out of the recursion.)

; Because of all these complications, we have adopted a two pass
; approach to printing out segments of the world.  Both passes are
; tail recursive.  During the first, we collect a list of "landmark
; display directives" (ldd's) and during the second we interpret those
; directives to display the landmarks.  Roughly speaking, each ldd
; corresponds to one line of the display.

; Note to Software Archaeologists of the Future:

; As you study this code, you may wonder why the authors are so
; persistent in inventing long, pompous sounding names, e.g.,
; "landmark display directives" or "prove spec var" and then
; shortening them to unpronounceable letter sequences, e.g., "ldd" and
; "pspv".  This certainly goes against the grain of some software
; scientists who rail against unpronounceable names, acronyms, and
; unnecessary terminology in general.  For the record, we are not
; unsympathetic to their pleas.  However, by adopting these
; conventions we make it easy to use Emacs to find out where these
; objects are documented and manipulated.  Until this code was added
; to the system, the character string "ldd" did not occur in it.  Big
; surprise!  Had we used some perfectly reasonable English word, e.g.,
; "line" (as we might have had we described this code in isolation
; from all other) there would be many false matches.  Of course, we
; could adopt an ordinary word, e.g., "item" that just happened not to
; occur in our sources.  But unfortunately this suffers not only from
; giving a very technical meaning to an ordinary word, but offers no
; protection against the accidental use of the word later in a
; confusing way.  Better, we thought, to come up with the damn
; acronyms which one pretty much has to know about to use.

; In addition to telling us the form to print, an ldd must tell us the
; form to print, whether it is a command or an event, the command
; number, whether it is to be printed in full or only sketched,
; whether it is to be marked, whether it is fully, partially, or not
; disabled, and how far to indent it.

(defrec ldd-status
  (defun-mode-pair disabled memoized)
  nil) ; could change to t after awhile; this new record was created April 2011

(defun make-ldd-flags (class markp status fullp)

; Class is 'COMMAND or 'EVENT, markp is t or nil indicating whether we are to
; print the ">" beside the line, status is a record containing characters that
; indicate the defun-mode and disabled status (also memoized status for the
; HONS version), and fullp is t or nil indicating whether we are to print the
; form in full or just sketch it.  Once upon a time this fn didn't do any
; consing because there were only a small number of combinations and they were
; all built in.  But with the introduction of colors (which became defun-modes)
; that strategy lost its allure.

 (cons (cons class markp) (cons status fullp)))

(defun make-ldd (class markp status n fullp form)

; Class is 'command or 'event.
; Markp is t or nil, indicating whether we are to print a ">".
; Status is a an ldd-status record indicating defun-mode, disabled, and
;   (for the HONS version) memoized status.
; n is a natural number whose interpretation depends on class:
;   if class is 'command, n is the command number; otherwise,
;   n is how far we are to indent, where 1 means indent one
;   space in from the command column.
; fullp is t or nil, indicating whether we are to print the form
;   in full or only sketch it.
; form is the form to print.

  (cons (make-ldd-flags class markp status fullp)
        (cons n form)))

(defun access-ldd-class  (ldd) (caaar ldd))
(defun access-ldd-markp  (ldd) (cdaar ldd))
(defun access-ldd-status (ldd) (cadar ldd))
(defun access-ldd-fullp  (ldd) (cddar ldd))
(defun access-ldd-n      (ldd) (cadr ldd))
(defun access-ldd-form   (ldd) (cddr ldd))

(defun big-d-little-d-name1 (lst ens ans)

; Lst is a list of runic-mapping-pairs.  The car of each pair is a nume.  We
; are considering the enabled status of the runes (numes) in lst.  If all
; members of the list are enabled, we return #\E.  If all are disabled, we
; return #\D.  If some are enabled and some are disabled, we return #\d.  Ans
; is #\E or #\D signifying that we have seen some runes so far and they are all
; enabled or disabled as indicated.

  (cond ((null lst) ans)
        ((equal ans (if (enabled-numep (caar lst) ens) #\E #\D))
         (big-d-little-d-name1 (cdr lst) ens ans))
        (t #\d)))

(defun big-d-little-d-name (name ens wrld)

; Name is a symbol.  If it is the basic symbol of some nonempty set of runes,
; then we return either #\D, #\d, or #\E, depending on whether all, some, or
; none of the runes based on name are disabled.  If name is not the basic
; symbol of any rune, we return #\Space.

  (let ((temp (getprop name 'runic-mapping-pairs nil 'current-acl2-world wrld)))
    (cond ((null temp) #\Space)
          (t (big-d-little-d-name1 (cdr temp) ens
                                   (if (enabled-numep (caar temp) ens)
                                       #\E
                                       #\D))))))

(defun big-d-little-d-clique1 (names ens wrld ans)

; Same drill, one level higher.  Names is a clique of function symbols.  Ans is
; #\E or #\D indicating that all the previously seen names in the clique
; are enabled or disabled as appropriate.  We return #\E, #\D or #\d.

  (cond ((null names) ans)
        (t (let ((ans1 (big-d-little-d-name (car names) ens wrld)))
             (cond ((eql ans1 #\d) #\d)
                   ((eql ans1 ans)
                    (big-d-little-d-clique1 (cdr names) ens wrld ans))
                   (t #\d))))))

(defun big-d-little-d-clique (names ens wrld)

; Names is a list of function symbols.  As such, each symbol in it is the basic
; symbol of a set of runes.  If all of the runes are enabled, we return
; #\E, if all are disabled, we return #\D, and otherwise we return #\d.  We
; assume names is non-nil.

  (let ((ans (big-d-little-d-name (car names) ens wrld)))
    (cond ((eql ans #\d) #\d)
          (t (big-d-little-d-clique1 (cdr names) ens wrld ans)))))

(defun big-d-little-d-event (ev-tuple ens wrld)

; This function determines the enabled/disabled status of an event.  Ev-Tuple
; is an event tuple.  Wrld is the current ACL2 world.

; We return #\D, #\d, #\E or #\Space, with the following interpretation:
; #\D - at least one rule was added by this event and all rules added
;       are currently disabled;
; #\d - at least one rule was added by this event and at least one rule added
;       is currently disabled and at least one rule added is currently enabled.
; #\E - at least one rule was added by this event and all rules added
;       are currently enabled.
; #\Space - no rules were added by this event.

; Note that we do not usually print #\E and we mash it together with #\Space to
; mean all rules added, if any, are enabled.  But we need the stronger
; condition to implement our handling of blocks of events.

  (let ((namex (access-event-tuple-namex ev-tuple)))
    (case (access-event-tuple-type ev-tuple)
          ((defun defthm defaxiom)
           (big-d-little-d-name namex ens wrld))
          (defuns (big-d-little-d-clique namex ens wrld))
          (defstobj (big-d-little-d-clique (cddr namex) ens wrld))
          (otherwise #\Space))))

(defun big-d-little-d-command-block (wrld1 ens wrld s)

; Same drill, one level higher.  We scan down wrld1 to the next command
; landmark inspecting each of the event landmarks in the current command block.
; (Therefore, initially wrld1 ought to be just past the command landmark for
; the block in question.)  We determine whether this command ought to have a
; #\D, #\E, #\d, or #\Space printed beside it, by collecting that information for
; each event in the block.  Wrld is the current ACL2 world and is used to
; obtain both the current global enabled structure and the numes of the runes
; involved.

; The interpretation of the character is as described in big-d-little-d-event.

; We sweep through the events accumulating our final answer in s, which we
; think of as a "state" (but not STATE).  The interpretation of s is:
; #\D - we have seen at least one event with status #\D and all the
;       events we've seen have status #\D or status #\Space.
; #\E - we have seen at least one event with status #\E and all the
;       events we've seen have status #\E or status #\Space
; #\Space - all events seen so far (if any) have status #\Space

  (cond ((or (null wrld1)
             (and (eq (caar wrld1) 'command-landmark)
                  (eq (cadar wrld1) 'global-value)))
         s)
        ((and (eq (caar wrld1) 'event-landmark)
              (eq (cadar wrld1) 'global-value))
         (let ((s1 (big-d-little-d-event (cddar wrld1) ens wrld)))
; S1 = #\D, #\E, #\d, or #\Space
           (cond
            ((or (eql s s1)
                 (eql s1 #\Space))
             (big-d-little-d-command-block (cdr wrld1) ens wrld s))
            ((or (eql s1 #\d)
                 (and (eql s #\E)
                      (eql s1 #\D))
                 (and (eql s #\D)
                      (eql s1 #\E)))
             #\d)
            (t ; s must be #\Space
             (big-d-little-d-command-block (cdr wrld1) ens wrld s1)))))
        (t (big-d-little-d-command-block (cdr wrld1) ens wrld s))))

(defun big-m-little-m-name (name wrld)

; This function, which supports the printing of the memoization status, is
; analogous to function big-d-little-d-name, which supports the printing of the
; disabled status.

  (cond ((and (function-symbolp name wrld)
              (not (getprop name 'constrainedp nil 'current-acl2-world wrld)))
         (if (memoizedp-world name wrld)
             #\M
           #\E))
        (t #\Space)))

(defun big-m-little-m-clique1 (names wrld ans)

; This function, which supports the printing of the memoization status, is
; analogous to function big-d-little-d-clique1, which supports the printing of
; the disabled status.

  (cond ((null names) ans)
        (t (let ((ans1 (big-m-little-m-name (car names) wrld)))
             (cond ((eql ans1 #\m) #\m)
                   ((eql ans1 ans)
                    (big-m-little-m-clique1 (cdr names) wrld ans))
                   (t #\m))))))

(defun big-m-little-m-clique (names wrld)

; This function, which supports the printing of the memoization status, is
; analogous to function big-d-little-d-clique, which supports the printing of
; the disabled status.

  (let ((ans (big-m-little-m-name (car names) wrld)))
    (cond ((eql ans #\m) #\m)
          (t (big-m-little-m-clique1 (cdr names) wrld ans)))))

(defun big-m-little-m-event (ev-tuple wrld)

; This function, which supports the printing of the memoization status, is
; analogous to function big-d-little-d-event, which supports the printing of
; the disabled status.

  (let ((namex (access-event-tuple-namex ev-tuple)))
    (case (access-event-tuple-type ev-tuple)
          ((defun)
           (big-m-little-m-name namex wrld))
          (defuns (big-m-little-m-clique namex wrld))
          (defstobj (big-m-little-m-clique (cddr namex) wrld))
          (otherwise #\Space))))

(defun big-m-little-m-command-block (wrld1 wrld s)

; This function, which supports the printing of the memoization status, is
; analogous to function big-d-little-d-command-block, which supports the
; printing of the disabled status.

  (cond ((or (null wrld1)
             (and (eq (caar wrld1) 'command-landmark)
                  (eq (cadar wrld1) 'global-value)))
         s)
        ((and (eq (caar wrld1) 'event-landmark)
              (eq (cadar wrld1) 'global-value))
         (let ((s1 (big-m-little-m-event (cddar wrld1) wrld)))
; S1 = #\M, #\E, #\m, or #\Space
           (cond
            ((or (eql s s1)
                 (eql s1 #\Space))
             (big-m-little-m-command-block (cdr wrld1) wrld s))
            ((or (eql s1 #\m)
                 (and (eql s #\E)
                      (eql s1 #\M))
                 (and (eql s #\M)
                      (eql s1 #\E)))
             #\m)
            (t ; s must be #\Space
             (big-m-little-m-command-block (cdr wrld1) wrld s1)))))
        (t (big-m-little-m-command-block (cdr wrld1) wrld s))))

(defun symbol-class-char (symbol-class)

; Note: If you change the chars used below, recall that big-c-little-c-event
; knows that #\v is the symbol-class char for encapsulated fns.

  (case symbol-class
        (:program #\P)
        (:ideal #\L)
        (:common-lisp-compliant #\V)
        (otherwise #\Space)))

(defun defun-mode-string (defun-mode)
  (case defun-mode
        (:logic ":logic")
        (:program ":program")
        (otherwise (er hard 'defun-mode-string
                       "Unrecognized defun-mode, ~x0."
                       defun-mode))))

(defun big-c-little-c-event (ev-tuple wrld)

; The big-c-little-c of an event tuple with non-0 namex is a pair of
; characters, (c1 . c2), where each indicates a symbol-class.  C1 indicates the
; introductory symbol-class of the namex.  C2 indicates the current
; symbol-class.  However, if the current class is the same as the introductory
; one, c2 is #\Space.  Note that all elements of namex have the same
; symbol-class forever.  (Only defuns and encapsulate events introduce more
; than one name, and those cliques of functions are in the same class forever.)
; If an event tuple introduces no names, we return (#\Space . #\Space).

; Note: The name big-c-little-c-event is a misnomer from an earlier age.

  (case
    (access-event-tuple-type ev-tuple)
    ((defuns defun defstobj)
     (let ((c1 (symbol-class-char (access-event-tuple-symbol-class ev-tuple)))
           (c2 (symbol-class-char
                (let ((namex (access-event-tuple-namex ev-tuple)))
                  (cond ((symbolp namex) (symbol-class namex wrld))
                        (t (symbol-class (car namex) wrld)))))))
       (cond ((eql c1 c2)
              (cons c1 #\Space))
             (t (cons c1 c2)))))
    (encapsulate '(#\v . #\Space))
    (otherwise '(#\Space . #\Space))))

(defun big-c-little-c-command-block (wrld1 wrld s)

; This function determines the big-c-little-c pair of a block of events.  If
; the block contains more than one event, its pair is (#\Space . #\Space)
; because we expect the individual events in the block to have their own
; pairs printed.  If the block contains only one event, its pair is
; the pair of the block, because we generally print such blocks as the
; event.

; We scan down wrld1 to the next command landmark inspecting each of the event
; landmarks in the current command block.  (Therefore, initially wrld1 ought to
; be just past the command landmark for the block in question.) S is initially
; nil and is set to the pair of the first event we find.  Upon finding a
; second event we return (#\Space . #\Space), but if we get to the end of the
; block, we return s.

  (cond ((or (null wrld1)
             (and (eq (caar wrld1) 'command-landmark)
                  (eq (cadar wrld1) 'global-value)))

; Can a block contain no events?  I don't know anymore.  But if so, its
; defun-mode is '(#\Space . #\Space).

         (or s '(#\Space . #\Space)))
        ((and (eq (caar wrld1) 'event-landmark)
              (eq (cadar wrld1) 'global-value))
         (cond (s '(#\Space . #\Space))
               (t (big-c-little-c-command-block
                   (cdr wrld1) wrld
                   (big-c-little-c-event (cddar wrld1) wrld)))))
        (t (big-c-little-c-command-block (cdr wrld1) wrld s))))

; Now we turn to the problem of printing according to some ldd.  We first
; develop the functions for sketching a command or event form.  This is
; like evisceration (indeed, it uses the same mechanisms) but we handle
; commonly occurring event and command forms specially so that we see
; what we often want to see and no more.

(defun print-ldd-full-or-sketch/mutual-recursion (lst)

; See print-ldd-full-or-sketch.

  (cond ((null lst) nil)
        (t (cons (list 'defun (cadr (car lst)) (caddr (car lst))
                       *evisceration-ellipsis-mark*)
                 (print-ldd-full-or-sketch/mutual-recursion (cdr lst))))))

(defun print-ldd-full-or-sketch/encapsulate (lst)

; See print-ldd-full-or-sketch.

  (cond ((null lst) nil)
        (t (cons (list (car (car lst)) *evisceration-ellipsis-mark*)
                 (print-ldd-full-or-sketch/encapsulate (cdr lst))))))

; If a form has a documentation string in the database, we avoid printing
; the string.  We'll develop the general handling of doc strings soon.  But
; for now we have to define the function that recognizes when the user
; intends his string to be inserted into the database.

(defun normalize-char (c hyphen-is-spacep)
  (if (or (eql c #\Newline)
          (and hyphen-is-spacep (eql c #\-)))
      #\Space
      (char-upcase c)))

(defun normalize-string1 (str hyphen-is-spacep j ans)
  (cond ((< j 0) ans)
        (t (let ((c (normalize-char (char str j)
                                    hyphen-is-spacep)))
             (normalize-string1 str
                                hyphen-is-spacep
                                (1- j)
                                (cond ((and (eql c #\Space)
                                            (eql c (car ans)))
                                       ans)
                                      (t (cons c ans))))))))

(defun normalize-string (str hyphen-is-spacep)

; Str is a string for which we wish to search.  A normalized pattern
; is a list of the chars in the string, all of which are upper cased
; with #\Newline converted to #\Space and adjacent #\Spaces collapsed
; to one #\Space.  If hyphen-is-spacep is t, #\- is normalized to
; #\Space too.

  (normalize-string1 str hyphen-is-spacep (1- (length str)) nil))

(defun string-matchp (pat-lst str j jmax normp skippingp)

; Pat-lst is a list of characters.  Str is a string of length jmax.
; 0<=j<jmax.  If normp is non-nil we are to see str as though it had
; been normalized.  Normp should be either nil, t or
; 'hyphen-is-space.  If Skippingp is t then we are skipping
; whitespace in the str.

  (cond
   ((null pat-lst) t)
   ((>= j jmax) nil)
   (t (let ((c (if normp
                   (normalize-char (char str j)
                                   (eq normp 'hyphen-is-space))
                   (char str j))))
        (cond
         ((and skippingp (eql c #\Space))
          (string-matchp pat-lst str (1+ j) jmax normp t))
         (t (and (eql c (car pat-lst))
                 (string-matchp (cdr pat-lst)
                                str (1+ j) jmax
                                normp
                                (if normp
                                    (eql c #\Space)
                                    nil)))))))))

(defun string-search1 (pat-lst str j j-max normp)
  (cond ((< j j-max)
         (if (string-matchp pat-lst str j j-max normp nil)
             j
             (string-search1 pat-lst str (1+ j) j-max normp)))
        (t nil)))

(defun string-search (pat str normp)

; We ask whether pat occurs in str, normalizing both according to
; normp, which is either nil, t, or 'hyphen-is-space.  If pat is
; a consp, we assume it is already normalized appropriately.

  (string-search1 (if (consp pat)
                      pat
                      (if normp
                          (normalize-string pat
                                            (eq normp 'hyphen-is-space))
                          (coerce pat 'list)))
                  str
                  0
                  (length str)
                  normp))

(defun doc-stringp (str)

; If this function returns t then the first character (if any) after
; the matching #\Space in the string is at index 13.

  (and (stringp str)
       (<= 13 (length str))
       (string-matchp '(#\: #\D #\O #\C #\- #\S #\E #\C #\T #\I #\O #\N
                        #\Space)
                      str
                      0
                      13
                      t
                      nil)))

; So now we continue with the development of printing event forms.

(defconst *zapped-doc-string*
  "Documentation available via :doc")

(defun zap-doc-string-from-event-form/all-but-last (lst)
  (cond ((null lst) nil)
        ((null (cdr lst)) lst)
        ((doc-stringp (car lst))
         (cons *zapped-doc-string*
               (zap-doc-string-from-event-form/all-but-last (cdr lst))))
        (t (cons (car lst)
                 (zap-doc-string-from-event-form/all-but-last (cdr lst))))))

(defun zap-doc-string-from-event-form/second-arg (form)

; Zap a doc string if it occurs in the second arg, e.g.,
; (defdoc x doc).

  (cond ((doc-stringp (third form))
         (list (first form) (second form)
               *zapped-doc-string*))
        (t form)))

(defun zap-doc-string-from-event-form/third-arg (form)

; Zap a doc string if it occurs in the third arg, e.g.,
; (defconst x y doc).  But form may only be
; (defconst x y).

  (cond ((doc-stringp (fourth form))
         (list (first form) (second form) (third form)
               *zapped-doc-string*))
        (t form)))

(defun zap-doc-string-from-event-form/mutual-recursion (lst)
  (cond ((null lst) nil)
        (t (cons (zap-doc-string-from-event-form/all-but-last (car lst))
                 (zap-doc-string-from-event-form/mutual-recursion (cdr lst))))))

(defun zap-doc-string-from-event-form/doc-keyword (lst)

; This function is supposed to zap out a doc string if it occurs in
; :doc keyword slot.  But study the recursion and you'll find that it
; will zap a doc string str that occurs as in: (fn :key1 :doc str).
; Now is that in the :doc keyword slot or not?  If the first arg is
; normal, then it is.  If the first arg is a : keyword then the :doc
; is a value, BUT then str is in a string in another keyword position.
; So I think this function is actually correct.  It doesn't really
; matter since it is just for informative purposes.

  (cond ((null lst) nil)
        ((null (cdr lst)) lst)
        ((and (eq (car lst) :doc)
              (doc-stringp (cadr lst)))
         (cons :doc
               (cons *zapped-doc-string*
                     (zap-doc-string-from-event-form/doc-keyword (cddr lst)))))
        (t (cons (car lst)
                 (zap-doc-string-from-event-form/doc-keyword (cdr lst))))))

(defun zap-doc-string-from-event-form (form)
  (case (car form)
    ((defun defmacro)
     (zap-doc-string-from-event-form/all-but-last form))
    (mutual-recursion
     (cons 'mutual-recursion
           (zap-doc-string-from-event-form/mutual-recursion (cdr form))))
    ((defthm defaxiom deflabel deftheory include-book defchoose)
     (zap-doc-string-from-event-form/doc-keyword form))
    ((defdoc)
     (zap-doc-string-from-event-form/second-arg form))
    ((defconst defpkg)
     (zap-doc-string-from-event-form/third-arg form))
    ((verify-guards in-theory
                    in-arithmetic-theory regenerate-tau-database
                    push-untouchable remove-untouchable reset-prehistory
                    table encapsulate defstobj) form)
    (otherwise form)))

(defun print-ldd-full-or-sketch (fullp form)

; When fullp is nil, this function is like eviscerate with print-level
; 2 and print-length 3, except that we here recognize several special
; cases.  We return the eviscerated form.

; Forms with the cars shown below are always eviscerated as
; shown:

; (defun name args ...)
; (defmacro name args ...)
; (defthm name ...)
; (mutual-recursion (defun name1 args1 ...) etc)
; (encapsulate ((name1 ...) etc) ...)    ; which is also:
; (encapsulate (((P * *) ...) etc) ...)

; When fullp is t we zap the documentation strings out of event
; forms.

; It is assumed that form is well-formed.  In particular, that it has
; been evaluated without error.  Thus, if its car is defun, for
; example, it really is of the form (defun name args dcls* body).

; Technically, we should eviscerate the name and args to ensure that
; any occurrence of the *evisceration-mark* in them is properly protected.
; But the mark is a keyword and inspection of the special forms above
; reveals that there are no keywords among the uneviscerated parts.

  (cond
   ((atom form) form)
   (fullp (zap-doc-string-from-event-form form))
   (t
    (case
     (car form)
     ((defun defund defmacro)
      (list (car form) (cadr form) (caddr form) *evisceration-ellipsis-mark*))
     ((defthm defthmd)
       (list (car form) (cadr form) *evisceration-ellipsis-mark*))
     ((defdoc defconst)
      (list (car form) (cadr form) *evisceration-ellipsis-mark*))
     (mutual-recursion
      (cons 'mutual-recursion
            (print-ldd-full-or-sketch/mutual-recursion (cdr form))))
     (encapsulate
      (list 'encapsulate
            (print-ldd-full-or-sketch/encapsulate (cadr form))
            *evisceration-ellipsis-mark*))
     (t (eviscerate-simple form 2 3 nil nil nil))))))

(defmacro with-base-10 (form)

; Form evaluates to state.  Here, we want to evaluate form with the print base
; set to 10 and the print radix set to nil.

; In order to avoid parallelism hazards due to wormhole printing from inside
; the waterfall (see for example (io? prove t ...) in waterfall-msg), we avoid
; calling state-global-let* below when the print-base is already 10, as it
; typically will be (see with-ctx-summarized).  The downside is that we are
; replicating the code, form.  Without this change, if you build ACL2 with
; #+acl2-par, then evaluate the following forms, you'll see lots of parallelism
; hazard warnings.

;   :mini-proveall
;   :ubt! force-test
;   (set-waterfall-parallelism :pseudo-parallel)
;   (set-waterfall-printing :full)
;   (f-put-global 'parallelism-hazards-action t state)
;   (DEFTHM FORCE-TEST ...) ; see mini-proveall

  `(cond ((and (eq (f-get-global 'print-base state) 10)
               (eq (f-get-global 'print-radix state) nil))
          ,form)
         (t (mv-let (erp val state)
                    (state-global-let* ((print-base 10 set-print-base)
                                        (print-radix nil set-print-radix))
                                       (pprogn ,form (value nil)))
                    (declare (ignore erp val))
                    state))))

(defun print-ldd-formula-column (state)
  (cond ((hons-enabledp state) ; extra column for the memoization status
         14)
        (t 13)))

(defun print-ldd (ldd channel state)

; This is the general purpose function for printing out an ldd.

  (with-base-10
   (let ((formula-col
          (if (eq (access-ldd-class ldd) 'command)
              (print-ldd-formula-column state)
            (+ (print-ldd-formula-column state)
               (access-ldd-n ldd))))
         (status (access-ldd-status ldd)))
     (declare (type (signed-byte 30) formula-col))
     (pprogn
      (princ$ (if (access-ldd-markp ldd)
                  (access-ldd-markp ldd)
                #\Space)
              channel state)
      (let ((defun-mode-pair (access ldd-status status :defun-mode-pair)))
        (pprogn
         (princ$ (car defun-mode-pair) channel state)
         (princ$ (cdr defun-mode-pair) channel state)))
      (let ((disabled (access ldd-status status :disabled)))
        (princ$ (if (eql disabled #\E) #\Space disabled)
                channel state))
      (if (hons-enabledp state)
          (let ((memoized (access ldd-status status :memoized)))
            (princ$ (if (eql memoized #\E) #\Space memoized)
                    channel state))
        state)
      (let ((cur-col (if (hons-enabledp state) 5 4)))
        (if (eq (access-ldd-class ldd) 'command)
            (mv-let
             (col state)
             (fmt1 "~c0~s1"
                   (list
                    (cons #\0 (cons (access-ldd-n ldd) 7))
                    (cons #\1 (cond
                               ((= (access-ldd-n ldd)
                                   (absolute-to-relative-command-number
                                    (max-absolute-command-number (w state))
                                    (w state)))
                                ":x")
                               (t "  "))))
                   cur-col channel state nil)
             (declare (ignore col))
             state)
          (spaces (- formula-col cur-col) cur-col channel state)))
      (fmt-ppr
       (print-ldd-full-or-sketch (access-ldd-fullp ldd)
                                 (access-ldd-form ldd))
       t
       (+f (fmt-hard-right-margin state) (-f formula-col))
       0
       formula-col channel state
       (not (access-ldd-fullp ldd)))
      (newline channel state)))))

(defun print-ldds (ldds channel state)
  (cond ((null ldds) state)
        (t (pprogn (print-ldd (car ldds) channel state)
                   (print-ldds (cdr ldds) channel state)))))

; Now we turn to the problem of assembling lists of ldds.  There are
; currently three different situations in which we do this and rather
; than try to unify them, we write a special-purpose function for
; each.  The three situations are:

; (1) When we wish to print out a sequence of commands:  We print only the
;     commands, not their events, and we only sketch each command.  We
;     mark the endpoints.

; (2) When we wish to print out an entire command block, meaning the
;     command and each of its events: We will print the command in
;     full and marked, and we will only sketch each event.  We will
;     not show any events in the special case that there is only one
;     event and it has the same form as the command.  This function,
;     make-ldd-command-block, is the simplest of our functions that
;     deals with a mixture of commands and events.  It has to crawl
;     over the world, reversing the order (more or less) of the events
;     and taking the command in at the end.

; (3) When we wish to print out an event and its context: This is like
;     case (2) above in that we print a command and its block.  But we
;     only sketch the forms involved, except for the event requested,
;     which we print marked and in full.  To make things monumentally
;     more difficult, we also elide away irrelevant events in the
;     block.

(defun make-command-ldd (markp fullp cmd-wrld ens wrld)
  (make-ldd 'command
            markp
            (make ldd-status
                  :defun-mode-pair
                  (big-c-little-c-command-block (cdr cmd-wrld) wrld nil)
                  :disabled
                  (big-d-little-d-command-block (cdr cmd-wrld) ens wrld
                                                #\Space)
                  :memoized
                  (and (global-val 'hons-enabled wrld) ; else don't care
                       (big-m-little-m-command-block (cdr cmd-wrld) wrld
                                                     #\Space)))
            (absolute-to-relative-command-number
             (access-command-tuple-number (cddar cmd-wrld))
             wrld)
            fullp
            (access-command-tuple-form (cddar cmd-wrld))))

(defun make-event-ldd (markp indent fullp ev-tuple ens wrld)
  (make-ldd 'event
            markp
            (make ldd-status
                  :defun-mode-pair
                  (big-c-little-c-event ev-tuple wrld)
                  :disabled
                  (big-d-little-d-event ev-tuple ens wrld)
                  :memoized
                  (and (global-val 'hons-enabled wrld) ; else don't care
                       (big-m-little-m-event ev-tuple wrld)))
            indent
            fullp
            (access-event-tuple-form ev-tuple)))

(defun make-ldds-command-sequence (cmd-wrld1 cmd2 ens wrld markp ans)

; Cmd-wrld1 is a world that starts on a command landmark.  Cmd2 is a command
; tuple somewhere in cmd-wrld1 (that is, cmd1 occurred chronologically after
; cmd2).  We assemble onto ans the ldds for sketching each command between the
; two.  We mark the two endpoints provided markp is t.  If we mark, we use / as
; the mark for the earliest command and \ as the mark for the latest, so that
; when printed chronologically the marks resemble the ends of a large brace.
; If only one command is in the region, we mark it with the pointer character,
; >.

  (cond ((equal (cddar cmd-wrld1) cmd2)
         (cons (make-command-ldd (and markp (cond ((null ans) #\>) (t #\/)))
                                 nil cmd-wrld1 ens wrld)
               ans))
        (t (make-ldds-command-sequence
            (scan-to-command (cdr cmd-wrld1))
            cmd2
            ens wrld
            markp
            (cons (make-command-ldd (and markp (cond ((null ans) #\\)(t nil)))
                                    nil cmd-wrld1 ens wrld)
                  ans)))))

(defun make-ldds-command-block1 (wrld1 cmd-ldd indent fullp super-stk ens wrld
                                       ans)

; Wrld1 is a world created by the command tuple described by cmd-ldd.
; Indent is the current indent value for the ldds we create.
; Super-stk is a list of event tuples, each of which is a currently
; open superior event (e.g., encapsulation or include-book).  We wish
; to make a list of ldds for printing out that command and every event
; in its block.  We print the command marked and in full.  We only
; sketch the events, but we sketch each of them.  This is the simplest
; function that shows how to crawl down a world and produce
; print-order ldds that suggest the structure of a block.

  (cond
   ((or (null wrld1)
        (and (eq (caar wrld1) 'command-landmark)
             (eq (cadar wrld1) 'global-value)))
    (cond
     (super-stk
      (make-ldds-command-block1
       wrld1
       cmd-ldd
       (1- indent)
       fullp
       (cdr super-stk)
       ens wrld
       (cons (make-event-ldd nil (1- indent) fullp (car super-stk) ens wrld)
             ans)))
     (t (cons cmd-ldd ans))))
   ((and (eq (caar wrld1) 'event-landmark)
         (eq (cadar wrld1) 'global-value))
    (cond
     ((and super-stk
           (<= (access-event-tuple-depth (cddar wrld1))
               (access-event-tuple-depth (car super-stk))))
      (make-ldds-command-block1
       wrld1
       cmd-ldd
       (1- indent)
       fullp
       (cdr super-stk)
       ens wrld
       (cons (make-event-ldd nil (1- indent) fullp (car super-stk) ens wrld)
             ans)))
     ((or (eq (access-event-tuple-type (cddar wrld1)) 'encapsulate)
          (eq (access-event-tuple-type (cddar wrld1)) 'include-book))
      (make-ldds-command-block1
       (cdr wrld1)
       cmd-ldd
       (1+ indent)
       fullp
       (cons (cddar wrld1) super-stk)
       ens wrld
       ans))
     (t (make-ldds-command-block1
         (cdr wrld1)
         cmd-ldd
         indent
         fullp
         super-stk
         ens wrld
         (cons (make-event-ldd nil indent fullp (cddar wrld1) ens wrld)
               ans)))))
   (t (make-ldds-command-block1 (cdr wrld1)
                                cmd-ldd
                                indent
                                fullp
                                super-stk
                                ens wrld
                                ans))))

(defun make-ldds-command-block (cmd-wrld ens wrld fullp ans)

; Cmd-wrld is a world starting with a command landmark.  We make a list of ldds
; to describe the entire command block, sketching the command and sketching
; each of the events contained within the block.

  (let ((cmd-ldd (make-command-ldd nil fullp cmd-wrld ens wrld))
        (wrld1 (scan-to-event (cdr cmd-wrld))))
    (cond
     ((equal (access-event-tuple-form (cddar wrld1))
             (access-command-tuple-form (cddar cmd-wrld)))

; If the command form is the same as the event form of the
; chronologically last event then that event is to be skipped.

      (make-ldds-command-block1 (cdr wrld1) cmd-ldd 1 fullp nil ens wrld ans))
     (t (make-ldds-command-block1 wrld1 cmd-ldd 1 fullp nil ens wrld ans)))))

(defun pcb-pcb!-fn (cd fullp state)
  (io? history nil (mv erp val state)
       (cd fullp)
       (let ((wrld (w state))
             (ens (ens state)))
         (er-let* ((cmd-wrld (er-decode-cd cd wrld :pcb state)))
                  (pprogn
                   (print-ldds
                    (make-ldds-command-block cmd-wrld ens wrld fullp nil)
                    (standard-co state)
                    state)
                   (value :invisible))))))

(defun pcb!-fn (cd state)
  (pcb-pcb!-fn cd t state))

(defun pcb-fn (cd state)
  (pcb-pcb!-fn cd nil state))

(defmacro pcb! (cd)
  (list 'pcb!-fn cd 'state))

(defun pc-fn (cd state)
  (io? history nil (mv erp val state)
       (cd)
       (let ((wrld (w state)))
         (er-let* ((cmd-wrld (er-decode-cd cd wrld :pc state)))
                  (pprogn
                   (print-ldd
                    (make-command-ldd nil t cmd-wrld (ens state) wrld)
                    (standard-co state)
                    state)
                   (value :invisible))))))

(defmacro pc (cd)
  (list 'pc-fn cd 'state))

(defun pcs-fn (cd1 cd2 markp state)

; We print the commands between cd1 and cd2 (relative order of these two cds is
; irrelevant).  We always print the most recent command here, possibly elided
; into the cd1-cd2 region.  We mark the end points of the region if markp is t.

  (io? history nil (mv erp val state)
       (cd1 markp cd2)
       (let ((wrld (w state))
             (ens (ens state)))
         (er-let*
          ((cmd-wrld1 (er-decode-cd cd1 wrld :ps state))
           (cmd-wrld2 (er-decode-cd cd2 wrld :ps state)))
          (let ((later-wrld
                 (if (>= (access-command-tuple-number (cddar cmd-wrld1))
                         (access-command-tuple-number (cddar cmd-wrld2)))
                     cmd-wrld1
                   cmd-wrld2))
                (earlier-wrld
                 (if (>= (access-command-tuple-number (cddar cmd-wrld1))
                         (access-command-tuple-number (cddar cmd-wrld2)))
                     cmd-wrld2
                   cmd-wrld1)))
            (pprogn
             (print-ldds (make-ldds-command-sequence later-wrld
                                                     (cddar earlier-wrld)
                                                     ens
                                                     wrld
                                                     markp
                                                     nil)
                         (standard-co state)
                         state)
             (cond
              ((= (access-command-tuple-number (cddar later-wrld))
                  (max-absolute-command-number wrld))
               state)
              ((= (1+ (access-command-tuple-number (cddar later-wrld)))
                  (max-absolute-command-number wrld))
               (print-ldd (make-command-ldd nil nil wrld ens wrld)
                          (standard-co state)
                          state))
              (t (pprogn (mv-let
                          (col state)
                          (fmt1 "~t0: ...~%"
                                (list (cons #\0
                                            (- (print-ldd-formula-column state)
                                               2)))
                                0 (standard-co state) state nil)
                          (declare (ignore col))
                          state)
                         (print-ldd (make-command-ldd nil nil wrld ens wrld)
                                    (standard-co state)
                                    state))))
             (value :invisible)))))))

(defmacro pcs (cd1 cd2)
  (list 'pcs-fn cd1 cd2 t 'state))

(defun get-command-sequence-fn1 (cmd-wrld1 cmd2 ans)

; Keep this in sync with make-ldds-command-sequence.

  (cond ((equal (cddar cmd-wrld1) cmd2)
         (cons (access-command-tuple-form (cddar cmd-wrld1))
               ans))
        (t (get-command-sequence-fn1
            (scan-to-command (cdr cmd-wrld1))
            cmd2
            (cons (access-command-tuple-form (cddar cmd-wrld1))
                  ans)))))

(defun get-command-sequence-fn (cd1 cd2 state)

; We print the commands between cd1 and cd2 (relative order of these two cds is
; irrelevant).  We always print the most recent command here, possibly elided
; into the cd1-cd2 region.  We mark the end points of the region if markp is t.

  (let ((wrld (w state))
        (ctx 'get-command-sequence))
    (er-let*
        ((cmd-wrld1 (er-decode-cd cd1 wrld ctx state))
         (cmd-wrld2 (er-decode-cd cd2 wrld ctx state)))
      (let ((later-wrld
             (if (>= (access-command-tuple-number (cddar cmd-wrld1))
                     (access-command-tuple-number (cddar cmd-wrld2)))
                 cmd-wrld1
               cmd-wrld2))
            (earlier-wrld
             (if (>= (access-command-tuple-number (cddar cmd-wrld1))
                     (access-command-tuple-number (cddar cmd-wrld2)))
                 cmd-wrld2
               cmd-wrld1)))
        (value (get-command-sequence-fn1 later-wrld
                                         (cddar earlier-wrld)
                                         nil))))))

(defmacro get-command-sequence (cd1 cd2)
  (list 'get-command-sequence-fn cd1 cd2 'state))

(defmacro gcs (cd1 cd2)
  `(get-command-sequence ,cd1 ,cd2))

(defmacro pbt (cd1)
  (list 'pcs-fn cd1 :x nil 'state))

(defmacro pcb (cd)
  (list 'pcb-fn cd 'state))

(defun print-indented-list-msg (objects indent final-string)

; Indents the indicated number of spaces, then prints the first object, then
; prints a newline; then, recurs.  Finally, prints the string final-string.  If
; final-string is punctuation as represented by fmt directive ~y, then it will
; be printed just after the last object.

  (cond
   ((null objects) "")
   ((and final-string (null (cdr objects)))
    (msg (concatenate 'string "~_0~y1" final-string)
         indent
         (car objects)))
   (t
    (msg "~_0~y1~@2"
         indent
         (car objects)
         (print-indented-list-msg (cdr objects) indent final-string)))))

(defun print-indented-list (objects indent last-col channel evisc-tuple state)
  (cond ((null objects)
         (mv last-col state))
        (t (fmt1 "~@0"
                 (list (cons #\0 (print-indented-list-msg objects indent nil)))
                 0 channel state evisc-tuple))))

(defun print-book-path (book-path indent channel state)
  (assert$
   book-path
   (mv-let (col state)
     (fmt1 "~_0[Included books, outermost to innermost:~|"
           (list (cons #\0 indent))
           0 channel state nil)
     (declare (ignore col))
     (mv-let (col state)
       (print-indented-list book-path (1+ indent) 0 channel nil state)
       (pprogn (if (eql col 0)
                   (spaces indent col channel state)
                 state)
               (princ$ #\] channel state))))))

(defun pe-fn1 (wrld channel ev-wrld cmd-wrld state)
  (cond
   ((equal (access-event-tuple-form (cddar ev-wrld))
           (access-command-tuple-form (cddar cmd-wrld)))
    (print-ldd
     (make-command-ldd nil t cmd-wrld (ens state) wrld)
     channel state))
   (t
    (let ((indent (print-ldd-formula-column state))
          (ens (ens state)))
      (pprogn
       (print-ldd
        (make-command-ldd nil nil cmd-wrld ens wrld)
        channel state)
       (mv-let (col state)
         (fmt1 "~_0\\~%" (list (cons #\0 indent)) 0 channel state nil)
         (declare (ignore col))
         state)
       (let ((book-path (global-val 'include-book-path ev-wrld)))
         (cond (book-path
                (pprogn
                 (print-book-path (reverse book-path)
                                  indent channel state)
                 (fms "~_0\\~%" (list (cons #\0 indent)) channel state nil)))
               (t state)))
       (print-ldd
        (make-event-ldd #\> 1 t (cddar ev-wrld) ens wrld)
        channel
        state))))))

(defun pe-fn2 (logical-name wrld channel ev-wrld state)
  (er-let* ((cmd-wrld (superior-command-world ev-wrld wrld :pe state)))
           (pprogn (pe-fn1 wrld channel ev-wrld cmd-wrld state)
                   (let ((new-ev-wrld (decode-logical-name
                                       logical-name
                                       (scan-to-event (cdr ev-wrld)))))
                     (if new-ev-wrld
                         (pe-fn2 logical-name wrld channel new-ev-wrld state)
                       (value :invisible))))))

(defun pe-fn (logical-name state)
  (io? history nil (mv erp val state)
       (logical-name)
       (let ((wrld (w state))
             (channel (standard-co state)))
         (cond
          ((and (symbolp logical-name)
                (not (eq logical-name :here))
                (eql (getprop logical-name 'absolute-event-number nil
                              'current-acl2-world wrld)
                     0))

; This special case avoids printing something like the following, which isn't
; very useful.

;       -7479  (ENTER-BOOT-STRAP-MODE :UNIX)

; We make the change here rather than in pe-fn1 because don't want to mess
; around at the level of ldd structures.  It's a close call.

; We don't make the corresponding change to pc-fn.  With pe, one is asking for
; an event, which in the case of a function is probably a request for a
; definition.  We want to serve the intention of that request.  With pc, one is
; asking for the full command, so we give it to them.

           (pprogn
            (fms "~x0 is built into ACL2, without a defining event.~#1~[  See ~
                  :DOC ~x0.~/~]~|"
                 (list (cons #\0 logical-name)
                       (cons #\1 (if (assoc-eq logical-name
                                               (global-val 'documentation-alist
                                                           wrld))
                                     0
                                   1)))
                 channel state nil)
            (value :invisible)))
          (t
           (er-let* ((ev-wrld (er-decode-logical-name logical-name wrld :pe
                                                      state))
                     (cmd-wrld (superior-command-world ev-wrld wrld :pe
                                                       state)))
             (pprogn
              (pe-fn1 wrld channel ev-wrld cmd-wrld state)
              (let ((new-ev-wrld (and (not (eq logical-name :here))
                                      (decode-logical-name
                                       logical-name
                                       (scan-to-event (cdr ev-wrld))))))
                (if (null new-ev-wrld)
                    (value :invisible)
                  (pprogn
                   (fms "Additional events for the logical name ~x0:~%"
                        (list (cons #\0 logical-name))
                        channel
                        state
                        nil)
                   (pe-fn2 logical-name wrld channel new-ev-wrld
                           state)))))))))))

(defmacro pe (logical-name)
  (list 'pe-fn logical-name 'state))

(defmacro pe! (logical-name)
  (declare (ignore logical-name))
  `(er hard 'pe!
       "Pe! has been deprecated.  Please use :pe, which now has the ~
        functionality formerly provided by :pe!; or consider :pcb, :pcb!, or ~
        :pr!.  See :DOC history."))

(defun command-block-names1 (wrld ans symbol-classes)

; Symbol-Classes is a list of symbol-classes or else is t.  We scan down world
; to the next command landmark unioning into ans all the names whose
; introduction-time symbol-class is contained in symbol-classes, where
; symbol-classes t denotes the set of everything (!).  Note that symbol-classes
; t is different from symbol-classes (:program :ideal :common-lisp-compliant)
; because some names, e.g., label names, don't have symbol-classes (i.e., have
; access-event-tuple-symbol-class nil).  We return the final ans and the wrld
; starting with the next command landmark.  Note also that we use the
; symbol-class at introduction, not the current one.

  (cond
   ((or (null wrld)
        (and (eq (caar wrld) 'command-landmark)
             (eq (cadar wrld) 'global-value)))
    (mv ans wrld))
   ((and (eq (caar wrld) 'event-landmark)
         (eq (cadar wrld) 'global-value))
    (cond
     ((or (eq symbol-classes t)
          (member-eq (access-event-tuple-symbol-class (cddar wrld))
                     symbol-classes))
      (let ((namex (access-event-tuple-namex (cddar wrld))))
        (command-block-names1 (cdr wrld)
                              (cond ((equal namex 0) ans)
                                    ((equal namex nil) ans)
                                    ((atom namex)
; Might be symbolp or stringp.
                                     (add-to-set-equal namex ans))
                                    (t (union-equal namex ans)))
                              symbol-classes)))
     (t (command-block-names1 (cdr wrld) ans symbol-classes))))
   (t (command-block-names1 (cdr wrld) ans symbol-classes))))

(defun command-block-names (wrld symbol-classes)

; Wrld is a world that begins with a command landmark.  We collect all the
; names introduced in the symbol-classes listed.  Symbol-Classes = t means all
; (including nil).  We return the collection of names and the world starting
; with the next command landmark.

  (command-block-names1 (cdr wrld) nil symbol-classes))

(defun symbol-name-lst (lst)
  (cond ((null lst) nil)
        (t (cons (symbol-name (car lst))
                 (symbol-name-lst (cdr lst))))))

(defun acl2-query-simulate-interaction (msg alist controlledp ans state)
  (cond ((and (atom ans)
              (or controlledp
                  (and (not (f-get-global 'window-interfacep state))

; If a special window is devoted to queries, then there is no way to
; pretend to answer, so we don't.  We just go on.  Imagine that we
; answered and the window disappeared so quickly you couldn't see the
; answer.

                       (not (eq (standard-co state) *standard-co*)))))
         (pprogn
          (fms msg alist (standard-co state) state (ld-evisc-tuple state))
          (princ$ ans (standard-co state) state)
          (newline (standard-co state) state)
          state))
        (t state)))

(defun acl2-query1 (id qt alist state)

; This is the function actually responsible for printing the query
; and getting the answer, for the current level in the query tree qt.
; See acl2-query for the context.

  (let ((dv (cdr-assoc-query-id id (ld-query-control-alist state)))
        (msg "ACL2 Query (~x0):  ~@1  (~*2):  ")
        (alist1 (list (cons #\0 id)
                      (cons #\1 (cons (car qt) alist))
                      (cons #\2
                            (list "" "~s*" "~s* or " "~s*, "
                                  (symbol-name-lst (evens (cdr qt))))))))
    (cond
     ((null dv)
      (pprogn
       (io? query nil state
            (alist1 msg)
            (fms msg alist1 *standard-co* state (ld-evisc-tuple state)))
       (er-let*
        ((ans (state-global-let*
               ((infixp nil))
               (read-object *standard-oi* state))))
        (let ((temp (and (symbolp ans)
                         (assoc-keyword
                          (intern (symbol-name ans) "KEYWORD")
                          (cdr qt)))))
          (cond (temp
                 (pprogn
                  (acl2-query-simulate-interaction msg alist1 nil ans state)
                  (value (cadr temp))))
                (t (acl2-query1 id qt alist state)))))))
     ((eq dv t)
      (pprogn
       (acl2-query-simulate-interaction msg alist1 t (cadr qt) state)
       (value (caddr qt))))
     (t (let ((temp (assoc-keyword (if (consp dv) (car dv) dv) (cdr qt))))
          (cond
           ((null temp)
            (er soft 'acl2-query
                "The default response, ~x0, supplied in ~
                 ld-query-control-alist for the ~x1 query, is not one ~
                 of the expected responses.  The ~x1 query ~
                 is~%~%~@2~%~%Note the expected responses above.  See ~
                 :DOC ld-query-control-alist."
                (if (consp dv) (car dv) dv)
                id
                (cons msg alist1)))
           (t
            (pprogn
             (acl2-query-simulate-interaction msg alist1 t dv state)
             (value (cadr temp))))))))))

(defun acl2-query (id qt alist state)

; A query-tree qt is either an atom or a cons of the form
;   (str :k1 qt1 ... :kn qtn)
; where str is a string suitable for printing with ~@, each :ki is a
; keyword, and each qti is a query tree.  If qt is an atom, it is
; returned.  Otherwise, str is printed and the user is prompted for
; one of the keys.  When ki is typed, we recur on the corresponding
; qti.  Note that the user need not type a keyword, just a symbol
; whose symbol-name is that of one of the keywords.

; Thus, '("Do you want to redefine ~x0?" :y t :n nil) will print
; the question and require a simple y or n answer, returning t or nil
; as appropriate.

; Warning: We don't always actually read an answer!  We sometimes
; default.  Our behavior depends on the LD specials standard-co,
; standard-oi, and ld-query-control-alist, as follows.

; Let x be (cdr (assoc-eq id (ld-query-control-alist state))).  X must
; be either nil, a keyword, or a singleton list containing a keyword.
; If it is a keyword, then it must be one of the keys in (cdr qt) or
; else we cause an error.  If x is a keyword or a one-element list
; containing a keyword, we act as though we read that keyword as the
; answer to our query.  If x is nil, we read *standard-oi* for an
; answer.

; Now what about printing?  Where does the query actually appear?  If
; we get the answer from the control alist, then we print both the
; query and the answer to standard-co, making it simulate an
; interaction -- except, if the control alist gave us a singleton
; list, then we do not do any printing.  If we get the answer from
; *standard-oi* then we print the query to *standard-co*.  In
; addition, if we get the answer from *standard-oi* but *standard-co*
; is not standard-co, we simulate the interaction on standard-co.

  (cond ((atom qt) (value qt))
        ((not (and (or (stringp (car qt))
                       (and (consp (car qt))
                            (stringp (caar qt))))
                   (consp (cdr qt))
                   (keyword-value-listp (cdr qt))))
         (er soft 'acl2-query
             "The object ~x0 is not a query tree!  See the comment in ~
              acl2-query."
             qt))
        (t
         (er-let* ((qt1 (acl2-query1 id qt alist state)))
                  (acl2-query id qt1 alist state)))))

(defun collect-names-in-defun-modes (names defun-modes wrld)

; Collect the elements of names (all of which are fn symbols) whose current
; defun-mode is in the given set.

  (cond ((null names) nil)
        ((member-eq (fdefun-mode (car names) wrld) defun-modes)
         (cons (car names)
               (collect-names-in-defun-modes (cdr names) defun-modes wrld)))
        (t (collect-names-in-defun-modes (cdr names) defun-modes wrld))))

(defun ubt-ubu-query (kwd wrld1 wrld0 seen kept-commands wrld state banger)

; Wrld0 is a predecessor world of wrld1 which starts with a command landmark.
; We scan down wrld1 until we get to wrld0.  For each command encountered we
; ask the user if he wants us to preserve the :program names introduced.
; If so, we add the command to kept-commands.  We only ask about the latest
; definition of any name (the accumulator seen contains all the names we've
; asked about).  We return the list of commands to be re-executed (in
; chronological -- not reverse chronological -- order).  Of course, this is an
; error/value/state function.

; Kwd is :ubt, :ubu, or :ubt-prehistory.

; Note: The kept-commands, when non-nil, always starts with a defun-mode
; keyword command, i.e., :logic or :program.  This is the
; default-defun-mode in which the next command on the list, the first "real
; command," was executed.  When we grow the kept-command list, we remove
; redundant mode changes.  So for example, if kept-commands were
; '(:program cmd2 ...) and we then wished to add cmd1, then if the mode in
; which cmd1 was executed was :program the result is '(:program cmd1
; cmd2 ...)  while if cmd1's mode is :logic the result is '(:logic cmd1
; :program cmd2 ...).  Note that the mode may indeed be :logic, even
; though cmd1 introduces a :program function, because the mode of the
; introduced function may not be the default-defun-mode.  The commands are kept
; because the functions they introduce are :program, not because they were
; executed in :program mode.  But we must make sure the default mode is
; the same as it was when the command was last executed, just in case the mode
; of the functions is the default one.

  (cond
   ((or (null wrld1)
        (equal wrld1 wrld0))
    (value kept-commands))
   (t (mv-let
       (names wrld2)
       (command-block-names wrld1 '(:program))

; Names is the list of all names in the current command block whose
; introduction-time symbol-class was :program.

       (cond
        ((and names (set-difference-eq names seen))
         (er-let*
          ((ans (if banger
                    (value banger)
                    (let ((logic-names
                           (collect-names-in-defun-modes names '(:logic) wrld)))
                      (acl2-query
                       kwd
                       '("The command ~X01 introduced the :program ~
                          name~#2~[~/s~] ~&2.~#5~[~/  ~&3 ~#4~[has~/have~] ~
                          since been made logical.~]  Do you wish to ~
                          re-execute this command after the ~xi?"
                         :y t :n nil :y! :all :n! :none :q :q
                         :? ("We are undoing some commands.  We have ~
                              encountered a command, printed above, that ~
                              introduced a :program function symbol.  It is ~
                              unusual to use ~xi while defining :program ~
                              functions, since redefinition is permitted.  ~
                              Therefore, we suspect that you are mixing ~
                              :program and :logic definitions, as when one is ~
                              developing utilities for the prover.  When ~
                              undoing through such a mixed session, it is ~
                              often intended that the :logic functions be ~
                              undone while the :program ones not be, since the ~
                              latter ones are just utilities.  While we cannot ~
                              selectively undo commands, we do offer to redo ~
                              selected commands when we have finished undoing. ~
                               The situation is complicated by the fact that ~
                              :programs can become :logic functions after the ~
                              introductory event and that the same name can be ~
                              redefined several times.  Unless noted in the ~
                              question above, the functions discussed are all ~
                              still :program. The commands we offer for ~
                              re-execution are those responsible for ~
                              introducing the most recent definitions of ~
                              :program names, whether the names are still ~
                              :program or not.  That is, if in the region ~
                              undone there is more than one :program ~
                              definition of a name, we will offer to redo the ~
                              chronologically latest one.~%~%If you answer Y, ~
                              the command printed above will be re-executed.  ~
                              If you answer N, it will not be.  The answer Y! ~
                              means the same thing as answering Y to this and ~
                              all subsequent queries in this ~xi  The answer ~
                              N! is analogous.  Finally, Q means to abort the ~
                              ~xi without undoing anything."
                             :y t :n nil :y! :all :n! :none :q :q))
                       (list (cons #\i kwd)
                             (cons #\0
                                   (access-command-tuple-form (cddar wrld1)))
                             (cons #\1 (term-evisc-tuple t state))
                             (cons #\2 names)
                             (cons #\3 logic-names)
                             (cons #\4 (if (cdr logic-names) 1 0))
                             (cons #\5 (if (null logic-names) 0 1)))
                       state)))))
          (cond
           ((eq ans :q) (mv t nil state))
           (t
            (ubt-ubu-query
             kwd wrld2 wrld0
             (union-eq names seen)
             (if (or (eq ans t) (eq ans :all))
                 (cons (access-command-tuple-defun-mode (cddar wrld1))
                       (cons (access-command-tuple-form (cddar wrld1))
                             (cond
                              ((eq (access-command-tuple-defun-mode
                                    (cddar wrld1))
                                   (car kept-commands))
                               (cdr kept-commands))
                              (t kept-commands))))
               kept-commands)
             wrld state
             (or banger
                 (if (eq ans :all) :all nil)
                 (if (eq ans :none) :none nil)))))))
        (t (ubt-ubu-query kwd wrld2 wrld0 seen kept-commands wrld state
                          banger)))))))

; We can't define ubt-ubu-fn until we define LD, because it uses LD to replay
; selected commands.  So we proceed as though we had defined ubt-ubu-fn.

(defmacro ubt (cd)
  (list 'ubt-ubu-fn :ubt cd 'state))

(defmacro ubt! (cd)
  (list 'ubt!-ubu!-fn :ubt cd 'state))

(defmacro ubu (cd)
  (list 'ubt-ubu-fn :ubu cd 'state))

(defmacro ubu! (cd)
  (list 'ubt!-ubu!-fn :ubu cd 'state))

(defmacro u nil
  '(ubt! :x))

; We now develop the most trivial event we have: deflabel.  It
; illustrates the basic structure of our event code and we need it for
; all other events because any event with a documentation string uses
; the processing defined here.  (Actually defdoc is a bit simpler, and
; we deal with it just after deflabel.)

(defun chk-virgin (name new-type wrld)

; Although this function axiomatically always returns the
; value t, it sometimes causes an error.


  #+acl2-loop-only
  (declare (ignore name new-type wrld))
  #-acl2-loop-only
  (chk-virgin2 name new-type wrld)
  t)

(defun chk-boot-strap-redefineable-namep (name ctx wrld state)
  (cond ((global-val 'boot-strap-pass-2 wrld)
         (value nil))
        ((not (member-eq name (global-val 'chk-new-name-lst wrld)))
         (er soft ctx
             "The name ~x0 is already in use and is not among those ~
              expected by chk-boot-strap-redefineable-namep to be redundantly defined ~
              during initialization. If you wish it to be, add ~x0 to ~
              the global-val setting of 'chk-new-name-lst in ~
              primordial-world-globals."
             name))
        ((not (chk-virgin name t wrld))
         (er soft ctx
             "Not a virgin name:  ~x0." name))
        (t (value nil))))

(defun maybe-coerce-overwrite-to-erase (old-type new-type mode)
  (cond ((and (eq old-type 'function)
              (eq new-type 'function))
         mode)
        (t :erase)))

(defun redefinition-renewal-mode (name old-type new-type reclassifyingp ctx
                                       wrld state)

; We use 'ld-redefinition-action to determine whether the redefinition of name,
; currently of old-type in wrld, is to be :erase, :overwrite or
; :reclassifying-overwrite.  New-type is the new type name will have and
; reclassifyingp is a non-nil, non-cons value only if this is a :program
; function to identical-defp :logic function redefinition.  If this
; redefinition is not permitted, we cause an error, in which case if
; reclassifyingp is a cons then it is an explanatory message to be printed in
; the error message, in the context "Note that <msg>".

; The only time we permit a redefinition when ld-redefinition-action prohibits
; it is when we return :reclassifying-overwrite, except for the case of
; updating non-executable :program mode ("proxy") functions; see :DOC
; defproxy.  In the latter case we have some concern about redefining inlined
; functions, so we proclaim them notinline; see install-defs-for-add-trip.

; This function interacts with the user if necessary.  See :DOC
; ld-redefinition-action.

  (let ((act (f-get-global 'ld-redefinition-action state))
        (proxy-upgrade-p
         (and (eq old-type 'function)
              (consp new-type)

; New-type is (function stobjs-in . stobjs-out); see chk-signature.

              (eq (car new-type) 'function)
              (eq (getprop name 'non-executablep nil 'current-acl2-world
                           wrld)
                  :program)

; A non-executable :program-mode function has no logical content, so it is
; logically safe to redefine it.  We check however that the signature hasn't
; changed, for the practical reason that we don't want to break existing
; calls.

              (equal (stobjs-in name wrld) (cadr new-type))
              (equal (stobjs-out name wrld) (cddr new-type))))
        (attachment-alist (attachment-alist name wrld)))
    (cond
     ((and reclassifyingp
           (not (consp reclassifyingp)))
      (cond ((member-eq name
                        (f-get-global 'program-fns-with-raw-code state))
             (er soft ctx
                 "The function ~x0 must remain in :PROGRAM mode, because it ~
                  has been marked as a function that has special raw Lisp ~
                  code."
                 name))
            (t (value :reclassifying-overwrite))))
     ((and attachment-alist
           (not (eq (car attachment-alist) :ATTACHMENT-DISALLOWED))

; During the boot-strap, we may replace non-executable :program mode
; definitions (from defproxy) without removing attachments, so that system
; functions implemented using attachments will not be disrupted.

           (not (global-val 'boot-strap-flg wrld)))
      (er soft ctx
          "The name ~x0 is in use as a ~@1, and it has an attachment.  Before ~
           redefining it you must remove its attachment, for example by ~
           executing the form ~x2.  We hope that this is not a significant ~
           inconvenience; it seemed potentially too complex to execute such a ~
           defattach form safely on your behalf."
          name
          (logical-name-type-string old-type)
          (cond ((programp name wrld)
                 `(defattach (,name nil) :skip-checks t))
                (t
                 `(defattach ,name nil)))))
     ((and (null act)
           (not proxy-upgrade-p))

; We cause an error, with rather extensive code below designed to print a
; helpful error message.

      (mv-let
       (erp val state)
       (er soft ctx
           "The name ~x0 is in use as a ~@1.~#2~[  ~/  (This name is used in ~
            the implementation of single-threaded objects.)  ~/  Note that ~
            ~@3~|~]The redefinition feature is currently off.  See :DOC ~
            ld-redefinition-action.~@4"
           name
           (logical-name-type-string old-type)
           (cond ((eq new-type 'stobj-live-var) 1)
                 ((consp reclassifyingp) 2)
                 (t 0))
           reclassifyingp
           (cond ((eq (getprop name 'non-executablep nil 'current-acl2-world
                               wrld)
                      :program)
                  (msg "  Note that you are attempting to upgrade a proxy, ~
                        which is only legal using an encapsulate signature ~
                        that matches the original signature of the function; ~
                        see :DOC defproxy."))
                 (t "")))
       (declare (ignore erp val))
       (er-let*
        ((ev-wrld (er-decode-logical-name name wrld ctx state)))
        (pprogn
         (let ((book-path-rev (reverse (global-val 'include-book-path
                                                   ev-wrld)))
               (current-path-rev (reverse (global-val 'include-book-path
                                                      wrld))))
           (io? error nil state
                (name book-path-rev current-path-rev wrld)
                (pprogn
                 (cond ((and (null book-path-rev)
                             (acl2-system-namep name wrld))
                        (fms "Note: ~x0 has already been defined as a system ~
                              name; that is, it is built into ACL2.~|~%"
                             (list (cons #\0 name))
                             (standard-co state) state nil))
                       ((null book-path-rev)
                        (fms "Note: ~x0 was previously defined at the top ~
                              level~#1~[~/ of the book being certified~].~|~%"
                             (list (cons #\0 name)
                                   (cons #\1
                                         (if (f-get-global 'certify-book-info
                                                           state)
                                             1
                                           0)))
                             (standard-co state) state nil))
                       (t (pprogn
                           (fms "Note: ~x0 was previously defined in the last ~
                                 of the following books.~|~%"
                                (list (cons #\0 name))
                                (standard-co state) state nil)
                           (print-book-path
                            book-path-rev
                            3 (standard-co state) state)
                           (newline (standard-co state) state))))
                 (cond ((null current-path-rev)
                        state)
                       (t (pprogn
                           (fms "Note: the current attempt to define ~x0 is ~
                                 being made in the last of the following ~
                                 books.~|~%"
                                (list (cons #\0 name))
                                (standard-co state) state nil)
                           (print-book-path
                            current-path-rev
                            3 (standard-co state) state)
                           (newline (standard-co state) state)))))))
         (silent-error state)))))
     ((and (hons-enabledp state) ; presumably an optimization
           (cdr (assoc-eq name (table-alist 'memoize-table wrld))))
      (er soft ctx
          "The name ~x0 is in use as a ~@1, and it is currently memoized.  ~
           You must execute ~x2 before attempting to redefine it."
          name
          (logical-name-type-string old-type)
          (list 'unmemoize (kwote name))))
     ((eq new-type 'package)

; Some symbols seen by this fn have new-type package, namely the base
; symbol of the rune naming the rules added by defpkg, q.v.  Old-type
; can't be 'package.  If this error message is eliminated and
; redefinition is ever permitted, then revisit the call of
; chk-just-new-name in chk-acceptable-defpkg and arrange for it to use
; the resulting world.

      (er soft ctx
          "When a package is introduced, a rule is added describing the ~
           result produced by (symbol-package-name (intern x pkg)).  That ~
           rule has a name, i.e., a rune, based on some symbol which must ~
           be new.  In the case of the current package definition the base ~
           symbol for the rune in question is ~x0.  The symbol is not new. ~
            Furthermore, the redefinition facility makes no provision for ~
           packages.  Please rename the package or :ubt ~x0.  Sorry."
          name))
     ((null (getprop name 'absolute-event-number nil 'current-acl2-world wrld))

; One might think that (a) this function is only called on old names and (b)
; every old name has an absolute event number.  Therefore, why do we ask the
; question above?  Because we could have a name introduced by the signature in
; encapsulate that is intended to be local, but was not embedded in a local
; form.

      (er soft ctx
          "The name ~x0 appears to have been introduced in the signature list ~
           of an encapsulate, yet is being defined non-locally."
          name))

; We do not permit any supporter of a single-threaded object implementation to
; be redefined, except by redefining the single-threaded object itself.  The
; main reason is that even though the functions like the recognizers appear as
; ordinary predicates, the types are really built in across the whole
; implementation.  So it's all or nothing.  Besides, I don't really want to
; think about the weird combinations of changing a defstobj supporter to an
; unrelated function, even if the user thinks he knows what he is doing.

     ((and (defstobj-supporterp name wrld)
           (not (and (eq new-type 'stobj)
                     (eq old-type 'stobj))))

; I sweated over the logic above.  How do we get here?  Name is a defstobj
; supporter.  Under what conditions do we permit a defstobj supporter to be
; redefined?  Only by redefining the object name itself -- not by redefining
; individual functions.  So we want to avoid causing an error if the new and
; old types are both 'stobj (i.e., name is the name of the single-threaded
; object both in the old and the new worlds).

; WARNING: If this function does not cause an error, we proceed, in
; chk-redefineable-namep, to renew name.  In the case of stobj names, that
; function renews all the supporting names as well.  Thus, it is important to
; maintain the invariant: if this function does not cause an error and name is
; a defstobj supporter, then name is the stobj name.

      (er soft ctx
          "The name ~x0 is in use supporting the implementation of ~
           the single-threaded object ~x1.  We do not permit such ~
           names to be redefined except by redefining ~x1 itself with ~
           a new DEFSTOBJ."
          name
          (defstobj-supporterp name wrld)))

; If we get here, we know that either name is not currently a defstobj
; supporter of any kind or else that it is the old defstobj name and is being
; redefined as a defstobj.

     (t
      (let ((sysdefp (acl2-system-namep name wrld)))
        (cond
         ((and sysdefp
               (not (ttag (w state)))
               (not (and proxy-upgrade-p
                         (global-val 'boot-strap-flg wrld))))
          (er soft ctx
              "Redefinition of system names, such as ~x0, is not permitted ~
               unless there is an active trust tag (ttag).  See :DOC defttag."
              name))
         (proxy-upgrade-p

; We erase all vestiges of the old function.  It may well be safe to return
; :overwrite instead.  But at one time we tried that while also leaving the
; 'attachment property unchanged by renew-name/overwrite (rather than making it
; unbound), and we then got an error from the following sequence of events,
; "HARD ACL2 ERROR in LOGICAL-NAME-TYPE: FOO is evidently a logical name but of
; undetermined type."

;  (defproxy foo (*) => *)
;  (defttag t)
;  (defun g (x) x)
;  (defattach (foo g) :skip-checks t)
;  (defattach (foo nil) :skip-checks t)
;  (defstub foo (x) t)

; When we promote boot-strap functions from non-executable :program mode
; ("proxy") functions to encapsulated functions, we thus lose the 'attachment
; property.  Outside the boot-strap, where we disallow all redefinition when
; there is an attachment, this is not a restriction.  But in the boot-strap, we
; will lose the 'attachment property even though the appropriate Lisp global
; (the attachment-symbol) remains set.  This doesn't present a problem,
; however; system functions are special, in that they can very temporarily have
; attachments without an 'attachment property, until the redefinition in
; progress (by an encapsulate) is complete.

          (cond ((eq (car attachment-alist) :ATTACHMENT-DISALLOWED)
                 (er soft ctx
                     "Implementation error: It is surprising to see ~
                      attachments disallowed for a non-executable :program ~
                      mode function (a proxy).  See ~
                      redefinition-renewal-mode."))
                (t (value :erase))))
         ((eq (car act) :doit!)
          (value
           (maybe-coerce-overwrite-to-erase old-type new-type (cdr act))))
         ((or (eq (car act) :query)
              (and sysdefp
                   (or (eq (car act) :warn)
                       (eq (car act) :doit))))
          (er-let*
           ((ans (acl2-query
                  :redef
                  '("~#0~[~x1 is an ACL2 system~/The name ~x1 is in use as ~
                     a~] ~@2.~#3~[~/  Its current defun-mode is ~@4.~] Do you ~
                     ~#0~[really ~/~]want to redefine it?~#6~[~/  Note: if ~
                     you redefine it we will first erase its supporters, ~
                     ~&7.~]"

                    :n nil :y t :e erase :o overwrite
                    :? ("N means ``no'' and answering that way will abort the ~
                         attempted redefinition.  All other responses allow ~
                         the redefinition and may render ACL2 unsafe and/or ~
                         unsound.  Y in the current context is the same as ~
                         ~#5~[E~/O~].  E means ``erase the property list of ~
                         ~x1 before redefining it.''  O means ``Overwrite ~
                         existing properties of ~x1 while redefining it'' but ~
                         is different from erasure only when a function is ~
                         being redefined as another function.   Neither ~
                         alternative is guaranteed to produce a sensible ACL2 ~
                         state.  If you are unsure of what all this means, ~
                         abort with N and see :DOC ld-redefinition-action for ~
                         details."
                        :n nil :y t :e erase :o overwrite))
                  (list (cons #\0 (if sysdefp 0 1))
                        (cons #\1 name)
                        (cons #\2 (logical-name-type-string old-type))
                        (cons #\3 (if (eq old-type 'function) 1 0))
                        (cons #\4 (if (eq old-type 'function)
                                      (defun-mode-string
                                        (fdefun-mode name wrld))
                                    nil))
                        (cons #\5 (if (eq (cdr act)
                                          :erase)
                                      0 1))
                        (cons #\6 (if (defstobj-supporterp name wrld)
                                      1 0))
                        (cons #\7 (getprop (defstobj-supporterp name wrld)
                                           'stobj
                                           nil
                                           'current-acl2-world
                                           wrld)))
                  state)))
           (cond
            ((null ans) (mv t nil state))
            ((eq ans t)
             (value
              (maybe-coerce-overwrite-to-erase old-type new-type (cdr act))))
            ((eq ans 'erase) (value :erase))
            (t (value
                (maybe-coerce-overwrite-to-erase old-type new-type
                                                 :overwrite))))))
         (t

; If name is a system name, then the car of 'ld-redefinition-action must be
; :warn!  If name is not a system name, the car of 'ld-redefinition-action may
; be :warn!, :doit, or :warn.  In all cases, we are to proceed with the
; redefinition without any interaction here.

          (value
           (maybe-coerce-overwrite-to-erase old-type new-type
                                            (cdr act))))))))))

(defun redefined-names1 (wrld ans)
  (cond ((null wrld) ans)
        ((eq (cadar wrld) 'redefined)
         (cond
          ((eq (car (cddar wrld)) :reclassifying-overwrite)
           (redefined-names1 (cdr wrld) ans))
          (t (redefined-names1 (cdr wrld)
                               (add-to-set-eq (caar wrld) ans)))))
        (t (redefined-names1 (cdr wrld) ans))))

(defun redefined-names (state)
  (redefined-names1 (w state) nil))

(defun chk-redefineable-namep (name new-type reclassifyingp ctx wrld state)

; Name is a non-new name in wrld.  We are about to redefine it and make its
; logical-name-type be new-type.  If reclassifyingp is non-nil and not a consp
; message (see redundant-or-reclassifying-defunp) then we know that in fact
; this new definition is just a conversion of the existing definition.
; Redefinition is permitted if the value of 'ld-redefinition-action is not nil,
; or if we are defining a function to replace a non-executable :program mode
; function (such as is introduced by defproxy).  In all these non-erroneous
; cases, we renew name appropriately and return the resulting world.

; The LD special 'ld-redefinition-action determines how we react to
; redefinition attempts.  See :DOC ld-redefinition-action.

; It must be understood that if 'ld-redefinition-action is non-nil then no
; logical sense is maintained, all bets are off, the system is unsound and
; liable to cause all manner of hard lisp errors, etc.

  (let ((old-type (logical-name-type name wrld nil)))
    (cond
     ((and (global-val 'boot-strap-flg wrld)
           (not (global-val 'boot-strap-pass-2 wrld))
           (or (not reclassifyingp)
               (consp reclassifyingp)))

; If we are in the first pass of booting and name is one of those we know is
; used before it is defined, we act as though it were actually new.

      (er-progn
       (chk-boot-strap-redefineable-namep name ctx wrld state)
       (value wrld)))
     (t

; In obtaining the renewal mode, :erase or :overwrite, we might cause an error
; that aborts because name is not to be redefined.

      (er-let*
       ((renewal-mode
         (redefinition-renewal-mode name
                                    old-type new-type reclassifyingp
                                    ctx wrld state)))
       (cond
        ((defstobj-supporterp name wrld)

; Because of the checks in redefinition-renewal-mode, we know the
; defstobj-supporterp above returns name itself.  But to be rugged I
; will code it this way.  If name is a defstobj supporter of any kind,
; we renew all the supporters!

         (value
          (renew-names (cons name
                             (getprop (defstobj-supporterp name wrld)
                                      'stobj
                                      nil
                                      'current-acl2-world
                                      wrld))
                       renewal-mode wrld)))
        (t (value (renew-name name renewal-mode wrld)))))))))

(defun chk-just-new-name (name new-type reclassifyingp ctx w state)

; Assuming that name has survived chk-all-but-new-name, we check that it is in
; fact new.  If it is, we return the world, w.  If it is not new, then what we
; do depends on various state variables such as whether we are in boot-strap
; and whether redefinition is allowed.  But unless we cause an error we will
; always return the world extending w in which the redefinition is to occur.

; Name is being considered for introduction with logical-name-type new-type.
; Reclassifyingp, when not nil and not a consp, means that this redefinition is
; known to be identical to the existing definition except that it has been
; given the new defun-mode :logic.  This will allow us to permit the
; redefinition of system functions.  See the comment in
; redundant-or-reclassifying-defunp for more about reclassifyingp.

; Observe that it is difficult for the caller to tell whether redefinition is
; occurring.  In fact, inspection of the returned world will reveal the answer:
; sweep down the world to the next event-landmark and see whether any
; 'redefined property is stored.  All names with such a property are being
; redefined by this event (possibly soundly by reclassifying :program names).
; This sweep is actually done by collect-redefined on behalf of stop-event
; which prints a suitable warning message.

  (cond
   ((new-namep name w)

; If name has no properties in w, then we next check that it is not
; defined in raw Common Lisp.

    (let ((actual-new-type
           (cond ((and (consp new-type)
                       (eq (car new-type) 'function))
                  'function)
                 (t new-type))))
      (cond ((not (chk-virgin name actual-new-type w))
             (er soft ctx
                 "Not a virgin name for type ~x0:  ~x1." new-type name))
            (t (value w)))))
   ((and (global-val 'boot-strap-flg w)
         (not (global-val 'boot-strap-pass-2 w))
         (or (not reclassifyingp)
             (consp reclassifyingp)))

; If we are in the first pass of booting and name is one of those we know is
; used before it is defined, we act as though it were actually new.

    (er-progn
     (chk-boot-strap-redefineable-namep name ctx w state)
     (value w)))
   (t
    (chk-redefineable-namep name new-type reclassifyingp ctx w state))))

(defun no-new-namesp (lst wrld)

; Lst is a true list of symbols.  We return t if every name in it
; is old.

  (cond ((null lst) t)
        ((new-namep (car lst) wrld) nil)
        (t (no-new-namesp (cdr lst) wrld))))

(defun chk-just-new-names (names new-type reclassifyingp ctx w state)

; Assuming that names has survived chk-all-but-new-names, we check that they
; are in fact all new.  We either cause an error or return the world, we are to
; use in the coming definition.  Observe that it is difficult for the caller to
; tell whether redefinition is occuring.  In fact, inspection of world will
; reveal the answer: sweep down world to the next event-landmark and see
; whether any 'redefined property is stored.  All names with such a property
; are being redefined by this event.  This sweep is actually done by
; collect-redefined on behalf of stop-event which prints a suitable warning
; message.

; Reclassifyingp is as explained in redundant-or-reclassifying-defunp.  In
; particular, it can be a message (a cons pair suitable for printing with ~@).

  (cond
   ((null names) (value w))
   (t (er-let*
        ((wrld1 (chk-just-new-name (car names) new-type reclassifyingp
                                   ctx w state)))
        (chk-just-new-names (cdr names) new-type reclassifyingp
                            ctx wrld1 state)))))

; We now develop the code for checking that a documentation string
; is well formed.

(defconst *return-character* (code-char 13))

(defun read-symbol-from-string1 (str i len ans)
  (cond ((< i len)
         (let ((c (char str i)))
           (cond ((or (eql c #\Space)
                      (eql c #\Newline)

; The following modification is useful for avoiding CR characters in Windows
; systems that use CR/LF for line breaks.

                      (eql c *return-character*))
                  (mv (reverse ans) i))
                 (t (read-symbol-from-string1 str (1+ i) len
                                              (cons (char-upcase c) ans))))))
        (t (mv (reverse ans) i))))

(defun read-symbol-from-string2 (str i len ans)
  (cond ((< i len)
         (let ((c (char str i)))
           (cond ((eql c #\|)
                  (mv (reverse ans) i))
                 (t (read-symbol-from-string2 str (1+ i) len
                                              (cons c ans))))))
        (t (mv (reverse ans) i))))

(defun read-symbol-from-string (str i pkg-witness)

; Reads one symbol from str, starting at index i.  The symbol will
; either be in the pkg of pkg-witness (which is a symbol) or else
; will be in "KEYWORD" or in "ACL2" if its print representation so
; specifies.  Leading whitespace is ignored.  Two values are returned:
; the symbol read and the index of the first whitespace character
; after the symbol read.  If there is no non-whitespace after i,
; two nils are returned.

; Warning:  This is a cheap imitation of the CLTL READ.  We put the symbol in
; the keyword package if the first non-whitespace char is a colon.  Then we
; read to a certain delimiter, either vertical bar or space/newline, depending
; on whether the next char is a vertical bar.  Then we make a symbol out of
; that, even if it has the syntax of a number.  And we put it in pkg-witness's
; package unless the first chars of it are ACL2::.  Known Discrepancy:  We read
; |ACL2::Foo| as ACL2::|Foo| while CLTL reads it as pkg::|ACL2::Foo|.

  (let* ((len (length str))
         (i (scan-past-whitespace str i len)))
    (cond ((< i len)
           (mv-let (char-lst j)
                   (cond
                    ((and (eql (char str i) #\:)
                          (< (1+ i) len))
                     (cond
                      ((eql (char str (1+ i)) #\|)
                       (read-symbol-from-string2 str (+ i 2) len nil))
                      (t (read-symbol-from-string1 str (1+ i) len nil))))
                    ((eql (char str i) #\|)
                     (read-symbol-from-string2 str (1+ i) len nil))
                    (t (read-symbol-from-string1 str i len nil)))
                   (mv
                    (cond
                     ((eql (char str i) #\:)
                      (intern (coerce char-lst 'string)
                              "KEYWORD"))
                     ((and (<= 6 (length char-lst))
                           (eql #\A (car char-lst))
                           (eql #\C (cadr char-lst))
                           (eql #\L (caddr char-lst))
                           (eql #\2 (cadddr char-lst))
                           (eql #\: (car (cddddr char-lst)))
                           (eql #\: (cadr (cddddr char-lst))))
                      (intern (coerce (cddr (cddddr char-lst)) 'string)
                              "ACL2"))
                     (t (intern-in-package-of-symbol (coerce char-lst 'string)
                                                     pkg-witness)))
                    j)))
          (t (mv nil nil)))))

(defun scan-past-newline (str i maximum)
  (cond ((< i maximum)
         (cond ((eql (char str i) #\Newline)
                (1+ i))
               (t (scan-past-newline str (1+ i) maximum))))
        (t maximum)))

(defun scan-past-newlines (str i maximum)
  (cond ((< i maximum)
         (cond ((eql (char str i) #\Newline)
                (scan-past-newlines str (1+ i) maximum))
               (t i)))
        (t maximum)))

(defun scan-past-tilde-slash (str i maximum)
  (cond ((< i maximum)
         (cond ((eql (char str i) #\~)
                (cond ((and (< (1+ i) maximum)
                            (eql (char str (1+ i)) #\/))
                       (cond ((or (= i 0) (not (eql (char str (1- i)) #\~)))
                              (+ 2 i))
                             (t (scan-past-tilde-slash str (+ 2 i) maximum))))
                      (t (scan-past-tilde-slash str (+ 2 i) maximum))))
               (t (scan-past-tilde-slash str (1+ i) maximum))))
        (t maximum)))

(defun scan-to-doc-string-part1 (parti str i maximum)
  (cond ((= parti 0) i)
        (t (scan-to-doc-string-part1
            (1- parti)
            str
            (scan-past-whitespace
             str
             (scan-past-tilde-slash str i maximum)
             maximum)
            maximum))))

(defun scan-to-doc-string-part (i str)

; We assume str is a doc-stringp.  Thus, it has the form:
; ":Doc-Section <sym><cr><part0>~/ <part1>~/ <part2>~/ <part3>"
; where the first space above is one or more #\Spaces, the <cr> is
; arbitrary whitespace but including at least one #\Newline, and the
; remaining spaces are arbitrary whitespace.  It is possible that
; the string terminates after any parti.  We return the index of
; the ith part.

  (let ((len (length str)))
    (scan-to-doc-string-part1 i
                              str
                              (scan-past-whitespace
                               str
                               (scan-past-newline str 0 len)
                               len)
                              len)))

(defun get-one-liner-as-string1 (str i j acc)
  (cond ((<= i j)
         (get-one-liner-as-string1 str i (1- j) (cons (char str j) acc)))
        (t (coerce acc 'string))))

(defun get-one-liner-as-string (str)
  (let ((i (scan-to-doc-string-part 0 str))
        (max (length str)))
    (get-one-liner-as-string1 str
                              i
                              (- (scan-past-tilde-slash str i max) 3)
                              nil)))

(defun read-doc-string-citations1 (name str i)
  (mv-let (sym1 i)
          (read-symbol-from-string str i name)
          (cond
           ((null i) nil)
           (t (mv-let (sym2 i)
                      (read-symbol-from-string str i name)
                      (cond
                       ((null i)
                        (cons (cons sym1 0) nil))
                       (t
                        (cons (cons sym1 sym2)
                              (read-doc-string-citations1 name str i)))))))))

(defun read-doc-string-citations (name str)

; This function reads the contents of the citations section of a doc
; string, expecting it to be an even number of symbols and returning
; them as a list of pairs.  I.e., ":cite a :cited-by b :cite c" is
; read as ((:cite . a) (:cited-by . b) (:cite . c)).  If there are an
; odd number of symbols, a 0 replaces the unsupplied one.  Since we
; can't possibly read a 0 as a number (our stupid reader makes
; symbols) this is an unambiguous signal that the string does not
; parse.  This function doesn't care whether the symbols in the odd
; positions are :cite and :cited-by or not.  I.e., "A B C D" reads as
; ((A . B) (C . D)).

  (let ((i (scan-to-doc-string-part 3 str)))
    (read-doc-string-citations1 name str i)))

(defun doc-topicp (name wrld)
  (assoc-equal name (global-val 'documentation-alist wrld)))

(defun ignore-doc-string-error (wrld)
  (cdr (assoc-eq :ignore-doc-string-error
                 (table-alist 'acl2-defaults-table wrld))))

(defmacro er-doc (ctx str &rest str-args)
  `(let ((er-doc-ign (ignore-doc-string-error (w state))))
     (cond ((eq er-doc-ign t)
            (value nil))
           ((eq er-doc-ign :warn)
            (pprogn (warning$ ,ctx "Documentation"
                              "No :doc string will be stored.  ~@0"
                              (check-vars-not-free (er-doc-ign)
                                                   (msg ,str ,@str-args)))
                    (value nil)))
           (t (er soft ,ctx "~@0"
                  (check-vars-not-free (er-doc-ign)
                                       (msg ,str ,@str-args)))))))

(defun chk-doc-string-citations (str citations wrld)

; We know that citations is a list of pairs of symbols, by construction -- it
; was produced by read-doc-string-citations.  We check that the car of each
; pair is either :cite or :cited-by and the cdr is a previously documented
; topic symbol, returning an error message or nil.

  (cond
   ((null citations) nil)
   ((or (eq (caar citations) :cite)
        (eq (caar citations) :cited-by))
    (cond ((equal (cdar citations) 0)
           (msg "The citations section of a formatted documentation string ~
                 must contain an even number of tokens.  The citations below ~
                 do not.  See :DOC doc-string.~|~%~x0.~%"
                str))
          ((doc-topicp (cdar citations) wrld)
           (chk-doc-string-citations str (cdr citations) wrld))
          (t (msg "The symbols cited in the citations section of a formatted ~
                   documentation string must be previously documented topics. ~
                    ~x0 is not and, hence, the string below is ill-formed.  ~
                   See :DOC doc-string.~|~%~x1.~%"
                  (cdar citations)
                  str))))
   (t (msg "The citations section of a formatted documentation string must ~
            contain an even number of tokens.  Each token in an odd numbered ~
            position must be either :CITE or :CITED-BY.  But in the string ~
            below ~x0 occurs in an odd numbered position.  See :DOC ~
            doc-string.~|~%~x1.~%"
           (caar citations)
           str))))

(defun chk-well-formed-doc-string (name doc ctx state)

; This function checks that doc is a well-formed doc string.
; It either causes an error or returns (as the value component of
; an error triple) a pair (section-symbol . citations) obtained
; by parsing the doc string.  If doc does not even appear to
; be one of our formatted doc strings, we return nil.

  (let ((wrld (w state)))
    (cond
     ((doc-stringp doc)
      (let ((len (length doc))
            (old-doc-tuple
             (assoc-equal name (global-val 'documentation-alist wrld))))
        (cond

; We used to print a warning here when a system DEFLABEL is redefined, which
; advised that the documentation would remain unchanged.  Probably we had this
; code as an aid towards proving our way through axioms.lisp, but now we don't
; seem to need it.

         ((= (scan-past-tilde-slash
              doc
              (scan-past-tilde-slash
               doc
               (scan-past-newline doc 0 len)
               len)
              len)
             len)
          (er-doc ctx
                  "Formatted documentation strings must contain at least two ~
                   occurrences of tilde slash after the first newline so as ~
                   to delimit the three required parts:  the one-liner, the ~
                   notes, and the details.  While the notes section may be ~
                   empty, the details section may not.  The string below ~
                   violates this requirement.  See :DOC doc-string.~|~%~x0.~%"
                  doc))
         (t
          (mv-let (section-sym i)
                  (read-symbol-from-string doc 13
                                           (if (stringp name)
                                               'chk-well-formed-doc-string
                                             name))

; If we're documenting a package or book name, i.e., a stringp, then we can't
; use it to provide the default package in which read-symbol-from-string
; interns its symbols.  We use the "ACL2" package.

                  (cond
                   ((null i)
                    (er-doc ctx
                            "Formatted documentation strings must specify a ~
                             section symbol after the :Doc-Section header and ~
                             before the first newline character.  The string ~
                             below does not specify a section symbol.  See ~
                             :DOC doc-string.~|~%~y0.~%"
                            doc))
                   ((and old-doc-tuple
                         (not (equal section-sym (cadr old-doc-tuple))))
                    (er-doc ctx
                            "The documentation string already in place for ~
                             the name ~x0 is stored under section name ~x1, ~
                             but you are trying to store it under a new ~
                             section name, ~x2.  This is not allowed.  See ~
                             :DOC defdoc."
                            name (cadr old-doc-tuple) section-sym))
                   ((or (equal section-sym name)
                        (doc-topicp section-sym wrld))
                    (let ((citations
                           (read-doc-string-citations section-sym doc)))
                      (let ((msg
                             (chk-doc-string-citations doc citations wrld)))
                        (cond
                         (msg (er-doc ctx "~@0" msg))
                         (t
                          (pprogn
                           (if old-doc-tuple
                               (warning$ ctx "Documentation"
                                         "The name ~x0 is currently ~
                                          documented.  That documentation is ~
                                          about to be replaced."
                                         name)
                             state)
                           (value (cons section-sym citations))))))))
                   (t (er-doc ctx
                              "The section symbol of a formatted ~
                               documentation string must be either the name ~
                               being documented or a previously documented ~
                               name.  ~x1 is neither.  Thus, the string below ~
                               is an ill-formed documentation string.  See ~
                               :DOC doc-string.~|~%~x2.~%"
                              name section-sym doc))))))))
     (t (value nil)))))

(defun translate-doc (name doc ctx state)

; If this function does not cause an error, it returns a pair of the form
; (section-symbol . citations) parsed from the doc string, or nil if the
; doc string is unformatted.

  (cond ((and doc (not (stringp doc)))
         (er soft ctx
             "When a documentation string is supplied the value must ~
              be a string, but ~x0 is not.  See :DOC doc-string."
             doc))
        ((null name)
         (cond ((doc-stringp doc)
                (er soft ctx
                    "Events that introduce no names (e.g., in-theory ~
                     and verify-guards) are not permitted to have ~
                     documentation strings that begin with the ~
                     characters ``:Doc-Section''.  See :DOC ~
                     doc-string."))
               (t (value nil))))
        (t (chk-well-formed-doc-string name doc ctx state))))

(defun translate-doc-lst (names docs ctx state)
  (cond
   ((null names) (value nil))
   (t (er-let* ((pair (translate-doc (car names) (car docs) ctx state))
                (rst (translate-doc-lst (cdr names) (cdr docs) ctx state)))
               (value (cons pair rst))))))

(defun get-cites (citations)

; This function collects all the symbols that are paired with
; :cite in the citations alist.

  (cond ((null citations) nil)
        ((eq (caar citations) :cite)
         (add-to-set-equal (cdar citations)
                           (get-cites (cdr citations))))
        (t (get-cites (cdr citations)))))

(defun alpha-< (x y)

; X and y are symbols or strings.  We return t iff x comes before y in
; an alphabetic ordering of their print names.  We are somewhat free
; to decide how to handle packages and strings v. symbols.  We choose
; to put 'ABC before "ABC" and we use package-names only to break
; ties among two symbols with the same symbol-name.

  (let ((xstr (if (symbolp x) (symbol-name x) x))
        (ystr (if (symbolp y) (symbol-name y) y)))
    (cond ((string< xstr ystr) t)
          ((equal xstr ystr)
           (if (symbolp x)
               (if (symbolp y)
                   (string< (symbol-package-name x)
                            (symbol-package-name y))
                   t)
               nil))
          (t nil))))

(defun merge-alpha-< (l1 l2)
  (cond ((null l1) l2)
        ((null l2) l1)
        ((alpha-< (car l1) (car l2))
         (cons (car l1) (merge-alpha-< (cdr l1) l2)))
        (t (cons (car l2) (merge-alpha-< l1 (cdr l2))))))

(defun merge-sort-alpha-< (l)
  (cond ((null (cdr l)) l)
        (t (merge-alpha-< (merge-sort-alpha-< (evens l))
                          (merge-sort-alpha-< (odds l))))))

(defun update-alpha-<-alist (key val alist)

; Alist is an alist whose keys are either symbols or strings and
; ordered by alpha-<.  We bind key to val.  Key may already be
; present.

  (cond ((null alist) (list (cons key val)))
        ((equal key (caar alist)) (cons (cons key val) (cdr alist)))
        ((alpha-< (caar alist) key)
         (cons (car alist) (update-alpha-<-alist key val (cdr alist))))
        (t (cons (cons key val) alist))))

(defun put-cited-bys (name citations alist)

; This function visits every symbol paired with :cited-by in the
; citations alist and puts name in the citations field of the symbol,
; unless name is either the symbol itself or name already occurs in
; the citations.  Alist is the 'documentation-alist.

  (cond
   ((null citations) alist)
   (t (put-cited-bys
       name
       (cdr citations)
       (if (and (eq (caar citations) :cited-by)
                (not (equal name (cdar citations))))
           (let ((doc-tuple (assoc-equal (cdar citations) alist)))
             (cond ((member-equal name (caddr doc-tuple))
                    alist)
                   (t (update-alpha-<-alist
                       (cdar citations)
                       (list (cadr doc-tuple)
                             (cons name (caddr doc-tuple))
                             (cadddr doc-tuple))
                       alist))))
           alist)))))

(defun update-doc-database (name doc pair wrld)

; Name is a documented name, i.e., a symbol or a string (package name).
; Pair is the (section-symbol . citations) pair parsed from the doc
; string, or nil if doc is unformatted.  If pair is non-nil we add a
; new entry to the documentation database.  Each entry has the form
; (name section-symbol cites doc), where cites is the list of all x
; such that (:cite x) occurs citations.  Entries are ordered
; alphabetically by name.  In addition, add name to the cites list of
; every x such that (:cited-by x) occurs in citations.

  (cond (pair
         (global-set 'documentation-alist
                     (put-cited-bys
                      name
                      (cons (cons :cited-by (car pair)) (cdr pair))
                      (update-alpha-<-alist
                       name
                       (list (car pair)
                             (get-cites (cdr pair))
                             doc)
                       (global-val 'documentation-alist wrld)))
                     wrld))
        (t wrld)))

(defun update-doc-database-lst (names docs pairs wrld)
  (cond ((null names) wrld)
        (t (update-doc-database-lst
            (cdr names)
            (cdr docs)
            (cdr pairs)
            (update-doc-database (car names) (car docs) (car pairs) wrld)))))

(defun putprop-unless (sym key val exception wrld)

; We do (putprop sym key val wrld) unless val is exception, in which case we do
; nothing.  We return the possibly modified wrld.

; It has occurred to us to wonder whether a form such as (putprop-unless sym
; prop val nil wrld) -- that is, where exception is nil -- might cause problems
; if the the value of property prop for symbol sym is *acl2-property-unbound*.
; We don't think that's a problem, though, since in that case (getprop sym prop
; default name wrld) returns nil, just as though we'd actually put nil
; explicitly as the property value.

; See also the related function putprop-if-different, whose definition contains
; a comment showing how it relates to the present function.

  (cond ((equal val exception) wrld)
        (t (putprop sym key val wrld))))

(defun redefined-warning (redef ctx state)

; Redef is either nil, a true-list of symbols, a single symbol, or a
; single string.  In the latter two cases we think of redef denoting a
; singleton list.  If the list denoted by redef is non-nil we print a
; warning that every name in that list has been redefined.

  (if redef
      (warning$ ctx "Redef"
               "~&0 redefined.~%~%"
               (if (atom redef) (list redef) redef))
      state))

(defun get-event (name wrld)

; This function has undefined behavior when name was not introduced by an ACL2
; event.

  (access-event-tuple-form
   (cddr
    (car
     (lookup-world-index 'event
                         (getprop name 'absolute-event-number 0
                                  'current-acl2-world wrld)
                         wrld)))))

(defun redundant-labelp (name event-form wrld)

; The only time a label is considered redundant is during the second pass of
; initialization and only then if it was already defined with the same
; event-form.

  (and (global-val 'boot-strap-pass-2 wrld)
       (getprop name 'label nil 'current-acl2-world wrld)
       (equal event-form (get-event name wrld))))

(defun deflabel-fn (name state doc event-form)

; Warning: If this event ever generates proof obligations, remove it from the
; list of exceptions in install-event just below its "Comment on irrelevance of
; skip-proofs".

  (with-ctx-summarized
   (if (output-in-infixp state) event-form (cons 'deflabel name))
   (let ((wrld1 (w state))
         (event-form (or event-form
                         (list* 'deflabel name
                                (if doc
                                    (list :doc doc)
                                  nil)))))
     (cond
      ((redundant-labelp name event-form wrld1)
       (stop-redundant-event ctx state))
      (t
       (er-progn
        (chk-all-but-new-name name ctx 'label wrld1 state)
        (er-let*
         ((wrld2 (chk-just-new-name name 'label nil ctx wrld1 state))
          (doc-pair (translate-doc name doc ctx state)))
         (let ((wrld3 (update-doc-database
                       name doc doc-pair
                       (putprop name 'label t wrld2))))

; The only reason we store the 'label property is so that name-introduced
; recognizes this name.

; Note:  We do not permit DEFLABEL to be made redundant.  If this
; is changed, change the text of the :DOC for redundant-events.

           (install-event name
                          event-form
                          'deflabel
                          name
                          nil
                          nil
                          nil
                          nil
                          wrld3
                          state)))))))))

; That completes the development of deflabel.  But now there is the
; considerable task of printing out documentation strings and help
; info based on the documentation database.  First, let us get
; defdoc out of the way.

(defun defdoc-fn (name state doc event-form)

; Warning: If this event ever generates proof obligations, remove it from the
; list of exceptions in install-event just below its "Comment on irrelevance of
; skip-proofs".

  (with-ctx-summarized
   (if (output-in-infixp state) event-form (cons 'defdoc name))
   (let ((wrld1 (w state))
         (event-form (or event-form
                         (list* 'defdoc name doc))))
     (er-progn
      (if (or (and (symbolp name) name) (stringp name))
          (value nil)
        (er soft ctx
            "Names to be documented must be strings or non-nil symbols and ~x0 ~
             is not."
            name))
      (cond
       ((global-val 'boot-strap-pass-2 (w state))

; Legacy comment, from before the documentation was moved to
; books/system/doc/acl2-doc.lisp:

;   When the documentation for topic BDD was moved to axioms.lisp, we had the
;   following problem: evaluation of (defdoc bdd ...) in the second pass of
;   boot-strap was setting the "cites" (subtopics) field to nil.  So, now we
;   skip defdoc events on the second pass of the boot-strap.

        (value :skipped))
       (t
        (er-let*
         ((doc-pair (translate-doc name doc ctx state)))
         (cond
          (doc-pair
           (let ((wrld2 (update-doc-database
                         name doc doc-pair wrld1)))
             (install-event name
                            event-form
                            'defdoc
                            0
                            nil
                            nil
                            nil
                            nil
                            wrld2
                            state)))
          (t (er soft ctx
                 "The doc string supplied for ~x0 is not a valid ACL2 ~
                  documentation string.  See :DOC doc-string."
                 name))))))))))

#+acl2-loop-only
(defmacro defdoc (&whole event-form name doc) ;See note

; Warning: See the Important Boot-Strapping Invariants before modifying!

; Warning: If this event ever generates proof obligations, remove it from the
; list of exceptions in install-event just below its "Comment on irrelevance of
; skip-proofs".

  (list 'defdoc-fn
        (list 'quote name)
        'state
        (list 'quote doc)
        (list 'quote event-form)))

(defun access-doc-string-database (name state)

; Name is a symbol or a string.  This function would be just
; (assoc-equal name documentation-alist) but for one twist: if name is
; a symbol and not in the database, we try acl2::name instead.  We
; return (name section-symbol cites doc), or nil if there is no entry
; for either name.  The reason we go to ACL2::name after name fails is
; that:

; MY-PKG !>:doc defthm

; will read as MY-PKG::DEFTHM and we assume that most of the time
; the documentation topics the user is interested in are ours.

  (cond
   ((symbolp name)
    (let ((doc-tuple
           (assoc-eq name
                     (global-val 'documentation-alist (w state)))))
      (cond (doc-tuple doc-tuple)
            ((not (equal (symbol-package-name name)
                         "ACL2"))
             (assoc-equal
              (intern-in-package-of-symbol
               (symbol-name name)
               'get-doc-string)
              (global-val 'documentation-alist (w state))))
            (t nil))))
   ((stringp name)
    (assoc-equal name
                 (global-val 'documentation-alist (w state))))
   (t nil)))

(defun get-doc-string (name state)

; This function is provided simply to let the user see what
; doc strings really look like.

  (cadddr (access-doc-string-database name state)))

(defun get-doc-string-de-indent1 (str i)
  (cond ((eql (char str i) #\Newline) 0)
        (t (1+ (get-doc-string-de-indent1 str (1- i))))))

(defun get-doc-string-de-indent (str)

; The text in a doc string is assumed to be indented some to
; avoid screwing up the Emacs formatting commands and to make their
; appearance in source files more pleasant.  We de-indent them as we
; print, stripping off a fixed number of #\Spaces after every newline,
; when possible.  We compute the de-indent number by looking at the
; indentation of the one-liner part.

  (get-doc-string-de-indent1 str
                             (1- (scan-to-doc-string-part 0 str))))

(defun use-doc-string-de-indent (d str i maximum)

; If there are d spaces in str starting at i, return i+d; else nil.

  (cond ((= d 0) i)
        ((< i maximum)
         (cond ((eql (char str i) #\Space)
                (use-doc-string-de-indent (1- d) str (1+ i) maximum))
               (t nil)))
        (t nil)))

(defun doc-prefix (state)
  (if (f-boundp-global 'doc-prefix state)
      (f-get-global 'doc-prefix state)
      "| "))

(defun princ-prefix (prefix channel state)
  (cond ((consp prefix)
         (pprogn (princ$ (car prefix) channel state)
                 (spaces (cdr prefix) (length (car prefix)) channel state)))
        (t (princ$ prefix channel state))))

(defun length-prefix (prefix)
  (cond ((consp prefix) (+ (length (car prefix)) (cdr prefix)))
        (t (length prefix))))

(defun save-more-doc-state (str i maximum de-indent prefix state)
  (cond ((or (>= i maximum)
         (and (int= (+ i 2) maximum)
              (eql (char str i) #\~) (eql (char str (1+ i)) #\/)))
         (f-put-global 'more-doc-state nil state))
        (t (f-put-global 'more-doc-state
                         (list str i maximum de-indent prefix)
                         state))))

(defun doc-char-subst-table-p (x)

; See comment in terminal-markup-table.

  (cond
   ((consp x)
    (and (consp (car x))
         (not (eql (caar x) #\~))
         (not (eql (caar x) #\Newline))
         (character-listp (car x))
         (doc-char-subst-table-p (cdr x))))
   (t (null x))))

(defun set-doc-char-subst-table (x state)
  (if (doc-char-subst-table-p x)
      (pprogn (f-put-global 'doc-char-subst-table x state)
              (value :invisible))
    (er soft 'set-doc-char-subst-table
        "The character substitution table must be an alistp whose keys are ~
         all characters other than ~~ and values are all strings.  The object ~
         ~x0 does not have this property."
        x)))

(defun doc-char-subst-table (state)

; See comment in terminal-markup-table.

  (f-get-global 'doc-char-subst-table state))

(defun doc-fmt-alist (state)
  (f-get-global 'doc-fmt-alist state))

(defconst *terminal-markup-table*

; Examples of links are as follows.

; ~L (ordinary link)
; ~L[arg] prints ``See :DOC arg'' to the terminal, and something
;     analogous in other settings (but possibly with a link established,
;     or in the case of printed text, with a reference to a page number
;     and a section).
; Example:  ~l[program] for how to do rapid prototyping.
; -- Prints to the terminal as
;     See :DOC program for how to do rapid prototyping.
; -- A printed version might look more like:
;     See :DOC program, Section 1.3, page 92 for how to do rapid prototyping.
; -- Could print to emacs info as something like:
;     *See program:: for how to do rapid prototyping.

; ~PL (parenthetical link)
; ~pl[arg] prints ``see :DOC arg'' (just like ~l, but with lower-case ``see'')
;      to the terminal; as with ~l, it may establish a link in other settings.
;      The name ``parenthetical'' is taken from texinfo, which claims to
;      require that, unlike the other kind of link, commas and periods may not
;      appear immediately afterwards.  For now, we ignore this issue,
;      considering that ~pl is distinguished from ~l mainly by the case of
;      ``see''.

; ~IL (invisible link):  use the word normally and do not draw any special
;                        attention to the fact that it is a link.
; ~IL[arg] prints ``arg''

; The following association list maps each such directive (as a
; case-insensitive string) to a flag and fmt message, i.e., to a string
; followed by an association list appropriate for that string.  The flag
; determines whether the first part of arg is to be read as a symbol as when it
; represents the name of a link.  When flag=t, we split the arg into two parts,
; the symbol and the text.  A flag of t is used on those keys which translate
; into HREF links in HTML so that the first of the two args is treated as the
; doc topic identifying the link and the rest is treated as the mouse-sensitive
; button text highlighted by HTML.  (Note that even in the terminal and tex
; markup tables we must use flag t on those keys so that those commands get
; only the first doc topic part of the arg.)  The string corresponding to key
; will ultimately be printed in place of the ~key[arg] expression, except that
; the corresponding alist will first be extended by mapping #\a to the (first
; part of the) string arg, and mapping #\A to the upper-casing of that string,
; and #\t to the second part of the string arg (provided flag=t).  Note also
; that the (doc-char-subst-table state) is used to control the substitution of
; sequences of characters for single characters, both in the arg portion of
; ~key[arg] and in characters not part of such expressions, but *not* in the
; key.  To escape a character from substitution by that table, precede it by a
; ~.

; Finally, note that in ~key[arg] we do not allow newline characters.  That is
; because they will not get printed appropriately to the terminal.  Thus, ~c
; may have to be used more than we'd like.  If we really want to include a
; newline for some reason, it should be escaped with ~.

  `(("-"   nil . "--")
    ("B"   nil . "~st")   ;bold font
    ("BF"  nil . "")      ;begin format --
                         ; -- like verbatim, but if possible don't change font
    ("BID" nil . "")      ;begin implementation dependent
    ("BQ"  nil . "")      ;begin quotation
    ("BV"  nil . "")      ;begin verbatim
    ("C"   nil . "~st")   ;code, often preferred even if we have invisible link
    ("EF"  nil . "")      ;end format
    ("EID" nil . "")      ;end implementation dependent
    ("EM"  nil . "~st")   ;emphasis (presumably italics if fonts are available)
    ("EQ"  nil . "")      ;end quotation
    ("EV"  nil . "")      ;end verbatim
    ("GIF" nil . "")      ;gif file (currently only for HTML)
;   ("GIF" nil . "gif file ~st omitted")   ;alternate possibility for ~gif
    ("I"   nil . "~st")   ;italics font
    ("ID"  nil . "")       ;implementation dependent
    ("IL"  t   . "~st")   ;invisible link, for true hypertext environments
    ("ILC" t   . "~st")   ;invisible link, but use code if such links don't show
    ("L"   t   . "See :DOC ~ss") ;link at beginning of sentence
    ("NL"  nil . "~%")    ;newline
    ("PAR" nil . "")      ;paragraph mark, of no significance at the terminal
    ("PL"  t   . "see :DOC ~ss");parenthetical link, i.e., link
;                                  not at beginning of sentence
    ("SC"  nil . "~sT")   ;(small, if possible) caps
    ("ST"  nil . "~sT")   ;strong emphasis (presumably bold if fonts are available)
    ("T"   nil . "~st")   ;typewriter font
    ("TERMINAL" nil . "~st") ;terminal only; otherwise argument is ignored
    ("WARN" nil . "<>")
    ("CLICK-HERE" t . "See :DOC ~ss")
    ("PCLICK-HERE" t . "see :DOC ~ss")
    ("FLY" t . "Flying Tour: see :DOC ~ss")
    ("WALK" t . "Walking Tour: see :DOC ~ss")
    ("LARGE-WALK" t . "Walking Tour: see :DOC ~ss")
    ("URL"  nil . "~st")   ;print as HTML hyperlink (when possible)
    ))

(defun doc-markup-table (state)
  (or (and (f-boundp-global 'doc-markup-table state)
           (f-get-global 'doc-markup-table state))
      *terminal-markup-table*))

(defun doc-scan-past-tilde-key (name orig-position posn str maximum acc state)

; Posn is the position just after the first opening bracket ([) that is at or
; after position posn in the string str, and acc accumulates the characters
; found in the interim.  The function returns (mv erp posn key state), where
; key is built from the accumulated characters so that we can view the string
; from the original position as "key[".  Note that we deliberately do *not* use
; a char-subst-table here; key is taken literally.

  (cond
   ((not (< posn maximum))
    (mv-let (erp val state)
            (er soft "printing documentation string"
                "In the process of processing the tilde (~~) directive at ~
                 position ~x0 in the documentation string for ~x1, ~
                 no opening bracket ([) was found between that tilde ~
                 and before the end of the string."
                orig-position name)
            (declare (ignore erp val))
            (mv t nil nil state)))
   (t
    (let ((ch (char str posn)))
      (cond
       ((eql ch #\[)
        (mv nil (1+ posn) (coerce (reverse acc) 'string) state))
       (t (doc-scan-past-tilde-key
           name orig-position (1+ posn) str maximum (cons ch acc) state)))))))

(defun doc-scan-past-tilde-arg
  (name orig-position posn str maximum acc state)

; Posn is the position just after the first non-escaped closing bracket (]) at
; or after position posn in the string str, and acc accumulates the characters
; found in the interim.  The function returns (mv erp posn arg state), where
; arg is built from the accumulated characters so that we can view the string
; from the original position as "arg]".

  (cond
   ((not (< posn maximum))
    (mv-let (erp val state)
            (er soft "printing documentation string"
                "In the process of processing the tilde (~~) directive whose ~
                 argument begins at position ~x0 in the documentation string ~
                 for ~x1, no closing bracket (]) was found corresponding to ~
                 the preceding opening bracket."
                orig-position name)
            (declare (ignore erp val))
            (mv t nil nil state)))
   (t
    (let ((ch (char str posn)))
      (cond
       ((eql ch #\])
        (mv nil (1+ posn) (coerce (reverse acc) 'string) state))
       ((eql ch #\Newline)

; Why do we have this annoying newline check, which so often bites us when
; writing out the :doc for html or texinfo?  A quick answer is that a newline
; could indicate that we are missing a closing bracket in ~key[...], and
; perhaps that's a sufficient answer.  But another answer is that otherwise,
; our printing to the terminal is ugly.  Without this check we get the
; following after:

;   (defdoc foo
;     ":Doc-Section Miscellaneous
;
;     my one-liner~/
;
;     Here we insert a linebreak: ~c[(fn
;     arg)].~/~/")

; Notice the missing `|' at the beginning of a line.

;   ACL2 !>:doc! foo
;   | FOO          my one-liner
;   |
;   | Here we insert a linebreak: (fn
;     arg).
;   |
;   *-
;   ACL2 !>

        (mv-let (erp val state)
                (er soft "printing documentation string"
                    "In the process of processing the tilde (~~) directive ~
                     whose argument begins at position ~x0 in the ~
                     documentation string for ~x1, a newline was encountered.  ~
                     This is illegal.  Consider breaking this tilde directive ~
                     into several separate ones, each occurring on its own ~
                     line."
                    orig-position name)
                (declare (ignore erp val))
                (mv t nil nil state)))
       ((and (eql ch #\~)
             (< (1+ posn) maximum))
        (doc-scan-past-tilde-arg name orig-position (+ 2 posn) str maximum
                                 (cons (char str (1+ posn)) acc) state))
       (t (doc-scan-past-tilde-arg name orig-position (1+ posn) str maximum
                                   (cons ch acc)
                                   state)))))))

(defun doc-scan-past-tilde
  (name posn str maximum markup-table state)

; Posn is the position of the first character after a tilde in str,
; in the following sense:
;   ....~key[arg]....
;        ^
; We return (mv erp posn entry arg state), where
;
; erp = nil iff the `parse' succeeds;
; posn = new position, after the closing right bracket (]);
; entry = the entry in markup-table associated with k (which is non-empty if
;         erp is nil);
; arg = the string enclosed in brackets after the key, as shown above.

  (mv-let (erp posn key state)
          (doc-scan-past-tilde-key name posn posn str maximum nil state)
          (cond
           (erp (mv erp nil nil nil state))
           (t (let ((entry (assoc-string-equal key markup-table)))
                (cond ((null entry)
                       (mv-let (erp val state)
                               (er soft "printing documentation string"
                                   "~|Failed to find key ~x0 in current ~
                                    markup table,~|~%  ~x1,~|~%when printing ~
                                    documentation for ~x2.~|"
                                   key markup-table name)
                               (declare (ignore erp val))
                               (mv t nil nil nil state)))
                      (t
                       (mv-let (erp posn arg state)
                               (doc-scan-past-tilde-arg name
                                                        posn posn str maximum
                                                        nil state)
                               (cond
                                (erp (mv erp nil nil nil state))
                                (t (mv nil posn entry arg state)))))))))))

(defun assoc-char-alist-stringp (char-alist str len)

; Warning:  Just like member-char-stringp, len must be strictly less than the
; length of string!

  (cond
   ((null char-alist) nil)
   (t (or (member-char-stringp (caar char-alist) str len)
          (assoc-char-alist-stringp (cdr char-alist) str len)))))

(defun apply-char-subst-table1 (char-lst acc char-subst-table)

; Consider the result of replacing each character in char-lst with its value in
; char-subst-table when it is bound there, else leaving it unchanged, and then
; appending the result to the front of the list acc of characters.  A symbol is
; then returned with that name that resides in the package of orig-symbol if
; orig-symbol is non-nil; otherwise, the string is returned.

  (cond
   ((null char-lst)
    (coerce (reverse acc) 'string))
   (t
    (let ((temp (assoc (car char-lst) char-subst-table)))
      (cond
       (temp
        (apply-char-subst-table1 (cdr char-lst) (revappend (cdr temp) acc)
                                 char-subst-table))
       (t (apply-char-subst-table1 (cdr char-lst)
                                   (cons (car char-lst) acc)
                                   char-subst-table)))))))

(defun apply-char-subst-table (s char-subst-table spack)

; Consider the result of replacing each character in char-lst with its value in
; char-subst-table when it is bound there, else leaving it unchanged, and then
; appending the result to the front of the list acc of characters.  A symbol is
; then returned with that name that resides in the package of orig-symbol if
; orig-symbol is non-nil; otherwise, the string is returned.

  (cond
   ((symbolp s)
    (let ((n (symbol-name s)))
      (cond
       ((assoc-char-alist-stringp char-subst-table n (1- (length n)))
        (intern-in-package-of-symbol
         (apply-char-subst-table1 (coerce n 'list) nil char-subst-table)
         spack))
       (t s))))
   ((stringp s)
    (cond
     ((assoc-char-alist-stringp char-subst-table s (1- (length s)))
      (apply-char-subst-table1 (coerce s 'list) nil char-subst-table))
     (t s)))
   (t (er hard 'apply-char-subst-table
          "Attempted to apply character substitution table to non-symbol, ~
           non-string:  ~x0"
          s))))

(defun read-pointer-and-text1 (lst pacc sacc)
  (cond ((null lst)
         (mv (er hard 'read-pointer-and-text
                 "Unbalanced vertical bars, ~x0"
                 (coerce (reverse sacc) 'string))
             nil
             nil))
        ((eql (car lst) #\|)
         (cond ((cdr lst)
                (cond ((eql (cadr lst) #\Space)
                       (mv (coerce (reverse pacc) 'string)
                           (coerce (reverse (cons #\| sacc)) 'string)
                           (coerce (cddr lst) 'string)))
                      (t (mv (coerce (reverse pacc) 'string)
                             (coerce (reverse (cons #\| sacc)) 'string)
                             (coerce (cdr lst) 'string)))))
               (t (let ((temp (coerce (reverse pacc) 'string)))
                    (mv temp
                        (coerce (reverse (cons #\| sacc)) 'string)
                        temp)))))
        (t (read-pointer-and-text1 (cdr lst)
                                   (cons (car lst) pacc)
                                   (cons (car lst) sacc)))))

(defun read-pointer-and-text2 (lst acc)
  (cond ((eql (car lst) #\Space)
         (let ((temp (coerce (reverse acc) 'string)))
           (mv temp
               temp
               (coerce (cdr lst) 'string))))
        (t (read-pointer-and-text2 (cdr lst)
                                   (cons (char-upcase (car lst)) acc)))))

(defun read-pointer-and-text-raw (str)

; See the comment in lookup-fmt-alist, especially the table showing
; how we ``read'' a symbol from str.

  (cond
   ((eql (char str 0) #\|)
    (read-pointer-and-text1 (cdr (coerce str 'list)) nil '(#\|)))
   ((string-search '(#\Space) str nil)
    (read-pointer-and-text2 (coerce str 'list) nil))
   (t (let ((temp (string-upcase str)))
        (mv temp temp str)))))

(defun posn-char-stringp (chr str i)
  (cond ((zp i)
         (if (eql chr (char str i))
             0
           nil))
        ((eql chr (char str i))
         i)
        (t
         (posn-char-stringp chr str (1- i)))))

(defun replace-colons (p)
  (let ((posn (posn-char-stringp #\: p (1- (length p)))))
    (if (or (null posn)
            (eql posn 0))
        p
      (concatenate 'string
                   (subseq p 0
                           (if (eql (char p (1- posn)) #\:)
                               (1- posn)
                             posn))
                   "||"
                   (subseq p (1+ posn) (length p))))))

(defun read-pointer-and-text (str bar-sep-p)
  (if bar-sep-p
      (mv-let
       (p s text)
       (read-pointer-and-text-raw str)
       (mv (replace-colons p) (replace-colons s) text))
    (read-pointer-and-text-raw str)))

(defun lookup-fmt-alist (str flag fmt-alist char-subst-table bar-sep-p)

; Warning: Keep this in sync with missing-fmt-alist-chars.

; Consider a tilde-directive ~?[str].  From str we create a fmt alist that is
; used while we print the string associated with ? in the markup table.  This
; function creates that fmt alist from str and the flag which indicates whether
; the first part of str is to be read as a symbol, as in ~il[defun Definition],
; or not as in ~c[this Definition].

; What are the symbols in the fmt alist we need?  To find the answer, look in
; the markup table and collect all the fmt vars used.  They are:

; #\p -- the "pointer"     ; only used if flag is t
; #\s -- the print name version of the pointer, e.g., |abc| or ABC
; #\c -- the parent file   ; only used if flag is t
; #\t -- the displayed text
; #\T -- uppercased displayed text
; #\w -- the html anchor for the warning message ; only used on ~WARN[]

; The entries marked "only used if flag is t" are not necessarily used if flag
; is t.  For example, the entries in *terminal-markup-table* do not refer to
; #\c, since terminal documentation has no reason to refer to a "parent file".

; If flag is nil, then we bind just the last three.  In this case, the
; displayed text is all of str.

; If flag is t, then we first ``read'' a symbol from str, effectively splitting
; str into two parts, sym and text.  The split is indicated below.  Note that
; sym is a string, not really a symbol.  The "pointer" is the symbol-name of
; sym.  The "print name of the pointer" is the symbol-name of sym possibly
; surrounded by vertical bars.

;    str             #\p    #\s     #\t

; ~?[abc]           "ABC"  "ABC"    "abc"
; ~?[abc ]          "ABC"  "ABC"    ""
; ~?[abc def ghi]   "ABC"  "ABC"    "def ghi"
; ~?[|abc|]         "abc"  "|abc|"  "abc"
; ~?[|abc| ]        "abc"  "|abc|"  ""
; ~?[|abc| def ghi] "abc"  "|abc|"  "def ghi"
; ~?[|abc|def ghi]  "abc"  "|abc|"  "def ghi"

; Parameter bar-sep-p says that symbols with :: in them, but not starting with
; :, are to be converted to strings with || in place of the colons.

; To find #\c we lookup sym in the fmt-alist provided.  Then we bind #\p to sym
; and process text as in the flag=nil case.

  (cond
   ((null flag)
    (cond ((equal str "")

; We don't know that we are in the ~warn[] case so we might need #\t and #\T in
; the alist.  We add them.

           (list* (cons #\t "")
                  (cons #\T "")
                  (cdr (assoc-string-equal "" fmt-alist))))
          (t (list (cons #\t (apply-char-subst-table str
                                                     char-subst-table
                                                     nil))
                   (cons #\T (apply-char-subst-table (string-upcase str)
                                                     char-subst-table
                                                     nil))))))
   (t (mv-let
       (p s text)
       (read-pointer-and-text str bar-sep-p)
       (let ((alist0
              (list* (cons #\t (apply-char-subst-table text
                                                       char-subst-table
                                                       nil))
                     (cons #\T (apply-char-subst-table (string-upcase text)
                                                       char-subst-table
                                                       nil))

; Note that it is NOT necessarily an error if the assoc-string-equal returns
; nil in the next line.  This may be the case for forms of documentation where
; extra fmt-alist information is not required.  For example, terminal
; documentation doesn't require the #\c "parent file" information that HTML
; documentation does, so for "links" produced by markup like ~il[x] and ~ilc[x]
; there may still be no fmt-alist entry for x.

                     (cdr (assoc-string-equal p fmt-alist)))))
         (if (assoc #\p alist0)
             alist0
           (list* (cons #\p (apply-char-subst-table p char-subst-table nil))
                  (cons #\s (apply-char-subst-table s char-subst-table nil))
                  alist0)))))))

(defun bar-sep-p (state)
  (and (f-boundp-global 'bar-sep-p state)
       (f-get-global 'bar-sep-p state)))

(defun char-to-string-alistp (lst)
  (declare (xargs :guard t
                  :mode :logic))
  (cond ((atom lst)
         (null lst))
        (t (and (consp lst)
                (consp (car lst))
                (characterp (caar lst))
                (stringp (cdar lst))
                (char-to-string-alistp (cdr lst))))))

(defun missing-fmt-alist-chars1 (str char-to-tilde-s-string-alist fmt-alist)

; See documentation for missing-fmt-alist-chars.

  (declare (xargs :guard (and (stringp str)
                              (char-to-string-alistp char-to-tilde-s-string-alist)
                              (eqlable-alistp fmt-alist))))
  (cond ((endp char-to-tilde-s-string-alist)
         nil)
        (t
         (let ((fmt-char  (caar char-to-tilde-s-string-alist))
               (tilde-str (cdar char-to-tilde-s-string-alist))
               (rest
                (missing-fmt-alist-chars1 str
                                          (cdr char-to-tilde-s-string-alist)
                                          fmt-alist)))
           (cond ((and (not (assoc fmt-char fmt-alist))
                       (search tilde-str str))
                  (cons fmt-char rest))
                 (t rest))))))

(defun missing-fmt-alist-chars (str fmt-alist)

; Warning: Keep the characters bound below with the documentation for
; lookup-fmt-alist.  (NOTE: As of Oct. 2009 I do not really understand why
; other than #\p and #\c should get any attention here.  Note that #\c and #\p
; are used for links in doc/write-acl2-html.lisp and
; doc/write-acl2-texinfo.lisp, respectively.)

; Return a list of characters C for which the given fmt-alist is incomplete for
; the fmt string, str, in the sense that (1) C is one of the characters listed
; below, (2) str contains the substring "~sC", and (3) C is not bound in
; fmt-alist.  By calling this function, we can cause a nice error if such a
; character C is found, or even avoid an error by pointing to a special
; "undocumented" topic.

  (declare (xargs :guard (and (stringp str)
                              (eqlable-alistp fmt-alist))))
  (missing-fmt-alist-chars1 str
                            '((#\p . "~sp")
                              (#\s . "~ss")
                              (#\c . "~sc")
                              (#\t . "~st")
                              (#\T . "~sT")
                              (#\w . "~sw"))
                            fmt-alist))

(defun complete-fmt-alist (topic-name fmt-alist undocumented-file
                                      char-subst-table)

; Warning: Keep this in sync with the comment about complete-fmt-alist in
; print-doc-string-part1.

; Return an extension of fmt-alist so that ~sc will refer to an undocumented
; topic if #\c is not already bound in fmt-alist (thus supporting the use of
; ~sc by doc/write-acl2-html.lisp at least through Oct. 2009), and similarly
; for ~sp and #\p (thus supporting the use of ~sp by
; doc/write-acl2-texinfo.lisp at least through Oct. 2009).  Some day we may
; want to complete with other characters as well.

  (let* ((c-missing-p (not (assoc #\c fmt-alist)))
         (p-missing-p (not (assoc #\p fmt-alist)))
         (fmt-alist
          (cond (c-missing-p (acons #\c undocumented-file fmt-alist))
                (t fmt-alist)))
         (fmt-alist
          (cond (p-missing-p (acons #\p
                                    (apply-char-subst-table topic-name
                                                            char-subst-table
                                                            nil)
                                    fmt-alist))
                (t fmt-alist))))
    fmt-alist))

(defmacro mv-to-state (n form)

; Form should evaluate to an mv of two or more values, all non-stobjs except
; the, which should be state.  We return that state, discarding the other
; values.

  (declare (xargs :guard (and (integerp n)
                              (< 1 n))))
  (let ((vars (make-var-lst 'x (1- n))))
    `(mv-let (,@vars state)
             ,form
             (declare (ignore ,@vars))
             state)))

(defun print-par-entry (entry fmt-alist char-subst-table channel state)
  (mv-to-state
   2
   (fmt1 (cddr entry)
         (lookup-fmt-alist "" nil fmt-alist char-subst-table
                           (bar-sep-p state))
         0 channel state nil)))

(defun print-doc-string-part1 (str i maximum de-indent prefix
                                   markup-table char-subst-table
                                   fmt-alist channel name state ln
                                   undocumented-file vp)

; Parameter ln is a bit complicated, so we describe it in some detail.

; First suppose that ln is a number, in which case it is the number of lines
; printed so far.  In this case, we do :more processing until we hit the line
; maximum (at which point we save the more-doc-state to continue) or the
; tilde-slash (at which point we set the more-doc-state to nil).

; When ln is nil, we do not bother to track the number of lines printed and we
; print them all up to the tilde-slash, but we then initialize the
; more-doc-state.  The nil setting should be used when you are printing out
; parts 0 or 1 of the doc string.

; When ln is t we behave as for nil, except that we set the more-doc-state to
; nil (as we would for numeric ln) when we hit the tilde-slash.  This setting
; is used when we want to dump the entire part 2.

; When ln is :par, then two consecutive newlines, together with all consecutive
; whitespace characters following them, are handled by printing using the entry
; for EPAR in markup-table, if there is one; else, by using the entry for PAR
; if there is one; else, without such special paragraph treatment.  In the case
; that EPAR's entry is used, then if there are any remaining characters after
; the block of newlines, the entry for BPAR is then printed.

; The final legal value of ln is :par-off, whose purpose is to avoid printing
; paragraph markers when inside certain preformatted (verbatim) environments,
; typically ~bv/~ev and ~bf/~ev for printing to html and the like (but not the
; terminal or texinfo).  Thus, :par-off is treated like :par except that there
; is no special treatment in the case of consecutive newlines.  Thus :par-off
; is really treated like t, except that ln becomes :par in recursive calls when
; the end of a preformatted environment is encountered.  The argument vp
; (verbatim pair) never changes, and is nil when ln is not :par or :par-off.
; But vp is a pair (begin-markers . end-markers), for example, (("BV" "BF")
; . ("EV" "EF")), where begin-markers tell us to change ln from :par to
; :par-off and end-markers tell us to change ln from :par-off to :par.

; A precondition for this function is that if ln is :par or :par-off and if
; "EPAR" is bound in markup-table (and hence so is "BPAR"), then the
; begin-paragraph marker (as per "BPAR") has already been printed and the
; end-paragraph marker (as per "EPAR") will be printed.  Informatlly, then, it
; is an invariant of this function that at every call in the case that ln is
; :par or :par-off, an end-paragraph marker is pending.

  (cond ((< i maximum)
         (let ((c (char str i)))
           (cond
            ((eql c #\~)
             (cond
              ((< (1+ i) maximum)
               (let ((c (char str (1+ i))))
                 (cond
                  ((eql c #\/)
                   (pprogn
                    (newline channel state)
                    (save-more-doc-state
                     str
                     (cond ((null ln)
                            (scan-past-whitespace str (+ 2 i) maximum))
                           (t maximum))
                     maximum de-indent prefix state)
                    (mv ln state)))
                  ((eql c #\])

; This directive, ~], in a documentation string is effective only during the
; processing of part 2, the details, and controls how much we show on each
; round of :more processing.  If ln is not a number we are not doing :more
; processing and we act as though the ~] were not present.  Otherwise, we put
; out a newline and save the :more state, positioning the string after the ~]
; (or the newlines following it).

                   (cond ((not (integerp ln))
                          (print-doc-string-part1
                           str (+ 2 i) maximum de-indent prefix markup-table
                           char-subst-table fmt-alist
                           channel name state ln undocumented-file vp))
                         (t (pprogn (newline channel state)
                                    (save-more-doc-state
                                     str
                                     (scan-past-newline str (+ 2 i) maximum)
                                     maximum de-indent prefix state)
                                    (mv ln state)))))
                  ((eql c #\~)
                   (pprogn (princ$ c channel state)
                           (print-doc-string-part1 str (+ 2 i) maximum
                                                   de-indent
                                                   prefix
                                                   markup-table
                                                   char-subst-table
                                                   fmt-alist
                                                   channel name state ln
                                                   undocumented-file vp)))
                  (t
                   (mv-let
                    (erp posn entry arg state)
                    (doc-scan-past-tilde
                     name (1+ i) str maximum markup-table state)
                    (cond
                     (erp (pprogn (save-more-doc-state str maximum maximum
                                                       de-indent prefix
                                                       state)
                                  (mv ln state)))
                     (t (let* ((fmt-alist-for-fmt1
                                (lookup-fmt-alist arg (cadr entry) fmt-alist
                                                  char-subst-table
                                                  (bar-sep-p state)))
                               (missing-fmt-alist-chars
                                (missing-fmt-alist-chars (cddr entry)
                                                         fmt-alist-for-fmt1))
                               (complete-alist-p
                                (and undocumented-file
                                     missing-fmt-alist-chars))
                               (fmt-alist-for-fmt1
                                (if complete-alist-p
                                    (complete-fmt-alist
                                     name
                                     fmt-alist-for-fmt1
                                     undocumented-file
                                     char-subst-table)
                                  fmt-alist-for-fmt1)))
                          (prog2$
                           (cond
                            ((set-difference-eq missing-fmt-alist-chars

; Keep the list below in sync with complete-fmt-alist.  In this case it is
; irrelevant whether or not undocumented-file is specified (non-nil); we will
; get an error either way.

                                                '(#\c #\p))
                             (er hard 'print-doc-string-part1

; The use of ~| below guarantees reasonable line breaks even if the margins are
; set to very large numbers.

                                 "~|Fatal error printing the :DOC string for ~
                                  topic ~x0,~|due to substring:~|  ~~~s1[~s2]."
                                 name
                                 (string-downcase (car entry))
                                 arg))
                            ((and missing-fmt-alist-chars
                                  (not undocumented-file))
                             (er hard 'print-doc-string-part1
                                 "~|Error printing the :DOC string for topic ~
                                  ~x0,~|due to substring:~|  ~~~s1[~s2].~|If ~
                                  this error is not due to a typo, then it ~
                                  can probably be resolved either by:~|-- ~
                                  adding a :DOC string for ~x2,~|OR~|-- ~
                                  passing an UNDOCUMENTED-FILE argument to ~
                                  the appropriate~|   translator (e.g., ~
                                  function acl2::write-html-file in~|~ ~ ~ ~
                                  distributed file doc/write-html)."
                                 name
                                 (string-downcase (car entry))
                                 arg))
                            (t nil))
                           (pprogn
                            (cond (missing-fmt-alist-chars
                                   (assert$
                                    undocumented-file ; see error above
                                    (warning$ 'print-doc-string-part1
                                              "Documentation"

; Add a newline just below, since we may be in a context where the margins have
; been made essentially infinite.

                                              "~|Broken link in :doc ~x0: ~
                                               ~~~s1[~s2].~%"
                                              name
                                              (string-downcase (car entry))
                                              arg)))
                                  (t state))
                            (mv-let (col state)
                                    (fmt1 (cddr entry)
                                          fmt-alist-for-fmt1
                                          0 channel state nil)
                                    (declare (ignore col))
                                    (print-doc-string-part1
                                     str posn maximum de-indent prefix
                                     markup-table char-subst-table fmt-alist
                                     channel name state
                                     (cond ((not vp) ln)
                                           ((eq ln :par)
                                            (if (member-string-equal (car entry)
                                                                     (car vp))
                                                :par-off
                                              :par))
                                           ((eq ln :par-off)
                                            (if (member-string-equal (car entry)
                                                                     (cdr vp))
                                                :par
                                              :par-off))
                                           (t ln))
                                     undocumented-file vp))))))))))))
              (t (pprogn (princ$ c channel state)
                         (newline channel state)
                         (save-more-doc-state str (+ 1 i) maximum
                                              de-indent prefix
                                              state)
                         (mv ln state)))))
            ((eql c #\Newline)
             (mv-let
              (epar-p entry)
              (cond
               ((and (eq ln :par)
                     (< (1+ i) maximum)
                     (eql (char str (1+ i)) #\Newline))
                (let ((temp (assoc-string-equal "EPAR" markup-table)))
                  (cond (temp (mv t temp))
                        (t (let ((temp (assoc-string-equal "PAR"
                                                           markup-table)))
                             (mv nil temp))))))
               (t (mv nil nil)))
              (cond
               (entry
                (let ((next-i (scan-past-whitespace str (+ 2 i) maximum)))
                  (cond
                   ((eql next-i maximum)
                    (pprogn (save-more-doc-state str next-i maximum de-indent
                                                 prefix state)
                            (mv ln state)))
                   (t
                    (pprogn
                     (print-par-entry entry fmt-alist char-subst-table
                                      channel state)
                     (cond
                      ((not epar-p) state)
                      (t (let ((entry2
                                (assoc-string-equal "BPAR" markup-table)))
                           (prog2$ (or entry2
                                       (er hard 'print-doc-string-part1
                                           "Found EPAR but not BPAR in ~
                                            markup-table,~|~x0."
                                           markup-table))
                                   (print-par-entry entry2 fmt-alist
                                                    char-subst-table
                                                    channel state)))))
                     (print-doc-string-part1
                      str
                      next-i
                      maximum
                      de-indent
                      prefix
                      markup-table
                      char-subst-table
                      fmt-alist
                      channel name state
                      ln undocumented-file vp))))))
               ((and (integerp ln)
                     (< (1+ i) maximum)
                     (eql (char str (1+ i)) #\Newline)
                     (<= (f-get-global 'more-doc-min-lines state) (+ 2 ln)))
                (pprogn
                 (newline channel state)
                 (newline channel state)
                 (save-more-doc-state str
                                      (or (use-doc-string-de-indent
                                           de-indent
                                           str
                                           (+ 2 i)
                                           maximum)
                                          (+ 2 i))
                                      maximum de-indent prefix
                                      state)
                 (mv ln state)))
               ((and (integerp ln)
                     (<= (f-get-global 'more-doc-max-lines state) (1+ ln)))
                (pprogn
                 (newline channel state)
                 (save-more-doc-state str
                                      (or (use-doc-string-de-indent
                                           de-indent
                                           str
                                           (+ 1 i)
                                           maximum)
                                          (+ 1 i))
                                      maximum de-indent prefix
                                      state)
                 (mv ln state)))
               (t
                (pprogn (newline channel state)
                        (princ-prefix prefix channel state)
                        (print-doc-string-part1
                         str
                         (or (use-doc-string-de-indent de-indent
                                                       str (1+ i) maximum)
                             (1+ i))
                         maximum
                         de-indent
                         prefix
                         markup-table
                         char-subst-table
                         fmt-alist
                         channel name state
                         (if (integerp ln) (1+ ln) ln)
                         undocumented-file vp))))))
            (t (pprogn (princ$ (let ((temp (assoc c char-subst-table)))
                                 (if temp
                                     (coerce (cdr temp) 'string)
                                   c))
                               channel state)
                       (print-doc-string-part1 str (+ 1 i) maximum
                                               de-indent
                                               prefix markup-table
                                               char-subst-table
                                               fmt-alist
                                               channel name state ln
                                               undocumented-file vp))))))
        (t (pprogn
            (newline channel state)
            (save-more-doc-state str i maximum de-indent prefix state)
            (mv ln state)))))

(defun print-doc-string-part-mv
  (i str prefix markup-table char-subst-table fmt-alist
     channel name ln undocumented-file vp state)

; Str is a doc string and i is a part number, 0, 1, or 2.  We print the ith
; part of the string to channel.  We embed non-empty part 1's between a pair of
; newlines.

; When ln is :par, we interpret two consecutive blank lines as calling for a
; paragraph marker, in the sense described in the comments in
; print-doc-string-part1.  When ln is t, we print the entire part; see
; print-doc-string-part1.  Note that ln is ignored when i is 0.

; We return (mv new-ln state), where new-ln is the final value of ln.  Normally
; we will not need new-ln, but it is useful when printing part 1 followed by
; part 2 in the case that a preformatted environment spans the two parts, e.g.,
; "~bv[]...~/...~ev[]".  Typically we find this with "Example Forms" followed
; by "General Form".  We use the new-ln value in file doc/write-acl2-html.lisp,
; function write-a-doc-section (as of 1/12/2011).

  (let ((b-entry (assoc-string-equal "BPAR" markup-table))
        (e-entry (assoc-string-equal "EPAR" markup-table)))
    (pprogn
     (prog2$ (or (iff b-entry e-entry)
                 (er hard 'print-doc-string-part
                     "Found ~x0 but not ~x1 in markup-table,~|~x2."
                     (if b-entry "BPAR" "EPAR")
                     (if b-entry "EPAR" "BPAR")
                     markup-table))
             (cond ((and (not (eql i 0))
                         b-entry
                         (not (eq ln :par-off)))
                    (print-par-entry b-entry fmt-alist char-subst-table channel
                                     state))
                   (t state)))
     (mv-let
      (new-ln state)
      (let ((k (scan-to-doc-string-part i str))
            (maximum (length str)))
        (cond ((= i 1)
               (if (or (= k maximum)
                       (and (eql (char str k) #\~)
                            (< (1+ k) maximum)
                            (eql (char str (1+ k)) #\/)))

; If the part we are trying to print is empty, then don't do anything.
; except save the more doc state.

                   (pprogn (save-more-doc-state
                            str
                            (scan-past-whitespace str (+ 2 k) maximum)
                            maximum
                            (get-doc-string-de-indent str)
                            prefix
                            state)
                           (mv ln state))

; Otherwise, put out a newline first and then do it.  This elaborate
; code is here to prevent us from putting out an unnecessary newline.

                 (pprogn (princ-prefix prefix channel state)
                         (newline channel state)
                         (princ-prefix prefix channel state)
                         (print-doc-string-part1 str
                                                 k
                                                 maximum
                                                 (get-doc-string-de-indent str)
                                                 prefix
                                                 markup-table
                                                 char-subst-table
                                                 fmt-alist
                                                 channel
                                                 name
                                                 state
                                                 ln
                                                 undocumented-file vp))))
              (t (print-doc-string-part1 str
                                         k
                                         maximum
                                         (get-doc-string-de-indent str)
                                         prefix
                                         markup-table
                                         char-subst-table
                                         fmt-alist
                                         channel
                                         name
                                         state
                                         (if (= i 0) nil ln)
                                         undocumented-file vp))))
      (pprogn (cond ((and (not (eql i 0))
                          e-entry
                          (not (eq new-ln :par-off)))
                     (print-par-entry e-entry fmt-alist char-subst-table
                                      channel state))
                    (t state))
              (mv new-ln state))))))

(defun print-doc-string-part
  (i str prefix markup-table char-subst-table fmt-alist
     channel name ln undocumented-file vp state)
  (mv-to-state
   2
   (print-doc-string-part-mv i str prefix markup-table char-subst-table
                             fmt-alist channel name ln undocumented-file vp
                             state)))

(defun get-doc-section (section alist)
  (cond ((null alist) nil)
        ((and (equal section (cadar alist))
              (not (equal section (caar alist))))
         (cons (car alist)
               (get-doc-section section (cdr alist))))
        (t (get-doc-section section (cdr alist)))))

(defmacro pstate-global-let* (bindings body)

; This macro is useful when you want the effect of state-global-let*
; but you are in a situation in which you are working only with state
; and not with error/val/state triples.

  `(mv-let (erp val state)
           (state-global-let* ,bindings
                              (pprogn ,body (value nil)))
           (declare (ignore erp val))
           state))

(mutual-recursion

(defun print-doc (name n prefix
                       markup-table char-subst-table fmt-alist
                       channel state)

; Name is either an atom (in which case we look it up in the documentation
; alist) -- it must be there -- or it is a doc-tuple from the alist.
; N should be either 0, 1, or 2.  We print the level 0, 1, or 2 for
; doc-tuple.  We assume that we are printing into col 0.  We always
; end at col 0.

  (let ((doc-tuple
         (cond
          ((atom name)
           (assoc-equal name (global-val 'documentation-alist (w state))))
          (t name)))
        (start-column (f-get-global 'print-doc-start-column state)))
    (cond
     ((= n 0)
      (pprogn
       (princ-prefix prefix channel state)
       (mv-let (col state)
               (splat-atom (cond
                            ((symbolp (car doc-tuple))
                             (apply-char-subst-table
                              (car doc-tuple)
                              char-subst-table
                              (car doc-tuple)))
                            ((stringp (car doc-tuple))
                             (apply-char-subst-table
                              (car doc-tuple)
                              char-subst-table
                              nil))
                            (t (car doc-tuple)))
                           (print-base) (print-radix)
                           2
                           (length-prefix prefix)
                           channel state)
               (pprogn
                (cond ((and start-column (>= col start-column))
                       (let ((length-prefix (length-prefix prefix)))
                         (pprogn
                          (newline channel state)
                          (princ-prefix prefix channel state)
                          (spaces (- start-column length-prefix)
                                  length-prefix channel state))))
                      (t (spaces (if start-column (- start-column col) 2)
                                 col channel state)))
                (print-doc-string-part 0 (cadddr doc-tuple)
                                       prefix
                                       markup-table
                                       char-subst-table
                                       fmt-alist
                                       channel
                                       name
                                       nil
                                       nil
                                       nil
                                       state)))))
     ((= n 1)
      (pprogn
       (print-doc-string-part 1 (cadddr doc-tuple)
                              prefix
                              markup-table
                              char-subst-table
                              fmt-alist
                              channel name nil nil nil state)
       (cond
        ((caddr doc-tuple)
         (pprogn
          (princ-prefix prefix channel state)
          (newline channel state)
          (princ-prefix prefix channel state)
          (princ$ "Subtopics (listed alphabetically):" channel state)
          (newline channel state)
          (pstate-global-let*
           ((more-doc-state (f-get-global 'more-doc-state state)))
           (print-doc-lst (merge-sort-alpha-< (caddr doc-tuple))
                          (cons prefix 1)
                          markup-table
                          char-subst-table
                          fmt-alist
                          channel state))
          (princ-prefix prefix channel state)
          (princ$ "[end of subtopics]" channel state)
          (newline channel state)))
        (t state))))
     (t (pprogn
         (princ-prefix prefix channel state)
         (print-doc-string-part 2 (cadddr doc-tuple)
                                prefix markup-table char-subst-table
                                fmt-alist
                                channel name nil nil nil state))))))

(defun print-doc-lst (lst prefix
                          markup-table char-subst-table fmt-alist
                          channel state)
  (cond ((null lst) state)
        (t (pprogn (print-doc (car lst) 0 prefix markup-table char-subst-table
                              fmt-alist
                              channel state)
                   (print-doc-lst (cdr lst) prefix markup-table
                                  char-subst-table
                                  fmt-alist
                                  channel state)))))

)

; Now we implement the DWIM feature of doc, which prints out the
; near-misses for an alleged (but erroneous) documentation topic.

(defun degree-of-match2 (ch1 ch2 str i maximum)
  (cond ((< (1+ i) maximum)
         (if (and (eql ch1 (normalize-char (char str i) nil))
                  (eql ch2 (normalize-char (char str (1+ i)) nil)))
             1
             (degree-of-match2 ch1 ch2 str (1+ i) maximum)))
        (t 0)))

(defun degree-of-match1 (pat-lst str maximum)
  (cond ((null pat-lst) 0)
        ((null (cdr pat-lst)) 0)
        (t (+ (degree-of-match2 (car pat-lst) (cadr pat-lst) str 0 maximum)
              (degree-of-match1 (cdr pat-lst) str maximum)))))

(defun degree-of-match (pat-lst str)

; Pat-lst is a normalized string (with hyphen-is-space nil).  We
; normalize str similarly and compute the degree of match between
; them.  The answer is a rational between 0 and 1.  The number is just
; n divided by (length pat)-1, where n is the number of adjacent
; character pairs in pat that occur adjacently in str.  This is just
; a Royal Kludge that seems to work.

  (if (< (length pat-lst) 2)
      0
      (/ (degree-of-match1 pat-lst str (length str))
         (1- (length pat-lst)))))

(defun find-likely-near-misses (pat-lst alist)

; Alist is the documentation-alist.  Pat-lst is a normalized string
; (with hyphen-is-space nil).  We collect the cars of the pairs in
; alist that have a degree of match of more than one half.  Again, an
; utter kludge.

  (cond ((null alist) nil)
        (t (let ((d (degree-of-match pat-lst
                                     (if (stringp (caar alist))
                                         (caar alist)
                                         (symbol-name (caar alist))))))
             (cond ((<= d 1/2)
                    (find-likely-near-misses pat-lst (cdr alist)))
                   (t (cons (cons d (caar alist))
                            (find-likely-near-misses pat-lst
                                                     (cdr alist)))))))))

(defun print-doc-dwim (name ctx state)
  (let ((lst (merge-sort-car->
              (find-likely-near-misses
               (normalize-string
                (if (stringp name) ; impossible after Version_6.3
                    name
                    (symbol-name name))
                nil)
               *acl2-system-documentation*))))
    (er soft ctx
        "There is no documentation for ~x0.~#1~[~/  A similar documented name ~
         is ~&2.~/  Similar documented names are ~&2.~]~|~%NOTE: See also ~
         :DOC finding-documentation."
        name
        (zero-one-or-more (length lst))
        (strip-cdrs lst))))

(defun end-doc (channel state)
  (cond
   ((f-get-global 'more-doc-state state)
    (pprogn (princ$ "(type :more for more, :more! for the rest)" channel state)
            (newline channel state)
            (value :invisible)))
   (t (pprogn (princ$
               (if (hons-enabledp state)
                   "  " ; Boyer preference
                 "*-")
               channel state)
              (newline channel state)
              (value :invisible)))))

(defun legacy-doc-fn (name state)
  (cond
   ((not (symbolp name))
    (er soft :doc
        ":DOC requires a symbol"))
   (t
    (io? temporary nil (mv erp val state)
         (name)
         (let* ((channel (standard-co state))
                (ld-keyword-aliases (ld-keyword-aliases state))
                (temp (if (keywordp name)
                          (assoc-eq name ld-keyword-aliases)
                        nil))
                (doc-tuple (access-doc-string-database name state)))
           (cond
            ((or temp
                 (null doc-tuple))
             (let ((temp (cond
                          ((symbolp name)
                           (assoc-eq (intern (symbol-name name) "KEYWORD")
                                     ld-keyword-aliases))
                          ((stringp name)
                           (assoc-eq (intern name "KEYWORD")
                                     ld-keyword-aliases))
                          (t nil))))
               (cond
                ((null temp)
                 (print-doc-dwim name :doc state))
                (t
                 (mv-let
                  (col state)
                  (fmt1 "~@0~x1 is ~#2~[a~/an~] ~n3 input alias for ~x4.~%~%"
                        (list (cons #\0 (doc-prefix state))
                              (cons #\1 (car temp))
                              (cons #\2 (if (member (cadr temp) '(8 18)) 1 0))
                              (cons #\3 (cadr temp))
                              (cons #\4 (caddr temp)))
                        0 channel state nil)
                  (declare (ignore col))
                  (cond ((and (symbolp (caddr temp))
                              (access-doc-string-database (caddr temp) state))
                         (legacy-doc-fn (caddr temp) state))
                        (t (value :invisible))))))))
            (t (pprogn (print-doc doc-tuple 0 (doc-prefix state)
                                  (doc-markup-table state)
                                  (doc-char-subst-table state)
                                  (doc-fmt-alist state)
                                  channel state)
                       (print-doc doc-tuple 1 (doc-prefix state)
                                  (doc-markup-table state)
                                  (doc-char-subst-table state)
                                  (doc-fmt-alist state)
                                  channel state)
                       (newline channel state)
                       (end-doc channel state)))))))))

(defun doc-fn (name state)
  (cond
   ((not (symbolp name))
    (er soft 'doc
        "Documentation topics are symbols."))
   (t (let ((entry (assoc name *acl2-system-documentation*)))
        (cond (entry (mv-let
                      (col state)
                      (fmt1 "Parent~#0~[~/s~]: ~&0.~|~%"
                            (list (cons #\0 (cadr entry)))
                            0 *standard-co* state nil)
                      (declare (ignore col))
                      (pprogn (princ$ (caddr entry) *standard-co* state)
                              (newline *standard-co* state)
                              (value :invisible))))
              (t (print-doc-dwim name :doc state)))))))

(defun more-fn (ln state)
  (io? temporary nil (mv erp val state)
       (ln)
       (let ((more-doc-state (f-get-global 'more-doc-state state))
             (channel (standard-co state)))
         (cond
          (more-doc-state
           (pprogn
            (princ-prefix (car (cddddr more-doc-state)) channel state)
            (mv-to-state
             2
             (print-doc-string-part1 (car more-doc-state)
                                     (cadr more-doc-state)
                                     (caddr more-doc-state)
                                     (cadddr more-doc-state)
                                     (car (cddddr more-doc-state))
                                     (doc-markup-table state)
                                     (doc-char-subst-table state)
                                     (doc-fmt-alist state)
                                     channel "the current item" state ln nil
                                     nil))
            (end-doc channel state)))
          (t (end-doc channel state))))))

(defun doc!-fn (name state)
  (cond
   ((not (symbolp name))
    (er soft :doc!
        ":DOC! requires a symbol"))
   (t
    (io? temporary nil (mv erp val state)
         (name)
         (let ((channel (standard-co state))
               (doc-tuple (access-doc-string-database name state)))
           (cond ((null doc-tuple)
                  (print-doc-dwim name :doc state))
                 (t (pprogn (print-doc doc-tuple 0 (doc-prefix state)
                                       (doc-markup-table state)
                                       (doc-char-subst-table state)
                                       (doc-fmt-alist state)
                                       channel state)
                            (print-doc doc-tuple 1 (doc-prefix state)
                                       (doc-markup-table state)
                                       (doc-char-subst-table state)
                                       (doc-fmt-alist state)
                                       channel state)
                            (princ-prefix (doc-prefix state) channel state)
                            (newline channel state)
                            (more-fn t state)))))))))

(defmacro more nil
 '(more-fn 0 state))

(defmacro more! nil
  '(more-fn t state))

(defun print-doc-outline
  (name prefix markup-table char-subst-table fmt-alist
        channel state)

; Name is either an atom (in which case it must be a topic in the
; documentation alist) or else is a doc-tuple from the alist.
; This function is sort of like (doc-fn name state) except
; that it just prints the one-liner for name and then the related
; topics, while doc-fn would print the notes section too.

  (let ((doc-tuple
         (cond
          ((atom name)
           (assoc-equal name (global-val 'documentation-alist (w state))))
          (t name))))
    (pprogn (print-doc doc-tuple 0 prefix
                       markup-table char-subst-table fmt-alist
                       channel state)
            (print-doc-lst
             (merge-sort-alpha-< (caddr doc-tuple))
             (cons prefix 1)
             markup-table
             char-subst-table
             fmt-alist
             channel state)
            (princ-prefix prefix channel state)
            (princ$ " See also :MORE-DOC " channel state)
            (princ$ (car doc-tuple) channel state)
            (newline channel state))))

(defun print-doc-outline-lst (name-lst prefix
                                       markup-table char-subst-table
                                       fmt-alist
                                       channel state)
  (cond ((null name-lst) state)
        (t (pprogn (print-doc-outline (car name-lst) prefix markup-table
                                      char-subst-table
                                      fmt-alist
                                      channel state)
                   (print-doc-outline-lst (cdr name-lst)
                                          prefix markup-table char-subst-table
                                          fmt-alist
                                          channel state)))))

(defmacro legacy-doc (name)
  (list 'legacy-doc-fn name 'state))

(defmacro doc (name)

; This documentation is out of date!  It is more properly associated with
; legacy-doc, which we expect to remove.

  (list 'doc-fn name 'state))

(defmacro doc! (name)
  (list 'doc!-fn name 'state))

(defun more-doc-fn (name state)
  (cond
   ((not (symbolp name))
    (er soft :more-doc
        ":MORE-DOC requires a symbol"))
   (t
    (io? temporary nil (mv erp val state)
         (name)
         (let ((channel (standard-co state))
               (doc-tuple (access-doc-string-database name state)))
           (cond ((null doc-tuple)
                  (print-doc-dwim name :more-doc state))
                 (t (pprogn (print-doc doc-tuple 2 (doc-prefix state)
                                       (doc-markup-table state)
                                       (doc-char-subst-table state)
                                       (doc-fmt-alist state)
                                       channel state)
                            (end-doc channel state)))))))))

(defmacro more-doc (name)
  (list 'more-doc-fn name 'state))

(defun get-doc-section-symbols (alist ans)
  (cond ((null alist) ans)
        (t (get-doc-section-symbols (cdr alist)
                                    (add-to-set-eq (cadar alist) ans)))))

(defun get-docs-apropos1 (pat-lst alist ans)
  (cond ((null alist) ans)
        ((string-search pat-lst (cadddr (car alist)) 'hyphen-is-space)
         (get-docs-apropos1 pat-lst (cdr alist) (cons (car alist) ans)))
        (t (get-docs-apropos1 pat-lst (cdr alist) ans))))

(defun get-docs-apropos (pat alist)
  (reverse (get-docs-apropos1 (normalize-string pat t) alist nil)))

(defun docs-fn (x state)
  (io? temporary nil (mv erp val state)
       (x)
       (let ((channel (standard-co state)))
         (cond
          ((eq x '*)
           (pprogn
            (fms "Documentation Sections~%~*0:DOC sect lists the contents of ~
                  section sect.~%"
                 (list
                  (cons #\0
                        (list "" "~ ~F*~%" "~ ~F*~%" "~ ~F*~%"
                              (merge-sort-alpha-<
                               (get-doc-section-symbols
                                (global-val 'documentation-alist (w state))
                                nil)))))
                 channel state nil)
            (f-put-global 'more-doc-state nil state)
            (end-doc channel state)))
          ((eq x '**)
           (pprogn
            (print-doc-outline-lst
             (merge-sort-alpha-<
              (get-doc-section-symbols
               (global-val 'documentation-alist (w state))
               nil))
             (doc-prefix state)
             (doc-markup-table state)
             (doc-char-subst-table state)
             (doc-fmt-alist state)
             channel
             state)
            (f-put-global 'more-doc-state nil state)
            (end-doc channel state)))
          ((symbolp x)
           (legacy-doc-fn x state))
          ((stringp x)
           (let ((doc-tuples
                  (get-docs-apropos x
                                    (global-val 'documentation-alist
                                                (w state)))))
             (pprogn
              (fms "Documentation Topics Apropos ~y0~%"
                   (list (cons #\0 x))
                   channel state nil)
              (print-doc-lst doc-tuples (doc-prefix state)
                             (doc-markup-table state)
                             (doc-char-subst-table state)
                             (doc-fmt-alist state)
                             channel state)
              (newline (standard-co state) state)
              (f-put-global 'more-doc-state nil state)
              (end-doc channel state))))
          (t (er soft :docs "Unrecognized argument, ~x0." x))))))

(defmacro docs (x)
  (list 'docs-fn x 'state))

(defun print-top-doc-topics (doc-alist channel state)
  (cond
   ((endp doc-alist)
    (newline channel state))
   ((eq (car (car doc-alist))
        (cadr (car doc-alist)))
    (pprogn (newline channel state)
            (princ-prefix (doc-prefix state) channel state)
            (princ$ (car (car doc-alist)) channel state)
            (print-top-doc-topics (cdr doc-alist) channel state)))
   (t (print-top-doc-topics (cdr doc-alist) channel state))))

(defun help-fn (state)
  (io? temporary nil (mv erp val state)
       nil
       (let ((channel (standard-co state)))
         (pprogn
          (princ-prefix (doc-prefix state) channel state)
          (princ$ (f-get-global 'acl2-version state) channel state)
          (princ$ " Help.  See also :MORE-DOC help." channel state)
          (newline channel state)

; At one time we printed an outline, and we may choose to do so again some day.
; But for now, we simply print the topics, and a message about them.

;      (print-doc-outline-lst '(events documentation history other)
;                             (doc-prefix state)
;                             (doc-markup-table state)
;                             (doc-char-subst-table state)
;                             (doc-fmt-alist state)
;                             channel state)

          (f-put-global 'more-doc-state nil state)
          (princ-prefix (doc-prefix state) channel state)
          (newline channel state)
          (princ-prefix (doc-prefix state) channel state)
          (princ$
           "For information about name, type :DOC name.  For an introduction"
           channel
           state)
          (newline channel state)
          (princ-prefix (doc-prefix state) channel state)
          (princ$
           "to the ACL2 online documentation, type :DOC documentation.  For"
           channel state)
          (newline channel state)
          (princ-prefix (doc-prefix state) channel state)
          (princ$ "release notes, type :DOC release-notes." channel state)
          (newline channel state)
          (princ-prefix (doc-prefix state) channel state)
          (newline channel state)
          (princ-prefix (doc-prefix state) channel state)
          (princ$ "Type (a!) to abort to the ACL2 top-level from anywhere."
                  channel state)
          (newline channel state)
          (princ-prefix (doc-prefix state) channel state)
          (princ$ "Type (p!) to pop up one ACL2 LD level from anywhere."
                  channel state)
          (newline channel state)
          (princ-prefix (doc-prefix state) channel state)
          (princ$ "The top-level topics in the documentatation are:"
                  channel state)
          (newline channel state)
          (princ-prefix (doc-prefix state) channel state)
          (print-top-doc-topics (global-val 'documentation-alist (w state))
                                channel state)
          (princ$ "*-" channel state)
          (newline channel state)
          (value :invisible)))))

(defmacro help nil
  '(help-fn state))

(defun trans-fn (form state)
  (io? temporary nil (mv erp val state)
       (form)
       (let ((wrld (w state))
             (channel (standard-co state)))
         (mv-let (flg val bindings state)
                 (translate1 form
                             :stobjs-out
                             '((:stobjs-out . :stobjs-out))
                             t ;;; known-stobjs = t (user interface)
                             'top-level wrld state)
                 (cond ((null flg)
                        (pprogn
                         (fms "~Y01~%=> ~y2~|~%"
                              (list
                               (cons #\0 val)
                               (cons #\1 (term-evisc-tuple nil state))
                               (cons #\2
                                     (prettyify-stobjs-out
                                      (translate-deref :stobjs-out bindings))))
                              channel state nil)
                         (value :invisible)))
                       (t
                        (er soft 'trans
                            ":Trans has failed.  Consider trying :trans! ~
                             instead; see :DOC trans!.")))))))

(defun trans!-fn (form state)
  (io? temporary nil (mv erp val state)
       (form)
       (let ((wrld (w state))
             (channel (standard-co state)))
         (mv-let (flg val bindings state)
                 (translate1 form
                             t
                             nil
                             t ;;; known-stobjs = t (user interface)
                             'top-level wrld state)
                 (declare (ignore bindings))
                 (cond ((null flg)
                        (pprogn
                         (fms "~Y01~|~%"
                              (list (cons #\0 val)
                                    (cons #\1 (term-evisc-tuple nil state)))
                              channel state nil)
                         (value :invisible)))
                       (t (value :invisible)))))))

(defmacro trans (form)
  (list 'trans-fn form 'state))

(defmacro trans! (form)
  (list 'trans!-fn form 'state))

(defun trans1-fn (form state)
  (if (and (consp form)
           (true-listp form)
           (symbolp (car form))
           (getprop (car form) 'macro-body nil 'current-acl2-world (w state)))
      (macroexpand1 form 'top-level state)
    (er soft 'top-level
        "TRANS1 may only be applied to a form (m t1 ... tk) where m is a ~
         symbol with a 'macro-body property.")))

(defmacro trans1 (form)
  `(trans1-fn ,form state))

(defun tilde-*-props-fn-phrase1 (alist)
  (cond ((null alist) nil)
        (t (cons (msg "~y0~|~ ~y1~|"
                      (caar alist)
                      (cdar alist))
                 (tilde-*-props-fn-phrase1 (cdr alist))))))

(defun tilde-*-props-fn-phrase (alist)
  (list "none" "~@*" "~@*" "~@*"
        (tilde-*-props-fn-phrase1 alist)))

(defun props-fn (sym state)
  (cond ((symbolp sym)
         (io? temporary nil (mv erp val state)
              (sym)
              (pprogn
               (fms "ACL2 Properties of ~y0:~%~*1~%"
                    (list (cons #\0 sym)
                          (cons #\1
                                (tilde-*-props-fn-phrase
                                 (getprops sym
                                           'current-acl2-world
                                           (w
                                            state)))))
                    (standard-co state)
                    state
                    (ld-evisc-tuple state))
               (value :invisible))))
        (t (er soft :props
               "~x0 is not a symbol."
               sym))))

(defmacro props (sym)
  (list 'props-fn sym 'state))

; We now develop walkabout, an extremely useful tool for exploring

(defun walkabout-nth (i x)

; Enumerate the elements of the print representation of the list x,
; from 0.  Include the possible dot as an element.

;      Example x                  Example x
;      (a b c . d)                (a b c d)
; i     0 1 2 3 4                  0 1 2 3

; We fetch the ith element.  But how do we return the dot?  We
; actually return two values (mv dotp xi).  If dotp is true, we're
; really returning the dot.  In this case xi is the character #\.,
; just in case we want to pretend there was a dot there and try
; to go into it or return it.  If dotp is false, then xi is the
; corresponding element of x.

  (cond ((int= i 0)
         (cond ((atom x)
                (mv t #\.))
               (t (mv nil (car x)))))
        ((atom x) (mv nil x))
        (t (walkabout-nth (1- i) (cdr x)))))

(defun walkabout-ip (i x)

; See the examples above showing how we enumerate the elements of the
; print representation of x.  We return t if i is a legal index
; and nil otherwise.

  (cond ((null x) nil)
        ((atom x) (or (int= i 0) (int= i 1)))
        ((int= i 0) t)
        (t (walkabout-ip (1- i) (cdr x)))))

(defun walkabout-huh (state)
  (pprogn (princ$ "Huh?" *standard-co* state)
          (newline *standard-co* state)
          (mv 'continue nil state)))

(defun walkabout1 (i x state intern-flg evisc-tuple alt-evisc-tuple)

; X is a list and we are at position i within it.  This function
; reads commands from *standard-oi* and moves us around in x.  This
; function is inefficient in that it computes the current object,
; xi, from i and x each time.  It would be better to maintain the
; current tail of x so nx could be fast.

  (mv-let
   (dotp xi)
   (walkabout-nth i x)
   (pprogn
    (mv-let (col state)
            (fmt1 (if dotp ".~%:" "~y0~|:")
                  (list (cons #\0 xi))
                  0
                  *standard-co* state
                  (if (eq alt-evisc-tuple :none)
                      evisc-tuple
                    alt-evisc-tuple))
            (declare (ignore col))
            state)
    (mv-let
     (signal val state)
     (mv-let
      (erp obj state)
      (state-global-let*
       ((infixp nil))
       (read-object *standard-oi* state))
      (cond
       (erp (mv 'exit nil state))
       (t (case (if intern-flg
                    (intern (symbol-name obj) "ACL2")
                    obj)
                (nx (if (walkabout-ip (1+ i) x)
                        (mv 'continue (1+ i) state)
                        (walkabout-huh state)))
                (bk (if (= i 0)
                        (walkabout-huh state)
                        (mv 'continue (1- i) state)))
                (0 (mv 'up nil state))
                (pp (mv 'continue-fullp nil state))
                (= (mv 'exit xi state))
                (q (mv 'exit :invisible state))
                (otherwise
                 (cond
                  ((and (integerp obj) (> obj 0))
                   (cond
                    ((atom xi)
                     (walkabout-huh state))
                    ((walkabout-ip (1- obj) xi)
                     (walkabout1 (1- obj) xi state intern-flg evisc-tuple
                                 :none))
                    (t (walkabout-huh state))))
                  ((and (consp obj)
                        (eq (car obj) 'pp))
                   (mv-let (print-level print-length)
                           (let ((args (cdr obj)))
                             (case-match args
                               ((print-level print-length)
                                (mv print-level print-length))
                               ((n) (mv n n))
                               (& (mv :bad nil))))
                           (cond ((and (or (natp print-level)
                                           (null print-level))
                                       (or (natp print-length)
                                           (null print-length)))
                                  (mv 'continue-fullp
                                      (evisc-tuple print-level print-length
                                                   nil nil)
                                      state))
                                 (t (walkabout-huh state)))))
                  ((and (consp obj)
                        (eq (car obj) '=)
                        (consp (cdr obj))
                        (symbolp (cadr obj))
                        (null (cddr obj)))
                   (pprogn
                    (f-put-global 'walkabout-alist
                                  (cons (cons (cadr obj) xi)
                                        (f-get-global 'walkabout-alist
                                                      state))
                                  state)
                    (mv-let (col state)
                            (fmt1 "(walkabout= ~x0) is~%"
                                  (list (cons #\0 (cadr obj)))
                                  0 *standard-co* state (ld-evisc-tuple state))
                            (declare (ignore col))
                            (mv 'continue nil state))))
                  (t (walkabout-huh state))))))))
     (cond
      ((eq signal 'continue)
       (walkabout1 (or val i) x state intern-flg evisc-tuple :none))
      ((eq signal 'up)
       (mv 'continue nil state))
      ((eq signal 'continue-fullp)
       (walkabout1 i x state intern-flg evisc-tuple val))
      (t (mv 'exit val state)))))))

(defun walkabout (x state)
  (pprogn
   (fms "Commands:~|0, 1, 2, ..., nx, bk, pp, (pp n), (pp lev len), =, (= ~
         symb), and q.~%~%"
        nil *standard-co* state nil)
   (mv-let (signal val state)
           (walkabout1 0 (list x)
                       state
                       (not (equal (current-package state) "ACL2"))
                       (evisc-tuple 2 3 nil nil)
                       :none)
           (declare (ignore signal))
           (value val))))

(defun walkabout=-fn (var state)
  (cond ((symbolp var)
         (cdr (assoc-eq var (f-get-global 'walkabout-alist state))))
        (t nil)))

(defmacro walkabout= (var)
  `(walkabout=-fn ',var state))

; Here we develop the code for inspecting the results of using OBDDs.

(defun lookup-bddnote (cl-id bddnotes)
  (cond
   ((endp bddnotes) nil)
   ((equal cl-id (access bddnote (car bddnotes) :cl-id))
    (car bddnotes))
   (t (lookup-bddnote cl-id (cdr bddnotes)))))

(defun update-bddnote-with-term (cl-id term bddnotes)
  (cond
   ((endp bddnotes)
    (er hard 'update-bddnote-with-term
        "Expected to find clause with name ~@0, but did not!"
        (tilde-@-clause-id-phrase cl-id)))
   ((equal cl-id (access bddnote (car bddnotes) :cl-id))
    (cons (change bddnote (car bddnotes)
                  :term term)
          (cdr bddnotes)))
   (t (cons (car bddnotes)
            (update-bddnote-with-term cl-id term (cdr bddnotes))))))

(defmacro show-bdd (&optional str
                              goal-query-response
                              counterex-query-response
                              term-query-response)

; Not documented below is our use of evisc-tuples that hardwire the print-level
; and print-length, rather than using say the abbrev-evisc-tuple.  That seems
; reasonable given the design of show-bdd, which allows printing terms in full
; after the user sees their abbreviated versions.  It could add more confusion
; than clarity for us to add such documentation below, but if anyone complains,
; then we should probably do so.

  (cond
   ((not (symbolp goal-query-response))
    `(er soft 'show-bdd
         "The optional second argument of show-bdd must be a symbol, but ~x0 ~
          is not."
         ',goal-query-response))
   ((not (symbolp counterex-query-response))
    `(er soft 'show-bdd
         "The optional third argument of show-bdd must be a symbol, but ~x0 ~
          is not."
         ',counterex-query-response))
   ((not (symbolp term-query-response))
    `(er soft 'show-bdd
         "The optional fourth argument of show-bdd must be a symbol, but ~x0 ~
          is not."
         ',term-query-response))
   (t
    `(show-bdd-fn ,str
                  ',goal-query-response
                  ',counterex-query-response
                  ',term-query-response
                  state))))

(defun show-bdd-goal (query-response bddnote chan state)
  (let* ((goal (untranslate (access bddnote bddnote :goal-term) t (w state))))
    (pprogn
     (fms "BDD input term (derived from ~@1):~|"
          (list (cons #\1 (tilde-@-clause-id-phrase
                           (access bddnote bddnote :cl-id))))
          (standard-co state) state nil)
     (cond
      (query-response
       state)
      (t
       (fms "~q2~|"
            (list (cons #\2 goal))
            (standard-co state) state (evisc-tuple 5 7 nil nil))))
     (cond
      ((equal goal (eviscerate-simple goal 5 7 nil
                                      (table-alist 'evisc-table (w state))
                                      nil))
       state)
      (t
       (mv-let (erp ans state)
               (if query-response
                   (let ((query-response
                          (intern (symbol-name query-response) "KEYWORD")))
                     (value (case query-response
                                  (:w :w)
                                  (:nil nil)
                                  (otherwise t))))
                 (acl2-query
                  :show-bdd
                  '("Print the goal in full?"
                    :n nil :y t :w :w
                    :? ("Y will print the goal in full.  W will put you in a ~
                         structural display editor that lets you type a ~
                         positive integer N to dive to the Nth element of the ~
                         current list, 0 to go up a level, PP to print the ~
                         current object in full, and Q to quit."
                        :n nil :y t :w :w))
                  nil
                  state))
               (declare (ignore erp))
               (cond ((eq ans :w)
                      (mv-let (erp ans state)
                              (walkabout goal state)
                              (declare (ignore erp ans))
                              state))
                     (ans (fms "~x0~|"
                               (list (cons #\0 goal))
                               chan state nil))
                     (t state))))))))

(defun merge-car-term-order (l1 l2)
  (cond ((null l1) l2)
        ((null l2) l1)
        ((term-order (car (car l1)) (car (car l2)))
         (cons (car l1) (merge-car-term-order (cdr l1) l2)))
        (t (cons (car l2) (merge-car-term-order l1 (cdr l2))))))

(defun merge-sort-car-term-order (l)
  (cond ((null (cdr l)) l)
        (t (merge-car-term-order (merge-sort-car-term-order (evens l))
                                 (merge-sort-car-term-order (odds l))))))

(defun falsifying-pair-p (term val asst)
  (cond
   ((endp asst) nil)
   ((equal term (caar asst))
    (or (and (null val) (equal (cadar asst) *some-non-nil-value*))
        (and (null (cadar asst)) (equal val *some-non-nil-value*))
        (falsifying-pair-p term val (cdr asst))))
   (t nil)))

(defun bogus-falsifying-assignment-var (asst)

; Asst is assumed to be sorted by car.

  (cond
   ((endp asst) nil)
   ((falsifying-pair-p (caar asst) (cadar asst) (cdr asst))
    (caar asst))
   (t
    (bogus-falsifying-assignment-var (cdr asst)))))

(defun show-falsifying-assignment (query-response bddnote chan state)
  (let ((cst (access bddnote bddnote :cst)))
    (cond
     ((cst-tp cst)
      (fms "There is no falsifying assignment, since ~@0 was proved."
           (list (cons #\0 (tilde-@-clause-id-phrase
                            (access bddnote bddnote :cl-id))))
           chan state nil))
     (t
      (let ((asst (falsifying-assignment
                   cst
                   (access bddnote bddnote :mx-id))))
        (pprogn (let ((var (bogus-falsifying-assignment-var
                            (merge-sort-car-term-order asst))))
                  (cond (var (fms "WARNING:  The term ~p0 is assigned both to ~
                                   nil and a non-nil value in the following ~
                                   assignment.  This generally occurs because ~
                                   the term is not known to be Boolean.  ~
                                   Consider adding appropriate booleanp or ~
                                   boolean-listp hypotheses. See :DOC ~
                                   bdd-introduction."
                                  (list (cons #\0 var))
                                  (standard-co state) state
                                  (evisc-tuple 5 7 nil nil)))
                        (t state)))
                (fms "Falsifying constraints:~%"
                     nil chan state nil)
                (cond
                 (query-response
                  state)
                 (t
                  (fms "~x0~|"
                       (list (cons #\0 asst))
                       chan state
                       (evisc-tuple 5 (max 7 (length asst)) nil nil))))
                (cond
                 ((equal asst
                         (eviscerate-simple
                          asst 5 (max 7 (length asst)) nil
                          (table-alist 'evisc-table (w state))
                          nil))
                  state)
                 (t
                  (mv-let
                   (erp ans state)
                   (if query-response
                       (let ((query-response
                              (intern (symbol-name query-response) "KEYWORD")))
                         (value (case query-response
                                      (:w :w)
                                      (:nil nil)
                                      (otherwise t))))
                     (acl2-query
                      :show-bdd
                      '("Print the falsifying constraints in full?"
                        :n nil :y t :w :w
                        :? ("Y will print the constraints in full.  W will put ~
                             you in a structural display editor that lets you ~
                             type a positive integer N to dive to the Nth ~
                             element of the current list, 0 to go up a level, ~
                             PP to print the current object in full, and Q to ~
                             quit."
                            :n nil :y t :w :w))
                      nil
                      state))
                   (declare (ignore erp))
                   (cond ((eq ans :w)
                          (mv-let (erp ans state)
                                  (walkabout asst state)
                                  (declare (ignore erp ans))
                                  state))
                         (ans (fms "~x0~|"
                                   (list (cons #\0 asst))
                                   chan state nil))
                         (t state)))))))))))

(defun show-bdd-term (query-response bddnote chan state)
  (let* ((orig-term (access bddnote bddnote :term))
         (term (if orig-term
                   orig-term
                 (mv-let (term cst-array)
                         (decode-cst (access bddnote bddnote
                                             :cst)
                                     (leaf-cst-list-array
                                      (access bddnote bddnote
                                              :mx-id)))
                         (declare (ignore cst-array))
                         term))))
    (pprogn
     (cond ((null orig-term)
            (f-put-global 'bddnotes
                          (update-bddnote-with-term
                           (access bddnote bddnote :cl-id)
                           term
                           (f-get-global 'bddnotes state))
                          state))
           (t state))
     (fms "Term obtained from BDD computation on ~@1:~|"
          (list (cons #\1 (tilde-@-clause-id-phrase
                           (access bddnote bddnote :cl-id))))
          (standard-co state) state nil)
     (cond
      (query-response
       state)
      (t
       (fms "~x2~|"
            (list (cons #\2 term))
            (standard-co state) state (evisc-tuple 5 7 nil nil))))
     (cond
      ((equal term (eviscerate-simple term 5 7 nil
                                      (table-alist 'evisc-table (w state))
                                      nil))
       state)
      (t
       (mv-let (erp ans state)
               (if query-response
                   (let ((query-response
                          (intern (symbol-name query-response) "KEYWORD")))
                     (value (case query-response
                                  (:w :w)
                                  (:nil nil)
                                  (otherwise t))))
                 (acl2-query
                  :show-bdd
                  '("Print the term in full?"
                    :n nil :y t :w :w
                    :? ("Y will print the term in full.  W will put you in a ~
                         structural display editor that lets you type a ~
                         positive integer N to dive to the Nth element of the ~
                         current list, 0 to go up a level, PP to print the ~
                         current object in full, and Q to quit."
                        :n nil :y t :w :w))
                  nil
                  state))
               (declare (ignore erp))
               (cond ((eq ans :w)
                      (mv-let (erp ans state)
                              (walkabout term state)
                              (declare (ignore erp ans))
                              state))
                     (ans (fms "~x0~|"
                               (list (cons #\0 term))
                               chan state nil))
                     (t state))))))))

(defun tilde-*-substitution-phrase1 (alist is-replaced-by-str evisc-tuple wrld)
  (cond ((null alist) nil)
        (t (cons (msg "~P01 ~s2 ~P31"
                      (untranslate (caar alist) nil wrld)
                      evisc-tuple
                      is-replaced-by-str
                      (untranslate (cdar alist) nil wrld))
                 (tilde-*-substitution-phrase1 (cdr alist)
                                               is-replaced-by-str
                                               evisc-tuple wrld)))))

(defun tilde-*-substitution-phrase (alist is-replaced-by-str evisc-tuple wrld)
  (list* "" "~@*" "~@* and " "~@*, "
         (tilde-*-substitution-phrase1 alist is-replaced-by-str evisc-tuple
                                       wrld)
         nil))

(defun show-bdd-backtrace (call-stack cst-array chan state)
  (cond
   ((endp call-stack)
    state)
   (t (mv-let
       (term-list cst-array)
       (decode-cst-lst
        (strip-cdrs (cdar call-stack))
        cst-array)
       (let ((term (untranslate (caar call-stack) nil (w state)))
             (alist (pairlis$ (strip-cars (cdar call-stack))

; Once upon a time we untranslate term-list below, but
; tilde-*-substitution-phrase does an untranslate.

                              term-list)))
         (pprogn
          (fms "~X02~|  alist: ~*1~|"
               (list (cons #\0 term)
                     (cons #\1 (tilde-*-substitution-phrase
                                alist
                                ":="
                                (evisc-tuple 5 (max 7 (length alist))
                                             nil nil)
                                (w state)))
                     (cons #\2 (evisc-tuple 5 7 nil nil)))
               chan state nil)
          (show-bdd-backtrace (cdr call-stack) cst-array chan state)))))))

(defun show-bdd-fn (str goal-query-response
                        counterex-query-response
                        term-query-response
                        state)
  (let ((bddnotes (f-get-global 'bddnotes state))
        (cl-id (parse-clause-id str))
        (separator "==============================~%"))
    (cond
     ((and str (null cl-id))
      (er soft 'show-bdd
          "The string ~x0 does not have the syntax of a goal name.  See :DOC ~
           goal-spec."
          str))
     (t
      (let ((bddnote (if cl-id ;equivalently, if str
                         (lookup-bddnote cl-id bddnotes)
                       (car bddnotes)))
            (chan (standard-co state)))
        (cond
         ((null bddnote)
          (er soft 'show-bdd
              "There is no recent record of applying BDDs~#0~[~/ to ~s1~]."
              (if str 1 0)
              (if (eq str t) "Goal" str)))
         (t
          (pprogn
            (show-bdd-goal goal-query-response
                           bddnote chan state)
            (fms "~@0" (list (cons #\0 separator)) chan state nil)
            (fms "BDD computation on ~@0 yielded ~x1 nodes.~|~@2"
                (list (cons #\0 (tilde-@-clause-id-phrase
                                 (access bddnote bddnote :cl-id)))
                      (cons #\1 (access bddnote bddnote :mx-id))
                      (cons #\2 separator))
                chan state nil)
            (cond
             ((access bddnote bddnote :err-string)
              (pprogn (fms
                       "BDD computation was aborted on ~@0, and hence there is ~
                        no falsifying assignment that can be constructed.  ~
                        Here is a backtrace of calls, starting with the ~
                        top-level call and ending with the one that led to the ~
                        abort.  See :DOC show-bdd.~|"
                       (list (cons #\0 (tilde-@-clause-id-phrase
                                        (access bddnote bddnote :cl-id))))
                       chan state nil)
                      (show-bdd-backtrace (access bddnote bddnote
                                                  :bdd-call-stack)

; Note that we will probably be building the same array as the one just below
; for show-bdd-term, but that seems a small price to pay for modularity here.

                                          (leaf-cst-list-array
                                           (access bddnote bddnote :mx-id))
                                          chan state)
                      (value :invisible)))
             (t (pprogn (show-falsifying-assignment counterex-query-response
                                                    bddnote chan state)
                        (fms "~@0" (list (cons #\0 separator)) chan state nil)
                        (show-bdd-term term-query-response bddnote chan state)
                        (value :invisible))))))))))))

(defun get-docs (lst)

; Each element of lst is a 5-tuple (name args doc edcls body).  We
; return a list in 1:1 correspondence with lst containing the docs
; (each of which is either a stringp or nil).

  (cond ((null lst) nil)
        (t (cons (third (car lst))
                 (get-docs (cdr lst))))))

; Rockwell Addition:  Now when you declare a fn to traffic in the stobj st
; the guard is automatically extended with a (stp st).

(defun get-guards2 (edcls targets wrld acc)

; Targets is a subset of (GUARDS TYPES), where we pick up expressions from
; :GUARD and :STOBJS XARGS declarations if GUARDS is in the list and we pick up
; expressions corresponding to TYPE declaraions if TYPES is in the list.

; See get-guards for an example of what edcls looks like.  We require that
; edcls contains only valid type declarations, as explained in the comment
; below about translate-declaration-to-guard-var-lst.

; We are careful to preserve the order, except that within a given declaration
; we consider :stobjs as going before :guard.  (An example is (defun load-qs
; ...) in community book books/defexec/other-apps/qsort/programs.lisp.)  Before
; Version_3.5, Jared Davis sent us the following example, for which guard
; verification failed on the guard of the guard, because the :guard conjuncts
; were unioned into the :type contribution to the guard, leaving a guard of
; (and (natp n) (= (length x) n) (stringp x)).  It seems reasonable to
; accumulate the guard conjuncts in the order presented by the user.

; (defun f (x n)
;   (declare (xargs :guard (and (stringp x)
;                               (natp n)
;                               (= (length x) n)))
;            (type string x)
;            (ignore x n))
;   t)

  (cond ((null edcls) (reverse acc))
        ((and (eq (caar edcls) 'xargs)
              (member-eq 'guards targets))

; We know (from chk-dcl-lst) that (cdar edcls) is a "keyword list"
; and so we can assoc-keyword up it looking for :GUARD.  We also know
; that there is at most one :GUARD entry.

         (let* ((temp1 (assoc-keyword :GUARD (cdar edcls)))
                (guard-conjuncts
                 (if temp1
                     (if (and (true-listp (cadr temp1))
                              (eq (car (cadr temp1)) 'AND))
                         (or (cdr (cadr temp1))
; The following (list t) avoids ignoring :guard (and).
                             (list t))
                       (list (cadr temp1)))
                   nil))
                (temp2 (assoc-keyword :STOBJS (cdar edcls)))
                (stobj-conjuncts
                 (if temp2
                     (stobj-recognizer-terms
                      (cond
                       ((symbol-listp (cadr temp2))
                        (cadr temp2))
                       ((and (cadr temp2)
                             (symbolp (cadr temp2)))
                        (list (cadr temp2)))
                       (t nil))
                      wrld)
                   nil)))
           (get-guards2 (cdr edcls)
                        targets
                        wrld
                        (rev-union-equal
                         guard-conjuncts
                         (rev-union-equal stobj-conjuncts
                                          acc)))))
        ((and (eq (caar edcls) 'type)
              (member-eq 'types targets))
         (get-guards2 (cdr edcls)
                      targets
                      wrld

; The call of translate-declaration-to-guard-var-lst below assumes that
; (translate-declaration-to-guard (cadr (car edcls)) 'var wrld) is non-nil.
; This is indeed the case, because edcls is as created by chk-defuns-tuples,
; which leads to a call of chk-dcl-lst to check that the type declarations are
; legal.

                      (rev-union-equal (translate-declaration-to-guard-var-lst
                                        (cadr (car edcls))
                                        (cddr (car edcls))
                                        wrld)
                                       acc)))
        (t (get-guards2 (cdr edcls) targets wrld acc))))

(defun get-guards1 (edcls targets wrld)
  (get-guards2 edcls targets wrld nil))

(defun get-guards (lst split-types-lst split-types-p wrld)

; Warning: see :DOC guard-miscellany for a specification of how conjuncts are
; ordered when forming the guard from :xargs and type declarations.

; Each element of lst is a 5-tuple (name args doc edcls body), where every TYPE
; declaration in edcls is valid (see get-guards2 for an explanation of why that
; is important).  We return a list in 1:1 correspondence with lst.  Each
; element is the untranslated guard or type expressions extracted from the
; edcls of the corresponding element of lst.  A typical value of edcls might be

; '((IGNORE X Y)
;   (XARGS :GUARD g1 :MEASURE m1 :HINTS ((id :USE ... :IN-THEORY ...)))
;   (TYPE ...)
;   (XARGS :GUARD g2 :MEASURE m2))

; The guard extracted from such an edcls is the conjunction of all the guards
; mentioned.

; We extract only the split-types expressions if split-types-p is true.
; Otherwise, we extract the guard expressions.  In both of these cases, the
; result depends on whether or not :split-types was assigned value t in the
; definition for the corresponding member of lst.

  (cond ((null lst) nil)
        (t (cons (let ((targets
                        (cond (split-types-p

; We are collecting type declarations for 'split-types-term properties.  Thus,
; we only collect these when the user has specified :split-types for a
; definition.

                               (and (car split-types-lst) '(types)))

; Otherwise, we are collecting terms for 'guard properties.  We skip type
; declarations when the user has specified :split-types for a definition.

                              ((car split-types-lst) '(guards))
                              (t '(guards types)))))
                   (conjoin-untranslated-terms
                    (and targets ; optimization
                         (get-guards2 (fourth (car lst)) targets wrld nil))))
                 (get-guards (cdr lst) (cdr split-types-lst) split-types-p
                             wrld)))))

(defun get-guardsp (lst wrld)

; Note that get-guards, above, always returns a list of untranslated terms as
; long as lst and that if a guard is not specified (via either a :GUARD or
; :STOBJS XARG declaration or a TYPE declaration) then *t* is used.  But in
; order to default the verify-guards flag in defuns we must be able to decide
; whether no such declaration was specified.  That is the role of this
; function.  It returns t or nil according to whether at least one of the
; 5-tuples in lst specifies a guard (or stobj) or a type.

; Thus, specification of a type is sufficient for this function to return t,
; even if :split-types t was specified.  If that changes, adjust :doc
; set-verify-guards-eagerness accordingly.

  (cond ((null lst) nil)
        ((get-guards1 (fourth (car lst)) '(guards types) wrld) t)
        (t (get-guardsp (cdr lst) wrld))))

(defconst *no-measure*
  *nil*)

(defun get-measures1 (m edcls ctx state)

; A typical edcls is given above, in the comment for get-guards.  Note that the
; :MEASURE entry is found in an XARGS declaration.  By the check in chk-dcl-lst
; we know there is at most one :MEASURE entry in each XARGS declaration.  But
; there may be more than one declaration.  If more than one measure is
; specified by this edcls, we'll cause an error.  Otherwise, we return the
; measure or the term *no-measure*, which is taken as a signal that no measure
; was specified.

; Our first argument, m, is the measure term found so far, or *no-measure* if
; none has been found.  We map down edcls and ensure that each XARGS either
; says nothing about :MEASURE or specifies m.

  (cond ((null edcls) (value m))
        ((eq (caar edcls) 'xargs)
         (let ((temp (assoc-keyword :MEASURE (cdar edcls))))
           (cond ((null temp)
                  (get-measures1 m (cdr edcls) ctx state))
                 ((equal m *no-measure*)
                  (get-measures1 (cadr temp) (cdr edcls) ctx state))
                 ((equal m (cadr temp))
                  (get-measures1 m (cdr edcls) ctx state))
                 (t (er soft ctx
                        "It is illegal to declare two different ~
                         measures for the admission of a single ~
                         function.  But you have specified :MEASURE ~
                         ~x0 and :MEASURE ~x1."
                        m (cadr temp))))))
        (t (get-measures1 m (cdr edcls) ctx state))))

(defun get-measures2 (lst ctx state)
  (cond ((null lst) (value nil))
        (t (er-let* ((m (get-measures1 *no-measure* (fourth (car lst)) ctx
                                       state))
                     (rst (get-measures2 (cdr lst) ctx state)))
                    (value (cons m rst))))))


(defun get-measures (symbol-class lst ctx state)

; This function returns a list in 1:1 correspondence with lst containing the
; user's specified :MEASUREs (or *no-measure* if no measure is specified).  We
; cause an error if more than one :MEASURE is specified within the edcls of a
; given element of lst.

; If symbol-class is program, we ignore the contents of lst and simply return
; all *no-measure*s.  See the comment in chk-acceptable-defuns where
; get-measures is called.

  (cond
   ((eq symbol-class :program)
    (value (make-list (length lst) :initial-element *no-measure*)))
   (t (get-measures2 lst ctx state))))

(defconst *no-ruler-extenders*
  :none)

(defconst *basic-ruler-extenders*
  '(mv-list return-last))

(defun get-ruler-extenders1 (r edcls default ctx wrld state)

; This function is analogous to get-measures1, but for obtaining the
; :ruler-extenders xarg.

  (cond ((null edcls) (value (if (eq r *no-ruler-extenders*)
                                 default
                               r)))
        ((eq (caar edcls) 'xargs)
         (let ((temp (assoc-keyword :RULER-EXTENDERS (cdar edcls))))
           (cond ((null temp)
                  (get-ruler-extenders1 r (cdr edcls) default ctx wrld state))
                 (t
                  (let ((r0 (cadr temp)))
                    (cond
                     ((eq r *no-ruler-extenders*)
                      (er-let*
                       ((r1

; If keywords other than :ALL, :BASIC, and :LAMBDAS are supported, then also
; change set-ruler-extenders.

                         (cond ((eq r0 :BASIC)
                                (value *basic-ruler-extenders*))
                               ((eq r0 :LAMBDAS)
                                (value (cons :lambdas
                                             *basic-ruler-extenders*)))
                               ((eq r0 :ALL)
                                (value :ALL))
                               (t (er-progn
                                   (chk-ruler-extenders r0 soft ctx wrld)
                                   (value r0))))))
                       (get-ruler-extenders1 r1 (cdr edcls) default ctx
                                             wrld state)))
                     ((equal r r0)
                      (get-ruler-extenders1 r (cdr edcls) default ctx wrld
                                            state))
                     (t (er soft ctx
                            "It is illegal to declare two different ~
                             ruler-extenders for the admission of a single ~
                             function.  But you have specified ~
                             :RULER-EXTENDERS ~x0 and :RULER-EXTENDERS ~x1."
                            r r0))))))))
        (t (get-ruler-extenders1 r (cdr edcls) default ctx wrld state))))

(defun get-ruler-extenders2 (lst default ctx wrld state)
  (cond ((null lst) (value nil))
        (t (er-let* ((r (get-ruler-extenders1
                         *no-ruler-extenders* (fourth (car lst)) default ctx
                         wrld state))
                     (rst (get-ruler-extenders2 (cdr lst) default ctx wrld
                                                state)))
                    (value (cons r rst))))))

(defmacro default-ruler-extenders-from-table (alist)
  `(let ((pair (assoc-eq :ruler-extenders ,alist)))
     (cond ((null pair)
            *basic-ruler-extenders*)
           (t (cdr pair)))))

(defun default-ruler-extenders (wrld)
  (default-ruler-extenders-from-table (table-alist 'acl2-defaults-table wrld)))

(defun get-ruler-extenders-lst (symbol-class lst ctx state)

; This function returns a list in 1:1 correspondence with lst containing the
; user's specified :RULER-EXTENDERS (or *no-ruler-extenders* if no
; ruler-extenders is specified).  We cause an error if more than one
; :RULER-EXTENDERS is specified within the edcls of a given element of lst.

; If symbol-class is program, we ignore the contents of lst and simply return
; all *no-ruler-extenders.  See the comment in chk-acceptable-defuns where
; get-ruler-extenders is called.

  (cond
   ((eq symbol-class :program)
    (value (make-list (length lst) :initial-element *no-ruler-extenders*)))
   (t (let ((wrld (w state)))
        (get-ruler-extenders2 lst (default-ruler-extenders wrld) ctx wrld
                              state)))))

(defun get-hints1 (edcls)

; A typical edcls might be

; '((IGNORE X Y)
;   (XARGS :GUARD g1 :MEASURE m1 :HINTS ((id :USE ... :IN-THEORY ...)))
;   (TYPE ...)
;   (XARGS :GUARD g2 :MEASURE m2))

; We find all the :HINTS and append them together.

  (cond ((null edcls) nil)
        ((eq (caar edcls) 'xargs)

; We know there is at most one occurrence of :HINTS in this XARGS entry.

         (let ((temp (assoc-keyword :HINTS (cdar edcls))))
           (cond ((null temp) (get-hints1 (cdr edcls)))
                 ((true-listp (cadr temp))
                  (append (cadr temp) (get-hints1 (cdr edcls))))
                 (t (er hard 'get-hints
                        "The value of :HINTS must satisfy the predicate ~x0.  ~
                         The value ~x1 is thus illegal.  See :DOC hints."
                        'true-listp
                        (cadr temp))))))
        (t (get-hints1 (cdr edcls)))))

(defun get-hints (lst)

; Lst is a list of tuples of the form (name args doc edcls body).  We
; scan the edcls in each tuple and collect all of the hints together
; into one list of hints.

  (cond ((null lst) nil)
        (t (append (get-hints1 (fourth (car lst)))
                   (get-hints (cdr lst))))))

(defun get-guard-hints1 (edcls)

; A typical edcls might be

; '((IGNORE X Y)
;   (XARGS :GUARD g1 :MEASURE m1 :GUARD-HINTS ((id :USE ... :IN-THEORY ...)))
;   (TYPE ...)
;   (XARGS :GUARD g2 :MEASURE m2))

; We find all the :GUARD-HINTS and append them together.

  (cond ((null edcls) nil)
        ((eq (caar edcls) 'xargs)

; We know there is at most one occurrence of :GUARD-HINTS in this
; XARGS entry.

         (let ((temp (assoc-keyword :GUARD-HINTS (cdar edcls))))
           (cond ((null temp) (get-guard-hints1 (cdr edcls)))
                 ((true-listp (cadr temp))
                  (append (cadr temp) (get-guard-hints1 (cdr edcls))))
                 (t (er hard 'get-guard-hints
                        "The value of :GUARD-HINTS must satisfy the predicate ~
                         ~x0.  The value ~x1 is thus illegal.  See :DOC hints."
                        'true-listp
                        (cadr temp))))))
        (t (get-guard-hints1 (cdr edcls)))))

(defun get-guard-hints (lst)

; Lst is a list of tuples of the form (name args doc edcls body).  We
; scan the edcls in each tuple and collect all of the guard-hints together
; into one list of hints.

  (cond ((null lst) nil)
        (t (append (get-guard-hints1 (fourth (car lst)))
                   (get-guard-hints (cdr lst))))))

#+:non-standard-analysis
(defun get-std-hints1 (edcls)

; A typical edcls might be

; '((IGNORE X Y)
;   (XARGS :STD-HINTS ((id :USE ... :IN-THEORY ...)))
;   (TYPE ...)
;   (XARGS :GUARD g2 :MEASURE m2))

; We find all the :STD-HINTS and append them together.

  (cond ((null edcls) nil)
        ((eq (caar edcls) 'xargs)

; We know there is at most one occurrence of :STD-HINTS in this
; XARGS entry.

         (let ((temp (assoc-keyword :STD-HINTS (cdar edcls))))
           (cond ((null temp) (get-std-hints1 (cdr edcls)))
                 ((true-listp (cadr temp))
                  (append (cadr temp) (get-std-hints1 (cdr edcls))))
                 (t (er hard 'get-std-hints
                        "The value of :STD-HINTS must satisfy the predicate ~
                         ~x0.  The value ~x1 is thus illegal.  See :DOC hints."
                        'true-listp
                        (cadr temp))))))
        (t (get-std-hints1 (cdr edcls)))))

#+:non-standard-analysis
(defun get-std-hints (lst)

; Lst is a list of tuples of the form (name args doc edcls body).  We
; scan the edcls in each tuple and collect all of the std-hints together
; into one list of hints.

  (cond ((null lst) nil)
        (t (append (get-std-hints1 (fourth (car lst)))
                   (get-std-hints (cdr lst))))))

(defun get-normalizep (edcls ans ctx state)

; A typical edcls might be

; '((IGNORE X Y)
;   (XARGS :GUARD g1 :MEASURE m1 :HINTS ((id :USE ... :IN-THEORY ...)))
;   (TYPE ...)
;   (XARGS :GUARD g2 :MEASURE m2))

; We find the first :NORMALIZE, if there is one.  But we check that there is
; not more than one.

  (cond ((null edcls)
         (value (if (eq ans :absent)
                    t ; default
                  ans)))
        ((eq (caar edcls) 'xargs)

; We know there is at most one occurrence of :NORMALIZE in this XARGS entry,
; but we are concerned about the possibility of other XARGS entries (from other
; declare forms).  Perhaps we should be concerned in other cases too, e.g.,
; :HINTS.

         (let ((temp (assoc-keyword :NORMALIZE (cdar edcls))))
           (cond
            ((null temp)
             (get-normalizep (cdr edcls) ans ctx state))
            ((not (member-eq (cadr temp) '(t nil)))
             (er soft ctx
                 "The :NORMALIZE keyword specified by XARGS must have value t ~
                  or nil, but the following has been supplied: ~p0."
                 (cadr temp)))
            ((eq ans :absent)
             (get-normalizep (cdr edcls) (cadr temp) ctx state))
            (t
             (er soft ctx
                 "Only one :NORMALIZE keyword may be specified by XARGS.")))))
        (t (get-normalizep (cdr edcls) ans ctx state))))

(defun get-normalizeps (lst acc ctx state)

; Lst is a list of tuples of the form (name args doc edcls body).  We
; scan the edcls in each tuple and collect all of the normalizeps together
; into one list, checking that each is Boolean.

  (cond ((null lst) (value (reverse acc)))
        (t (er-let* ((normalizep (get-normalizep (fourth (car lst)) :absent
                                                 ctx state)))
             (get-normalizeps (cdr lst) (cons normalizep acc) ctx state)))))

(defconst *unspecified-xarg-value*

; Warning: This must be a consp.  See comments in functions that use this
; constant.

  '(unspecified))

(defun get-unambiguous-xargs-flg1/edcls1 (key v edcls event-msg)

; V is the value specified so far for key in the XARGSs of this or previous
; edcls, or else the consp *unspecified-xarg-value* if no value has been
; specified yet.  We return an error message if any non-symbol is used for the
; value of key or if a value different from that specified so far is specified.
; Otherwise, we return either *unspecified-xarg-value* or the uniformly agreed
; upon value.  Event-msg is a string or message for fmt's tilde-atsign and is
; used only to indicate the event in an error message; for example, it may be
; "DEFUN" to indicate a check for a single definition, or "DEFUN event" or
; "MUTUAL-RECURSION" to indicate a check that is made for an entire clique.

  (cond
   ((null edcls) v)
   ((eq (caar edcls) 'xargs)
    (let ((temp (assoc-keyword key (cdar edcls))))
      (cond ((null temp)
             (get-unambiguous-xargs-flg1/edcls1 key v (cdr edcls) event-msg))
            ((not (symbolp (cadr temp)))
             (msg "It is illegal to specify ~x0 to be ~x1.  The value must be ~
                   a symbol."
                  key (cadr temp)))
            ((or (consp v)
                 (eq v (cadr temp)))
             (get-unambiguous-xargs-flg1/edcls1 key (cadr temp) (cdr edcls)
                                                event-msg))
            (t
             (msg "It is illegal to specify ~x0 ~x1 in one place and ~x2 in ~
                   another within the same ~@3.  The functionality controlled ~
                   by that flag operates on the entire ~@3."
                  key v (cadr temp) event-msg)))))
   (t (get-unambiguous-xargs-flg1/edcls1 key v (cdr edcls) event-msg))))

(defun get-unambiguous-xargs-flg1/edcls (key v edcls event-msg ctx state)

; This is just a version of get-unambiguous-xargs-flg1/edcls1 that returns an
; error triple.

  (let ((ans (get-unambiguous-xargs-flg1/edcls1 key v edcls event-msg)))
    (cond ((or (equal ans *unspecified-xarg-value*)
               (atom ans))
           (value ans))
          (t (er soft ctx "~@0" ans)))))

(defun get-unambiguous-xargs-flg1 (key lst event-msg ctx state)

; We scan the edcls of lst and either extract a single uniformly agreed upon
; value for key among the XARGS and return that value, or else no value is
; specified and we return the consp *unspecified-xarg-value*, or else two or
; more values are specified and we cause an error.  We also cause an error if
; any edcls specifies a non-symbol for the value of key.  Thus, if we return a
; symbol it is the uniformly agreed upon value and if we return a consp there
; was no value specified.

  (cond ((null lst) (value *unspecified-xarg-value*))
        (t (er-let*
               ((v (get-unambiguous-xargs-flg1 key (cdr lst) event-msg ctx
                                               state))
             (ans (get-unambiguous-xargs-flg1/edcls key v (fourth (car lst))
                                                    event-msg ctx state)))
            (value ans)))))

(defun get-unambiguous-xargs-flg (key lst default ctx state)

; Lst is a list of mutually recursive defun tuples of the form (name args doc
; edcls body).  We scan the edcls for the settings of the XARGS keyword key.
; If at least one entry specifies a setting, x, and all entries that specify a
; setting specify x, we return x.  If no entry specifies a setting, we return
; default.  If two or more entries specify different settings, we cause an
; error.

; See also get-unambiguous-xargs-flg-lst for a similar function that instead
; allows a different value for each defun tuple, and returns the list of these
; values instead of a single value.

; We assume every legal value of key is a symbol.  If you supply a consp
; default and the default is returned, then no value was specified for key.

; Just to be concrete, suppose key is :mode and default is :logic.  The
; user has the opportunity to specify :mode in each element of lst, i.e., he
; may say to make the first fn :logic and the second fn :program.  But
; that is nonsense.  We have to process the whole clique or none at all.
; Therefore, we have to meld all of his various :mode specs together to come
; up with a setting for the DEFUNS event.  This function explores lst and
; either comes up with an unambiguous :mode or else causes an error.

  (let ((event-msg (if (cdr lst) "MUTUAL-RECURSION" "DEFUN event")))
    (er-let* ((x (get-unambiguous-xargs-flg1 key lst event-msg ctx state)))
      (cond ((consp x) (value default))
            (t (value x))))))

(defun get-unambiguous-xargs-flg-lst (key lst default ctx state)

; See get-unambiguous-xargs-flg.  Unlike that function, this function allows a
; different value for each defun tuple, and returns the list of these values
; instead of a single value.

  (cond ((null lst) (value nil))
        (t (er-let*
               ((ans (get-unambiguous-xargs-flg1/edcls key
                                                       *unspecified-xarg-value*
                                                       (fourth (car lst))
                                                       "DEFUN"
                                                       ctx
                                                       state))
                (rst (get-unambiguous-xargs-flg-lst key (cdr lst) default ctx
                                                    state)))
             (value (cons (if (consp ans) ; ans = *unspecified-xarg-value*
                              default
                            ans)
                          rst))))))

(defun chk-xargs-keywords1 (edcls keywords ctx state)
  (cond ((null edcls) (value nil))
        ((eq (caar edcls) 'xargs)
         (cond ((null keywords)
                (er soft ctx
                    "No XARGS declaration is legal in this context."))
               ((subsetp-eq (evens (cdar edcls)) keywords)
                (chk-xargs-keywords1 (cdr edcls) keywords ctx state))
               (t (er soft ctx
                      "The only acceptable XARGS keyword~#0~[ in this ~
                       context is~/s in this context are~] ~&0.  Thus, ~
                       the keyword~#1~[ ~&1 is~/s ~&1 are~] illegal."
                      keywords
                      (set-difference-eq (evens (cdar edcls))
                                         keywords)))))
        (t (chk-xargs-keywords1 (cdr edcls) keywords ctx state))))

(defun chk-xargs-keywords (lst keywords ctx state)

; Lst is a list of 5-tuples of the form (name args doc edcls body).  The
; edcls contain XARGS keyword lists, e.g., a typical edcls might be

; '((IGNORE X Y)
;   (XARGS :GUARD g1 :MEASURE m1 :HINTS ((id :USE ... :IN-THEORY ...)))
;   (TYPE ...)
;   (XARGS :GUARD g2 :MEASURE m2))

; We check that the only keywords mentioned in the list are those of
; keywords.  We once put this check into translate itself, when it
; was producing the edcls.  But the keywords allowed by DEFUN are
; different from those allowed by DEFMACRO, and so we've moved this
; check into the specific event file.

  (cond
   ((null lst) (value nil))
   (t (er-progn (chk-xargs-keywords1 (fourth (car lst)) keywords ctx state)
                (chk-xargs-keywords (cdr lst) keywords ctx state)))))

(defun get-names (lst)
  (cond ((null lst) nil)
        (t (cons (caar lst)
                 (get-names (cdr lst))))))

(defun get-bodies (lst)
  (cond ((null lst) nil)
        (t (cons (fifth (car lst))
                 (get-bodies (cdr lst))))))

(mutual-recursion

(defun find-nontrivial-rulers (var term)

; Returns a non-empty list of rulers governing an occurrence of var in term, if
; such exists.  Otherwise returns :none if var occurs in term and nil if var
; does not occur in term.

  (cond ((variablep term)
         (if (eq var term) :none nil))
        ((fquotep term)
         nil)
        ((eq (ffn-symb term) 'if)
         (let ((x (find-nontrivial-rulers var (fargn term 2))))
           (cond (x (cons (fargn term 1)
                          (if (eq x :none)
                              nil
                            x)))
                 (t (let ((x (find-nontrivial-rulers var (fargn term 3))))
                      (cond (x (cons (dumb-negate-lit (fargn term 1))
                                     (if (eq x :none)
                                         nil
                                       x)))
                            (t
                             (find-nontrivial-rulers var (fargn term 1)))))))))
        (t (find-nontrivial-rulers-lst var (fargs term) nil))))

(defun find-nontrivial-rulers-lst (var termlist flg)
  (cond ((endp termlist) flg)
        (t (let ((x (find-nontrivial-rulers var (car termlist))))
             (cond ((or (null x)
                        (eq x :none))
                    (find-nontrivial-rulers-lst var (cdr termlist) (or flg x)))
                   (t x))))))
)

(defun tilde-@-free-vars-phrase (vars term wrld)
  (declare (xargs :guard (and (symbol-listp vars)
                              (pseudo-termp term)
                              (nvariablep term)
                              (not (fquotep term))
                              (plist-worldp wrld))))
  (cond ((endp vars) "")
        (t (let ((rulers (find-nontrivial-rulers (car vars) term)))
             (assert$
              rulers ; (car vars) occurs in term, so expect :none if no rulers
              (cond ((eq rulers :none)
                     (tilde-@-free-vars-phrase (cdr vars) term wrld))
                    ((null (cdr rulers))
                     (msg "  Note that ~x0 occurs in the context of condition ~
                           ~x1 from a surrounding IF test."
                          (car vars)
                          (untranslate (car rulers) t wrld)))
                    (t
                     (msg "  Note that ~x0 occurs in the following context, ~
                           i.e., governed by these conditions from ~
                           surrounding IF tests.~|~%  (AND~|~@1"
                          (car vars)
                          (print-indented-list-msg
                           (untranslate-lst rulers t wrld)
                           3
                           ")")))))))))

(defun chk-free-vars (name formals term loc-str ctx state)
  (declare (xargs :guard (and (symbol-listp formals)
                              (pseudo-termp term))))
  (cond ((subsetp (all-vars term) formals) (value nil))
        ((variablep term)
         (er soft ctx
             "The ~@0 ~x1 is a free variable occurrence."
             loc-str name))
        (t (assert$
            (not (fquotep term))
            (let ((vars (set-difference-eq (all-vars term) formals)))
              (er soft ctx
                  "The ~@0 ~x1 contains ~#2~[a free occurrence of the ~
                   variable symbol~/free occurrences of the variable ~
                   symbols~] ~&2.~@3"
                  loc-str name
                  (set-difference-eq vars formals)
                  (tilde-@-free-vars-phrase vars term (w state))))))))

(defun chk-declared-ignores (name ignores term loc-str ctx state)
  (declare (xargs :guard (and (symbol-listp ignores)
                              (pseudo-termp term))))
  (cond ((intersectp-eq (all-vars term) ignores)
         (er soft ctx
             "The ~@0 ~x1 uses the variable symbol~#2~[~/s~] ~&2, ~
              contrary to the declaration that ~#2~[it is~/they are~] ~
              IGNOREd."
             loc-str name
             (intersection-eq (all-vars term) ignores)))
        (t (value nil))))

(defun chk-free-and-ignored-vars (name formals guard split-types-term measure
                                       ignores ignorables body ctx state)
  (er-progn
   (chk-free-vars name formals guard "guard for" ctx state)
   (chk-free-vars name formals split-types-term "split-types expression for"
                  ctx state)
   (chk-free-vars name formals measure "measure supplied with" ctx state)
   (chk-free-vars name formals (cons 'list ignores)
                  "list of variables declared IGNOREd in" ctx state)
   (chk-free-vars name formals (cons 'list ignorables)
                  "list of variables declared IGNORABLE in" ctx state)
   (chk-free-vars name formals body "body of" ctx state)

; Once upon a time we considered a variable used if it occurred in the
; guard or the measure of a function.  Thus, we signaled an error
; if it was declared ignored but used in the guard or measure.
; Now we don't.  Why?  Because this meant that one was not allowed to
; declare ignored a variable used only in (say) the guard.  But when
; the defun is compiled by Allegro, it would complain that the variable
; should have been declared ignored.  We simply are not free to give
; semantics to IGNORE.  CLTL does that and it only cares about the
; body.

   (chk-declared-ignores name ignores body "body of" ctx state)
   (let* ((ignore-ok (cdr (assoc-eq
                           :ignore-ok
                           (table-alist 'acl2-defaults-table (w state)))))
          (undeclared-ignores ; first conjunct is an optimization
           (cond ((or (eq ignore-ok t)
                      (and (not (eq ignore-ok nil))
                           (warning-disabled-p "Ignored-variables")))
                  nil)
                 (t (set-difference-eq
                     formals
                     (union-eq (all-vars body)
                               (union-eq ignorables ignores)))))))
     (cond ((and undeclared-ignores
                 (eq ignore-ok nil))
            (er soft ctx
                "The formal variable~#0~[ ~&0 is~/s ~&0 are~] not used in the ~
                 definition of ~x1 but ~#0~[is~/are~] not DECLAREd IGNOREd or ~
                 IGNORABLE.  Any formal variable not used in the body of a ~
                 definition must be so declared.  To remove this requirement, ~
                 see :DOC set-ignore-ok."
                undeclared-ignores name))
           (undeclared-ignores ; :warn
            (pprogn
             (warning$ ctx ("Ignored-variables")
                      "The formal variable~#0~[ ~&0 is~/s ~&0 are~] not used ~
                       in the definition of ~x1 but ~#0~[is~/are~] not ~
                       DECLAREd IGNOREd or IGNORABLE.  See :DOC set-ignore-ok ~
                       for how to either remove this warning or to enforce it ~
                       by causing an error."
                      undeclared-ignores name)
             (value nil)))
           (t (value nil))))))

(defun chk-free-and-ignored-vars-lsts (names arglists guards split-types-terms
                                             measures ignores ignorables bodies
                                             ctx state)

; This function does all of the defun checking related to the use of free vars
; and ignored/ignorable vars.  We package it all up here to simplify the
; appearance (and post-macro-expansion size) of the caller,
; chk-acceptable-defuns.  The first 6 args are in 1:1 correspondence.

  (declare (xargs :guard (and (symbol-listp names)
                              (symbol-list-listp arglists)
                              (pseudo-term-listp guards)
                              (pseudo-term-listp split-types-terms)
                              (pseudo-term-listp measures)
                              (pseudo-term-listp bodies)
                              (symbol-list-listp ignores)
                              (symbol-list-listp ignorables))))
  (cond ((null names) (value nil))
        (t (er-progn (chk-free-and-ignored-vars (car names)
                                                (car arglists)
                                                (car guards)
                                                (car split-types-terms)
                                                (car measures)
                                                (car ignores)
                                                (car ignorables)
                                                (car bodies)
                                                ctx state)
                     (chk-free-and-ignored-vars-lsts (cdr names)
                                                     (cdr arglists)
                                                     (cdr guards)
                                                     (cdr split-types-terms)
                                                     (cdr measures)
                                                     (cdr ignores)
                                                     (cdr ignorables)
                                                     (cdr bodies)
                                                     ctx state)))))

(defun putprop-x-lst1 (symbols key value wrld)

; For every sym in symbols, (putprop sym key value).

  (cond ((null symbols) wrld)
        (t (putprop-x-lst1 (cdr symbols)
                           key
                           value
                           (putprop (car symbols) key value wrld)))))

(defun putprop-x-lst2 (symbols key vals wrld)

; For corresponding symi,vali pairs in symbols x vals,
; (putprop symi key vali).

  (cond ((null symbols) wrld)
        (t (putprop-x-lst2 (cdr symbols)
                           key
                           (cdr vals)
                           (putprop (car symbols) key (car vals) wrld)))))

(defun putprop-x-lst2-unless (symbols key vals exception wrld)

; For corresponding symi,vali pairs in symbols x vals, (putprop symi
; key vali), unless vali is exception, in which case we do nothing.

  (cond ((null symbols) wrld)
        (t (putprop-x-lst2-unless (cdr symbols)
                                  key
                                  (cdr vals)
                                  exception
                                  (putprop-unless (car symbols)
                                                  key
                                                  (car vals)
                                                  exception
                                                  wrld)))))

(defun@par translate-term-lst (terms stobjs-out logic-modep known-stobjs-lst
                                     ctx wrld state)

; WARNING: Keep this in sync with translate-measures.

; This function translates each of the terms in terms and returns the
; list of translations or causes an error.  It uses the given
; stobjs-out and logic-modep on each term.  As it maps over terms it
; maps over known-stobjs-lst and uses the corresponding element for
; the known-stobjs of each translation.  However, if known-stobjs-lst
; is t it uses t for each.  Note the difference between the treatment
; of stobjs-out and logic-modep, on the one hand, and known-stobjs-lst
; on the other.  The former are ``fixed'' in the sense that the same
; setting is used for EACH term in terms, whereas the latter allows a
; different setting for each term in terms.

; Call this function with stobjs-out t if you want
; merely the logical meaning of the terms.  Call this function with
; stobjs-out '(nil state nil), for example, if you want to ensure that
; each term has the output signature given.

  (cond ((null terms) (value@par nil))
        (t (er-let*@par
            ((term (translate@par (car terms) stobjs-out logic-modep
                                  (if (eq known-stobjs-lst t)
                                      t
                                    (car known-stobjs-lst))
                                  ctx wrld state))
             (rst (translate-term-lst@par (cdr terms) stobjs-out logic-modep
                                          (if (eq known-stobjs-lst t)
                                              t
                                            (cdr known-stobjs-lst))
                                          ctx wrld state)))
            (value@par (cons term rst))))))

; We now turn to the major question of translating user typed hints into
; their internal form.  We combine this translation process with the
; checking that ensures that the hints are legal.  While our immediate
; interest is in the hints for defuns, we in fact handle all the hints
; supported by the system.

; Defthm takes a keyword argument, :HINTS, whose expected value is a
; "hints" of the form ((str1 . hints1) ... (strn . hintsn)) where
; each stri is a string that parses to a clause-id and each hintsi is
; a keyword/value list of the form :key1 val1 ... :keyk valk, where a
; typical :keyi might be :USE, :DO-NOT-INDUCT, :IN-THEORY, etc.  Thus,
; a typical defthm event might be:

; (defthm foo (equal x x)
;   :hints (("Goal''" :use assoc-of-append :in-theory *bar*)))

; Defun, the other event most commonly given hints, does not have room
; in its arg list for :HINTS since defun is a CLTL primitive.  So we have
; implemented the notion of the XARGS of DEFUN and permit it to have as its
; value a keyword/value list exactly like a keyword/value list in macro
; calls.  Thus, to pass the hint above into a defun event you would write

; (defun foo (x)
;   (declare (xargs :hints (("Goal''" :use assoc-of-append :in-theory *bar*))))
;   body)

; Making matters somewhat more complicated are the facts that defuns may
; take more than one defun tuple, i.e., one might be defining a clique of
; functions

;  (defuns
;    (fn1 (x) (DECLARE ...) ... body1)
;    ...
;    (fnn (x) (DECLARE ...) ... bodyn))

; and each such tuple may have zero or more DECLARE forms (or, in
; general, arbitrary forms which macroexpand into DECLARE forms).
; Each of those DECLAREs may have zero or more XARGS and we somehow
; have to extract a single list of hints from them collectively.  What
; we do is just concatenate the hints from each DECLARE form.  Thus,
; it is possible that fn1 will say to use hint settings hs1 on
; "Goal''" and fn2 will say to use hs2 on it.  Because we concatenate
; in the presented order, the clause-id's specified by fn1 have the
; first shot.

; The basic function we define below is translate-hints which takes a
; list of the alleged form ((str1 . hint-settings1) ...) and
; translates the strings and processes the keyword/value pairs
; appropriately.

; Just for the record, the complete list of hint keywords that might
; be used in a given hint-settings may be found in *hint-keywords*.

; For each hint keyword, :x, we have a function,
; translate-x-hint-value, that checks the form.  Each of these
; functions gets as its arg argument the object that was supplied as
; the value of the keyword.  We cause an error or return a translated
; value.  Of course, "translate" here means more than just apply the
; function translate; it means "convert to internal form", e.g.,
; in-theory hints are evaluated into theories.

(defun find-named-lemma (sym lst top-level)

; Sym is a symbol and lst is a list of lemmas, and top-level is initially t.
; We return a lemma in lst whose rune has base-symbol sym, if such a lemma is
; unique and top-level is t.  Otherwise we return nil, except we return
; :several if top-level is nil.

  (cond ((null lst) nil)
        ((equal sym
                (base-symbol (access rewrite-rule (car lst) :rune)))
         (cond ((and top-level
                     (null (find-named-lemma sym (cdr lst) nil)))
                (car lst))
               (top-level nil)
               (t :several)))
        (t (find-named-lemma sym (cdr lst) top-level))))

(defun find-runed-lemma (rune lst)

; Lst must be a list of lemmas.  We find the first one with :rune rune (but we
; make no assumptions on the form of rune).

  (cond ((null lst) nil)
        ((equal rune
                (access rewrite-rule (car lst) :rune))
         (car lst))
        (t (find-runed-lemma rune (cdr lst)))))

(mutual-recursion

(defun free-varsp-member (term vars)

; Like free-varsp, but takes a list of variables instead of an alist.

  (cond ((variablep term) (not (member-eq term vars)))
        ((fquotep term) nil)
        (t (free-varsp-member-lst (fargs term) vars))))

(defun free-varsp-member-lst (args vars)
  (cond ((null args) nil)
        (t (or (free-varsp-member (car args) vars)
               (free-varsp-member-lst (cdr args) vars)))))

)

(defun@par translate-expand-term1 (name form free-vars ctx wrld state)

; Returns an error triple (mv erp val state) where if erp is not nil, then val
; is an expand-hint determined by the given rune and alist.

  (cond
   ((not (arglistp free-vars))
    (er@par soft ctx
      "The use of :FREE in :expand hints should be of the form (:FREE ~
       var-list x), where var-list is a list of distinct variables, unlike ~
       ~x0."
      free-vars))
   (t
    (er-let*@par
     ((term (translate@par form t t t ctx wrld state)))
     (cond
      ((or (variablep term)
           (fquotep term))
       (er@par soft ctx
         "The term ~x0 is not expandable.  See the :expand discussion in :DOC ~
          hints."
         form))
      ((flambda-applicationp term)
       (cond
        (name (er@par soft ctx
                "An :expand hint may only specify :WITH for an expression ~
                 that is the application of a function, unlike ~x0."
                form))
        (t (value@par (make expand-hint
                            :pattern term
                            :alist (if (null free-vars)
                                       :none
                                     (let ((bound-vars
                                            (set-difference-eq (all-vars term)
                                                               free-vars)))
                                       (pairlis$ bound-vars bound-vars)))
                            :rune nil
                            :equiv 'equal
                            :hyp nil
                            :lhs term
                            :rhs (subcor-var (lambda-formals (ffn-symb term))
                                             (fargs term)
                                             (lambda-body (ffn-symb term))))))))
      (t
       (mv-let
        (er-msg rune equiv hyp lhs rhs)
        (cond
         (name
          (let* ((fn (ffn-symb term))
                 (lemmas (getprop fn 'lemmas nil 'current-acl2-world wrld))
                 (lemma (cond ((symbolp name)
                               (find-named-lemma
                                (deref-macro-name name (macro-aliases wrld))
                                lemmas
                                t))
                              (t (find-runed-lemma name lemmas)))))
            (cond
             (lemma
              (let* ((hyps (access rewrite-rule lemma :hyps))
                     (lhs (access rewrite-rule lemma :lhs))
                     (lhs-vars (all-vars lhs))
                     (rhs (access rewrite-rule lemma :rhs)))
                (cond
                 ((or (free-varsp-member-lst hyps lhs-vars)
                      (free-varsp-member rhs lhs-vars))
                  (mv (msg "The ~@0 of a rule given to :with in an :expand ~
                            hint must not contain free variables that are not ~
                            among the variables on its left-hand side.  The ~
                            ~#1~[variable ~&1 violates~/variables ~&1 ~
                            violate~] this requirement."
                           (if (free-varsp-member rhs lhs-vars)
                               "left-hand side"
                             "hypotheses")
                           (if (free-varsp-member rhs lhs-vars)
                               (set-difference-eq (all-vars rhs) lhs-vars)
                             (set-difference-eq (all-vars1-lst hyps nil)
                                                lhs-vars)))
                      nil nil nil nil nil))
                 (t (mv nil
                        (access rewrite-rule lemma :rune)
                        (access rewrite-rule lemma :equiv)
                        (and hyps (conjoin hyps))
                        lhs
                        rhs)))))
             (t (mv (msg "Unable to find a lemma for :expand hint (:WITH ~x0 ~
                          ...)."
                         name)
                    nil nil nil nil nil)))))
         (t (let ((def-body (def-body (ffn-symb term) wrld)))
              (cond
               (def-body
                 (let ((formals (access def-body def-body :formals)))
                   (mv nil
                       (access def-body def-body :rune)
                       'equal
                       (access def-body def-body :hyp)
                       (cons-term (ffn-symb term) formals)
                       (access def-body def-body :concl))))
               (t (mv (msg "The :expand hint for ~x0 is illegal, because ~x1 ~
                            is not a defined function."
                           form
                           (ffn-symb term))
                      nil nil nil nil nil))))))

; We could do an extra check that the lemma has some chance of applying.  This
; would involve a call of (one-way-unify lhs term) unless :free was specified,
; in which case we would need to call a full unification routine.  That doesn't
; seem worth the trouble merely for early user feedback.

        (cond
         (er-msg (er@par soft ctx "~@0" er-msg))
         (t (value@par (make expand-hint
                             :pattern term
                             :alist (if (null free-vars)
                                        :none
                                      (let ((bound-vars
                                             (set-difference-eq (all-vars term)
                                                                free-vars)))
                                        (pairlis$ bound-vars bound-vars)))
                             :rune rune
                             :equiv equiv
                             :hyp hyp
                             :lhs lhs
                             :rhs rhs)))))))))))

(defun@par translate-expand-term (x ctx wrld state)

; X is a "term" given to an expand hint, which can be a term or the result of
; prepending (:free vars) or (:with name-or-rune), or both, to a term.  We
; return (mv erp expand-hint state).

  (case-match x
    (':lambdas
     (value@par x))
    ((':free vars (':with name form))
     (translate-expand-term1@par name form vars ctx wrld state))
    ((':with name (':free vars form))
     (translate-expand-term1@par name form vars ctx wrld state))
    ((':with name form)
     (translate-expand-term1@par name form nil  ctx wrld state))
    ((':free vars form)
     (translate-expand-term1@par nil  form vars ctx wrld state))
    (&
     (cond ((or (atom x)
                (keywordp (car x)))
            (er@par soft ctx
              "An :expand hint must either be a term, or of one of the forms ~
               (:free vars term) or (:with name term), or a combination of ~
               the two forms. The form ~x0 is thus illegal for an :expand ~
               hint.  See :DOC hints."
              x))
           (t (translate-expand-term1@par nil x nil ctx wrld state))))))

(defun@par translate-expand-hint1 (arg acc ctx wrld state)
  (cond ((atom arg)
         (cond
          ((null arg) (value@par (reverse acc)))
          (t (er@par soft ctx
               "The value of the :expand hint must be a true list, but your ~
                list ends in ~x0.  See :DOC hints."
               arg))))
        (t (er-let*@par
            ((xtrans (translate-expand-term@par (car arg) ctx wrld state)))
            (translate-expand-hint1@par (cdr arg) (cons xtrans acc) ctx wrld
                                        state)))))

(defun@par translate-expand-hint (arg ctx wrld state)

; Arg is whatever the user typed after the :expand keyword.  We
; allow it to be either a term or a list of terms.  For example,
; all of the following are legal:

;   :expand (append a b)
;   :expand ((append a b))
;   :expand (:with append (append a b))
;   :expand ((:with append (append a b)))
;   :expand ((:free (a) (append a b)))
;   :expand (:with append (:free (a) (append a b)))
;   :expand ((:with append (:free (a) (append a b))))

; Here we allow a general notion of "term" that includes expressions of the
; form (:free (var1 ... varn) term), indicating that the indicated variables
; are instantiatable in term, and (:with rd term), where rd is a runic
; designator (see :doc theories).  We also interpret :lambdas specially, to
; represent the user's desire that all lambda applications be expanded.

  (cond ((eq arg :lambdas)
         (translate-expand-hint1@par (list arg) nil ctx wrld state))
        ((atom arg)

; Arg had better be nil, otherwise we'll cause an error.

         (translate-expand-hint1@par arg nil ctx wrld state))
        ((and (consp arg)
              (symbolp (car arg))
              (not (eq (car arg) :lambdas)))

; In this case, arg is of the form (sym ...).  Now if arg were really
; intended as a list of terms to expand, the user would be asking us
; to expand the symbol sym, which doesn't make sense, and so we'd
; cause an error in translate-expand-hint1 above.  So we will treat
; this arg as a term.

         (translate-expand-hint1@par (list arg) nil ctx wrld state))
        ((and (consp arg)
              (consp (car arg))
              (eq (caar arg) 'lambda))

; In this case, arg is of the form ((lambda ...) ...).  If arg were
; really intended as a list of terms, then the first object on the
; list is illegal and would cause an error because lambda is not a
; function symbol.  So we will treat arg as a single term.

         (translate-expand-hint1@par (list arg) nil ctx wrld state))
        (t

; Otherwise, arg is treated as a list of terms.

         (translate-expand-hint1@par arg nil ctx wrld state))))

(defun cons-all-to-lst (new-members lst)
  (cond ((null new-members) nil)
        (t (cons (cons (car new-members) lst)
                 (cons-all-to-lst (cdr new-members) lst)))))

(defun@par translate-substitution (substn ctx wrld state)

; Note: This function deals with variable substitutions.  For
; functional substitutions, use translate-functional-substitution.

; Substn is alleged to be a substitution from variables to terms.
; We know it is a true list!  We check that each element is of the
; the form (v term) where v is a variable symbol and term is a term.
; We also check that no v is bound twice.  If things check out we
; return an alist in which each pair is of the form (v . term'), where
; term' is the translation of term.  Otherwise, we cause an error.

  (cond
   ((null substn) (value@par nil))
   ((not (and (true-listp (car substn))
              (= (length (car substn)) 2)))
    (er@par soft ctx
      "Each element of a substitution must be a pair of the form (var term), ~
       where var is a variable symbol and term is a term.  Your alleged ~
       substitution contains the element ~x0, which is not of this form.  See ~
       the discussion of :instance in :MORE-DOC lemma-instance."
      (car substn)))
   (t (let ((var (caar substn))
            (term (cadar substn)))
        (cond
         ((not (legal-variablep var))
          (mv-let (x str)
                  (find-first-bad-arg (list var))
                  (declare (ignore x))
                  (er@par soft ctx
                    "It is illegal to substitute for the non-variable ~x0.  ~
                     It fails to be a variable because ~@1.  See :DOC name ~
                     and see :DOC lemma-instance, in particular the ~
                     discussion of :instance."
                    var
                    (or str "LEGAL-VARIABLEP says so, but FIND-FIRST-BAD-ARG ~
                             can't see why"))))
         (t (er-let*@par
             ((term (translate@par term t t t ctx wrld state))
; known-stobjs = t (stobjs-out = t)
              (y (translate-substitution@par (cdr substn) ctx wrld state)))
             (cond ((assoc-eq var y)
                    (er@par soft ctx
                      "It is illegal to bind ~x0 twice in a substitution.  ~
                       See the discussion of :instance in :MORE-DOC ~
                       lemma-instance."
                      var))
                   (t (value@par (cons (cons var term) y)))))))))))

(defun@par translate-substitution-lst (substn-lst ctx wrld state)
  (cond
   ((null substn-lst) (value@par nil))
   (t (er-let*@par
       ((tsubstn
         (translate-substitution@par (car substn-lst) ctx wrld state))
        (rst
         (translate-substitution-lst@par (cdr substn-lst) ctx wrld state)))
       (value@par (cons tsubstn rst))))))

(defun get-rewrite-and-defn-runes-from-runic-mapping-pairs (pairs)
  (cond
   ((null pairs)
    nil)
   ((member-eq (cadr (car pairs)) '(:rewrite :definition))
    (cons (cdr (car pairs))
          (get-rewrite-and-defn-runes-from-runic-mapping-pairs (cdr pairs))))
   (t (get-rewrite-and-defn-runes-from-runic-mapping-pairs (cdr pairs)))))

(defun@par translate-restrict-hint (arg ctx wrld state)

; Arg is whatever the user typed after the :restrict keyword.

  (cond
   ((atom arg)
    (cond
     ((null arg) (value@par nil))
     (t (er@par soft ctx
          "The value of the :RESTRICT hint must be an alistp (association ~
           list), and hence a true list, but your list ends in ~x0.  See :DOC ~
           hints."
          arg))))
   ((not (and (true-listp (car arg))
              (cdr (car arg))))
    (er@par soft ctx
      "Each member of a :RESTRICT hint must be a true list associating a name ~
       with at least one substitution, but the member ~x0 of your hint ~
       violates this requirement.  See :DOC hints."
      (car arg)))
   ((not (or (symbolp (caar arg))
             (and (runep (caar arg) wrld)
                  (member-eq (car (caar arg)) '(:rewrite :definition)))))
    (er@par soft ctx
      "Each member of a :RESTRICT hint must be a true list whose first ~
       element is either a symbol or a :rewrite or :definition rune in the ~
       current ACL2 world.  The member ~x0 of your hint violates this ~
       requirement."
      (car arg)))
   (t (let ((runes (if (symbolp (caar arg))
                       (get-rewrite-and-defn-runes-from-runic-mapping-pairs
                        (getprop (caar arg)
                                 'runic-mapping-pairs nil
                                 'current-acl2-world wrld))
                     (list (caar arg)))))
        (cond
         ((null runes)
          (er@par soft ctx
            "The name ~x0 does not correspond to any :rewrite or :definition ~
             runes, so the element ~x1 of your :RESTRICT hint is not valid.  ~
             See :DOC hints."
            (caar arg) (car arg)))
         (t (er-let*@par
             ((subst-lst (translate-substitution-lst@par
                          (cdr (car arg)) ctx wrld state))
              (rst (translate-restrict-hint@par (cdr arg) ctx wrld state)))
             (value@par (append (cons-all-to-lst runes subst-lst)
                                rst)))))))))

(defconst *do-not-processes*
  '(generalize preprocess simplify eliminate-destructors
               fertilize eliminate-irrelevance))

(defun coerce-to-process-name-lst (lst)
  (declare (xargs :guard (symbol-listp lst)))
  (if lst
      (cons (intern (string-append (symbol-name (car lst)) "-CLAUSE") "ACL2")
            (coerce-to-process-name-lst (cdr lst)))
      nil))

(defun coerce-to-acl2-package-lst (lst)
  (declare (xargs :guard (symbol-listp lst)))
  (if lst
      (cons (intern (symbol-name (car lst)) "ACL2")
            (coerce-to-acl2-package-lst (cdr lst)))
      nil))

(defun@par chk-do-not-expr-value (lst expr ctx state)

  ;; here lst is the raw names, coerced to the "ACL2" package

  (cond ((atom lst)
         (cond ((null lst)
                (value@par nil))
               (t (er@par soft ctx
                    "The value of the :DO-NOT expression ~x0 is not a true ~
                     list and, hence, is not legal.  In particular, the final ~
                     non-consp cdr is the atom ~x1.  See :DOC hints."
                    expr lst))))
        ((and (symbolp (car lst))
              (member-eq (car lst) *do-not-processes*))
         (chk-do-not-expr-value@par (cdr lst) expr ctx state))
        ((eq (car lst) 'induct)
         (er@par soft ctx
           "The value of the alleged :DO-NOT expression ~x0 includes INDUCT, ~
            which is not the name of a process to turn off.  You probably ~
            mean to use :DO-NOT-INDUCT T or :DO-NOT-INDUCT :BYE instead.  The ~
            legal names are ~&1."
           expr *do-not-processes*))
        (t (er@par soft ctx
             "The value of the alleged :DO-NOT expression ~x0 includes the ~
              element ~x1, which is not the name of a process to turn off.  ~
              The legal names are ~&2."
             expr (car lst) *do-not-processes*))))

(defun@par translate-do-not-hint (expr ctx state)

; We translate and evaluate expr and make sure that it produces something that
; is appropriate for :do-not.  We either cause an error or return the resulting
; list.

  (let ((wrld (w state)))
    (er-let*@par
     ((trans-ans (if (legal-variablep expr)
                     (value@par (cons nil (list expr)))
                   (serial-first-form-parallel-second-form@par
                    (simple-translate-and-eval
                     expr
                     (list (cons 'world wrld))
                     nil
                     "A :do-not hint"
                     ctx wrld state t)
                    (simple-translate-and-eval@par
                     expr
                     (list (cons 'world wrld))
                     nil
                     "A :do-not hint"
                     ctx wrld state t
                     (f-get-global 'safe-mode state)
                     (gc-off state))))))

; trans-ans is (& . val), where & is either nil or a term.

     (cond
      ((not (symbol-listp (cdr trans-ans)))
       (er@par soft ctx
         "The expression following :do-not is required either to be a symbol ~
          or an expression whose value is a true list of symbols, but the ~
          expression ~x0 has returned the value ~x1.  See :DOC hints."
         expr (cdr trans-ans)))
      (t
       (er-progn@par
        (chk-do-not-expr-value@par
         (coerce-to-acl2-package-lst (cdr trans-ans)) expr ctx state)
        (value@par (coerce-to-process-name-lst (cdr trans-ans)))))))))

(defun@par translate-do-not-induct-hint (arg ctx wrld state)
  (declare (ignore wrld))
  (cond ((symbolp arg)
         (cond ((member-eq arg '(:otf :otf-flg-override))
                (value@par arg))
               ((keywordp arg)
                (let ((name (symbol-name arg)))
                  (cond ((and (<= 3 (length name))
                              (equal (subseq name 0 3) "OTF"))
                         (er@par soft ctx
                           "We do not allow :do-not-induct hint values in the ~
                            keyword package whose name starts with \"OTF\", ~
                            unless the value is :OTF or :OTF-FLG-OVERRIDE, ~
                            because we suspect you intended :OTF or ~
                            :OTF-FLG-OVERRIDE in this case.  The value ~x0 is ~
                            thus illegal."
                           arg))
                        (t (value@par arg)))))
               (t (value@par arg))))
        (t (er@par soft ctx
             "The :do-not-induct hint should be followed by a symbol: either ~
              T, :QUIT, or the root name to be used in the naming of any ~
              clauses given byes.  ~x0 is an illegal root name.  See the ~
              :do-not-induct discussion in :MORE-DOC hints."
             arg))))

(defun@par translate-hands-off-hint1 (arg ctx wrld state)
  (cond
   ((atom arg)
    (cond
     ((null arg) (value@par nil))
     (t (er@par soft ctx
          "The value of the :hands-off hint must be a true list, but your ~
           list ends in ~x0.  See the :hands-off discussion in :MORE-DOC ~
           hints."
          arg))))
   ((and (consp (car arg))
         (eq (car (car arg)) 'lambda)
         (consp (cdr (car arg)))
         (true-listp (cadr (car arg))))

; At this point we know that the car of arg is of the form (lambda
; (...) . &) and we want to translate it.  To do so, we create a term
; by applying it to a list of terms.  Where do we get a list of the
; right number of terms?  We use its own formals!

    (er-let*@par
     ((term (translate@par (cons (car arg) (cadr (car arg)))
                           t t t ctx wrld state))
; known-stobjs = t (stobjs-out = t)
      (rst (translate-hands-off-hint1@par (cdr arg) ctx wrld state)))

; Below we assume that if you give translate ((lambda ...) ...) and it
; does not cause an error, then it gives you back a function application.

     (value@par (cons (ffn-symb term) rst))))
   ((and (symbolp (car arg))
         (function-symbolp (car arg) wrld))
    (er-let*@par
     ((rst (translate-hands-off-hint1@par (cdr arg) ctx wrld state)))
     (value@par (cons (car arg) rst))))
   (t (er@par soft ctx
        "The object ~x0 is not a legal element of a :hands-off hint.  See the ~
         :hands-off discussion in :MORE-DOC hints."
        (car arg)))))

(defun@par translate-hands-off-hint (arg ctx wrld state)

; Arg is supposed to be a list of function symbols.  However, we
; allow either
;   :hands-off append
; or
;   :hands-off (append)
; in the singleton case.  If the user writes
;   :hands-off (lambda ...)
; we will understand it as
;   :hands-off ((lambda ...))
; since lambda is not a function symbol.

  (cond ((atom arg)
         (cond ((null arg) (value@par nil))
               ((symbolp arg)
                (translate-hands-off-hint1@par (list arg) ctx wrld state))
               (t (translate-hands-off-hint1@par arg ctx wrld state))))
        ((eq (car arg) 'lambda)
         (translate-hands-off-hint1@par (list arg) ctx wrld state))
        (t (translate-hands-off-hint1@par arg ctx wrld state))))

(defun truncated-class (rune mapping-pairs classes)

; Rune is a rune and mapping-pairs and classes are the corresponding
; properties of its base symbol.  We return the class corresponding to
; rune.  Recall that the classes stored are truncated classes, e.g.,
; they have the proof-specific parts removed and no :COROLLARY if it
; is the same as the 'THEOREM of the base symbol.  By convention, nil
; is the truncated class of a rune whose base symbol has no 'classes
; property.  An example of such a rune is (:DEFINITION fn).

  (cond ((null classes) nil)
        ((equal rune (cdr (car mapping-pairs))) (car classes))
        (t (truncated-class rune (cdr mapping-pairs) (cdr classes)))))

(defun tests-and-alists-lst-from-fn (fn wrld)
  (let* ((formals (formals fn wrld))
         (term (fcons-term fn formals))
         (quick-block-info
          (getprop fn 'quick-block-info
                   '(:error "See SUGGESTED-INDUCTION-CANDS1.")
                   'current-acl2-world wrld))
         (justification
          (getprop fn 'justification
                   '(:error "See SUGGESTED-INDUCTION-CANDS1.")
                   'current-acl2-world wrld))
         (mask (sound-induction-principle-mask term formals
                                               quick-block-info
                                               (access justification
                                                       justification
                                                       :subset)))
         (machine (getprop fn 'induction-machine nil
                           'current-acl2-world wrld)))
    (tests-and-alists-lst (pairlis$ formals (fargs term))
                          (fargs term) mask machine)))

(defun corollary (rune wrld)

; We return the :COROLLARY that justifies the rule named by rune.
; Nil is returned when we cannot recover a suitable formula.

  (let* ((name (base-symbol rune))
         (classes (getprop name 'classes nil 'current-acl2-world wrld)))
    (cond
     ((null classes)
      (cond
       ((or (eq (car rune) :definition)
            (eq (car rune) :executable-counterpart))
        (let ((body (body name t wrld)))
          (cond ((null body) nil)
                ((eq (car rune) :definition)
                 (let ((lemma (find-runed-lemma rune
                                                (getprop name 'lemmas nil
                                                         'current-acl2-world
                                                         wrld))))
                   (and lemma
                        (let ((concl
                               (mcons-term* (access rewrite-rule lemma :equiv)
                                            (access rewrite-rule lemma :lhs)
                                            (access rewrite-rule lemma :rhs))))
                          (if (access rewrite-rule lemma :hyps) ; impossible?
                              (mcons-term* 'implies
                                           (conjoin (access rewrite-rule lemma
                                                            :hyps))
                                           concl)
                            concl)))))
                (t
                 (mcons-term* 'equal
                              (cons-term name (formals name wrld))
                              body)))))
       ((eq (car rune) :type-prescription)
        (let ((tp (find-runed-type-prescription
                   rune
                   (getprop name 'type-prescriptions nil
                            'current-acl2-world wrld))))
          (cond
           ((null tp) *t*)
           (t (access type-prescription tp :corollary)))))
       ((and (eq (car rune) :induction)
             (equal (cddr rune) nil))
        (prettyify-clause-set
         (induction-formula (list (list (cons :p (formals (base-symbol rune)
                                                          wrld))))
                            (tests-and-alists-lst-from-fn (base-symbol rune)
                                                          wrld))
         nil
         wrld))
       (t (er hard 'corollary
              "It was thought to be impossible for a rune to have no ~
               'classes property except in the case of the four or five ~
               definition runes described in the Essay on the ~
               Assignment of Runes and Numes by DEFUNS.  But ~x0 is a ~
               counterexample."
              rune))))
     (t (let ((term
               (cadr
                (assoc-keyword
                 :COROLLARY
                 (cdr
                  (truncated-class
                   rune
                   (getprop name 'runic-mapping-pairs
                            '(:error "See COROLLARY.")
                            'current-acl2-world wrld)
                   classes))))))
          (or term
              (getprop name 'theorem nil 'current-acl2-world wrld)))))))

(defun formula (name normalp wrld)

; Name may be either an event name or a rune.  We return the formula associated
; with name.  We may return nil if we can find no such formula.

  (cond ((consp name) (corollary name wrld))
        (t (let ((body (body name normalp wrld)))
             (cond ((and body normalp)

; We have a defined function.  We want to use the original definition, not one
; installed by a :definition rule with non-nil :install-body field.

                    (corollary `(:DEFINITION ,name) wrld))
                   (body
                    (mcons-term* 'equal
                                 (cons-term name (formals name wrld))
                                 body))
                   (t (or (getprop name 'theorem nil 'current-acl2-world wrld)
                          (getprop name 'defchoose-axiom nil
                                   'current-acl2-world wrld))))))))

(defun pf-fn (name state)
  (io? temporary nil (mv erp val state)
       (name)
       (let ((wrld (w state)))
         (cond
          ((or (symbolp name)
               (runep name wrld))
           (let* ((name (if (symbolp name)
                            (deref-macro-name name (macro-aliases (w state)))
                          name))
                  (term (formula name t wrld)))
             (mv-let (col state)
                     (cond
                      ((equal term *t*)
                       (fmt1 "The formula associated with ~x0 is simply T.~%"
                             (list (cons #\0 name))
                             0
                             (standard-co state) state nil))
                      (term
                       (fmt1 "~p0~|"
                             (list (cons #\0 (untranslate term t wrld)))
                             0
                             (standard-co state) state
                             (term-evisc-tuple nil state)))
                      (t
                       (fmt1 "There is no formula associated with ~x0.~%"
                             (list (cons #\0 name))
                             0 (standard-co state) state nil)))
                     (declare (ignore col))
                     (value :invisible))))
          (t
           (er soft 'pf
               "~x0 is neither a symbol nor a rune in the current world."
               name))))))

(defmacro pf (name)
  (list 'pf-fn name 'state))

(defun merge-symbol-< (l1 l2 acc)
  (cond ((null l1) (revappend acc l2))
        ((null l2) (revappend acc l1))
        ((symbol-< (car l1) (car l2))
         (merge-symbol-< (cdr l1) l2 (cons (car l1) acc)))
        (t (merge-symbol-< l1 (cdr l2) (cons (car l2) acc)))))

(defun merge-sort-symbol-< (l)
  (cond ((null (cdr l)) l)
        (t (merge-symbol-< (merge-sort-symbol-< (evens l))
                           (merge-sort-symbol-< (odds l))
                           nil))))

;; RAG - I added the non-standard primitives here.

(defconst *non-instantiable-primitives*

; We could redefine ENDP in terms of CONS so that ATOM doesn't have to be on
; the list below, but this seems unimportant.  If we take ATOM off, we need to
; change the definition of MAKE-CHARACTER-LIST.

  '(NOT IMPLIES O<
        MEMBER-EQUAL        ;;; perhaps not needed; we are conservative here
        FIX                 ;;; used in DEFAULT-+-2
        BOOLEANP            ;;; used in BOOLEANP-CHARACTERP
        CHARACTER-LISTP     ;;; used in CHARACTER-LISTP-COERCE
        FORCE               ;;; just nice to protect
        CASE-SPLIT          ;;; just nice to protect
        MAKE-CHARACTER-LIST ;;; used in COMPLETION-OF-COERCE
        EQL ENDP            ;;; probably used in others
        ATOM                ;;; used in ENDP; probably used in others
        BAD-ATOM            ;;; used in several defaxioms
        RETURN-LAST         ;;; affects constraints (see remove-guard-holders1)
        MV-LIST             ;;; affects constraints (see remove-guard-holders1)

; The next six are used in built-in defpkg axioms.

        MEMBER-SYMBOL-NAME
        SYMBOL-PACKAGE-NAME
        INTERN-IN-PACKAGE-OF-SYMBOL
        PKG-IMPORTS
        SYMBOL-LISTP
        NO-DUPLICATESP-EQUAL
        NO-DUPLICATESP-EQ-EXEC ; not critical?
        NO-DUPLICATESP-EQ-EXEC$GUARD-CHECK ; not critical?

; We do not want vestiges of the non-standard version in the standard version.

        #+:non-standard-analysis STANDARDP
        #+:non-standard-analysis STANDARD-PART
        #+:non-standard-analysis I-LARGE-INTEGER
        #+:non-standard-analysis REALFIX
        #+:non-standard-analysis I-LARGE
        #+:non-standard-analysis I-SMALL

        ))

(defun instantiablep (fn wrld)

; This function returns t if fn is instantiable and nil otherwise; except, if
; if it has been introduced with the designation of a dependent
; clause-processor, then it returns the name of such a dependent
; clause-processor.

  (and (symbolp fn)
       (not (member-eq fn *non-instantiable-primitives*))

; The list of functions above consists of o<, which we believe is built in
; implicitly in the defun principle, plus every symbol mentioned in any
; defaxiom in axioms.lisp that is not excluded by the tests below.  The
; function check-out-instantiablep, when applied to an :init world will check
; that this function excludes all the fns mentioned in axioms.  We call this
; function in initialize-acl2 to make sure we haven't forgotten some fns.

; We believe it would be ok to permit the instantiation of any defun'd
; function (except maybe o<) because we believe only one function
; satisfies each of those defuns.  It is not clear if we should be biased
; against the other fns above.

       (function-symbolp fn wrld)

; A :logic mode function symbol is non-primitive if and only if it has an
; 'unnormalized-body or 'constrainedp property.  For the forward implication,
; note that the symbol must have been introduced either in the signature of an
; encapsulate, in defuns, or in defchoose.  Note that the value of the
; 'constrainedp property can be a clause-processor, in which case that is the
; value we want to return here; so do not switch the order of the disjuncts
; below!

       (or (getprop fn 'constrainedp nil 'current-acl2-world wrld)
           (and (body fn nil wrld)
                t))))

(mutual-recursion

(defun all-ffn-symbs (term ans)
  (cond
   ((variablep term) ans)
   ((fquotep term) ans)
   (t (all-ffn-symbs-lst (fargs term)
                         (cond ((flambda-applicationp term)
                                (all-ffn-symbs (lambda-body (ffn-symb term))
                                               ans))
                               (t (add-to-set-eq (ffn-symb term) ans)))))))

(defun all-ffn-symbs-lst (lst ans)
  (cond ((null lst) ans)
        (t (all-ffn-symbs-lst (cdr lst)
                              (all-ffn-symbs (car lst) ans)))))

)

(defconst *unknown-constraints*

; This value must not be a function symbol, because functions may need to
; distinguish conses whose car is this value from those consisting of function
; symbols.

  :unknown-constraints)

(defun constraint-info (fn wrld)

; This function returns a pair (mv flg x).  In the simplest and perhaps most
; common case, there is no 'constraint-lst property for fn, e.g., when fn is
; defined by defun or defchoose and not in the scope of an encapsulate.  In
; this case, flg is nil, and x is the defining axiom for fn.  In the other
; case, flg is the name under which the actual constraint for fn is stored
; (possibly name itself), and x is the list of constraints stored there or else
; the value *unknown-constraints* (indicating that the constraints cannot be
; determined because they are associated with a dependent clause-processor).

; We assume that if fn was introduced by a non-local defun or defchoose in the
; context of an encapsulate that introduced constraints, then the defining
; axiom for fn is included in its 'constraint-lst property.  That is:  in that
; case, we do not need to use the definitional axiom explicitly in order to
; obtain the full list of constraints.

  (declare (xargs :guard (and (symbolp fn)
                              (plist-worldp wrld))))
  (let ((prop (getprop fn 'constraint-lst

; We want to distinguish between not finding a list of constraints, and finding
; a list of constraints of nil.  Perhaps we only store non-nil constraints, but
; even if so, there is no need to rely on that invariant, and future versions
; of ACL2 may not respect it.

                       t
                       'current-acl2-world wrld)))

    (cond
     ((eq prop t)
      (let ((body ; (body fn nil wrld), but easier to guard-verify:
             (getprop fn 'unnormalized-body nil 'current-acl2-world wrld)))
        (cond (body

; Warning: Do not apply remove-guard-holders to body.  We rely on having all
; ancestors of body present in the constraint-info in our calculation of
; immediate-canonical-ancestors.  In particular, all function symbols in a call
; of return-last, especially one generated by mbe, must be collected here, to
; support the correct use of attachments in calls of metafunctions and
; clause-processor functions; see the remark about mbe in the Essay on
; Correctness of Meta Reasoning.

               (mv nil (fcons-term* 'equal
                                    (fcons-term fn (formals fn wrld))
                                    body)))
              (t
               (mv nil
                   (or (getprop fn 'defchoose-axiom nil 'current-acl2-world wrld)

; Then fn is a primitive, and has no constraint.

                       *t*))))))
     ((and (symbolp prop)
           prop
           (not (eq prop *unknown-constraints*)))

; Then prop is a name, and the constraints for fn are found under that name.

      (mv prop
          (getprop prop 'constraint-lst
                   '(:error "See constraint-info:  expected to find a ~
                             'constraint-lst property where we did not.")
                   'current-acl2-world wrld)))
     (t
      (mv fn prop)))))

(defun@par chk-equal-arities (fn1 n1 fn2 n2 ctx state)
  (cond
   ((not (equal n1 n2))
    (er@par soft ctx
      "It is illegal to replace ~x0 by ~x1 because the former ~#2~[takes no ~
       arguments~/takes one argument~/takes ~n3 arguments~] while the latter ~
       ~#4~[takes none~/takes one~/takes ~n5~].  See the :functional-instance ~
       discussion in :MORE-DOC :lemma-instance."
      fn1
      fn2
      (cond ((int= n1 0) 0)
            ((int= n1 1) 1)
            (t 2))
      n1
      (cond ((int= n2 0) 0)
            ((int= n2 1) 1)
            (t 2))
      n2))
   (t (value@par nil))))

(defun extend-sorted-symbol-alist (pair alist)
  (cond
   ((endp alist)
    (list pair))
   ((symbol-< (car pair) (caar alist))
    (cons pair alist))
   (t
    (cons (car alist)
          (extend-sorted-symbol-alist pair (cdr alist))))))

;; RAG - This checks to see whether two function symbols are both
;; classical or both non-classical

#+:non-standard-analysis
(defun@par chk-equiv-classicalp (fn1 fn2 termp ctx wrld state)
  (let ((cp1 (classicalp fn1 wrld))
        (cp2 (if termp ; fn2 is a term, not a function symbol
                 (classical-fn-list-p (all-fnnames fn2) wrld)
               (classicalp fn2 wrld))))
    (if (equal cp1 cp2)
        (value@par nil)
      (er@par soft ctx
        "It is illegal to replace ~x0 by ~x1 because the former ~#2~[is ~
         classical~/is not classical~] while the latter ~#3~[is~/is not~]."
        (if (symbolp fn1) fn1 (untranslate fn1 nil wrld))
        (if (symbolp fn2) fn2 (untranslate fn2 nil wrld))
        (if cp1 0 1)
        (if cp2 0 1)))))

;; RAG - I modified the following, so that we do not allow substn to
;; map a non-classical constrained function into a classical function
;; or vice versa.

(defun@par translate-functional-substitution (substn ctx wrld state)

; Substn is alleged to be a functional substitution.  We know that it is a true
; list!  We check that each element is a pair of the form (fn1 fn2), where fn1
; is an instantiable function symbol of arity n and fn2 is either a function
; symbol of arity n or else a lambda expression of arity n with a body that
; translates.  We also check that no fn1 is bound twice.

; Note: We permit free variables to occur in the body, we permit implicitly
; ignored variables, and we do not permit declarations in the lambda.  That is,
; we take each lambda to be of the form (lambda (v1 ... vn) body) and we merely
; insist that body be a term with no particular relation to the vi.

; If substn satisfies these conditions we return an alist in which each pair
; has the form (fn1 . fn2'), where fn2' is the symbol fn2 or the lambda
; expression (lambda (v1 ... vn) body'), where body' is the translation of
; body.  We call this the translated functional substitution.  The returned
; result is sorted by car; see event-responsible-for-proved-constraint for how
; we make use of this fact.

; Warning: The presence of free variables in the lambda expressions means that
; capturing is possible during functional substitution.  We do not check that
; no capturing occurs, since we are not given the terms into which we will
; substitute.

  (cond
   ((null substn) (value@par nil))
   ((not (and (true-listp (car substn))
              (= (length (car substn)) 2)))
    (er@par soft ctx
      "The object ~x0 is not of the form (fi gi) as described in the ~
       :functional-instance discussion of :MORE-DOC lemma-instance."
      (car substn)))
   (t (let ((fn1 (caar substn))
            (fn2 (cadar substn))
            (str "The object ~x0 is not of the form (fi gi) as ~
                  described in the :functional-instance discussion of ~
                  :MORE-DOC lemma-instance.  ~x1 is neither a ~
                  function symbol nor a pseudo-lambda expression."))
        (cond
         ((not (and (symbolp fn1)
                    (function-symbolp fn1 wrld)))
          (er@par soft ctx
            "Each domain element in a functional substitution must be a ~
             function symbol, but ~x0 is not.  See the :functional-instance ~
             discussion of :MORE-DOC lemma-instance."
            fn1))
         ((not (eq (instantiablep fn1 wrld) t))
          (er@par soft ctx
            "The function symbol ~x0 cannot be instantiated~@1.  See the ~
             :functional-instance discussion about `instantiable' in :DOC ~
             lemma-instance."
            fn1
            (if (eq (instantiablep fn1 wrld) nil)
                ""
              (msg " because it was introduced in an encapsulate specifying a ~
                    dependent clause-processor, ~x0 (see DOC ~
                    define-trusted-clause-processor)"
                   (instantiablep fn1 wrld)))))
         (t
          (er-let*@par
           ((x
             (cond
              ((symbolp fn2)
               (let ((fn2 (deref-macro-name fn2 (macro-aliases wrld))))
                 (cond
                  ((function-symbolp fn2 wrld)
                   (er-progn@par
                    (chk-equal-arities@par fn1 (arity fn1 wrld)
                                           fn2 (arity fn2 wrld)
                                           ctx state)
                    #+:non-standard-analysis
                    (chk-equiv-classicalp@par fn1 fn2 nil ctx wrld state)
                    (value@par (cons fn1 fn2))))
                  (t (er@par soft ctx str (car substn) fn2)))))
              ((and (true-listp fn2)
                    (= (length fn2) 3)
                    (eq (car fn2) 'lambda))
               (er-let*@par
                ((body
                  (translate@par (caddr fn2) t t t ctx wrld state)))
; known-stobjs = t (stobjs-out = t)
                (er-progn@par
                 (chk-arglist@par (cadr fn2) t ctx wrld state)
                 (chk-equal-arities@par fn1 (arity fn1 wrld)
                                        fn2 (length (cadr fn2))
                                        ctx state)
                 #+:non-standard-analysis
                 (chk-equiv-classicalp@par fn1 body t ctx wrld state)
                 (value@par (cons fn1 (make-lambda (cadr fn2) body))))))
              (t (er@par soft ctx str (car substn) fn2))))
            (y
             (translate-functional-substitution@par (cdr substn)
                                                    ctx wrld state)))
           (cond ((assoc-eq fn1 y)
                  (er@par soft ctx
                    "It is illegal to bind ~x0 twice in a functional ~
                     substitution.  See the :functional-instance discussion ~
                     of :MORE-DOC lemma-instance."
                    fn1))
                 (t (value@par (extend-sorted-symbol-alist x y)))))))))))

(mutual-recursion

; After Version_3.4, Ruben Gamboa added the variable allow-freevars-p, with the
; following explanation:

; Allow-freevars-p should be set to t in the #-:non-standard-analysis case, but
; otherwise set to nil when we are trying to apply the substitution to a
; non-classical formula.  In those cases, free variables in the body can
; capture non-standard objects, resulting in invalid theorems.  For example,
; take the following theorem
;
; (standardp x) => (standardp (f x))
;
; This theorem is true for classical constrained function f.  Now instantiate
; (f x) with (lambda (x) (+ x y)).  The result is
;
; (standardp x) => (standardp (+ x y))
;
; This formula is false.  E.g., it fails when x=0 and y=(i-large-integer).

(defun sublis-fn-rec (alist term bound-vars allow-freevars-p)

; See the comment just above for additional discussion of allow-freevars-p.

; This function carries out the functional substitution into term specified by
; the translated functional substitution alist.  It checks that alist does not
; allow capturing of its free variables by lambda expressions in term.  If
; allow-freevars-p is nil, it also checks that the alist does not have free
; variables in lambda expressions.  The return value is either (mv vars term),
; for vars a non-empty list of variables -- those having captured occurrences
; when allow-freevars-p is true, else all free variables of lambda expressions
; in alist when allow-freevars-p is nil -- or else is (mv nil new-term) when
; there are no such captures or invalid free variables, in which case new-term
; is the result of the functional substitution.  Note that the caller can tell
; whether an error is caused by capturing or by having disallowed free
; variables, since in the case that allow-freevars-p is nil, it is impossible
; for free variables to be captured (since no free variables are allowed).

; Let us say that an occurrence of fn in term is problematic if fn is bound to
; lambda-expr in alist and for every variable v that occurs free in
; lambda-expr, this occurrence of fn is not in the scope of a lambda binding of
; v.  Key Observation: If there is no problematic occurrence of any function
; symbol in term, then we can obtain the result of this call of sublis-fn by
; first replacing v in lambda-app by a fresh variable v', then carrying out the
; functional substitution, and finally doing an ordinary substitution of v for
; v'.  This Key Observation explains why it suffices to check that there is no
; such problematic occurrence.  As we recur, we maintain bound-vars to be a
; list that includes all variables lambda-bound in the original term at the
; present occurrence of term.

; Every element of alist is either of the form (fn . sym) or of the form (fn
; . (LAMBDA (v1...vn) body)) where the vi are distinct variables and body is a
; translated term, but it is not known that body mentions only vars in formals.

; The former case, where fn is bound to a sym, is simple to handle: when we see
; calls of fn we replace them by calls of sym.  The latter case is not.  When
; we hit (g (FOO) y) with the functional substitution in which FOO gets (LAMBDA
; NIL X), we generate (g X y).  Note that this "imports" a free X into a term,
; (g (foo) y), where there was no X.

; But there is a problem.  If you hit ((lambda (z) (g (FOO) z)) y) with FOO
; gets (LAMBDA NIL X), you would naively produce ((lambda (z) (g X z)) y),
; importing the X into the G term as noted above.  But we also just imported
; the X into the scope of a lambda!  Even though there is no capture, we now
; have a lambda expression whose body contains a var not among the formals.
; That is not a term!

; The solution is to scan the new lambda body, which is known to be a term, and
; collect the free vars -- vars not bound among the formals of the lambda --
; and add them both to the lambda formals and to the actuals.

  (cond
   ((variablep term) (mv nil term))
   ((fquotep term) (mv nil term))
   ((flambda-applicationp term)
    (let ((old-lambda-formals (lambda-formals (ffn-symb term))))
      (mv-let
       (erp new-lambda-body)
       (sublis-fn-rec alist
                      (lambda-body (ffn-symb term))
                      (append old-lambda-formals bound-vars)
                      allow-freevars-p)
       (cond
        (erp (mv erp new-lambda-body))
        (t (mv-let
            (erp args)
            (sublis-fn-rec-lst alist (fargs term) bound-vars allow-freevars-p)
            (cond (erp (mv erp args))
                  (t (let* ((body-vars (all-vars new-lambda-body))
                            (extra-body-vars
                             (set-difference-eq body-vars
                                                old-lambda-formals)))
                       (mv nil
                           (fcons-term
                            (make-lambda
                             (append old-lambda-formals extra-body-vars)
                             new-lambda-body)
                            (append args extra-body-vars))))))))))))
   (t (let ((temp (assoc-eq (ffn-symb term) alist)))
        (cond
         (temp
          (cond ((symbolp (cdr temp))
                 (mv-let
                  (erp args)
                  (sublis-fn-rec-lst alist (fargs term) bound-vars
                                     allow-freevars-p)
                  (cond (erp (mv erp args))
                        (t (mv nil
                               (cons-term (cdr temp) args))))))
                (t
                 (let ((bad (if allow-freevars-p
                                (intersection-eq
                                 (set-difference-eq
                                  (all-vars (lambda-body (cdr temp)))
                                  (lambda-formals (cdr temp)))
                                 bound-vars)
                              (set-difference-eq
                               (all-vars (lambda-body (cdr temp)))
                               (lambda-formals (cdr temp))))))
                   (cond
                    (bad (mv bad term))
                    (t (mv-let
                        (erp args)
                        (sublis-fn-rec-lst alist (fargs term) bound-vars
                                           allow-freevars-p)
                        (cond (erp (mv erp args))
                              (t (mv nil
                                     (sublis-var
                                      (pairlis$ (lambda-formals (cdr temp))
                                                args)
                                      (lambda-body (cdr temp)))))))))))))
         (t (mv-let (erp args)
                    (sublis-fn-rec-lst alist (fargs term) bound-vars
                                       allow-freevars-p)
                    (cond (erp (mv erp args))
                          (t (mv nil
                                 (cons-term (ffn-symb term) args)))))))))))

(defun sublis-fn-rec-lst (alist terms bound-vars allow-freevars-p)
  (cond ((null terms) (mv nil nil))
        (t (mv-let
            (erp term)
            (sublis-fn-rec alist (car terms) bound-vars allow-freevars-p)
            (cond (erp (mv erp term))
                  (t (mv-let
                      (erp tail)
                      (sublis-fn-rec-lst alist (cdr terms) bound-vars
                                         allow-freevars-p)
                      (cond (erp (mv erp tail))
                            (t (mv nil (cons term tail)))))))))))

)

(defun sublis-fn (alist term bound-vars)

; This is just the usual case.  We call the more general function
; sublis-fn-rec, which can be used on the non-standard case.

  (sublis-fn-rec alist term bound-vars t))

(defun sublis-fn-simple (alist term)

; This is the normal case, in which we call sublis-fn with no bound vars and we
; expect no vars to be captured (say, because alist has no free variables).

  (mv-let (vars result)
          (sublis-fn-rec alist term nil t)
          (assert$ (null vars)
                   result)))

(defun sublis-fn-lst-simple (alist termlist)

; See sublis-fn-simple, as this is the analogous function for a list of terms.

  (mv-let (vars result)
          (sublis-fn-rec-lst alist termlist nil t)
          (assert$ (null vars)
                   result)))

(mutual-recursion

(defun instantiable-ffn-symbs (term wrld ans ignore-fns)

; We collect every instantiablep ffn-symb occurring in term except those listed
; in ignore-fns.  We include functions introduced by an encapsulate specifying
; a dependent clause-processor.

  (cond
   ((variablep term) ans)
   ((fquotep term) ans)
   ((flambda-applicationp term)
    (let ((ans (instantiable-ffn-symbs (lambda-body (ffn-symb term))
                                       wrld
                                       ans
                                       ignore-fns)))
      (instantiable-ffn-symbs-lst (fargs term)
                                  wrld
                                  ans
                                  ignore-fns)))
   (t (instantiable-ffn-symbs-lst
       (fargs term)
       wrld
       (cond ((or (not (instantiablep (ffn-symb term) wrld))
                  (member-eq (ffn-symb term) ignore-fns))
              ans)
             (t (add-to-set-eq (ffn-symb term) ans)))
       ignore-fns))))

(defun instantiable-ffn-symbs-lst (lst wrld ans ignore-fns)
  (cond ((null lst) ans)
        (t
         (instantiable-ffn-symbs-lst (cdr lst)
                                     wrld
                                     (instantiable-ffn-symbs (car lst) wrld ans
                                                             ignore-fns)
                                     ignore-fns))))

)

(defun unknown-constraint-supporters (fn wrld)

; Fn is the constraint-lst property of some function g with a non-Boolean
; constraint-lst property, indicating that g was introduced in a dependent
; clause-processor.  The ancestors of g are guaranteed to be among the closure
; under ancestors of the supporters stored for fn in the
; trusted-clause-processor-table.

  (let ((entry (assoc-eq fn (table-alist 'trusted-clause-processor-table
                                         wrld))))
    (cond ((or (null entry)
               (not (eq (cddr entry) t)))
           (er hard 'unknown-constraint-supporters
               "Implementation error: Function ~x0 was called on ~x1, which ~
                was expected to be a dependent clause-processor function, but ~
                apparently is not."
               'unknown-constraint-supporters
               fn))
          (t (cadr entry)))))

(defun collect-instantiablep1 (fns wrld ignore-fns)

; We assume that fns has no duplicates.

  (cond ((endp fns) nil)
        ((and (not (member-eq (car fns) ignore-fns))
              (instantiablep (car fns) wrld))
         (cons (car fns)
               (collect-instantiablep1 (cdr fns) wrld ignore-fns)))
        (t (collect-instantiablep1 (cdr fns) wrld ignore-fns))))

(defun all-instantiablep (fns wrld)
  (cond ((endp fns) t)
        ((instantiablep (car fns) wrld)
         (all-instantiablep (cdr fns) wrld))
        (t nil)))

(defun collect-instantiablep (fns wrld ignore-fns)

; We assume that fns has no duplicates.

  (cond ((and (not (intersectp-eq fns ignore-fns))
              (all-instantiablep fns wrld))
         fns)
        (t (collect-instantiablep1 fns wrld ignore-fns))))

(defun immediate-instantiable-ancestors (fn wrld ignore-fns)

; We return the list of all the instantiable function symbols ('instantiablep
; property t) that are immediate supporters of the introduction of fn, except
; those appearing in ignore-fns.

; If there are (possibly empty) constraints associated with fn, then we get all
; of the instantiable function symbols used in the constraints, which includes
; the definitional axiom if there is one.  Note that the case of a dependent
; clause-processor with *unknown-constraints* is a bit different, as we use its
; supporters appropriately stored in a table.

; If fn was introduced by a defun or defchoose (it should be a non-primitive),
; we return the list of all instantiable functions used in its introduction.
; Note that even if fn is introduced by a defun, it may have constraints if its
; definition was within the scope of an encapsulate, in which case the
; preceding paragraph applies.

; If fn is introduced any other way we consider it primitive and all of the
; axioms about it had better involve non-instantiable symbols, so the answer is
; nil.

; Note: We pass down ignore-fns simply to avoid consing into our answer a
; function that the caller is going to ignore anyway.  It is possible for fn to
; occur as an element of its "immediate ancestors" as computed here.  This
; happens, for example, if fn is defun'd recursively and fn is not in
; ignore-fns.  At the time of this writing the only place we use
; immediate-instantiable-ancestors is in ancestors, where fn is always in
; ignore-fns (whether fn is recursive or not).

  (mv-let (name x)
          (constraint-info fn wrld)
    (cond
     ((eq x *unknown-constraints*)
      (let* ((cl-proc
              (getprop name 'constrainedp
                       '(:error
                         "See immediate-instantiable-ancestors:  expected to ~
                          find a 'constrainedp property where we did not.")
                       'current-acl2-world wrld))
             (supporters (unknown-constraint-supporters cl-proc wrld)))
        (collect-instantiablep supporters wrld ignore-fns)))
     (name (instantiable-ffn-symbs-lst x wrld nil ignore-fns))
     (t (instantiable-ffn-symbs x wrld nil ignore-fns)))))

(defun instantiable-ancestors (fns wrld ans)

; Fns is a list of function symbols.  We compute the list of all instantiable
; function symbols that are ancestral to the functions in fns and accumulate
; them in ans, including those introduced in an encapsulate specifying a
; dependent clause-processor.

  (cond
   ((null fns) ans)
   ((member-eq (car fns) ans)
    (instantiable-ancestors (cdr fns) wrld ans))
   (t
    (let* ((ans1 (cons (car fns) ans))
           (imm (immediate-instantiable-ancestors (car fns) wrld ans1))
           (ans2 (instantiable-ancestors imm wrld ans1)))
      (instantiable-ancestors (cdr fns) wrld ans2)))))

(mutual-recursion

(defun hitp (term alist)

; Alist is a translated functional substitution.  We return t iff
; term mentions some function symbol in the domain of alist.

  (cond ((variablep term) nil)
        ((fquotep term) nil)
        ((flambda-applicationp term)
         (or (hitp (lambda-body (ffn-symb term)) alist)
             (hitp-lst (fargs term) alist)))
        ((assoc-eq (ffn-symb term) alist) t)
        (t (hitp-lst (fargs term) alist))))

(defun hitp-lst (terms alist)
  (cond ((null terms) nil)
        (t (or (hitp (car terms) alist)
               (hitp-lst (cdr terms) alist)))))

)

(defun event-responsible-for-proved-constraint (name alist
                                                     proved-fnl-insts-alist)

; For context, see the Essay on the proved-functional-instances-alist.

; Here proved-fnl-insts-alist is of the form of the world global
; 'proved-functional-instances-alist.  Thus, it is a list of entries of the
; form (constraint-event-name restricted-alist . behalf-of-event-name), where
; constraint-event-name is the name of an event such that the functional
; instance of that event's constraint (i.e., function's constraint or axiom's
; 'theorem property) by restricted-alist was proved on behalf of the event
; named behalf-of-event-name.

  (cond
   ((endp proved-fnl-insts-alist)
    nil)
   ((and (eq name
             (access proved-functional-instances-alist-entry
                     (car proved-fnl-insts-alist)
                     :constraint-event-name))
         (equal alist
                (access proved-functional-instances-alist-entry
                        (car proved-fnl-insts-alist)
                        :restricted-alist)))

; We allow the behalf-of-event-name field (see comment above) to be nil in
; temporary versions of this sort of data structure, but we do not expect to
; find nil for that field in proved-fnl-insts-alist, which comes from the ACL2
; world.  (We store 0 there when there is no event name to use, e.g. when the
; event was a verify-guards event.  See the call of
; proved-functional-instances-from-tagged-objects in install-event.)  But to be
; safe in avoiding confusion with the first branch of our cond (in which there
; is no appropriate entry for our proof obligation), we check for nil here.

    (or (access proved-functional-instances-alist-entry
                (car proved-fnl-insts-alist)
                :behalf-of-event-name)
        (er hard 'event-responsible-for-proved-constraint
            "Implementation error: We expected to find a non-nil ~
             :behalf-of-event-name field in the following entry of the world ~
             global 'proved-functional-instances-alist, but did not:~%~x0."
            (car proved-fnl-insts-alist))))
   (t (event-responsible-for-proved-constraint
       name alist (cdr proved-fnl-insts-alist)))))

(defun getprop-x-lst (symbols prop wrld)
  (cond ((null symbols) nil)
        (t (cons (getprop (car symbols) prop nil
                          'current-acl2-world wrld)
                 (getprop-x-lst (cdr symbols) prop wrld)))))

(defun filter-hitps (lst alist ans)
  (cond
   ((endp lst) ans)
   ((hitp (car lst) alist)
    (filter-hitps (cdr lst) alist (cons (car lst) ans)))
   (t (filter-hitps (cdr lst) alist ans))))

(defun relevant-constraints1 (names alist proved-fnl-insts-alist constraints
                                    event-names new-entries seen wrld)

; For context, see the Essay on the proved-functional-instances-alist.

; Names is a list of function symbols, each of which therefore has a constraint
; formula.  We return three values, corresponding respectively to the following
; three formals, which are initially nil:  constraints, event-names, and
; new-entries.  The first value is the result of collecting those constraint
; formulas that are hit by the translated functional substitution alist, except
; for those that are known (via proved-fnl-insts-alist) to have already been
; proved.  The second is a list of names of events responsible for the validity
; of the omitted formulas.  The third is a list of pairs (cons name
; restr-alist), where restr-alist is obtained by restricting the given alist to
; the instantiable function symbols occurring in the constraint generated by
; name (in the sense of constraint-info).

; Exception: We are free to return (mv *unknown-constraints* g cl-proc).
; However, we only do so if the constraints cannot be determined because of the
; presence of unknown constraints on some function g encountered, where g was
; introduced with the designation of a dependent clause-processor, cl-proc.  We
; ignore this exceptional case in the comments just below.

; Seen is a list of names already processed.  Suppose that foo and bar are both
; constrained by the same encapsulate, and that the 'constraint-lst property of
; 'bar is 'foo.  Since both foo and bar generate the same constraint, we want
; to be sure only to process that constraint once.  So, we put foo on the list
; seen as soon as bar is processed, so that foo will not have to be processed.

; Note that the current ttree is not available here.  If it were, we could
; choose to avoid proving constraints that were already generated in the
; current proof.  It doesn't seem that this would buy us very much, though:
; how often does one find more than one :functional-instance lemma instance in
; a single proof, especially with overlapping constraints?

; See also relevant-constraints1-axioms, which is a similar function for
; collecting constraint information from defaxiom events.

  (cond ((null names) (mv constraints event-names new-entries))
        ((member-eq (car names) seen)
         (relevant-constraints1
          (cdr names) alist proved-fnl-insts-alist
          constraints event-names new-entries seen wrld))
        (t (mv-let
            (name x)
            (constraint-info (car names) wrld)

; Note that if x is not *unknown-constraints*, then x is a single constraint if
; name is nil and otherwise x is a list of constraints.

            (cond
             ((eq x *unknown-constraints*)
              (let ((cl-proc
                     (getprop name 'constrainedp
                              '(:error
                                "See relevant-constraints1: expected to find ~
                                 a 'constrainedp property where we did not.")
                              'current-acl2-world wrld)))
                (cond
                 ((first-assoc-eq (unknown-constraint-supporters cl-proc wrld)
                                  alist)
                  (mv x name cl-proc))
                 (t (relevant-constraints1
                     (cdr names) alist proved-fnl-insts-alist
                     constraints event-names new-entries
                     seen
                     wrld)))))
             ((and name
                   (not (eq name (car names)))

; Minor point:  the test immediately above is subsumed by the one below, since
; we already know at this point that (not (member-eq (car names) seen)), but we
; keep it in for efficiency.

                   (member-eq name seen))
              (relevant-constraints1
               (cdr names) alist proved-fnl-insts-alist
               constraints event-names new-entries
               (cons (car names) seen) wrld))
             (t
              (let* ((x (cond (name (filter-hitps x alist nil))
                              ((hitp x alist) x)

; We continue to treat x as a list of constraints or a single constraint,
; depending respectively on whether name is non-nil or nil; except, we will
; use nil for x when there are no constraints even when name is nil.

                              (t nil)))
                     (instantiable-fns
                      (and x ; optimization
                           (cond (name (instantiable-ffn-symbs-lst
                                        x wrld nil nil))
                                 (t (instantiable-ffn-symbs
                                     x wrld nil nil))))))
                (let* ((constraint-alist
                        (and x ; optimization
                             (restrict-alist instantiable-fns alist)))
                       (ev
                        (and x ; optimization: ev unused when (null x) below
                             (event-responsible-for-proved-constraint
                              (or name (car names))
                              constraint-alist
                              proved-fnl-insts-alist)))
                       (seen (cons (car names)
                                   (if (and name (not (eq name (car names))))
                                       (cons name seen)
                                     seen))))
                  (cond
                   ((null x)
                    (relevant-constraints1
                     (cdr names) alist proved-fnl-insts-alist
                     constraints event-names new-entries
                     seen
                     wrld))
                   (ev (relevant-constraints1
                        (cdr names) alist proved-fnl-insts-alist
                        constraints

; Notice that ev could be 0; see event-responsible-for-proved-constraint.
; Where do we handle such an "event name"?  Here is an inverted call stack:

;           relevant-constraints1             ; called by:
;           relevant-constraints              ; called by:
;           translate-lmi/functional-instance ; called by:
;           translate-lmi                     ; called by:
; translate-use-hint(1)   translate-by-hint   ; called by:
;           translate-x-hint-value

; So, hints are translated.  Who looks at the results?  Well,
; apply-top-hints-clause adds :use and :by to the tag-tree.
; Who looks at the tag-tree?  It's
; apply-top-hints-clause-msg1, which in turn calls
; tilde-@-lmi-phrase -- and THAT is who sees and handles an "event" of 0.
; We might want to construct an example that illustrates this "0 handling" by
; way of providing a :functional-instance lemma-instance in a verify-guards.

                        (add-to-set ev event-names)
                        new-entries
                        seen
                        wrld))
                   (t (relevant-constraints1
                       (cdr names) alist proved-fnl-insts-alist
                       (if name
                           (append x constraints)
                         (cons x constraints))
                       event-names

; On which name's behalf do we note the constraint-alist?  If name is not nil,
; then it is a "canonical" name for which constraint-info returns the
; constraints we are using, in the sense that its constraint-lst is a list.
; Otherwise, (car names) is the name used to obtain constraint-info.

                       (cons (make proved-functional-instances-alist-entry
                                   :constraint-event-name (or name
                                                              (car names))
                                   :restricted-alist constraint-alist
                                   :behalf-of-event-name

; Eventually, the ``nil'' below may be filled in with the event name on behalf
; of which we are carrying out the current proof.

                                   nil)
                             new-entries)
                       seen
                       wrld)))))))))))

(defun relevant-constraints1-axioms (names alist proved-fnl-insts-alist
                                           constraints event-names new-entries
                                           wrld)

; For context, see the Essay on the proved-functional-instances-alist.

; This function is similar to relevant-constraints1, and should be kept more or
; less conceptually in sync with it.  However, in this function, names is a
; list of distinct axiom names rather than function names.  See
; relevant-constraints1 for comments.

  (cond ((null names) (mv constraints event-names new-entries))
        (t (let* ((constraint
                   (getprop (car names)
                            'theorem
                            '(:error "See relevant-constraints1-axioms.")
                            'current-acl2-world wrld))
                  (instantiable-fns
                   (instantiable-ffn-symbs constraint wrld nil nil)))
             (cond ((hitp constraint alist)
                    (let* ((constraint-alist
                            (restrict-alist
                             instantiable-fns
                             alist))
                           (ev (event-responsible-for-proved-constraint
                                (car names)
                                constraint-alist
                                proved-fnl-insts-alist)))
                      (cond
                       (ev (relevant-constraints1-axioms
                            (cdr names) alist proved-fnl-insts-alist
                            constraints
                            (add-to-set ev event-names)
                            new-entries
                            wrld))
                       (t (relevant-constraints1-axioms
                           (cdr names) alist proved-fnl-insts-alist
                           (cons constraint constraints)
                           event-names
                           (cons (make proved-functional-instances-alist-entry
                                       :constraint-event-name (car names)
                                       :restricted-alist constraint-alist
                                       :behalf-of-event-name nil)
                                 new-entries)
                           wrld)))))
                   (t (relevant-constraints1-axioms
                       (cdr names) alist proved-fnl-insts-alist
                       constraints event-names new-entries
                       wrld)))))))

(defun relevant-constraints (thm alist proved-fnl-insts-alist wrld)

; For context, see the Essay on the proved-functional-instances-alist.

; Thm is a term and alist is a translated functional substitution.  We return
; three values.  The first value is the list of the constraints that must be
; instantiated with alist and proved in order to justify the functional
; instantiation of thm.  The second value is a list of names of events on whose
; behalf proof obligations were not generated that would otherwise have been,
; because those proof obligations were proved during processing of those
; events.  (In such cases we do not include these constraints in our first
; value.)  Our third and final value is a list of new entries to add to the
; world global 'proved-functional-instances-alist, as described in the comment
; for event-responsible-for-proved-constraint.

; Keep the following comment in sync with the corresponding comment in
; defaxiom-supporters.

; The relevant theorems are the set of all terms, term, such that
;   (a) term mentions some function symbol in the domain of alist,
;   AND
;   (b) either
;      (i) term arises from a definition of or constraint on a function symbol
;          ancestral either in thm or in some defaxiom,
;       OR
;      (ii) term is the body of a defaxiom.
; In translate-lmi/functional-instance we check that variable capture is
; avoided.

  (let ((nonconstructive-axiom-names
         (global-val 'nonconstructive-axiom-names wrld)))
    (mv-let
     (constraints event-names new-entries)
     (relevant-constraints1-axioms
      nonconstructive-axiom-names alist proved-fnl-insts-alist
      nil nil nil
      wrld)
     (assert$
      (not (eq constraints *unknown-constraints*))
      (let* ((instantiable-fns
              (instantiable-ffn-symbs-lst
               (cons thm (getprop-x-lst nonconstructive-axiom-names
                                        'theorem wrld))
               wrld nil nil))
             (ancestors (instantiable-ancestors instantiable-fns wrld nil)))
        (relevant-constraints1 ancestors alist proved-fnl-insts-alist
                               constraints event-names new-entries nil
                               wrld))))))

(mutual-recursion

(defun bound-vars (term ans)
  (cond ((variablep term) ans)
        ((fquotep term) ans)
        ((flambda-applicationp term)
         (bound-vars
          (lambda-body (ffn-symb term))
          (bound-vars-lst (fargs term)
                                  (union-eq (lambda-formals (ffn-symb term))
                                            ans))))
        (t (bound-vars-lst (fargs term) ans))))

(defun bound-vars-lst (terms ans)
  (cond ((null terms) ans)
        (t (bound-vars-lst
            (cdr terms)
            (bound-vars (car terms) ans)))))

)

(defun@par translate-lmi/instance (formula constraints event-names new-entries
                                           extra-bindings-ok substn ctx wrld
                                           state)

; Formula is some term, obtained by previous instantiations.  Constraints
; are the constraints generated by those instantiations -- i.e., if the
; constraints are theorems then formula is a theorem.  Substn is an
; alleged variable substitution.  We know substn is a true list.

; Provided substn indeed denotes a substitution that is ok to apply to formula,
; we create the instance of formula.  We return a list whose car is the
; instantiated formula and whose cdr is the incoming constraints, event-names
; and new-entries, which all pass through unchanged.  Otherwise, we cause an
; error.

  (er-let*@par
   ((alist (translate-substitution@par substn ctx wrld state)))
   (let* ((vars (all-vars formula))
          (un-mentioned-vars (and (not extra-bindings-ok)
                                  (set-difference-eq (strip-cars alist)
                                                     vars))))
     (cond
      (un-mentioned-vars
       (er@par soft ctx
         "The formula you wish to instantiate, ~p3, mentions ~#0~[no ~
          variables~/only the variable ~&1~/the variables ~&1~].  Thus, there ~
          is no reason to include ~&2 in the domain of your substitution.  We ~
          point this out only because it frequently indicates that a mistake ~
          has been made.  See the discussion of :instance in :DOC ~
          lemma-instance, which explains how to use a keyword, ~
          :extra-bindings-ok, to avoid this error (for example, in case your ~
          substitution was automatically generated by a macro)."
         (zero-one-or-more vars)
         (merge-sort-symbol-< vars)
         (merge-sort-symbol-< un-mentioned-vars)
         (untranslate formula t wrld)))
      (t (value@par (list (sublis-var alist formula)
                          constraints
                          event-names
                          new-entries)))))))

(defun@par translate-lmi/functional-instance (formula constraints event-names
                                                      new-entries substn
                                                      proved-fnl-insts-alist
                                                      ctx wrld state)

; For context, see the Essay on the proved-functional-instances-alist.

; Formula is some term, obtained by previous instantiations.  Constraints are
; the constraints generated by those instantiations -- i.e., if the constraints
; are theorems then formula is a theorem.  Substn is an untranslated object
; alleged to be a functional substitution.

; Provided substn indeed denotes a functional substitution that is ok to apply
; to both formula and the new constraints imposed, we create the functional
; instance of formula and the new constraints to prove.  We return a pair whose
; car is the instantiated formula and whose cdr is the incoming constraints
; appended to the new ones added by this functional instantiation.  Otherwise,
; we cause an error.

  (er-let*@par
   ((alist (translate-functional-substitution@par substn ctx wrld state)))
   (mv-let
    (new-constraints new-event-names new-new-entries)
    (relevant-constraints formula alist proved-fnl-insts-alist wrld)
    (cond
     ((eq new-constraints *unknown-constraints*)
      (er@par soft ctx
        "Functional instantiation is disallowed in this context, because the ~
         function ~x0 has unknown constraints provided by the dependent ~
         clause-processor ~x1.  See :DOC define-trusted-clause-processor."
        new-event-names
        new-new-entries))
     (t
      (let ((allow-freevars-p
             #-:non-standard-analysis
             t
             #+:non-standard-analysis
             (classical-fn-list-p (all-fnnames formula) wrld)))
        (mv-let
         (erp0 formula0)
         (sublis-fn-rec alist formula nil allow-freevars-p)
         (mv-let
          (erp new-constraints0)
          (cond (erp0 (mv erp0 formula0))
                (t (sublis-fn-rec-lst alist new-constraints nil
                                      allow-freevars-p)))
          (cond
           (erp

; The following message is surprising in a situation where a variable is
; captured by a binding to itself, sinced for example (let ((x x)) ...)
; translates and then untranslates back to (let () ...).  Presumably we could
; detect such cases and not consider them to be captures.  But we keep it
; simple and simply expect and hope that such a misleading message is never
; actually seen by a user.

            (er@par soft ctx
              (if allow-freevars-p
                  "Your functional substitution contains one or more free ~
                   occurrences of the variable~#0~[~/s~] ~&0 in its range.  ~
                   Alas, ~#1~[this variable occurrence is~/these variables ~
                   occurrences are~] bound in a LET or MV-LET expression of ~
                   ~#2~[the formula you wish to functionally instantiate, ~
                   ~p3.~|~/the constraints that must be relieved.  ~]You must ~
                   therefore change your functional substitution so that it ~
                   avoids such ``capture.''  It will suffice for your ~
                   functional substitution to stay clear of all the variables ~
                   bound by a LET or MV-LET expression that are used in the ~
                   target formula or in the corresponding constraints.  Thus ~
                   it will suffice for your substitution not to contain free ~
                   occurrences of ~v4 in its range, by using fresh variables ~
                   instead.  Once you have fixed this problem, you can :use ~
                   an :instance of your :functional-instance to bind the ~
                   fresh variables to ~&4."

; With allow-freevars-p = nil, it is impossible for free variables to be
; captured, since no free variables are allowed.

                "Your functional substitution contains one or more free ~
                 occurrences of the variable~#0~[~/s~] ~&0 in its range.  ~
                 Alas, the formula you wish to functionally instantiate is ~
                 not a classical formula, ~p3.  Free variables in lambda ~
                 expressions are only allowed when the formula to be ~
                 instantiated is classical, since these variables may admit ~
                 non-standard values, for which the theorem may be false.")
              (merge-sort-symbol-< erp)
              erp
              (if erp0 0 1)
              (untranslate formula t wrld)
              (bound-vars-lst (cons formula new-constraints)
                              nil)))
           (t (value@par
               (list formula0
                     (append constraints new-constraints0)
                     (union-equal new-event-names event-names)
                     (union-equal new-new-entries new-entries)))))))))))))

(defun@par translate-lmi (lmi normalizep ctx wrld state)

; Lmi is an object that specifies some instance of a theorem.  It may
; specify a substitution instance or a functional instantiation, or
; even some composition of such instances.  This function checks that
; lmi is meaningful and either causes an error or returns (as the
; value result of an error/value/state producing function) a list

; (thm constraints event-names new-entries)

; where:

; thm is a term, intuitively, the instance specified;

; constraints is a list of terms, intuitively a list of conjectures which must
; be proved in order to prove thm;

; event-names is a list of names to credit for avoiding certain proof
; obligations in the generation of the constraints; and

; new-entries is the list of new entries for the world global
; 'proved-functional-instances-alist, which we will place in a tag-tree and
; eventually using the name of the event currently being proved (if any).

; A lemma instance is either
; (a) the name of a formula,
; (b) the rune of a corollary,
; (c) (:theorem formula)
; (d) (:instance lmi . substn), or
; (e) (:functional-instance lmi . substn)

; where lmi is another lemma instance and substn is a substitution of the
; appropriate type.

; Normalizep tells us whether to use the normalized body or the
; 'unnormalized-body when the lmi refers to a funcction definition.  We use the
; normalized body for :use hints, where added simplification can presumably
; only be helpful (and for backwards compatibility as we introduce normalizep
; in Version_2.7).  But we use the 'unnormalized-body for :by hints as a
; courtesy to the user, who probably is thinking of that rather than the
; normalized body when instantiating a definition.

  (let ((str "The object ~x0 is an ill-formed lemma instance because ~@1.  ~
              See :DOC lemma-instance."))
    (cond
     ((atom lmi)
      (cond ((symbolp lmi)
             (let ((term (formula lmi normalizep wrld)))
               (cond (term (value@par (list term nil nil nil)))
                     (t (er@par soft ctx str
                          lmi
                          (msg "there is no formula associated with the name ~
                                ~x0"
                               lmi))))))
            (t (er@par soft ctx str lmi
                 "it is an atom that is not a symbol"))))
     ((runep lmi wrld)
      (let ((term (and (not (eq (car lmi) :INDUCTION))
                       (corollary lmi wrld))))
        (cond (term (value@par (list term nil nil nil)))
              (t (er@par soft ctx str lmi
                   "there is no known formula associated with this rune")))))
     ((eq (car lmi) :theorem)
      (cond
       ((and (true-listp lmi)
             (= (length lmi) 2))
        (er-let*@par
         ((term (translate@par (cadr lmi) t t t ctx wrld state)))
; known-stobjs = t (stobjs-out = t)
         (value@par (list term (list term) nil nil))))
       (t (er@par soft ctx str lmi
            "this :THEOREM lemma instance is not a true list of length 2"))))
     ((or (eq (car lmi) :instance)
          (eq (car lmi) :functional-instance))
      (cond
       ((and (true-listp lmi)
             (>= (length lmi) 2))
        (er-let*@par
         ((lst (translate-lmi@par (cadr lmi) normalizep ctx wrld state)))
         (let ((formula (car lst))
               (constraints (cadr lst))
               (event-names (caddr lst))
               (new-entries (cadddr lst))
               (substn (cddr lmi)))
           (cond
            ((eq (car lmi) :instance)
             (mv-let
              (extra-bindings-ok substn)
              (cond ((eq (car substn) :extra-bindings-ok)
                     (mv t (cdr substn)))
                    (t (mv nil substn)))
              (translate-lmi/instance@par formula constraints event-names
                                          new-entries extra-bindings-ok substn
                                          ctx wrld state)))
            (t (translate-lmi/functional-instance@par
                formula constraints event-names new-entries substn
                (global-val 'proved-functional-instances-alist wrld)
                ctx wrld state))))))
       (t (er@par soft ctx str lmi
            (msg "this ~x0 lemma instance is not a true list of length at ~
                  least 2"
                 (car lmi))))))
     (t (er@par soft ctx str lmi
          "is not a symbol, a rune in the current logical world, or a list ~
           whose first element is :THEOREM, :INSTANCE, or~ ~
           :FUNCTIONAL-INSTANCE")))))

(defun@par translate-use-hint1 (arg ctx wrld state)

; Arg is a list of lemma instantiations and we return a list of the form (hyps
; constraints event-names new-entries); see translate-by-hint or translate-lmi
; for details.  In particular, hyps is a list of the instantiated theorems to
; be added as hypotheses and constraints is a list of the constraints that must
; be proved.

  (cond ((atom arg)
         (cond ((null arg) (value@par '(nil nil nil nil)))
               (t (er@par soft ctx
                    "The value of the :use hint must be a true list but your ~
                     list ends in ~x0.  See the :use discussion in :MORE-DOC ~
                     hints."
                    arg))))
        (t (er-let*@par
            ((lst1 (translate-lmi@par (car arg) t ctx wrld state))
             (lst2 (translate-use-hint1@par (cdr arg) ctx wrld state)))
            (value@par (list (cons (car lst1) (car lst2))
                             (append (cadr lst1) (cadr lst2))
                             (union-eq (caddr lst1) (caddr lst2))
                             (union-equal (cadddr lst1) (cadddr lst2))))))))

(defun@par translate-use-hint (arg ctx wrld state)

; Nominally, the :use hint is followed by a list of lmi objects.
; However, if the :use hint is followed by a single lmi, we automatically
; make a singleton list out of the lmi, e.g.,

;   :use assoc-of-append
; is the same as
;   :use (assoc-of-append)
;
;   :use (:instance assoc-of-append (x a))
; is the same as
;   :use ((:instance assoc-of-append (x a)))

; This function either causes an error or returns (as the value component of
; an error/value/state triple) a list of the form
;    (lmi-lst (hyp1 ... hypn) cl k event-names new-entries),
; lmi-lst is the true-list of lmis processed, (hyp1 ... hypn) are the
; hypothesis theorems obtained, cl is a single clause that is the
; conjunction of the constraints, k is the number of conjuncts,
; event-names is a list of names to credit for avoiding certain proof
; obligations in the generation of the constraints, and new-entries is
; the list of new entries for the world global
; 'proved-functional-instances-alist.

; Note:  The subroutines of this function deal in answer pairs of the form
; ((hyp1 ... hypn) . constraints), where constraints is a list of all the
; constraint terms.  The conversion from that internal convention to the
; external one used in translated :use hints is made here.

; A Brief History of a Rapidly Changing Notation (Feb 28, 1990)

; Once upon a time, lemma instance had the form (assoc-of-append :x
; a).  We adopted the policy that if a substitution was going to be
; applied to a lemma, term, and x was in the domain of the
; substitution, then one wrote :x and wrote the substitution "flat",
; without parentheses around the variable/term pairs.  In general, :x
; meant "the variable symbol in term whose symbol name was "x"."  We
; enforced the restrictin that there was at most one variable symbol
; in a stored formula with a given symbol name.

; At that time we denoted lemma instances with such notation as
; (assoc-of-append :x a :y b :z c).  Functional instances were not yet
; implemented.  But in order to disambiguate the use of a single
; lemma instance from the use of several atomic instances, e.g.,
;    :use (assoc-of-append :x a :y b :z c)
; versus
;    :use (assoc-of-append rev-rev)
; we relied on the idea that the domain elements of the substitution
; were keywords.

; The implementation of functional instantiation changed all that.
; First, we learned that the translation of a keyword domain element,
; e.g., :fn, into a function symbol could not be done in a way
; analogous to what we were doing with variables.  Which function is
; meant by :fn?  You might say, "the one with that symbol name in the
; target theorem being instantiated."  But there may be no such symbol
; in the target theorem; the user may want to instantiate :fn in some
; constraint being proved for that theorem's instantiation.  But then
; you might say "then search the constraint too for a suitable meaning
; for :fn."  Ah ha!  You can't compute the constraint until you know
; which functions are being instantiated.  So the general idea of
; using the target to translate keyword references just fails and it
; was necessary to come up with an unambiguous way of writing a
; substitution.  We temporarily adopted the idea that the "keywords"
; in flat substitutions might not be keywords at all.  E.g., you could
; write ACL2-NQTHM::X as a domain element.  That might have put into
; jeapardy their use to disambiguate :use hint.

; But simultaneously we adopted the idea that lemma instances are
; written as (:instance assoc-of-append ...) or (:functional-instance
; assoc-of-append ...).  This was done so lemma instances could be
; nested, to allow functional instances to then be instantiated.  But
; with the keyword at the beginning of a lemma instance it suddenly
; became possible to disambiguate :use hints:
;   :use (assoc-of-append rev-rev)
; can mean nothing but use two lemma instances because the argument to
; the use is not a lemma instance.

; So we were left with no compelling need to have keywords and flat
; substitutions and a lot of confusion if we did have keywords.  So we
; abandoned them in favor of the let-bindings like notation.

  (cond
   ((null arg)
    (er@par soft ctx
      "Implementation error:  Empty :USE hints should not be handled by ~
       translate-use-hint (for example, they are handled by ~
       translate-hint-settings."))
   (t (let ((lmi-lst (cond ((atom arg) (list arg))
                           ((or (eq (car arg) :instance)
                                (eq (car arg) :functional-instance)
                                (eq (car arg) :theorem)
                                (runep arg wrld))
                            (list arg))
                           (t arg))))
        (er-let*@par
         ((lst (translate-use-hint1@par lmi-lst ctx wrld state)))

; Lst is of the form ((hyp1 ... hypn) constraints event-names new-entries),
; where constraints is a list of constraint terms, implicitly conjoined.  We
; wish to return something of the form
; (lmi-lst (hyp1 ... hypn) constraint-cl k event-names new-entries)
; where constraint-cl is a clause that is equivalent to the constraints.

         (value@par (list lmi-lst
                          (car lst)
                          (add-literal (conjoin (cadr lst)) nil nil)
                          (length (cadr lst))
                          (caddr lst)
                          (cadddr lst))))))))

(defun convert-name-tree-to-new-name1 (name-tree char-lst sym)
  (cond ((atom name-tree)
         (cond ((symbolp name-tree)
                (mv (append (coerce (symbol-name name-tree) 'list)
                            (cond ((null char-lst) nil)
                                  (t (cons #\Space char-lst))))
                    name-tree))
               ((stringp name-tree)
                (mv (append (coerce name-tree 'list)
                            (cond ((null char-lst) nil)
                                  (t (cons #\Space char-lst))))
                    sym))
               (t (mv
                   (er hard 'convert-name-tree-to-new-name1
                       "Name-tree was supposed to be a cons tree of ~
                        symbols and strings, but this one contained ~
                        ~x0.  One explanation for this is that we ~
                        liberalized what a goal-spec could be and ~
                        forgot this function."
                       name-tree)
                   nil))))
        (t (mv-let (char-lst sym)
                   (convert-name-tree-to-new-name1 (cdr name-tree)
                                                   char-lst sym)
                   (convert-name-tree-to-new-name1 (car name-tree)
                                                   char-lst sym)))))

(defun convert-name-tree-to-new-name (name-tree wrld)

; A name-tree is just a cons tree composed entirely of strings
; and symbols.  We construct the symbol whose symbol-name is the
; string that contains the fringe of the tree, separated by
; spaces, and then we generate a new name in wrld. For example,
; if name-tree is '(("Guard Lemma for" . APP) . "Subgoal 1.3''") then we
; will return '|Guard Lemma for APP Subgoal 1.3''|, provided that is new.
; To make it new we'll start tacking on successive subscripts,
; as with gen-new-name.  The symbol we generate is interned in
; the same package as the first symbol occurring in name-tree,
; or in "ACL2" if no symbol occurs in name-tree.

  (mv-let (char-lst sym)
          (convert-name-tree-to-new-name1 name-tree
                                          nil
                                          'convert-name-tree-to-new-name)
          (gen-new-name (intern-in-package-of-symbol
                         (coerce char-lst 'string)
                         sym)
                        wrld)))

(defun@par translate-by-hint (name-tree arg ctx wrld state)

; A :BY hint must either be a single lemma instance, nil, or a new
; name which we understand the user intends will eventually become a
; lemma instance.  Nil means that we are to make up an appropriate
; new name from the goal-spec.  Note:  We can't really guarantee that
; the name we make up (or one we check for the user) is new because
; the same name may be made up twice before either is actually
; created.  But this is just a courtesy to the user anyway.  In the
; end, he'll have to get his names defthm'd himself.

; If arg is an lemma instance, then we return a list of the form (lmi-lst
; thm-cl-set constraint-cl k event-names new-entries), where lmi-lst is a
; singleton list containing the lmi in question, thm-cl-set is the set of
; clauses obtained from the instantiated theorem and which is to subsume the
; indicated goal, constraint-cl is a single clause which represents the
; conjunction of the constraints we are to establish, k is the number of
; conjuncts, event-names is a list of names to credit for avoiding certain
; proof obligations in the generation of the constraints, and new-entries will
; be used to update the world global 'proved-functional-instances-alist.

; If arg is a new name, then we return just arg itself (or the name
; generated).

  (cond ((or (and arg
                  (symbolp arg)
                  (formula arg t wrld))
             (consp arg))
         (er-let*@par
          ((lst (translate-lmi@par arg nil ctx wrld state)))

; Lst is (thm constraints event-names new-entries), where:  thm is a term;
; constraints is a list of terms whose conjunction we must prove; event-names
; is a list of names of events on whose behalf we already proved certain proof
; obligations arising from functional instantiation; and new-entries may
; eventually be added to the world global 'proved-functional-instances-alist so
; that the present event can contribute to avoiding proof obligations for
; future proofs.

          (value@par
           (list (list arg)
                 (car lst)
                 (add-literal (conjoin (cadr lst)) nil nil)
                 (length (cadr lst))
                 (caddr lst)
                 (cadddr lst)))))
        ((null arg)

; The name nil is taken to mean make up a suitable name for this subgoal.

         (value@par (convert-name-tree-to-new-name name-tree wrld)))
        ((and (symbolp arg)
              (not (keywordp arg))
              (not (equal *main-lisp-package-name* (symbol-package-name arg)))
              (new-namep arg wrld))

; The above checks are equivalent to chk-all-but-new-name and chk-just-
; new-name, but don't cause the error upon failure.  The error message
; that would otherwise be generated is confusing because the user isn't
; really trying to define arg to be something yet.

         (value@par arg))
        (t
         (er@par soft ctx
           "The :BY hint must be given a lemma-instance, nil, or a new name.  ~
            ~x0 is none of these.  See :DOC hints."
           arg))))

(defun@par translate-cases-hint (arg ctx wrld state)

; This function either causes an error or returns (as the value component of
; an error/value/state triple) a list of terms.

  (cond
   ((null arg)
    (er@par soft ctx "We do not permit empty :CASES hints."))
   ((not (true-listp arg))
    (er@par soft ctx
      "The value associated with a :CASES hint must be a true-list of terms, ~
       but ~x0 is not."
      arg))
   (t (translate-term-lst@par arg t t t ctx wrld state))))

(defun@par translate-case-split-limitations-hint (arg ctx wrld state)

; This function returns an error triple.  In the non-error case, the value
; component of the error triple is a two-element list that controls the
; case-splitting, in analogy to set-case-split-limitations.

  (declare (ignore wrld))
  #+acl2-par
  (declare (ignorable state))
  (cond ((null arg) (value@par '(nil nil)))
        ((and (true-listp arg)
              (equal (len arg) 2)
              (or (natp (car arg))
                  (null (car arg)))
              (or (natp (cadr arg))
                  (null (cadr arg))))
         (value@par arg))
        (t (er@par soft ctx
             "The value associated with a :CASE-SPLIT-LIMITATIONS hint must ~
              be either nil (denoting a list of two nils), or a true list of ~
              length two, each element which is either nil or a natural ~
              number; but ~x0 is not."
             arg))))

(defun@par translate-no-op-hint (arg ctx wrld state)
  (declare (ignore arg ctx wrld))
  #+acl2-par
  (declare (ignorable state))
  (value@par t))

(defun@par translate-error-hint (arg ctx wrld state)
  (declare (ignore wrld))
  (cond ((tilde-@p arg)
         (er@par soft ctx "~@0" arg))
        (t (er@par soft ctx
             "The :ERROR hint keyword was included among your hints, with ~
              value ~x0."
             arg))))

(defun@par translate-induct-hint (arg ctx wrld state)
  (cond ((eq arg nil) (value@par nil))
        (t (translate@par arg t t t ctx wrld state))))

; known-stobjs = t (stobjs-out = t)

; We now turn to :in-theory hints.  We develop here only enough to
; translate and check an :in-theory hint.  We develop the code for
; the in-theory event and the related deftheory event later.
; Some such code (e.g., eval-theory-expr) was developed earlier in
; support of install-event.

(defconst *built-in-executable-counterparts*

; Keep this in sync with cons-term1.

  '(acl2-numberp
    binary-* binary-+ unary-- unary-/ < car cdr
    char-code characterp code-char complex
    complex-rationalp
    #+:non-standard-analysis complexp
    coerce cons consp denominator equal
    #+:non-standard-analysis floor1
    if imagpart integerp
    intern-in-package-of-symbol numerator pkg-witness pkg-imports rationalp
    #+:non-standard-analysis realp
    realpart stringp symbol-name symbol-package-name symbolp
    #+:non-standard-analysis standardp
    #+:non-standard-analysis standard-part
    ;; #+:non-standard-analysis i-large-integer
    not))

(defconst *s-prop-theory*

; This constant is no longer used in the ACL2 system code -- generally (theory
; 'minimal-theory) is more appropriate -- but we leave it here for use by
; existing books.

; This constant is not well-named, since some of its functions are not
; propositional.  But we keep the name since this constant has been used in
; theory hints since nearly as far back as the inception of ACL2.

  (cons 'iff ; expanded in tautologyp
        *expandable-boot-strap-non-rec-fns*))

(defconst *definition-minimal-theory*

; We include mv-nth because of the call of simplifiable-mv-nthp in the
; definition of call-stack, which (as noted there) results in a use of the
; definition of mv-nth without tracking it in a ttree.

  (list* 'mv-nth 'iff *expandable-boot-strap-non-rec-fns*))

(defun translate-in-theory-hint
  (expr chk-boot-strap-fns-flg ctx wrld state)

; We translate and evaluate expr and make sure that it produces a
; common theory.  We either cause an error or return the corresponding
; runic theory.

; Keep this definition in sync with minimal-theory and
; translate-in-theory-hint@par.

  (er-let*
   ((runic-value (eval-theory-expr expr ctx wrld state)))
   (let* ((warning-disabled-p (warning-disabled-p "Theory"))
          (state
           (cond
            (warning-disabled-p
             state)
            ((and chk-boot-strap-fns-flg
                  (f-get-global 'verbose-theory-warning state)
                  (not (subsetp-equal
                        (getprop 'definition-minimal-theory 'theory
                                 nil ; so, returns nil early in boot-strap
                                 'current-acl2-world wrld)
                        runic-value)))
             (warning$ ctx ("Theory")
                       "The :DEFINITION rule~#0~[ for ~v0 is~/s for ~v0 are~] ~
                        left disabled by the theory expression ~x1, but ~
                        because ~#0~[this function is~/these functions are~] ~
                        built-in in some way, some expansions of ~
                        ~#0~[its~/their~] calls may still occur.  See :DOC ~
                        theories-and-primitives."
                       (strip-base-symbols
                        (set-difference-equal
                         (getprop 'definition-minimal-theory 'theory nil
                                  'current-acl2-world wrld)
                         runic-value))
                       expr
                       *definition-minimal-theory*
                       '(assign verbose-theory-warning nil)))
            (t state))))
     (let ((state
            (cond
             (warning-disabled-p
              state)
             ((and chk-boot-strap-fns-flg
                   (f-get-global 'verbose-theory-warning state)
                   (not (subsetp-equal
                         (getprop 'executable-counterpart-minimal-theory
                                  'theory
                                  nil ; so, returns nil early in boot-strap
                                  'current-acl2-world wrld)
                         runic-value)))
              (warning$ ctx ("Theory")
                       "The :EXECUTABLE-COUNTERPART rule~#0~[ for ~v0 is~/s ~
                        for ~v0 are~] left disabled by the theory expression ~
                        ~x1, but because ~#0~[this funcction is~/these ~
                        functions are~] built-in in some way, some ~
                        evaluations of ~#0~[its~/their~] calls may still ~
                        occur.  See :DOC theories-and-primitives."
                        (strip-base-symbols
                         (set-difference-equal
                          (getprop 'executable-counterpart-minimal-theory
                                   'theory nil 'current-acl2-world wrld)
                          runic-value))
                        expr
                        *built-in-executable-counterparts*
                        '(assign verbose-theory-warning nil)))
             (t state))))
       (value runic-value)))))

#+acl2-par
(defun translate-in-theory-hint@par
  (expr chk-boot-strap-fns-flg ctx wrld state)

; We translate and evaluate expr and make sure that it produces a
; common theory.  We either cause an error or return the corresponding
; runic theory.

; Keep this definition in sync with minimal-theory and
; translate-in-theory-hint.

  (declare (ignorable chk-boot-strap-fns-flg)) ; suppress irrelevance warning
  (er-let*@par
   ((runic-value (eval-theory-expr@par expr ctx wrld state)))
   (let* ((warning-disabled-p (warning-disabled-p "Theory"))
          (ignored-val
           (cond
            (warning-disabled-p
             nil)
            ((and chk-boot-strap-fns-flg
                  (f-get-global 'verbose-theory-warning state)
                  (not (subsetp-equal
                        (getprop 'definition-minimal-theory 'theory
                                 nil ; so, returns nil early in boot-strap
                                 'current-acl2-world wrld)
                        runic-value)))
             (warning$@par ctx ("Theory")
               "The value of the theory expression ~x0 does not include the ~
                :DEFINITION rule~#1~[~/s~] for ~v1.  But ~#1~[this function ~
                is~/these functions are~] among a set of primitive functions ~
                whose definitions are built into the ACL2 system in various ~
                places.  This set consists of the functions ~&2.  While ~
                excluding :DEFINITION rules for any functions in this set ~
                from the current theory may prevent certain expansions, it ~
                may not prevent others.  Good luck!~|~%To inhibit this ~
                warning, evaluate:~|~x3."
               expr
               (strip-base-symbols
                (set-difference-equal
                 (getprop 'definition-minimal-theory 'theory nil
                          'current-acl2-world wrld)
                 runic-value))
               *definition-minimal-theory*
               '(assign verbose-theory-warning nil)))
            (t nil))))
     (declare (ignore ignored-val))
     (let ((ignored-val
            (cond
             (warning-disabled-p
              nil)
             ((and chk-boot-strap-fns-flg
                   (f-get-global 'verbose-theory-warning state)
                   (not (subsetp-equal
                         (getprop 'executable-counterpart-minimal-theory
                                  'theory
                                  nil ; so, returns nil early in boot-strap
                                  'current-acl2-world wrld)
                         runic-value)))
              (warning$@par ctx ("Theory")
                "The value of the theory expression ~x0 does not include the ~
                 :EXECUTABLE-COUNTERPART rule~#1~[~/s~] for ~v1.  But ~
                 ~#1~[this function is~/these functions are~] among a set of ~
                 primitive functions whose executable counterparts are built ~
                 into the ACL2 system.  This set consists of the functions ~
                 ~&2.  While excluding :EXECUTABLE-COUNTERPART rules for any ~
                 functions in this set from the current theory may prevent ~
                 certain expansions, it may not prevent others.  Good ~
                 luck!~|~%To inhibit this warning, evaluate:~|~x3."
                expr
                (strip-base-symbols
                 (set-difference-equal
                  (getprop 'executable-counterpart-minimal-theory
                           'theory nil 'current-acl2-world wrld)
                  runic-value))
                *built-in-executable-counterparts*
                '(assign verbose-theory-warning nil)))
             (t nil))))
       (declare (ignore ignored-val))
       (value@par runic-value)))))

(defun all-function-symbolps (fns wrld)
  (cond ((atom fns) (equal fns nil))
        (t (and (symbolp (car fns))
                (function-symbolp (car fns) wrld)
                (all-function-symbolps (cdr fns) wrld)))))

(defun non-function-symbols (lst wrld)
  (cond ((null lst) nil)
        ((function-symbolp (car lst) wrld)
         (non-function-symbols (cdr lst) wrld))
        (t (cons (car lst)
                 (non-function-symbols (cdr lst) wrld)))))

(defun collect-non-logic-mode (alist wrld)
  (cond ((null alist) nil)
        ((and (function-symbolp (caar alist) wrld)
              (logicalp (caar alist) wrld))
         (collect-non-logic-mode (cdr alist) wrld))
        (t (cons (caar alist)
                 (collect-non-logic-mode (cdr alist) wrld)))))

(defun@par translate-bdd-hint1 (top-arg rest ctx wrld state)
  (cond
   ((null rest)
    (value@par nil))
   (t (let ((kwd (car rest)))
        (er-let*@par
         ((cdar-alist
           (case kwd
             (:vars
              (cond
               ((eq (cadr rest) t)
                (value@par t))
               ((not (true-listp (cadr rest)))
                (er@par soft ctx
                  "The value associated with :VARS in the :BDD hint must ~
                   either be T or a true list, but ~x0 is neither."
                  (cadr rest)))
               ((collect-non-legal-variableps (cadr rest))
                (er@par soft ctx
                  "The value associated with :VARS in the :BDD hint must ~
                   either be T or a true list of variables, but in the :BDD ~
                   hint ~x0, :VARS is associated with the following list of ~
                   non-variables:  ~x1."
                  top-arg
                  (collect-non-legal-variableps (cadr rest))))
               (t (value@par (cadr rest)))))
             (:prove
              (cond ((member-eq (cadr rest) '(t nil))
                     (value@par (cadr rest)))
                    (t (er@par soft ctx
                         "The value associated with ~x0 in the :BDD hint ~x1 ~
                          is ~x2, but it needs to be t or nil."
                         kwd top-arg (cadr rest)))))
             (:literal
              (cond ((member-eq (cadr rest) '(:conc :all))
                     (value@par (cadr rest)))
                    ((and (integerp (cadr rest))
                          (< 0 (cadr rest)))

; The user provides a 1-based index, but we want a 0-based index.

                     (value@par (1- (cadr rest))))
                    (t (er@par soft ctx
                         "The value associated with :LITERAL in a :BDD hint ~
                          must be either :CONC, :ALL, or a positive integer ~
                          (indicating the index, starting with 1, of a ~
                          hypothesis). The value ~x0 from the :BDD hint ~x1 ~
                          is therefore illegal."
                         (cadr rest) top-arg))))
             (:bdd-constructors
              (cond ((and (consp (cadr rest))
                          (eq (car (cadr rest)) 'quote)
                          (consp (cdr (cadr rest)))
                          (null (cddr (cadr rest))))
                     (er@par soft ctx
                       "The value associated with :BDD-CONSTRUCTORS must be a ~
                        list of function symbols.  It should not be quoted, ~
                        but the value supplied is of the form (QUOTE x)."))
                    ((not (symbol-listp (cadr rest)))
                     (er@par soft ctx
                       "The value associated with :BDD-CONSTRUCTORS must be a ~
                        list of symbols, but ~x0 ~ is not."
                       (cadr rest)))
                    ((all-function-symbolps (cadr rest) wrld)
                     (value@par (cadr rest)))
                    (t (er@par soft ctx
                         "The value associated with :BDD-CONSTRUCTORS must be ~
                          a list of :logic mode function symbols, but ~&0 ~
                          ~#0~[is~/are~] not."
                         (collect-non-logic-mode

; This is an odd construct, but its saves us from defining a new function since
; we use collect-non-logic-mode elsewhere anyhow.

                          (pairlis$ (cadr rest) nil)
                          wrld)))))
             (otherwise
              (er@par soft ctx
                "The keyword ~x0 is not a legal keyword for a :BDD hint.  The ~
                 hint ~x1 is therefore illegal.  See :DOC hints."
                (car rest) top-arg)))))
         (er-let*@par
          ((cdr-alist
            (translate-bdd-hint1@par top-arg (cddr rest) ctx wrld state)))
          (value@par (cons (cons kwd cdar-alist) cdr-alist))))))))

(defun@par translate-bdd-hint (arg ctx wrld state)

; Returns an alist associating each of the permissible keywords with a value.

  (cond
   ((not (keyword-value-listp arg))
    (er@par soft ctx
      "The value associated with a :BDD hint must be a list of the form (:kw1 ~
       val1 :kw2 val2 ...), where each :kwi is a keyword.  However, ~x0 does ~
       not have this form."
      arg))
   ((not (assoc-keyword :vars arg))
    (er@par soft ctx
      "The value associated with a :BDD hint must include an assignment for ~
       :vars, but ~x0 does not."
      arg))
   (t (translate-bdd-hint1@par arg arg ctx wrld state))))

(defun@par translate-nonlinearp-hint (arg ctx wrld state)
  (declare (ignore wrld))
  #+acl2-par
  (declare (ignorable state))
  (if (or (equal arg t)
          (equal arg nil))
      (value@par arg)
    (er@par soft ctx
      "The only legal values for a :nonlinearp hint are T and NIL, but ~x0 is ~
       neither of these."
      arg)))

(defun@par translate-backchain-limit-rw-hint (arg ctx wrld state)
  (declare (ignore wrld))
  (if (or (natp arg)
          (equal arg nil))
      (value@par arg)
    (er@par soft ctx
      "The only legal values for a :backchain-limit-rw hint are NIL and ~
       natural numbers, but ~x0 is neither of these."
      arg)))

(defun@par translate-no-thanks-hint (arg ctx wrld state)
  (declare (ignore ctx wrld))
  #+acl2-par
  (declare (ignorable state))
  (value@par arg))

(defun@par translate-reorder-hint (arg ctx wrld state)
  (declare (ignore wrld))
  #+acl2-par
  (declare (ignorable state))
  (if (and (pos-listp arg)
           (no-duplicatesp arg))
      (value@par arg)
    (er@par soft ctx
      "The value for a :reorder hint must be a true list of positive integers ~
       without duplicates, but ~x0 is not."
      arg)))

(defun arity-mismatch-msg (sym expected-arity wrld)

; This little function avoids code replication in
; translate-clause-processor-hint.  Expected-arity is either a number,
; indicating the expected arity, or of the form (list n), where n is the
; minimum expected arity.  We return the arity of sym (or its macro alias) if
; it is not as expected, and we return t if sym has no arity and is not a
; macro.  Otherwise we return nil.  So if sym is a macro, then we return nil
; even though there might be a mismatch (presumably to be detected by other
; means).

  (let* ((fn (or (deref-macro-name sym (macro-aliases wrld))
                 sym))
         (arity (arity fn wrld)))
    (cond
     ((null arity)
      (if (getprop sym 'macro-body nil 'current-acl2-world wrld)
          nil
        (msg "~x0 is neither a function symbol nor a macro name"
             sym)))
     ((and (consp expected-arity)
           (< arity (car expected-arity)))
      (msg "~x0 has arity ~x1 (expected arity of at least ~x2 for this hint ~
            syntax)"
           fn arity (car expected-arity)))
     ((and (integerp expected-arity)
           (not (eql expected-arity arity)))
      (msg "~x0 has arity ~x1 (expected arity ~x2 for this hint syntax)"
           fn arity expected-arity))
     (t nil))))

(defun@par translate-clause-processor-hint (form ctx wrld state)

; We are given the hint :clause-processor form.  We return an error triple
; whose value in the non-error case is a cons pair consisting of the
; corresponding translated term (a legal call of a clause-processor) and its
; associated stobjs-out, suitable for evaluation for a :clause-processor hint.

; Each of the following cases shows legal hint syntax for a signature (or in
; the third case, a class of signatures).

; For signature ((cl-proc cl) => cl-list):
; :CLAUSE-PROCESSOR cl-proc
; :CLAUSE-PROCESSOR (:FUNCTION cl-proc)
; :CLAUSE-PROCESSOR (cl-proc CLAUSE)
;    or any form macroexpanding to (cl-proc &) with at most CLAUSE free

; For signature ((cl-proc cl hint) => cl-list):
; :CLAUSE-PROCESSOR (:FUNCTION cl-proc :HINT hint)
; :CLAUSE-PROCESSOR (cl-proc CLAUSE hint)
;    or any term macroexpanding to (cl-proc & &) with at most CLAUSE free

; For signature ((cl-proc cl hint stobj1 ... stobjk) =>
;                (mv erp cl-list stobj1 ... stobjk)):
; :CLAUSE-PROCESSOR (:FUNCTION cl-proc :HINT hint)
; :CLAUSE-PROCESSOR (cl-proc CLAUSE hint stobj1 ... stobjk):
;    or any term macroexpanding to (cl-proc & & stobj1 ... stobjk)
;    where CLAUSE is the only legal non-stobj free variable

  #+acl2-par
  (declare (ignorable state))
  (let ((err-msg (msg "The form ~x0 is not a legal value for a ~
                       :clause-processor hint because ~@1.  See :DOC hints."
                      form)))
    (er-let*@par
     ((form (cond ((atom form)
                   (cond ((symbolp form)
                          (let ((msg (arity-mismatch-msg form 1 wrld)))
                            (cond (msg (er@par soft ctx "~@0" err-msg msg))
                                  (t (value@par (list form 'clause))))))
                         (t (er@par soft ctx "~@0" err-msg
                              "it is an atom that is not a symbol"))))
                  ((not (true-listp form))
                   (er@par soft ctx "~@0" err-msg
                     "it is a cons that is not a true-listp"))
                  (t (case-match form
                       ((':function cl-proc)
                        (cond
                         ((symbolp cl-proc)
                          (let ((msg (arity-mismatch-msg cl-proc 1 wrld)))
                            (cond (msg (er@par soft ctx "~@0" err-msg msg))
                                  (t (value@par (list cl-proc 'clause))))))
                         (t (er@par soft ctx "~@0" err-msg
                              "the :FUNCTION is not a symbol"))))
                       ((':function cl-proc ':hint hint)
                        (cond ((symbolp cl-proc)
                               (let ((msg
                                      (arity-mismatch-msg cl-proc '(2) wrld)))
                                 (cond
                                  (msg (er@par soft ctx "~@0" err-msg msg))
                                  (t (value@par
                                      (list* cl-proc
                                             'clause
                                             hint
                                             (cddr (stobjs-out cl-proc
                                                               wrld))))))))
                              (t (er@par soft ctx "~@0" err-msg
                                   "the :FUNCTION is an atom that is not a ~
                                    symbol"))))
                       (& (value@par form)))))))
     (mv-let@par
      (erp term bindings state)
      (translate1@par form
                      :stobjs-out ; form must be executable
                      '((:stobjs-out . :stobjs-out))
                      t ctx wrld state)
      (cond
       (erp (er@par soft ctx "~@0" err-msg
              "it was not successfully translated (see error message above)"))
       ((or (variablep term)
            (fquotep term)
            (flambda-applicationp term))
        (er@par soft ctx "~@0" err-msg
          "it is not (even after doing macroexpansion) a call of a function ~
           symbol"))
       (t
        (let ((verified-p
               (getprop (ffn-symb term) 'clause-processor nil
                        'current-acl2-world wrld)))
          (cond
           ((not (or verified-p
                     (assoc-eq (ffn-symb term)
                               (table-alist 'trusted-clause-processor-table
                                            wrld))))
            (er@par soft ctx "~@0" err-msg
              "it is not a call of a clause-processor function"))
           ((not (eq (fargn term 1) 'clause))
            (er@par soft ctx "~@0" err-msg
              "its first argument is not the variable, CLAUSE"))
           ((set-difference-eq (non-stobjps (all-vars term) t wrld)
                               '(clause))
            (er@par soft ctx "~@0" err-msg
              (msg "it contains the free variable~#0~[~/s~] ~&0, but the only ~
                    legal variable (not including stobjs) is ~x1"
                   (set-difference-eq (non-stobjps (all-vars term) t wrld)
                                      '(clause))
                   'clause)))

; #+ACL2-PAR note: Here, we could check that clause-processors do not modify
; state when waterfall-parallelism is enabled.  However, since performing the
; check in eval-clause-processor@par suffices, we do not perform the check
; here.

           (t (value@par (make clause-processor-hint
                               :term term
                               :stobjs-out (translate-deref :stobjs-out
                                                            bindings)
                               :verified-p verified-p)))))))))))

; We next develop code for :custom hints.  See the Essay on the Design of
; Custom Keyword Hints.

(defun@par translate-custom-keyword-hint (arg uterm2 ctx wrld state)

; We run the checker term for the associated custom keyword and handle
; any error it generates.  But if no error is generated, the
; translation of arg (the user-supplied value for the custom keyword)
; is arg itself.

; Why do we not allow non-trivial translation of custom keyword hint
; values?  The main reason is that custom keyword hints do not see the
; translated values of common standard hints so why should they expect
; to see the translated values of custom hints?  While the author of
; custom keyword :key1 might like its argument to be translated, he
; probably doesn't want to know about the translated form of other
; custom keyword values.  Finally, when custom keyword hints generate
; new hints, they cannot be expected to translate their values.  And
; if they didn't translate their values then after one round of custom
; hint evaluation we could have a mix of translated and untranslated
; hint values: standard hints would not be translated -- no user wants
; to know the internal form of lmi's or theories! -- and some custom
; hint values would be translated and others wouldn't.  Furthermore,
; it is impossible to figure out which are which.  The only solution
; is to keep everything in untranslated form.  Example:
; Let :key1, :key2, and :key3 be custom keywords and suppose the user
; wrote the hint

;    :key1 val1  :key2 val2 :in-theory (enable foo)

; If we allowed non-trivial translation of custom hints, then at
; translate-time we'd convert that to

;    :key1 val1' :key2 val2' :in-theory (enable foo)

; Note the mix.  Then at prove-time we'd run :key1's generator on
; val1' and the whole hint.  It might return

;                :key2 val2' :key3 val3 :in-theory (enable foo)

; Note the additional mix.  We can't tell what's untranslated and what
; isn't, unless we made custom hint authors translate all custom
; hints, even those they don't "own."

  (er-progn@par (xtrans-eval@par #-acl2-par uterm2
                                 #+acl2-par
                                 (serial-first-form-parallel-second-form@par
                                  uterm2
                                  (if (equal uterm2 '(value t)) t uterm2))
                                 (list (cons 'val arg)
                                       (cons 'world wrld)
                                       (cons 'ctx ctx))
                                 t ; trans-flg
                                 t ; ev-flg
                                 ctx
                                 state
                                 t)
                (value@par arg)))

(defun custom-keyword-hint (key wrld)

; If key is a custom keyword hint, we return (mv t ugterm ucterm); else
; (mv nil nil nil).  The terms are untranslated.

  (let ((temp (assoc-eq key (table-alist 'custom-keywords-table wrld))))
    (cond
     (temp
      (mv t (car (cdr temp)) (cadr (cdr temp))))
     (t (mv nil nil nil)))))

(defun remove-all-no-ops (key-val-lst)
  (cond ((endp key-val-lst) nil)
        ((eq (car key-val-lst) :no-op)
         (remove-all-no-ops (cddr key-val-lst)))
        (t (cons (car key-val-lst)
                 (cons (cadr key-val-lst)
                       (remove-all-no-ops (cddr key-val-lst)))))))

(defun remove-redundant-no-ops (key-val-lst)

; We return a keyword value list equivalent to key-val-lst but
; containing at most one :NO-OP setting on the front.  We don't even
; add that unless the hint would be empty otherwise.  The associated
; value is always T, no matter what the user wrote.

; (:INDUCT term :NO-OP T :IN-THEORY x :NO-OP NIL)
;   => (:INDUCT term :IN-THEORY x)

; (:NO-OP 1 :NO-OP 2) => (:NO-OP T)

  (cond
   ((assoc-keyword :no-op key-val-lst)
    (let ((temp (remove-all-no-ops key-val-lst)))
      (cond (temp temp)
            (t '(:no-op t)))))
   (t key-val-lst)))

(defun find-first-custom-keyword-hint (user-hints wrld)

; User-hints is a keyword value list of the form (:key1 val1 :key2
; val2 ...).  We look for the first :keyi in user-hints that is a
; custom keyword hint, and if we find it, we return (mv keyi vali
; uterm1 uterm2), where uterm1 is the untranslated generator for keyi
; and uterm2 is the untranslated checker.

  (cond
   ((endp user-hints) (mv nil nil nil nil))
   (t (mv-let (flg uterm1 uterm2)
              (custom-keyword-hint (car user-hints) wrld)
              (cond
               (flg
                (mv (car user-hints)
                    (cadr user-hints)
                    uterm1
                    uterm2))
               (t (find-first-custom-keyword-hint (cddr user-hints) wrld)))))))

(defconst *custom-keyword-max-iterations*
  100)

(defun@par custom-keyword-hint-interpreter1
  (keyword-alist max specified-id id clause wrld
                 stable-under-simplificationp hist pspv ctx state
                 keyword-alist0 eagerp)

; On the top-level call, keyword-alist must be known to be a keyword
; value list, e.g., (:key1 val1 ... keyn valn).  On subsequent calls,
; that is guaranteed.  This function returns an error triple
; (mv erp val state).  But a little more than usual is being passed
; back in the erp=t case.

; If erp is nil: val is either nil, meaning that the custom keyword
; hint did not apply or is a new keyword-alist to be used as the hint.
; That hint will be subjected to standard hint translation.

; If erp is t, then an error has occurred and the caller should abort
; -- UNLESS it passed in eagerp=t and the returned val is the symbol
; WAIT.  If eagerp is t we are trying to evaluate the custom keyword
; hint at pre-process time rather than proof time and don't have
; bindings for some variables.  In that case, an ``error'' is signaled
; with erp t but the returned val is the symbol WAIT, meaning it was
; impossible to eagerly evaluate this form.

  (cond
   ((equal specified-id id)

; This is the clause to which this hint applies.

    (mv-let
     (keyi vali uterm1 uterm2)
     (find-first-custom-keyword-hint keyword-alist wrld)
     (cond
      ((null keyi)

; There are no custom keyword hints in the list.  In this case,
; we're done and we return keyword-alist.

       (value@par keyword-alist))
      ((zp max)
       (er@par soft ctx
         "We expanded the custom keyword hints in ~x0 a total of ~x1 times ~
          and were still left with a hint containing custom keywords, namely ~
          ~x2."
         keyword-alist0
         *custom-keyword-max-iterations*
         keyword-alist))
      (t
       (let ((checker-bindings
              (list (cons 'val vali)
                    (cons 'world wrld)
                    (cons 'ctx ctx))))
         (er-progn@par
          (xtrans-eval@par #-acl2-par uterm2

; Parallelism wart: Deal with the following comment, which appears out of date
; as of 2/4/2012.
; The following change doesn't seem to matter when we run our tests.  However,
; we include it, because from looking at the code, David Rager perceives that
; it can't hurt and that it might help.  It may turn out that the change to
; translate-custom-keyword-hint (which performs a similar replacement),
; supercedes this change, because that occurs earlier in the call stack (before
; the waterfall).  David Rager suspects that the call to
; custom-keyword-hint-interpreter1@par is used inside the waterfall (perhaps
; when the custom keyword hint process it told to 'wait and deal with the hint
; later).  If that is the case, then this replacement is indeed necessary!

                           #+acl2-par
                           (serial-first-form-parallel-second-form@par
                            uterm2
                            (if (equal uterm2 '(value t)) t uterm2))
                           checker-bindings
                           t ; trans-flg = t
                           t ; ev-flg = t
                           ctx state t)

; We just evaluated the checker term and it did not cause an error.
; We ignore its value (though er-let* doesn't).

          (mv-let@par
           (erp val state)
           (xtrans-eval@par uterm1
                            (cond
                             (eagerp

; We are trying to evaluate the generator eagerly.  That means that
; our given values for some dynamic variables, CLAUSE,
; STABLE-UNDER-SIMPLIFICATIONP, HIST, and PSPV are bogus.  We thus
; don't pass them in and we tell xtrans-eval it doesn't really have to
; ev the term if it finds unbound vars.

                              (list* (cons 'keyword-alist keyword-alist)
                                     (cons 'id id)
;                                 (cons 'clause clause) ; bogus
;                                 (cons 'stable-under-simplificationp
;                                       stable-under-simplificationp)
;                                 (cons 'hist hist)
;                                 (cons 'pspv pspv)
                                     checker-bindings))
                             (t

; Otherwise, we want all the bindings:

                              (list* (cons 'keyword-alist keyword-alist)
                                     (cons 'id id)
                                     (cons 'clause clause) ; bogus
                                     (cons 'stable-under-simplificationp
                                           stable-under-simplificationp)
                                     (cons 'hist hist)
                                     (cons 'pspv pspv)
                                     checker-bindings)))
                            t              ; trans-flg
                            (if eagerp nil t) ; ev-flg
                            ctx
                            state
                            t)
           (cond
            (erp

; If an error was caused, there are two possibilities.  One is that
; the form actually generated an error.  But the other is that we were
; trying eager evaluation with insufficient bindings.  That second
; case is characterized by eagerp = t and val = WAIT.  In both cases,
; we just pass it up.

             (mv@par erp val state))

; If no error was caused, we check the return value for our invariant.

            ((not (keyword-value-listp val))
             (er@par soft ctx
               "The custom keyword hint ~x0 in the context below generated a ~
                result that is not of the form (:key1 val1 ... :keyn valn), ~
                where the :keyi are keywords. The context is ~y1, and the ~
                result generated was ~y2."
               keyi
               keyword-alist
               val))
            (t

; We now know that val is a plausible new keyword-alist and replaces
; the old one.

             (pprogn@par
              (cond
               ((f-get-global 'show-custom-keyword-hint-expansion state)
                (io?@par prove nil state
                         (keyi id  keyword-alist val)
                         (fms "~%(Advisory from ~
                               show-custom-keyword-hint-expansion:  The ~
                               custom keyword hint ~x0, appearing in ~@1, ~
                               transformed~%~%~Y23,~%into~%~%~Y43.)~%"
                              (list
                               (cons #\0 keyi)
                               (cons #\1 (tilde-@-clause-id-phrase id))
                               (cons #\2 (cons
                                          (string-for-tilde-@-clause-id-phrase id)
                                          keyword-alist))
                               (cons #\3 (term-evisc-tuple nil state))
                               (cons #\4 (cons
                                          (string-for-tilde-@-clause-id-phrase id)
                                          val)))
                              (proofs-co state)
                              state
                              nil)))
               (t (state-mac@par)))
              (custom-keyword-hint-interpreter1@par
               val
               (- max 1)
               specified-id
               id clause wrld stable-under-simplificationp
               hist pspv ctx state
               keyword-alist0 eagerp)))))))))))
   (t (value@par nil))))

(defun@par custom-keyword-hint-interpreter
  (keyword-alist specified-id
                 id clause wrld stable-under-simplificationp
                 hist pspv ctx state eagerp)

; Warning: If you change or rearrange the arguments of this function,
; be sure to change custom-keyword-hint-in-computed-hint-form and
; put-cl-id-of-custom-keyword-hint-in-computed-hint-form.

; This function evaluates the custom keyword hints in keyword-alist.
; It either signals an error or returns as the value component of its
; error triple a new keyword-alist.

; Eagerp should be set to t if this is an attempt to expand the custom
; keyword hints at pre-process time.  If eagerp = t, then it is
; assumed that CLAUSE, STABLE-UNDER-SIMPLIFICATIONP, HIST, and
; PSPV are bogus (nil).

; WARNING: This function should be called from an mv-let, not an
; er-let*!  The erroneous return from this function should be handled
; carefully when eagerp = t.  It is possible in that case that the
; returned value, val, of (mv t erp state), is actually the symbol
; WAIT.  This means that during the eager expansion of some custom
; keyword hint we encountered a hint that required the dynamic
; variables.  It is not strictly an error, i.e., the caller shouldn't
; abort.

  (custom-keyword-hint-interpreter1@par
   keyword-alist *custom-keyword-max-iterations* specified-id id clause wrld
   stable-under-simplificationp hist pspv ctx state keyword-alist eagerp))

(defun custom-keyword-hint-in-computed-hint-form (computed-hint-tuple)

; Note:  Keep this in sync with eval-and-translate-hint-expression.
; That function uses the AND test below but not the rest, because it
; is dealing with the term itself, not the tuple.

; We assume computed-hint-tuple is the internal form of a computed
; hint.  If it is a custom keyword hint, we return the non-nil keyword
; alist supplied by the user.  Otherwise, nil.

; A translated computed hint has the form
; (EVAL-AND-TRANSLATE-HINT-EXPRESSION name-tree stablep term) and we
; assume that computed-hint-tuple is of that form.  A custom keyword
; hint is coded as a computed hint, where term, above, is
; (custom-keyword-hint-interpreter '(... :key val ...) 'cl-id ...)
; We insist that the keyword alist is a quoted constant (we will
; return its evg).  We also insist that the cl-id is a quoted
; constant.

  (let ((term (nth 3 computed-hint-tuple)))
    (cond ((and (nvariablep term)
                (not (fquotep term))

; Parallelism blemish: we do not believe that the quoting below of
; "custom-keyword-hint-interpreter@par" is a problem (as compared to the serial
; case).  One can issue a tags search for 'custom-keyword-hint-interpreter, and
; find some changed comparisons.  We believe that Matt K. and David R. began to
; look into this, and we were not aware of any problems, so we have decided not
; to try to think it all the way through.

                (serial-first-form-parallel-second-form@par
                 (eq (ffn-symb term) 'custom-keyword-hint-interpreter)
                 (or (eq (ffn-symb term) 'custom-keyword-hint-interpreter)
                     (eq (ffn-symb term) 'custom-keyword-hint-interpreter@par)))
                (quotep (fargn term 1))
                (quotep (fargn term 2)))
           (cadr (fargn term 1)))
          (t nil))))

(defun@par put-cl-id-of-custom-keyword-hint-in-computed-hint-form
  (computed-hint-tuple cl-id)

; We assume the computed-hint-tuple is a computed hint tuple and has
; passed custom-keyword-hint-in-computed-hint-form.  We set the cl-id
; field to cl-id.  This is only necessary in order to fix the cl-id
; for :or hints, which was set for the goal to which the :or hint was
; originally attached.

  (let ((term (nth 3 computed-hint-tuple)))
    (list 'eval-and-translate-hint-expression
          (nth 1 computed-hint-tuple)
          (nth 2 computed-hint-tuple)
          (fcons-term* (serial-first-form-parallel-second-form@par
                        'custom-keyword-hint-interpreter
                        'custom-keyword-hint-interpreter@par)
                       (fargn term 1)
                       (kwote cl-id)
                       (fargn term 3)
                       (fargn term 4)
                       (fargn term 5)
                       (fargn term 6)
                       (fargn term 7)
                       (fargn term 8)
                       (fargn term 9)
                       (fargn term 10)
                       (fargn term 11)))))

(defun make-disjunctive-clause-id (cl-id i pkg-name)
  (change clause-id cl-id
          :case-lst
          (append (access clause-id cl-id :case-lst)
                  (list (intern$ (coerce (packn1 (list 'd i)) 'string)
                                 pkg-name)))
          :primes 0))

(defun make-disjunctive-goal-spec (str i pkg-name)
  (let ((cl-id (parse-clause-id str)))
    (string-for-tilde-@-clause-id-phrase
     (make-disjunctive-clause-id cl-id i pkg-name))))

(defun minimally-well-formed-or-hintp (val)
  (cond ((atom val)
         (equal val nil))
        (t (and (consp (car val))
                (true-listp (car val))
                (evenp (length (car val)))
                (minimally-well-formed-or-hintp (cdr val))))))

(defun split-keyword-alist (key keyword-alist)
  (cond ((endp keyword-alist) (mv nil nil))
        ((eq key (car keyword-alist))
         (mv nil keyword-alist))
        (t (mv-let (pre post)
                   (split-keyword-alist key (cddr keyword-alist))
                   (mv (cons (car keyword-alist)
                             (cons (cadr keyword-alist)
                                   pre))
                       post)))))

(defun distribute-other-hints-into-or1 (pre x post)
  (cond ((endp x) nil)
        (t (cons (append pre (car x) post)
                 (distribute-other-hints-into-or1 pre (cdr x) post)))))

(defun distribute-other-hints-into-or (keyword-alist)

; We know keyword-alist is a keyword alist, that there is exactly one :OR, and
; that the value, val, of that :OR is a true-list of non-empty
; true-lists, each of which is of even length.  We distribute the
; other hints into the :OR.  Thus, given:

; (:in-theory a :OR ((:use l1) (:use l2)) :do-not '(...))

; we return:

; ((:OR ((:in-theory a :use l1 :do-not '(...))
;        (:in-theory a :use l2 :do-not '(...)))))

  (mv-let (pre post)
          (split-keyword-alist :OR keyword-alist)
          (list :OR
                (distribute-other-hints-into-or1 pre
                                                 (cadr post)
                                                 (cddr post)))))

(defconst *hint-expression-basic-vars*
  '(id clause world stable-under-simplificationp hist pspv ctx state))

(defconst *hint-expression-override-vars*
  (cons 'keyword-alist *hint-expression-basic-vars*))

(defconst *hint-expression-backtrack-vars*
  (append '(clause-list processor)
          (remove1-eq 'stable-under-simplificationp
                      *hint-expression-basic-vars*)))

(defconst *hint-expression-all-vars*
  (union-equal *hint-expression-override-vars*
               (union-equal *hint-expression-backtrack-vars*
                            *hint-expression-basic-vars*)))

(defun@par translate-hint-expression (name-tree term hint-type ctx wrld state)

; Term can be either (a) a non-variable term or (b) a symbol.

; (a) We allow a hint of the form term, where term is a term single-threaded in
; state that returns a single non-stobj value or an error triple and contains
; no free vars other than ID, CLAUSE, WORLD, STABLE-UNDER-SIMPLIFICATIONP,
; HIST, PSPV, CTX, and STATE, except that if if hint-type is non-nil then there
; may be additional variables.
;
; If term is such a term, we return the translated hint:

; (EVAL-AND-TRANSLATE-HINT-EXPRESSION name-tree flg term')

; where term' is the translation of term and flg indicates whether
; STABLE-UNDER-SIMPLIFICATIONP occurs freely in it.

; (b) We also allow term to be a symbol denoting a 3, 4, or 7 argument function
; not involving state and returning a single value taking:

;     (i)   a clause-id, a clause, and world, or,
;     (ii)  a clause-id, a clause,     world, and
;           stable-under-simplificationp, or
;     (iii) a clause-id, a clause,     world,
;           stable-under-simplificationp, hist, pspv, and ctx.

; We ``translate'' such a function symbol into a call of the function on the
; appropriate argument variables.

; Here is a form that allows us to trace many of the functions related to
; translating hints.

; (trace$
;  (translate-hints+1)
;  (translate-hints+1@par)
;  (translate-hints2)
;  (translate-hints2@par)
;  (translate-hints1)
;  (apply-override-hints@par)
;  (apply-override-hints)
;  (translate-x-hint-value)
;  (translate-x-hint-value@par)
;  (translate-custom-keyword-hint)
;  (translate-custom-keyword-hint@par)
;  (custom-keyword-hint-interpreter@par)
;  (custom-keyword-hint-interpreter)
;  (translate-simple-or-error-triple)
;  (translate-simple-or-error-triple@par)
;  (xtrans-eval)
;  (xtrans-eval-with-ev-w)
;  (eval-and-translate-hint-expression)
;  (eval-and-translate-hint-expression@par)
;  (translate-hint-expression@par)
;  (translate-hint-expression)
;  (translate-hints1@par)
;  (waterfall)
;  (find-applicable-hint-settings1)
;  (find-applicable-hint-settings1@par)
;  (xtrans-eval@par)
;  (simple-translate-and-eval@par)
;  (simple-translate-and-eval)
;  (translate-hints)
;  (translate-hints+)
;  (thm-fn)
;  (formal-value-triple)
;  (formal-value-triple@par)
;  (eval-clause-processor)
;  (eval-clause-processor@par)
;  (apply-top-hints-clause@par)
;  (apply-top-hints-clause)
;  (waterfall-step1)
;  (waterfall-step1@par)
;  (waterfall-step)
;  (waterfall-step@par)
;  (translate1)
;  (translate1@par)
;  (translate)
;  (translate@par)
;  (translate-doc)
;  (translate-clause-processor-hint)
;  (translate-clause-processor-hint@par)
;  (translate1-cmp))

  (cond
   ((symbolp term)
    (cond ((and (function-symbolp term wrld)
                (or (equal (arity term wrld) 3)
                    (equal (arity term wrld) 4)
                    (equal (arity term wrld) 7))
                (all-nils (stobjs-in term wrld))
                (not (eq term 'return-last)) ; avoid taking stobjs-out
                (equal (stobjs-out term wrld) '(nil)))
           (value@par
            (cond
             ((equal (arity term wrld) 3)
              (list 'eval-and-translate-hint-expression
                    name-tree
                    nil
                    (formal-value-triple@par
                     *nil*
                     (fcons-term term '(id clause world)))))
             ((equal (arity term wrld) 4)
              (list 'eval-and-translate-hint-expression
                    name-tree
                    t
                    (formal-value-triple@par
                     *nil*
                     (fcons-term term
                                 '(id clause world
                                      stable-under-simplificationp)))))
             (t
              (list 'eval-and-translate-hint-expression
                    name-tree
                    t
                    (formal-value-triple@par
                     *nil*
                     (fcons-term term
                                 '(id clause world
                                      stable-under-simplificationp
                                      hist pspv ctx))))))))
          (t (er@par soft ctx
               "When you give a hint that is a symbol, it must be a function ~
                symbol of three, four or seven arguments (not involving STATE ~
                or other single-threaded objects) that returns a single ~
                value.  The allowable arguments are ID, CLAUSE, WORLD, ~
                STABLE-UNDER-SIMPLIFICATIONP, HIST, PSPV, and CTX. See :DOC ~
                computed-hints.  ~x0 is not such a symbol."
               term))))
   (t
    (er-let*@par
     ((tterm (translate-simple-or-error-triple@par term ctx wrld state)))
     (let ((vars (all-vars tterm)))
       (cond
        ((subsetp-eq vars
                     (case hint-type
                       (backtrack *hint-expression-backtrack-vars*)
                       (override *hint-expression-override-vars*)
                       (otherwise *hint-expression-basic-vars*)))
         (value@par
          (list 'eval-and-translate-hint-expression
                name-tree
                (if (member-eq 'stable-under-simplificationp vars) t nil)
                tterm)))
        ((and (not hint-type) ; optimization
              (subsetp-eq vars *hint-expression-all-vars*))
         (let ((backtrack-bad-vars (intersection-eq '(CLAUSE-LIST PROCESSOR)
                                                    vars))
               (override-bad-vars (intersection-eq '(KEYWORD-ALIST)
                                                   vars)))
           (mv-let
            (bad-vars types-string)
            (cond (backtrack-bad-vars
                   (cond (override-bad-vars
                          (mv (append backtrack-bad-vars override-bad-vars)
                              ":BACKTRACK hints or override-hints"))
                         (t (mv backtrack-bad-vars ":BACKTRACK hints"))))
                  (t (assert$
                      override-bad-vars ; see subsetp-eq call above
                      (mv override-bad-vars "override-hints"))))
            (er@par soft ctx
              "The hint expression ~x0 mentions ~&1.  But variable~#2~[ ~&2 ~
               is~/s ~&2 are~] legal only for ~@3.  See :DOC computed-hints."
              term vars bad-vars types-string))))
        (t
         (mv-let
          (type-string legal-vars extra-doc-hint)
          (case hint-type
            (backtrack (mv ":BACKTRACK hint"
                           *hint-expression-backtrack-vars*
                           " and see :DOC hints for a discussion of :BACKTRACK ~
                        hints"))
            (override (mv "override-hint"
                          *hint-expression-override-vars*
                          " and see :DOC override-hints"))
            (otherwise (mv "Computed"
                           *hint-expression-basic-vars*
                           "")))
          (er@par soft ctx
            "~@0 expressions may not mention any variable symbols other than ~
             ~&1.  See :DOC computed-hints~@2.  But the hint expression ~x3 ~
             mentions ~&4."
            type-string
            legal-vars
            extra-doc-hint
            term
            vars)))))))))

(defun@par translate-backtrack-hint (name-tree arg ctx wrld state)
  (translate-hint-expression@par name-tree arg 'backtrack ctx wrld state))

(defun@par translate-rw-cache-state-hint (arg ctx wrld state)
  (declare (ignore wrld))
  (cond ((member-eq arg *legal-rw-cache-states*)
         (value@par arg))
        (t (er@par soft ctx
             "Illegal :rw-cache-state argument, ~x0 (should be ~v1)"
             arg
             *legal-rw-cache-states*))))

(mutual-recursion@par

(defun@par translate-or-hint (name-tree str arg ctx wrld state)

; Arg is the value of the :OR key in a user-supplied hint settings,
; e.g., if the user typed: :OR ((:in-theory t1 :use lem1) (:in-theory
; t2 :use lem2)) then arg is ((:in-theory t1 :use lem1) (:in-theory t2
; :use lem2)).  The translated form of this is a list as long as arg
; in which each element of the translated list is a pair (orig
; . trans) where orig is what the user typed and trans is its
; translation as a hint-settings.  (For example, the two theory
; expressions, t1 and t2, will be expanded into full runic
; theories.)  We either cause an error or return (as the value
; component of an error/value/state triple) a list of such pairs.

; Note: str is the original goal-spec string to which this :OR was
; attached.

; Note: Unlike other hints, we do some additional translation of :OR
; hints on the output of this function!  See translate-hint.

  (cond ((atom arg)
         (if (null arg)
             (value@par nil)
           (er@par soft ctx "An :OR hint must be a true-list.")))
        (t (er-let*@par
            ((val (translate-hint@par name-tree
                                      (cons
                                       (make-disjunctive-goal-spec
                                        str
                                        (length arg)
                                        (current-package state))
                                       (car arg))
                                      nil ctx wrld state))
             (tl (translate-or-hint@par name-tree str (cdr arg) ctx wrld state)))

; Val is either a translated computed hint expression, whose car
; is eval-and-translate-hint-expression, or else it is a pair of
; the form (cl-id . hint-settings), where cl-id was derived from
; str.

            (cond
             ((eq (car val) 'eval-and-translate-hint-expression)
              (value@par (cons (cons (car arg) val)
                               tl)))
             (t

; If val is (cl-id . hint-settings), we just let val be hint-settings
; below, as the cl-id is being managed by the :OR itself.

              (let ((val (cdr val)))
                (value@par (cons (cons (car arg) val)
                                 tl)))))))))

(defun@par translate-hint-settings (name-tree str key-val-lst ctx wrld state)

; We assume that key-val-lst is a list of :keyword/value pairs, (:key1
; val1 ... :keyn valn), and that each :keyi is one of the acceptable
; hint keywords.  We convert key-val-lst to alist form, ((:key1 .
; val1') ... (:keyn . valn')), where each vali' is the translated form
; of vali.

; Str is the goal-spec string identifying the clause to which these
; hints are attached.

  (cond
   ((null key-val-lst) (value@par nil))
   ((and (eq (car key-val-lst) :use)
         (eq (cadr key-val-lst) nil))

; We allow empty :use hints, but we do not want to have to think about
; how to process them.

    (translate-hint-settings@par name-tree
                                 str
                                 (cddr key-val-lst) ctx wrld state))
   (t (er-let*@par
       ((val (translate-x-hint-value@par name-tree
                                         str
                                         (car key-val-lst) (cadr key-val-lst)
                                         ctx wrld state))
        (tl (translate-hint-settings@par name-tree
                                         str
                                         (cddr key-val-lst) ctx wrld state)))
       (value@par
        (cons (cons (car key-val-lst) val)
              tl))))))

(defun@par translate-x-hint-value (name-tree str x arg ctx wrld state)

; Str is the goal-spec string identifying the clause to which this
; hint was attached.

  (mv-let
   (flg uterm1 uterm2)
   (custom-keyword-hint x wrld)
   (declare (ignore uterm1))
   (cond
    (flg
     (translate-custom-keyword-hint@par arg uterm2 ctx wrld state))
    (t
     (case x
       (:expand
        (translate-expand-hint@par arg ctx wrld state))
       (:restrict
        (translate-restrict-hint@par arg ctx wrld state))
       (:hands-off
        (translate-hands-off-hint@par arg ctx wrld state))
       (:do-not-induct
        (translate-do-not-induct-hint@par arg ctx wrld state))
       (:do-not
        (translate-do-not-hint@par arg ctx state))
       (:use
        (translate-use-hint@par arg ctx wrld state))
       (:or
        (translate-or-hint@par name-tree str arg ctx wrld state))
       (:cases
        (translate-cases-hint@par arg ctx wrld state))
       (:case-split-limitations
        (translate-case-split-limitations-hint@par arg ctx wrld state))
       (:by
        (translate-by-hint@par name-tree arg ctx wrld state))
       (:induct
        (translate-induct-hint@par arg ctx wrld state))
       (:in-theory
        (translate-in-theory-hint@par arg t ctx wrld state))
       (:bdd
        (translate-bdd-hint@par arg ctx wrld state))
       (:clause-processor
        (translate-clause-processor-hint@par arg ctx wrld state))
       (:nonlinearp
        (translate-nonlinearp-hint@par arg ctx wrld state))
       (:no-op
        (translate-no-op-hint@par arg ctx wrld state))
       (:no-thanks
        (translate-no-thanks-hint@par arg ctx wrld state))
       (:reorder
        (translate-reorder-hint@par arg ctx wrld state))
       (:backtrack
        (translate-backtrack-hint@par name-tree arg ctx wrld state))
       (:backchain-limit-rw
        (translate-backchain-limit-rw-hint@par arg ctx wrld state))
       (:error

; We know this case never happens.  The error is caught and signalled
; early by translate-hint.  But we include it here to remind us that
; :error is a legal keyword.  In fact the semantics given here --
; which causes an immediate error -- is also consistent with the
; intended interpretation of :error.

        (translate-error-hint@par arg ctx wrld state))
       (:rw-cache-state
        (translate-rw-cache-state-hint@par arg ctx wrld state))
       (otherwise
        (mv@par
         (er hard 'translate-x-hint-value
             "The object ~x0 not recognized as a legal hint keyword. See :DOC ~
              hints."
             x)
         nil
         state)))))))

(defun replace-goal-spec-in-name-tree1 (name-tree goal-spec)
  (cond
   ((atom name-tree)
    (cond ((and (stringp name-tree)
                (parse-clause-id name-tree))
           (mv t goal-spec))
          (t (mv nil name-tree))))
   (t (mv-let
       (flg1 name-tree1)
       (replace-goal-spec-in-name-tree1 (car name-tree)
                                        goal-spec)
       (cond
        (flg1 (mv t (cons name-tree1 (cdr name-tree))))
        (t (mv-let (flg2 name-tree2)
                   (replace-goal-spec-in-name-tree1 (cdr name-tree)
                                                    goal-spec)
                   (mv flg2
                       (cons (car name-tree)
                             name-tree2)))))))))

(defun replace-goal-spec-in-name-tree (name-tree goal-spec)

; Name-trees are trees of strings and symbols used to generate
; meaningful names for :by hints.  Typically, a name tree will have at
; most one goal spec in it, e.g., (name . "Subgoal *1/3") or
; ("Computed hint auto-generated for " (name . "Subgoal *1/3")).  We
; search nametree for the first occurrence of a goal spec and replace
; that goal spec by the given one.  This is an entirely heuristic
; operation.

; Why do we do this?  Suppose an :OR hint is attached to a given goal
; spec and we have a name tree corresponding to that goal spec.  To process
; the :OR we will produce a copy of the goal and rename the goal spec
; by adding a "Dj" suffice.  We want to replace the original goal spec
; in the name-tree by this modified goal spec.

  (mv-let (flg new-name-tree)
          (replace-goal-spec-in-name-tree1 name-tree goal-spec)
          (cond
           (flg new-name-tree)
           (t (cons name-tree goal-spec)))))

(defun@par translate-hint (name-tree pair hint-type ctx wrld state)

; Pair is supposed to be a "hint", i.e., a pair of the form (str :key1
; val1 ...  :keyn valn).  We check that it is, that str is a string
; that parses to a clause-id, and that each :keyi is a legal hint
; keyword.  Then we translate pair into a pair of the form (cl-id .
; hint-settings), where cl-id is the parsed clause-id and
; hint-settings is the translated alist form of the key/val lst above.
; We try to eliminate custom keyword hints by eager expansion.  If we
; cannot eliminate all custom hints, we do check that the individual
; :keyi vali pairs are translatable (which, in the case of the custom
; hints among them, means we run their checkers) but we ignore the
; translations.  We then convert the entire hint into a computed hint.

; We return a standard error triple.  If no custom keyword hints
; appear (or if all custom hints could be eagerly eliminated), the
; value is (cl-id . hint-settings).  If an un-eliminable custom
; keyword hint appears, the value is the translated form of a computed
; hint -- with the original version of the hint appearing in it as a
; quoted constant.

; Thus, if the car of the returned value is the word
; 'eval-and-translate-hint-expression the answer is a translated
; computed hint, otherwise it is of the form (cl-id . hint-settings).

  (cond ((not (and (consp pair)
                   (stringp (car pair))
                   (keyword-value-listp (cdr pair))))
         (er@par soft ctx
           "Each hint is supposed to be a list of the form (str :key1 val1 ~
            ... :keyn valn), but a proposed hint, ~x0, is not.  See :DOC ~
            hints."
           pair))
        (t (let ((cl-id (parse-clause-id (car pair))))
             (cond
              ((null cl-id)
               (er@par soft ctx
                 "The object ~x0 is not a goal-spec.  See :DOC hints and :DOC ~
                  goal-spec."
                 (car pair)))
              ((assoc-keyword :error (cdr pair))

; If an :error hint was given, we immediately cause the requested error.
; Note that we thus allow :error hints to occur multiple times and just
; look at the first one.  If we get past this test, there are no
; :error hints.

               (translate-error-hint@par
                (cadr (assoc-keyword :error (cdr pair)))
                ctx wrld state))
              (t
               (mv-let
                (keyi vali uterm1 uterm2)
                (find-first-custom-keyword-hint (cdr pair) wrld)
                (declare (ignore vali uterm1 uterm2))
                (cond
                 (keyi

; There is a custom keyword among the keys.  One of two possibilities
; exists.  The first is that the hint can be expanded statically
; (``eagerly'') now.  The second is that the hint is truly sensitive
; to dynamically determined variables like the variables CLAUSE, HIST,
; STABLE-UNDER-SIMPLIFICATIONP, or PSPV and must consequently be
; treated essentially as a computed hint.  But there is no way to find
; out except by trying to evaluate it!  That is because even if this
; hint involves none of the dynamic variables it might be that the
; value it computes contains other custom keyword hints that do
; involve those variables.

; Note: Recall that the interpreter runs the checker on a val before
; it runs the generator.  So each generator knows that its val is ok.
; But generators do not know that all vals are ok.  That is, a
; generator cannot assume that a common hint has a well-formed val or
; that other custom hints have well-formed vals.

                  (mv-let@par
                   (erp val state)
                   (custom-keyword-hint-interpreter@par
                    (cdr pair)
                    cl-id
                    cl-id
                    NIL wrld NIL NIL NIL ctx state
                    t)

; The four NILs above are bogus values for the dynamic variables.  The
; final t is the eagerp flag which will cause the interpreter to
; signal the WAIT ``error'' if the expansion fails because of some
; unbound dynamic variable.

                   (cond
                    (erp
                     (cond
                      ((eq val 'WAIT)

; In this case, we must treat this as a computed hint so we will
; manufacture an appropriate one.  As a courtesy to the user, we will
; check that all the hints are translatable.  But we ignore the
; translations because there is no way to know whether they are
; involved in the actual hint that will be generated by the processing
; of these custom hints when the subgoal arises.

                       (er-let*@par
                        ((hint-settings
                          (translate-hint-settings@par
                           (replace-goal-spec-in-name-tree
                            name-tree
                            (car pair))
                           (car pair)
                           (cdr pair)
                           ctx wrld state)))

; Note: If you ever consider not ignoring the translated
; hint-settings, recognize how strange it is.  E.g., it may have
; duplicate conflicting bindings of standard keys and pairs
; binding custom keywords to their untranslated values, a data
; structure we never use.

                        (translate-hint-expression@par
                         name-tree

; Below we generate a standard computed hint that uses the
; interpreter.  Note that the interpreter is given the eagerp
; NIL flag.

                         (serial-first-form-parallel-second-form@par
                          `(custom-keyword-hint-interpreter
                            ',(cdr pair)
                            ',cl-id
                            ID CLAUSE WORLD STABLE-UNDER-SIMPLIFICATIONP
                            HIST PSPV CTX STATE 'nil)
                          `(custom-keyword-hint-interpreter@par
                            ',(cdr pair)
                            ',cl-id
                            ID CLAUSE WORLD STABLE-UNDER-SIMPLIFICATIONP
                            HIST PSPV CTX STATE 'nil))
                         hint-type ctx wrld state)))
                      (t (mv@par t nil state))))
                    (t

; In this case, we have eliminated all custom keyword hints
; eagerly and val is a keyword alist we ought to
; use for the hint.  We translate it from scratch.

                     (translate-hint@par name-tree
                                         (cons (car pair) val)
                                         hint-type ctx wrld state)))))
                 (t

; There are no custom keywords in the hint.

                  (let* ((key-val-lst (remove-redundant-no-ops (cdr pair)))

; By stripping out redundant :NO-OPs now we allow such lists as (:OR x
; :NO-OP T), whereas normally :OR would "object" to the presence of
; another hint.

                         (keys (evens key-val-lst))
                         (expanded-hint-keywords
                          (append
                           (strip-cars
                            (table-alist 'custom-keywords-table wrld))
                           *hint-keywords*)))
                    (cond
                     ((null keys)
                      (er@par soft ctx
                        "There is no point in attaching the empty list of ~
                          hints to ~x0.  We suspect that you have made a ~
                          mistake in presenting your hints.  See :DOC hints. ~
                          ~ If you really want a hint that changes nothing, ~
                          use ~x1."
                        (car pair)
                        (cons (car pair) '(:NO-OP T))))
                     ((not (subsetp-eq keys expanded-hint-keywords))
                      (er@par soft ctx
                        "The legal hint keywords are ~&0.  ~&1 ~
                          ~#1~[is~/are~] unrecognized.  See :DOC hints."
                        expanded-hint-keywords
                        (set-difference-eq keys expanded-hint-keywords)))
                     ((member-eq :computed-hints-replacement keys)

; If translate-hint is called correctly, then we expect this case not to arise
; for well-formed hints.  For example, in eval-and-translate-hint-expression we
; remove an appropriate use of :computed-hints-replacement.

                      (er@par soft ctx
                        "The hint keyword ~x0 has been used incorrectly.  ~
                          Its only appropriate use is as a leading hint ~
                          keyword in computed hints.  See :DOC computed-hints."
                        :computed-hints-replacement))
                     ((not (no-duplicatesp-equal keys))
                      (er@par soft ctx
                        "You have duplicate occurrences of the hint keyword ~
                          ~&0 in your hint.  While duplicate occurrences of ~
                          keywords are permitted by CLTL, the semantics ~
                          ignores all but the left-most.  We therefore ~
                          suspect that you have made a mistake in presenting ~
                          your hints."
                        (duplicates keys)))
                     ((and (assoc-keyword :OR (cdr pair))
                           (not (minimally-well-formed-or-hintp
                                 (cadr (assoc-keyword :OR (cdr pair))))))

; Users are inclined to write hints like this:

; ("Goal" :OR ((...) (...)) :in-theory e)

; as abbreviations for

; ("Goal" :OR ((... :in-theory e) (... :in-theory e)))

; We implement this abbreviation below.  But we have to know that the
; value supplied to the :OR is a list of non-empty true-lists of even
; lengths to insure that we can append the other hints to it and still
; get reasonable translation errors in the presence of ill-formed
; hints.  If not, we cause an error now.  We check the rest of the
; restrictions on :OR after the transformation.

                      (er@par soft ctx
                        "The value supplied to an :OR hint must be a ~
                          non-empty true-list of non-empty true-lists of even ~
                          length, i.e., of the form ((...) ...).  But you ~
                          supplied the value ~x0."
                        (cdr pair)))
                     ((and (member-eq :induct keys)
                           (member-eq :use keys))
                      (er@par soft ctx
                        "We do not support the use of an :INDUCT hint with a ~
                          :USE hint.  When a subgoal with an :INDUCT hint ~
                          arises, we push it for proof by induction.  Upon ~
                          popping it, we interpret the :INDUCT hint to ~
                          determine the induction and we also install any ~
                          other non-:USE hints supplied.  On the other hand, ~
                          when a subgoal with a :USE hint arises, we augment ~
                          the formula with the additional hypotheses supplied ~
                          by the hint.  If both an :INDUCT and a :USE hint ~
                          were attached to the same subgoal we could either ~
                          add the hypotheses before induction, which is ~
                          generally detrimental to a successful induction, or ~
                          add them to each of the formulas produced by the ~
                          induction, which generally adds the hypotheses in ~
                          many more places than they are needed.  We ~
                          therefore do neither and cause this neat, ~
                          informative error.  You are encouraged to attach ~
                          the :INDUCT hint to the goal or subgoal to which ~
                          you want us to apply induction and then attach :USE ~
                          hints to the individual subgoals produced, as ~
                          necessary.  For what it is worth, :INDUCT hints get ~
                          along just fine with hints besides :USE.  For ~
                          example, an :INDUCT hint and an :IN-THEORY hint ~
                          would cause an induction and set the post-induction ~
                          locally enabled theory to be as specified by the ~
                          :IN-THEORY."))
                     ((and (member-eq :reorder keys)
                           (intersectp-eq '(:or :induct) keys))
                      (cond
                       ((member-eq :or keys)
                        (er@par soft ctx
                          "We do not support the use of a :REORDER hint with ~
                            an :OR hint.  The order of disjunctive subgoals ~
                            corresponds to the list of hints given by the :OR ~
                            hint, so you may want to reorder that list ~
                            instead."))
                       (t
                        (er@par soft ctx
                          "We do not support the use of a :REORDER hint with ~
                            an :INDUCT hint.  If you want this capability, ~
                            please send a request to the ACL2 implementors."))))
                     (t
                      (let ((bad-keys (intersection-eq
                                       `(:induct ,@*top-hint-keywords*)
                                       keys)))
                        (cond
                         ((and (< 1 (length bad-keys))
                               (not (and (member-eq :use bad-keys)
                                         (member-eq :cases bad-keys)
                                         (equal 2 (length bad-keys)))))
                          (er@par soft ctx
                            "We do not support the use of a~#0~[n~/~] ~x1 ~
                              hint with a~#2~[n~/~] ~x3 hint, since they ~
                              suggest two different ways of replacing the ~
                              current goal by new goals.  ~@4Which is it to ~
                              be?  To summarize:  A~#0~[n~/~] ~x1 hint ~
                              together with a~#2~[n~/~] ~x3 hint is not ~
                              allowed because the intention of such a ~
                              combination does not seem sufficiently clear."
                            (if (member-eq (car bad-keys) '(:or :induct))
                                0 1)
                            (car bad-keys)
                            (if (member-eq (cadr bad-keys) '(:or :induct))
                                0 1)
                            (cadr bad-keys)
                            (cond
                             ((and (eq (car bad-keys) :by)
                                   (eq (cadr bad-keys) :induct))
                              "The :BY hint suggests that the goal follows ~
                                 from an existing theorem, or is to be ~
                                 pushed.  However, the :INDUCT hint provides ~
                                 for replacement of the current goal by ~
                                 appropriate new goals before proceeding.  ")
                             (t ""))))
                         (t
                          (er-let*@par
                           ((hint-settings
                             (translate-hint-settings@par
                              (replace-goal-spec-in-name-tree
                               name-tree
                               (car pair))
                              (car pair)
                              (cond
                               ((assoc-keyword :or (cdr pair))
                                (distribute-other-hints-into-or
                                 (cdr pair)))
                               (t (cdr pair)))
                              ctx wrld state)))
                           (cond

; Hint-settings is of the form ((:key1 . val1) ...(:keyn . valn)).
; If :key1 is :OR, we know n=1; translated :ORs always occur as
; singletons.  But in ((:OR . val1)), val1 is always
; (((key . val) ...) ... ), i.e., is a list of alists.
; If there is only one alist in that list, then we're dealing
; with an :OR with only one disjunct.

                            ((and (consp hint-settings)
                                  (eq (caar hint-settings) :OR)
                                  (consp (cdr (car hint-settings)))
                                  (null (cddr (car hint-settings))))

; This is a singleton :OR.  We just drop the :OR.

                             (assert$
                              (null (cdr hint-settings))
                              (value@par
                               (cons cl-id
                                     (car (cdr (car hint-settings)))))))
                            (t (value@par
                                (cons cl-id hint-settings))))))))))))))))))))
)

(defun@par translate-hint-expressions (name-tree terms hint-type ctx wrld state)

; This function translates a true-list of hint expressions.  It is used when a
; hint generates a new list of hints.

  (cond
   ((endp terms)
    (cond ((equal terms nil) (value@par nil))
          (t (er@par soft ctx
               "The value of the :COMPUTED-HINT-REPLACEMENT key must be NIL, ~
                T, or a true list of terms.  Your list ends in ~x0."
               terms))))
   (t (er-let*@par
       ((thint (translate-hint-expression@par name-tree (car terms)
                                              hint-type ctx wrld
                                              state))
        (thints (translate-hint-expressions@par name-tree (cdr terms)
                                                hint-type ctx wrld state)))
       (value@par (cons thint thints))))))

(defun@par check-translated-override-hint (hint uhint ctx state)
  (cond ((not (and (consp hint)
                   (eq (car hint)
                       'eval-and-translate-hint-expression)))
         (er@par soft ctx
             "The proposed override-hint, ~x0, was not a computed hint.  See ~
              :DOC override-hints."
             uhint))
        (t ; term is (caddr (cdr hint)); we allow any term here
         (value@par nil))))

(defun@par translate-hints1 (name-tree lst hint-type override-hints ctx wrld state)

; A note on the taxonomy of translated hints.  A "hint setting" is a pair of
; the form (key . val), such as (:DO-NOT-INDUCT . T) or (:USE . (lmi-lst
; (h1...hn) ...)).  Lists of such pairs are called "hint settings."  A pair
; consisting of a clause-id and some hint-settings is called a "(translated)
; hint".  A list of such pairs is called "(translated) hints."

; Thus, following the :HINTS keyword to defthm, the user types "hints" (in
; untranslated form).  This function takes a lst, which is supposed be some
; hints, and translates it or else causes an error.

; Essay on the Handling of Override-hints

; When we translate an explicit (not computed) hint in the presence of at least
; one non-trivial override hint in the world, we append to the front of the
; hint-settings the list (:keyword-alist . x) (:name-tree . n), where x is the
; untranslated keyword-alist corresponding to hint-settings and n is the
; name-tree used for translation: so the hint is (goal-name (:keyword-alist
; . x) (:name-tree . n) (kwd1 . v1) ... (kwdk . vk)).  Later, when we select
; the hint with find-applicable-hint-settings, we will see (:keyword-alist . x)
; and apply the override-hints to x, and if the result of apply-override-hints
; is also x, then we will return ((kwd1 . v1) ... (kwdk . vk)); otherwise we
; will translate that result.  Note that in the special case that the original
; hint had at least one custom keyword hint but the ultimate resulting
; expansion was an explicit hint, the same technique will apply.  Also note
; that the keyword :keyword-alist is illegal for users, and would be flagged as
; such by translate-hint in translate-hints1; so we have full control over the
; use of :keyword-alist (and similarly for :name-tree).

; If however the resulting translated hint is a computed hint, i.e. a list
; whose car is 'eval-and-translate-hint-expression, then no modification is
; necessary; function find-applicable-hint-settings takes care to apply
; override-hints, by calling function eval-and-translate-hint-expression with
; the override-hints supplied.

; And how about backtrack hints?  Backtrack hints are computed hints, and
; receive the same treatment as described above, i.e. for computed hints
; selected by find-applicable-hint-settings -- namely, by passing the world's
; override-hints to eval-and-translate-hint-expression.

  (cond ((atom lst)
         (cond ((null lst) (value@par nil))
               (t (er@par soft ctx
                    "The :HINTS keyword is supposed to have a true-list as ~
                     its value, but ~x0 is not one.  See :DOC hints."
                    lst))))
        ((and (consp (car lst))
              (stringp (caar lst))
              (null (cdar lst)))
         (translate-hints1@par name-tree (cdr lst) hint-type override-hints ctx
                               wrld state))
        (t (er-let*@par
            ((hint (cond ((and (consp (car lst))
                               (stringp (caar lst)))
                          (translate-hint@par name-tree (car lst) hint-type ctx
                                              wrld state))
                         (t (translate-hint-expression@par
                             name-tree (car lst) hint-type ctx wrld state))))
             (rst (translate-hints1@par name-tree (cdr lst) hint-type
                                        override-hints ctx wrld state)))
            (er-progn@par
             (cond ((eq hint-type 'override)
                    (check-translated-override-hint@par hint (car lst) ctx state))
                   (t (value@par nil)))
             (value@par (cons (cond ((atom hint) hint) ; nil
                                    ((and (consp (car lst))
                                          (stringp (caar lst)))
                                     (cond (override-hints
                                            (list* (car hint) ; (caar lst)
                                                   (cons :KEYWORD-ALIST
                                                         (cdar lst))
                                                   (cons :NAME-TREE
                                                         name-tree)
                                                   (cdr hint)))
                                           (t hint)))
                                    ((eq (car hint)
                                         'eval-and-translate-hint-expression)
                                     hint)
                                    (t (er hard ctx
                                           "Internal error: Unexpected ~
                                            translation ~x0 for hint ~x1.  ~
                                            Please contact the ACL2 ~
                                            implementors."
                                           hint (car lst))))
                              rst)))))))

(defun@par warn-on-duplicate-hint-goal-specs (lst seen ctx state)
  (cond ((endp lst)
         (state-mac@par))
        ((and (consp (car lst))
              (stringp (caar lst)))
         (if (member-equal (caar lst) seen)
             (pprogn@par (warning$@par ctx ("Hints")
                           "The goal-spec ~x0 is explicitly associated with ~
                            more than one hint.  All but the first of these ~
                            hints may be ignored.  If you intended to give ~
                            all of these hints, combine them into a single ~
                            hint of the form (~x0 :kwd1 val1 :kwd2 val2 ...). ~
                            ~ See :DOC hints-and-the-waterfall."
                           (caar lst))
                         (warn-on-duplicate-hint-goal-specs@par (cdr lst) seen
                                                                ctx state))
           (warn-on-duplicate-hint-goal-specs@par (cdr lst)
                                                  (cons (caar lst) seen)
                                                  ctx state)))
        (t (warn-on-duplicate-hint-goal-specs@par (cdr lst) seen ctx state))))

(defun@par translate-hints2 (name-tree lst hint-type override-hints ctx wrld state)
  (cond ((warning-disabled-p "Hints")
         (translate-hints1@par name-tree lst hint-type override-hints ctx wrld
                               state))
        (t
         (er-let*@par ((hints (translate-hints1@par name-tree lst hint-type
                                                    override-hints ctx wrld
                                                    state)))
                      (pprogn@par (warn-on-duplicate-hint-goal-specs@par
                                   lst nil ctx state)
                                  (value@par hints))))))

(defun override-hints (wrld)
  (declare (xargs :guard (and (plist-worldp wrld)
                              (alistp (table-alist 'default-hints-table
                                                   wrld)))))
  (cdr (assoc-eq :override (table-alist 'default-hints-table wrld))))

(defun@par translate-hints (name-tree lst ctx wrld state)
  (translate-hints2@par name-tree lst nil (override-hints wrld) ctx wrld
                        state))

(defun@par translate-hints+1 (name-tree lst default-hints ctx wrld state)
  (cond
   ((not (true-listp lst))
    (er@par soft ctx
      "The :HINTS keyword is supposed to have a true-list as its value, but ~
       ~x0 is not one.  See :DOC hints."
      lst))
   (t
    (translate-hints@par name-tree (append lst default-hints) ctx wrld
                         state))))

(defun translate-hints+ (name-tree lst default-hints ctx wrld state)
  #-acl2-par
  (translate-hints+1 name-tree lst default-hints ctx wrld state)
  #+acl2-par
  (if (f-get-global 'waterfall-parallelism state)
      (cmp-to-error-triple
       (translate-hints+1@par name-tree lst default-hints ctx wrld state))
      (translate-hints+1 name-tree lst default-hints ctx wrld state)))

(defun translate-override-hints (name-tree lst ctx wrld state)
  #-acl2-par
  (translate-hints2 name-tree lst 'override
                    nil ; no override-hints are applied
                    ctx wrld state)
  #+acl2-par
  (if (f-get-global 'waterfall-parallelism state)
      (cmp-to-error-triple
       (translate-hints2@par name-tree lst 'override
                             nil ; no override-hints are applied
                             ctx wrld state))
    (translate-hints2 name-tree lst 'override
                      nil ; no override-hints are applied
                      ctx wrld state)))

(defun@par apply-override-hint1
  (override-hint cl-id clause hist pspv ctx wrld
                 stable-under-simplificationp clause-list processor
                 keyword-alist state)

; Apply the given override-hints to the given keyword-alist (for a hint) to
; obtain a resulting keyword alist.

  (let* ((tuple override-hint)
         (flg (cadr (cdr tuple)))
         (term (caddr (cdr tuple))))
    (er-let*@par
     ((new-keyword-alist
       (xtrans-eval@par
        term
        (list* (cons 'id cl-id)
               (cons 'clause clause)
               (cons 'hist hist)
               (cons 'pspv pspv)
               (cons 'ctx ctx)
               (cons 'world wrld)
               (cons 'clause-list clause-list)
               (cons 'processor processor)
               (cons 'keyword-alist keyword-alist)
               (if flg
                   (cons (cons 'stable-under-simplificationp
                               stable-under-simplificationp)
                         nil)
                 nil))

; #+ACL2-PAR note: we wish that we could have determined that the translation
; mentioned at the beginning of this function's definition was performed by
; translate-simple-or-error-triple@par (via a call to translate-hints+@par,
; which occurs before entering the waterfall).  However, in the case of
; override hints, the translation really occurs when the override hint is added
; (perhaps via a call to "set-override-hints").  As such, even though we would
; like to check the output signature of the override hint, there is no way to
; do so without retranslating.  We therefore disallow override hints whenever
; waterfall parallelism is enabled and waterfall-parallelism-hacks have not
; been enabled.

        nil ; trans-flg = nil because term is already translated
        t   ; ev-flg = t because we have bound all the vars
        ctx state t)))
     (cond
      ((not (keyword-value-listp new-keyword-alist))
       (er@par soft ctx
         "An override-hint, ~x0, has produced an illegal value from ~
          keyword-alist ~x1.  That value, ~x2, is illegal because it is not a ~
          keyword-value-listp, i.e., an alternating list of keywords and ~
          values."
         (untranslate term nil wrld)
         keyword-alist
         new-keyword-alist))
      (t

; If an override-hint generates a hint with a custom keyword that is sensitive
; to stable-under-simplificationp, then that keyword will not have been
; expanded away at hint translation time.  We deal with it now.  The following
; example from Ian Johnson failed before invoking
; custom-keyword-hint-interpreter here.

; (set-state-ok t)
; (defun blah (val stable-under-simplificationp state)
;   (declare (ignore val stable-under-simplificationp))
;   (value '(:in-theory (enable car-cons))))
; (add-custom-keyword-hint :test
;                          (blah val stable-under-simplificationp state))
; (defun ovrride (keyword-alist state)
;   (let ((ret (append keyword-alist (list :test t))))
;     (prog2$
;      (cw "HINTS ~x0 ~%" ret)
;      (if keyword-alist
;          (value ret)
;        (value nil)))))
; (add-override-hints (list '(ovrride keyword-alist state)))
; (thm (equal (* 4 (car (cons x x))) (* x 4))
;      :hints (("Goal" :in-theory (disable car-cons))))

       (mv-let@par
        (erp new-keyword-alist state)
        (custom-keyword-hint-interpreter@par
         new-keyword-alist
         cl-id
         cl-id
         clause wrld stable-under-simplificationp
         hist pspv ctx state
         nil)
        (cond
         (erp
          (er@par soft ctx
            "An override-hint applied to ~@0 has generated an illegal custom ~
             keyword hint, as reported above."
            (tilde-@-clause-id-phrase cl-id)))
         ((eq (car new-keyword-alist)
              :computed-hints-replacement)
          (er@par soft ctx
            "An override-hint, ~x0, has produced an illegal value from ~
             keyword-alist ~x1.  That value, ~x2, is illegal because it ~
             begins with the keyword :COMPUTED-HINT-REPLACEMENT; see :DOC ~
             override-hints."
            (untranslate term nil wrld)
            keyword-alist
            new-keyword-alist))
         ((assoc-keyword :error new-keyword-alist)
          (translate-error-hint@par
           (cadr (assoc-keyword :error new-keyword-alist))
           (msg "an override hint applied to ~@0"
                (tilde-@-clause-id-phrase cl-id))
           wrld state))
         (t
          (value@par new-keyword-alist)))))))))

(defun@par apply-override-hint
  (override-hint cl-id clause hist pspv ctx wrld
                 stable-under-simplificationp clause-list processor
                 keyword-alist state)
  #-acl2-par
  (apply-override-hint1 override-hint cl-id clause hist pspv ctx wrld
                        stable-under-simplificationp clause-list processor
                        keyword-alist state)
  #+acl2-par
  (cond ((and (f-get-global 'waterfall-parallelism state)
              (not (cdr (assoc-eq 'hacks-enabled
                                  (table-alist 'waterfall-parallelism-table
                                               (w state))))))
         (er@par soft ctx
           "Override-hints are not officially supported in ACL2(p).  If you ~
            wish to use override hints anyway, you can call ~x0. See :DOC ~
            set-waterfall-parallelism-hacks-enabled for more information."
           '(set-waterfall-parallelism-hacks-enabled t)))
        (t (apply-override-hint1@par override-hint cl-id clause hist pspv ctx
                                     wrld stable-under-simplificationp
                                     clause-list processor keyword-alist
                                     state))))

(defun@par apply-override-hints
  (override-hints cl-id clause hist pspv ctx wrld
                  stable-under-simplificationp clause-list processor
                  keyword-alist state)

; Apply the given override-hints to the given keyword-alist (for a hint) to
; obtain a resulting keyword alist.

  (cond
   ((endp override-hints)
    (value@par keyword-alist))
   (t
    (er-let*@par
     ((new-keyword-alist
       (apply-override-hint@par
        (car override-hints) cl-id clause hist pspv ctx wrld
        stable-under-simplificationp clause-list processor
        keyword-alist state)))
     (apply-override-hints@par
      (cdr override-hints) cl-id clause hist pspv ctx wrld
      stable-under-simplificationp clause-list processor
      new-keyword-alist state)))))

(defun@par eval-and-translate-hint-expression
  (tuple cl-id clause wrld stable-under-simplificationp hist pspv clause-list
         processor keyword-alist hint-type override-hints ctx state)

; Tuple is of the form (name-tree flg term), where term is a translated
; single-threaded error-triple producing term that mentions, at most, the
; variables ID, CLAUSE, CLAUSE-LIST, PROCESSOR, KEYWORD-ALIST, WORLD,
; STABLE-UNDER-SIMPLIFICATIONP, HIST, PSPV, CTX, and STATE; and flg is a flag
; indicating whether the variable STABLE-UNDER-SIMPLIFICATIONP occurs freely in
; term.  We eval term under the corresponding alist, obtaining a value val, and
; if val is non-erroneous and non-nil then we treat it as though it were a
; keyword-alist from an untranslated hint, i.e., (:key1 val1 ...), and
; translate it, using name-tree as the gensym name-tree for :bye hints.  We
; return the translated hint-settings or nil.

; The above description is inaccurate in three respects.  First, after the
; evaluation of term we restore proof related components of state.  Our
; intention is that the user have state so the computed hint can, say,
; translate terms and print error messages.  But we cannot prevent the user
; from abusing state and doing things like reading from files (which we can't
; undo) or changing the logical world with defun or defthm (which we can undo).
; So think of us as ignoring the state returned by the evaluation and reverting
; to the original one.

; Second, let's first remind ourselves that a computed hint gets to specify not
; just what the hint-settings is for this application but also gets to affect
; the hints that will be available later.  A computed hint can direct the
; system to (a) remove itself from the hints after the application, (b) leave
; itself in after the application, or (c) replace itself with a list of other
; hints.  This direction is provided by including the keyword
; :COMPUTED-HINT-REPLACEMENT and an associated value in the result, val, of the
; evaluation.

; The :COMPUTED-HINT-REPLACEMENT keyword and its value, chr, if provided, MUST
; BE THE FIRST two elements of val.

; The first paragraph is correct when val does not start with
; :COMPUTED-HINT-REPLACEMENT.  Otherwise, val is of the form
; (:COMPUTED-HINT-REPLACEMENT chr . keyword-alist) and this is what we do.  If
; keyword-alist is nil then we return (value nil).  Otherwise, we treat
; keyword-alist as an untranslated hint-settings and translate it.  We inspect
; chr to see whether it is (a) nil, (b) t, or (c) something else.  The first
; two mean the hint is to be (a) deleted or (b) preserved.  The last is
; understood as a list of terms to be be spliced into the hints in place of
; this one.  But these terms must be translated and so we do that.  Then we
; return (:COMPUTED-HINT-REPLACEMENT chr' . hint-settings), where chr' is the
; possibly translated chr and hint-settings' is the translated keyword-alist.
; It is left to our caller to interpret chr' and modify the hints
; appropriately.

; Finally the third inaccuracy of our initial description above is that it
; fails to account for override-hints.  We apply the given override-hints if
; the computed hint returns a keyword-value-alistp that is non-nil even after
; stripping off a (:COMPUTED-HINT-REPLACEMENT val) prefix.

  (let* ((name-tree (car tuple))
         (flg (cadr tuple))
         (term (caddr tuple))
         (custom-keyword-alist

; Keep this is sync with custom-keyword-hint-in-computed-hint-form.  This
; variable is set to nil if this is an undistinguished computed hint and is set
; to non-nil if it is a custom keyword hint in computed hint form.  The non-nil
; value is a hint keyword alist containing at least one custom keyword.

          (if (and (nvariablep term)
                   (not (fquotep term))
                   (serial-first-form-parallel-second-form@par
                    (eq (ffn-symb term) 'custom-keyword-hint-interpreter)
                    (or (eq (ffn-symb term)
                            'custom-keyword-hint-interpreter)
                        (eq (ffn-symb term)
                            'custom-keyword-hint-interpreter@par)))
                   (quotep (fargn term 1))
                   (quotep (fargn term 2)))
              (cadr (fargn term 1))
            nil)))

; The use of flg below might save a few conses.  We do this only because we
; can.  The real reason we have have the flg component in the computed hint
; tuple has to do with optimizing find-applicable-hint-settings.

    (er-let*@par
     ((val0 (xtrans-eval@par
             term
             (list* (cons 'id cl-id)
                    (cons 'clause clause)
                    (cons 'clause-list clause-list)
                    (cons 'processor processor)
                    (cons 'keyword-alist keyword-alist)
                    (cons 'world wrld)
                    (cons 'hist hist)
                    (cons 'pspv pspv)
                    (cons 'ctx ctx)
                    (if flg
                        (cons (cons 'stable-under-simplificationp
                                    stable-under-simplificationp)
                              nil)
                      nil))
             nil ; trans-flg = nil because term is already translated
             t   ; ev-flg = t because we have bound all the vars
             ctx state t)))
     (cond
      ((null val0)
       (value@par nil))
      (t
       (er-let*@par
        ((str (value@par (string-for-tilde-@-clause-id-phrase cl-id)))
         (chr-p

; This is a reasonable place to catch a non-keyword-alist result.  Before we
; had override-hints, we waited for the translate-hint call below.  But
; override-hints expect keyword-alists, so we do our checking earlier now.

          (cond ((keyword-value-listp val0)
                 (value@par (eq (car val0) :computed-hint-replacement)))
                (t
                 (er@par soft ctx
                   "A ~#0~[custom keyword~/computed~] hint for ~x1 has ~
                    produced a result that is not an alternating list of ~
                    keywords and values, (str :key1 val1 ... :keyn valn).  ~
                    That result, ~x2, is thus illegal."
                   (if custom-keyword-alist 0 1)
                   str
                   val0))))
         (chr
          (cond
           ((null chr-p) (value@par :irrelevant)) ; chr is not used
           (custom-keyword-alist
            (er@par soft
              (msg "a custom keyword hint for ~x0"
                   str)
              "The hint ~x0 produced a :COMPUTED-HINT-REPLACEMENT value as ~
               part of its result.  It is not permitted for custom keyword ~
               hints to produce such a value (only computed hints are allowed ~
               to do that).  The result produced was ~x1."
              (cons str
                    (cadr (fargn term 1)))
              val0))
           ((not (consp (cdr val0)))
            (er@par soft
              (msg
               "a computed hint for ~x0:  The computed hint ~% ~q1 produced ~
                the non-nil result~%~y2.  But this is an illegal value"
               str
               (untranslate term nil wrld)
               val0)
              "The :COMPUTED-HINT-REPLACEMENT keyword must be followed by a ~
               list whose first element is NIL, T, or a list of terms.  The ~
               remaining elements are to be keyword/value pairs."))
           ((or (eq (cadr val0) nil) (eq (cadr val0) t))
            (value@par (cadr val0)))
           (t
            (translate-hint-expressions@par
             (cons "Computed hint auto-generated for "
                   name-tree)
             (cadr val0)
             hint-type 'auto-generated-hint wrld state))))
         (val1 (value@par (if chr-p (cddr val0) val0))))
        (cond
         ((null val1)
          (value@par nil))
         (t
          (er-let*@par
           ((val (cond ((and (keyword-value-listp val1)
                             (assoc-keyword :ERROR val1))

; If the hint produced an :ERROR as one of the keys of its result, then rather
; than translate the whole hint we pick out the :ERROR msg and print it
; directly.

                        (translate-error-hint@par
                         (cadr (assoc-keyword :ERROR val1))
                         (msg "a ~#0~[custom keyword~/computed~] hint for ~x1"
                              (if custom-keyword-alist 0 1)
                              str)
                         wrld
                         state))
                       (t (apply-override-hints@par
                           override-hints cl-id clause hist pspv ctx wrld
                           stable-under-simplificationp clause-list processor
                           val1 state)))))
           (cond
            ((null val)
             (value@par nil))
            (t
             (er-let*@par
              ((temp

; Explanation of the call of translate-hint below: The val computed is supposed
; to be of the form (:key1 val1 ...) and we need to check that it really is and
; translate it into the internal form of a hint-settings.  We cons str onto the
; front of what we translate to create (str :key1 val1 ...) and then run it
; through the standard hint translator.  That string is used in the name
; generated by :by.  If no error occurs, we get back either
; (eval-and-translate-hint-expression ...)  or (cl-id . hint-settings).  The
; former is the translated form of a computed hint.  The latter contains the
; translated hint settings we seek.  We ignore the cl-id, which comes from the
; str we consed onto val.

; The msg below is the context of any error message generated by this
; translate-hint.  It will be printed followed by a colon.

                (translate-hint@par
                 name-tree
                 (cons str val)
                 hint-type
                 (msg
                  "a ~#0~[custom keyword~/computed~] hint for ~x1:  The ~
                   ~#0~[custom keyword~/computed~] hint ~%~#0~[~x2 ~
                   ~/~q2~]produced the non-nil result~%~y3.~@4Regarding this ~
                   value"
                  (if custom-keyword-alist 0 1)
                  str
                  (if custom-keyword-alist
                      custom-keyword-alist
                    (untranslate term nil wrld))
                  val0
                  (cond ((equal val val1) "")
                        (t (msg "In turn, override-hints transformed these ~
                                 hint-settings~#0~[ (without the leading ~
                                 :COMPUTED-HINTS-REPLACEMENT value)~/~] into ~
                                 ~x1.  "
                                (if (equal val0 val1) 1 0)
                                val))))
                 wrld state))
               (temp1
                (cond
                 ((eq (car temp) 'eval-and-translate-hint-expression)
                  (eval-and-translate-hint-expression@par
                   (cdr temp)
                   cl-id clause wrld stable-under-simplificationp hist pspv
                   clause-list processor keyword-alist hint-type
                   nil ; we have already dealt with the override-hints
                   ctx state))
                 (t (value@par (cdr temp))))))
              (cond
               ((and chr-p
                     (not (eq (car temp1) :computed-hint-replacement)))

; What if chr-p and (eq (car temp1) :computed-hint-replacement)?  We take the
; value of the inner :computed-hint-replacement, but we could equally well take
; the outer value or cause an error instead.  We have simply chosen the
; simplest alternative to code.

                (value@par (list* :computed-hint-replacement
                                  chr
                                  temp1)))
               (t (value@par temp1)))))))))))))))

; Essay on Trust Tags (Ttags)

; Here we place the bulk of the code for handling trust tags (ttags).

; A trust tag (ttag) is a keyword that represents where to place responsibility
; for potentially unsafe operations.  For example, suppose we define a
; function, foo, that calls sys-call.  Any call of sys-call is potentially
; unsafe, in the sense that it can do things not normally expected during book
; certification, such as overwriting a file or a core image.  But foo's call of
; sys-call may be one that can be explained somehow as safe.  At any rate,
; translate11 allows this call of sys-call if there is an active trust tag
; (ttag), in the sense that the key :ttag is bound to a non-nil value in the
; acl2-defaults-table.  See :doc defttag for more on ttags, in particular, the
; ``TTAG NOTE'' mechanism for determining which files need to be inspected in
; order to validate the proper use of ttags.

; There is a subtlety to the handling of trust tags by include-book in the case
; of uncertified books.  Consider the following example.  We have two books,
; sub.lisp and top.lisp, but we will be considering two versions of sub.lisp,
; as indicated.

; sub.lisp
; (in-package "ACL2")
; ; (defttag :sub-ttag1) ; will be uncommented later
; (defun f (x) x)

; top.lisp
; (in-package "ACL2")
; (encapsulate
;  () ;; start lemmas for sub
;
;  (include-book "sub")
;  )

; Now take the following steps:

; In a fresh ACL2 session:
; (certify-book "sub")
; (u)
; (certify-book "top")

; Now edit sub.lisp by uncommenting the defttag form.  Then, in a fresh ACL2
; session:
; (certify-book "sub" 0 t :ttags :all)
; (u)
; (include-book "top")

; The (include-book "top") form will fail when the attempt is made to include
; the book "sub".  To see why, first consider what happens when a superior book
; "top" includes a subsidiary certified book "sub".  When include-book-fn1 is
; called in support of including "sub", the second call of
; chk-acceptable-ttags1 therein uses the certificate's ttags, stored in
; variable cert-ttags, to refine the state global 'ttags-allowed.  After that
; check and refinement, which prints ttag notes based on cert-ttags,
; ttags-allowed is bound to cert-ttags for the inclusion of "sub", with further
; ttag notes omitted during that inclusion.

; Returning to our example, the recertification of "sub" results in the
; addition of a ttag for "sub" that has not yet been noticed for "top".  So
; when we include "top", state global ttags-allowed is bound to nil, since that
; is the cert-ttags for "top".  When sub is encountered, its additional ttag is
; not allowed (because ttags-allowed is nil), and we get an error.

; In a way, this error is unfortunate; after all, top is uncertified, and we
; wish to allow inclusion of uncertified books (with a suitable warning).  But
; it seems non-trivial to re-work the scheme described above.  In particular,
; it seems that we would have to avoid binding ttags-allowed to nil when
; including "top", before we realize that "top" is uncertified.  (The check on
; sub-book checksums occurs after events are processed.)  We could eliminate
; this "barrier" under which we report no further ttag notes, but that could
; generate a lot of ttag notes -- even if we defer, we may be tempted to print
; a note for each defttag encountered in a different sub-book.

; That said, if the need is great enough for us to avoid the error described
; above, we'll figure out something.

; Finally, we note that trust tags are always in the "KEYWORD" package.  This
; simplifies the implementation of provisional certification.  Previously
; (after Version_4.3 but before the next release), Sol Swords sent an example
; in which the Complete operation caused an error, the reason being that an
; unknown package was being used in the post-alist in the certificate file.

(defmacro ttags-seen ()

; The following is a potentially useful utility, which we choose to include in
; the ACL2 sources rather than in community book books/hacking/hacker.lisp.
; Thanks to Peter Dillinger for his contribution.

  '(mv-let (col state)
           (fmt1 "~*0Warning: This output is minimally trustworthy (see :DOC ~
                  ~x1).~%"
                 `((#\0 "<no ttags seen>~%" "~q*" "~q*" "~q*"
                        ,(global-val 'ttags-seen (w state)))
                   (#\1 . ttags-seen))
                 0 (standard-co state) state ())
           (declare (ignore col))
           (value ':invisible)))

(defrec certify-book-info
  (full-book-name cert-op . include-book-phase)
  nil) ; could replace with t sometime

(defun active-book-name (wrld state)

; This returns the full book name (an absolute pathname ending in .lisp) of the
; book currently being included, if any.  Otherwise, this returns the full book
; name of the book currently being certified, if any.

  (or (car (global-val 'include-book-path wrld))
      (let ((x (f-get-global 'certify-book-info state)))
        (cond (x (let ((y (access certify-book-info x :full-book-name)))
                   (assert$ (stringp y) y)))))))

(defrec deferred-ttag-note
  (val active-book-name . include-bookp)
  t)

(defun fms-to-standard-co (str alist state evisc-tuple)

; Warning: This function is used for printing ttag notes, so do not change
; *standard-co*, not even to (standard-co state)!

  (fms str alist *standard-co* state evisc-tuple))

(defun print-ttag-note (val active-book-name include-bookp deferred-p state)

; Active-book-name is nil or else satisfies chk-book-name.  If non-nil, we
; print it as "book x" where x omits the .lisp extension, since if the defttag
; event might not be in the .lisp file.  For example, it could be in the
; expansion-alist in the book's certificate or, if the book is not certified,
; it could be in the .port file.

; If include-bookp is a cons, then its cdr satisfies chk-book-name.

  (flet ((book-name-root (book-name)
                         (subseq book-name 0 (- (length book-name) 5))))
    (pprogn
     (let* ((book-name (cond (active-book-name
                              (book-name-root active-book-name))
                             (t "")))
            (included (if include-bookp
                          " (for included book)"
                        ""))
            (str (if active-book-name
                     "TTAG NOTE~s0: Adding ttag ~x1 from book ~s2."
                   "TTAG NOTE~s0: Adding ttag ~x1 from the top level loop."))
            (bound (+ (length included)
                      (length str)
                      (length (symbol-package-name val))
                      2 ; for "::"
                      (length (symbol-name val))
                      (length book-name))))
       (mv-let (erp val state)
               (state-global-let*
                ((fmt-hard-right-margin bound set-fmt-hard-right-margin)
                 (fmt-soft-right-margin bound set-fmt-soft-right-margin))
                (pprogn (fms-to-standard-co str
                                            (list (cons #\0 included)
                                                  (cons #\1 val)
                                                  (cons #\2 book-name))
                                            state nil)
                        (cond (deferred-p state)
                              (t (newline *standard-co* state)))
                        (value nil)))
               (declare (ignore erp val))
               state))
     (cond ((and (consp include-bookp) ; (cons ctx full-book-name)
                 (not deferred-p))
            (warning$ (car include-bookp) ; ctx
                      "Ttags"
                      "The ttag note just printed to the terminal indicates a ~
                       modification to ACL2.  To avoid this warning, supply ~
                       an explicit :TTAGS argument when including the book ~
                       ~x0."
                      (book-name-root
                       (cdr include-bookp)) ; full-book-name
                      ))
           (t state)))))

(defun show-ttag-notes1 (notes state)
  (cond ((endp notes)
         (newline *standard-co* state))
        (t (pprogn (let ((note (car notes)))
                     (print-ttag-note
                      (access deferred-ttag-note note :val)
                      (access deferred-ttag-note note :active-book-name)
                      (access deferred-ttag-note note :include-bookp)
                      t
                      state))
                   (show-ttag-notes1 (cdr notes) state)))))

(defun show-ttag-notes-fn (state)
  (let* ((notes0 (f-get-global 'deferred-ttag-notes-saved state))
         (notes (remove-duplicates-equal notes0)))
    (cond (notes
           (pprogn (cond ((equal notes notes0)
                          state)
                         (t (fms-to-standard-co
                             "Note: Duplicates have been removed from the ~
                              list of deferred ttag notes before printing ~
                              them below.~|"
                             nil state nil)))
                   (show-ttag-notes1 (reverse notes) state)
                   (f-put-global 'deferred-ttag-notes-saved nil state)))
          (t (fms-to-standard-co
              "All ttag notes have already been printed.~|"
              nil state nil)))))

(defmacro show-ttag-notes ()
  '(pprogn (show-ttag-notes-fn state)
           (value :invisible)))

(defun set-deferred-ttag-notes (val state)
  (let ((ctx 'set-deferred-ttag-notes)
        (immediate-p (not val)))
    (cond
     ((member-eq val '(t nil))
      (pprogn
       (cond ((eq immediate-p
                  (eq (f-get-global 'deferred-ttag-notes state)
                      :not-deferred))
              (observation ctx
                           "No change; ttag notes are already ~@0being ~
                            deferred."
                           (if immediate-p
                               "not "
                             "")))
             ((and immediate-p
                   (consp (f-get-global 'deferred-ttag-notes state)))
              (pprogn (fms-to-standard-co
                       "Note: Enabling immediate printing mode for ttag ~
                        notes.  Below are the ttag notes that have been ~
                        deferred without being reported."
                       nil state nil)
                      (f-put-global 'deferred-ttag-notes-saved
                                    (f-get-global 'deferred-ttag-notes state)
                                    state)
                      (f-put-global 'deferred-ttag-notes
                                    nil
                                    state)
                      (show-ttag-notes-fn state)))
             (immediate-p
              (pprogn
               (observation ctx
                            "Enabling immediate printing mode for ttag notes.")
               (f-put-global 'deferred-ttag-notes
                             :not-deferred
                             state)
               (f-put-global 'deferred-ttag-notes-saved
                             nil
                             state)))
             (t
              (pprogn (fms-to-standard-co
                       "TTAG NOTE: Printing of ttag notes is being put into ~
                        deferred mode.~|"
                       nil state nil)
                      (f-put-global 'deferred-ttag-notes
                                    :empty
                                    state))))
       (value :invisible)))
     (t (er soft ctx
            "The only legal values for set-deferred-ttag-notes are ~x0 and ~
             ~x1. ~ The value ~x2 is thus illegal."
            t nil val)))))

(defun ttags-from-deferred-ttag-notes1 (notes)

; Notes is formed by pushing ttag notes, hence we want to consider the
; corresponding ttags in reverse order.  But we'll want to reverse this
; result.

  (cond ((endp notes) nil)
        (t (add-to-set-eq (access deferred-ttag-note (car notes) :val)
                          (ttags-from-deferred-ttag-notes1 (cdr notes))))))

(defun ttags-from-deferred-ttag-notes (notes)
  (reverse (ttags-from-deferred-ttag-notes1 notes)))

(defun print-deferred-ttag-notes-summary (state)
  (let ((notes (f-get-global 'deferred-ttag-notes state)))
    (cond
     ((null notes)
      (f-put-global 'deferred-ttag-notes :empty state))
     ((atom notes) ; :empty or :not-deferred
      state)
     (t (pprogn (f-put-global 'deferred-ttag-notes-saved notes state)
                (fms-to-standard-co
                 "TTAG NOTE: Printing of ttag notes has been deferred for the ~
                  following list of ttags:~|  ~y0.To print the deferred ttag ~
                  notes:  ~y1."
                 (list (cons #\0 (ttags-from-deferred-ttag-notes notes))
                       (cons #\1 '(show-ttag-notes)))
                 state nil)
                (f-put-global 'deferred-ttag-notes :empty state))))))

(defun notify-on-defttag (val active-book-name include-bookp state)

; Warning: Here we must not call observation or any other printing function
; whose output can be inhibited.  The tightest security for ttags is obtained
; by searching for "TTAG NOTE" strings in the output.

  (cond
   ((or (f-get-global 'skip-notify-on-defttag state)
        (eq include-bookp :quiet))
    state)
   ((and (null include-bookp)
         (equal val (ttag (w state))))
; Avoid some noise, e.g. in encapsulate when there is already an active ttag.
    state)
   ((eq (f-get-global 'deferred-ttag-notes state)
        :not-deferred)
    (print-ttag-note val active-book-name include-bookp nil state))
   ((eq (f-get-global 'deferred-ttag-notes state)
        :empty)
    (pprogn (print-ttag-note val active-book-name include-bookp nil state)
            (f-put-global 'deferred-ttag-notes nil state)))
   (t
    (pprogn
     (cond ((null (f-get-global 'deferred-ttag-notes state))
            (fms-to-standard-co
             "TTAG NOTE: Deferring one or more ttag notes until the current ~
              top-level command completes.~|"
             nil state nil))
           (t state))
     (f-put-global 'deferred-ttag-notes
                   (cons (make deferred-ttag-note
                               :val val
                               :active-book-name active-book-name
                               :include-bookp include-bookp)
                         (f-get-global 'deferred-ttag-notes state))
                   state)))))

(defun ttag-allowed-p (ttag ttags active-book-name acc)

; We are executing a defttag event (or more accurately, a table event that
; could correspond to a defttag event).  We return nil if the ttag is illegal,
; else t if no update to ttags is required, else a new, more restrictive value
; for ttags that recognizes the association of ttag with active-book-name.

  (cond ((endp ttags)
         nil)
        ((eq ttag (car ttags))
         (revappend acc
                    (cons (list ttag active-book-name)
                          (cdr ttags))))
        ((atom (car ttags))
         (ttag-allowed-p ttag (cdr ttags) active-book-name
                         (cons (car ttags) acc)))
        ((eq ttag (caar ttags))
         (cond ((or (null (cdar ttags))
                    (member-equal active-book-name (cdar ttags)))
                t)
               (t nil)))
        (t (ttag-allowed-p ttag (cdr ttags) active-book-name
                           (cons (car ttags) acc)))))

(defun chk-acceptable-ttag1 (val active-book-name ttags-allowed ttags-seen
                                 include-bookp ctx state)

; An error triple (mv erp pair state) is returned, where if erp is nil then
; pair is either of the form (ttags-allowed1 . ttags-seen1), indicating a
; refined value for ttags-allowed and an extended value for ttags-seen, else is
; nil, indicating no such update.  By a "refined value" above, we mean that if
; val is a symbol then it is replaced in ttags-allowed by (val
; active-book-name).  However, val may be of the form (symbol), in which case
; no refinement takes place, or else of the form (symbol . filenames) where
; filenames is not nil, in which case active-book-name must be a member of
; filenames or we get an error.  Active-book-name is nil, representing the top
; level, or a string, generally thought of as an absolute filename.

; This function must be called if we are to add a ttag.  In particular, it
; should be called under table-fn; it would be a mistake to call this only
; under defttag, since then one could avoid this function by calling table
; directly.

; This function is where we call notify-on-defttag, which prints strings that
; provide the surest way for someone to check that functions requiring ttags
; are being called in a way that doesn't subvert the ttag mechanism.

  (let* ((ttags-allowed0 (cond ((eq ttags-allowed :all)
                                t)
                               (t (ttag-allowed-p val ttags-allowed
                                                  active-book-name nil))))
         (ttags-allowed1 (cond ((eq ttags-allowed0 t)
                                ttags-allowed)
                               (t ttags-allowed0))))
    (cond
     ((not ttags-allowed1)
      (er soft ctx
          "The ttag ~x0 associated with ~@1 is not among the set of ttags ~
           permitted in the current context, specified as follows:~|  ~
           ~x2.~|See :DOC defttag.~@3"
          val
          (if active-book-name
              (msg "file ~s0" active-book-name)
            "the top level loop")
          ttags-allowed
          (cond
           ((null (f-get-global 'skip-notify-on-defttag state))
            "")
           (t
            (msg "  This error is unusual since it is occurring while ~
                  including a book that appears to have been certified, in ~
                  this case, the book ~x0.  Most likely, that book needs to ~
                  be recertified, though a temporary workaround may be to ~
                  delete its certificate (i.e., its .cert file).  Otherwise ~
                  see :DOC make-event-details, section ``A note on ttags,'' ~
                  for a possible explanation."
                 (f-get-global 'skip-notify-on-defttag state))))))
     (t
      (pprogn
       (notify-on-defttag val active-book-name include-bookp state)
       (let ((old-filenames (cdr (assoc-eq val ttags-seen))))
         (cond
          ((member-equal active-book-name old-filenames)
           (value (cons ttags-allowed1 ttags-seen)))
          (t
           (value (cons ttags-allowed1
                        (put-assoc-eq val
                                      (cons active-book-name old-filenames)
                                      ttags-seen)))))))))))

(defun chk-acceptable-ttag (val include-bookp ctx wrld state)

; See the comment in chk-acceptable-ttag1, which explains the result for the
; call of chk-acceptable-ttag1 below.

  (cond
   ((null val)
    (value nil))
   (t
    (chk-acceptable-ttag1 val
                          (active-book-name wrld state)
                          (f-get-global 'ttags-allowed state)
                          (global-val 'ttags-seen wrld)
                          include-bookp ctx state))))

(defun chk-acceptable-ttags2 (ttag filenames ttags-allowed ttags-seen
                                   include-bookp ctx state)
  (cond ((endp filenames)
         (value (cons ttags-allowed ttags-seen)))
        (t (er-let* ((pair (chk-acceptable-ttag1 ttag (car filenames)
                                                 ttags-allowed ttags-seen
                                                 include-bookp ctx state)))
                    (mv-let (ttags-allowed ttags-seen)
                            (cond ((null pair)
                                   (mv ttags-allowed ttags-seen))
                                  (t (mv (car pair) (cdr pair))))
                            (chk-acceptable-ttags2 ttag (cdr filenames)
                                                   ttags-allowed ttags-seen
                                                   include-bookp ctx
                                                   state))))))

(defun chk-acceptable-ttags1 (vals active-book-name ttags-allowed ttags-seen
                                   include-bookp ctx state)

; See chk-acceptable-ttag1 for a description of the value returned based on the
; given active-book-name, tags-allowed, and ttags-seen.  Except, for this
; function, an element of vals can be a pair (tag . filenames), in which case
; active-book-name is irrelevant, as it is replaced by each filename in turn.
; If every element of vals has that form then active-book-name is irrelevant.

  (cond ((endp vals)
         (value (cons ttags-allowed ttags-seen)))
        (t (er-let* ((pair
                      (cond ((consp (car vals))
                             (chk-acceptable-ttags2 (caar vals) (cdar vals)
                                                    ttags-allowed ttags-seen
                                                    include-bookp ctx state))
                            (t
                             (chk-acceptable-ttag1 (car vals) active-book-name
                                                   ttags-allowed ttags-seen
                                                   include-bookp ctx state)))))
                    (mv-let (ttags-allowed ttags-seen)
                            (cond ((null pair)
                                   (mv ttags-allowed ttags-seen))
                                  (t (mv (car pair) (cdr pair))))
                            (chk-acceptable-ttags1 (cdr vals) active-book-name
                                                   ttags-allowed ttags-seen
                                                   include-bookp ctx
                                                   state))))))

(defun chk-acceptable-ttags (vals include-bookp ctx wrld state)

; See chk-acceptable-ttag1 for a description of the value returned based on the
; current book being included (if any), the value of state global
; 'tags-allowed, and the value of world global 'ttags-seen.

  (chk-acceptable-ttags1 vals
                         (active-book-name wrld state)
                         (f-get-global 'ttags-allowed state)
                         (global-val 'ttags-seen wrld)
                         include-bookp ctx state))

; Next we handle the table event.  We formerly did this in other-events.lisp,
; but in v2-9 we moved it here, in order to avoid a warning in admitting
; add-pc-command-1 that the *1* function for table-fn is undefined.

(defun chk-table-nil-args (op bad-arg bad-argn ctx state)

; See table-fn1 for representative calls of this weird little function.

  (cond (bad-arg
         (er soft ctx
             "Table operation ~x0 requires that the ~n1 argument to ~
              TABLE be nil.  Hence, ~x2 is an illegal ~n1 argument.  ~
              See :DOC table."
             op bad-argn bad-arg))
        (t (value nil))))

(defun chk-table-guard (name key val ctx wrld state)

; This function returns an error triple.  In the non-error case, the value is
; nil except when it is a pair as described in chk-acceptable-ttag1, based on
; the current book being included (if any), the value of state global
; 'tags-allowed, and the value of world global 'ttags-seen.

  (cond
   ((and (eq name 'acl2-defaults-table)
         (eq key :include-book-dir-alist)
         (not (f-get-global 'modifying-include-book-dir-alist state)))
    (er soft ctx
        "Illegal attempt to set the :include-book-dir-alist field of the ~
         acl2-defaults-table.  This can only be done by calling ~v0."
        '(add-include-book-dir delete-include-book-dir)))
   ((and (eq name 'include-book-dir!-table)
         (not (f-get-global 'modifying-include-book-dir-alist state)))
    (er soft ctx
        "Illegal attempt to set the include-book-dir!-table.  This can only ~
         be done by calling ~v0."
        '(add-include-book-dir! delete-include-book-dir!)))
   (t (let ((term (getprop name 'table-guard *t* 'current-acl2-world wrld)))
        (er-progn
         (mv-let
          (erp okp latches)
          (ev term
              (list (cons 'key key)
                    (cons 'val val)
                    (cons 'world wrld))
              state nil nil nil)
          (declare (ignore latches))
          (cond
           (erp (pprogn
                 (error-fms nil ctx (car okp) (cdr okp) state)
                 (er soft ctx
                     "The TABLE :guard for ~x0 on the key ~x1 and value ~x2 ~
                      could not be evaluated."
                     name key val)))
           (okp (value nil))
           (t (er soft ctx
                  "The TABLE :guard for ~x0 disallows the combination of key ~
                   ~x1 and value ~x2.  The :guard is ~x3.  See :DOC table."
                  name key val (untranslate term t wrld)))))
         (if (and (eq name 'acl2-defaults-table)
                  (eq key :ttag))
             (chk-acceptable-ttag val nil ctx wrld state)
           (value nil)))))))

(defun chk-table-guards-rec (name alist ctx pair wrld state)
  (if alist
      (er-let* ((new-pair (chk-table-guard name (caar alist) (cdar alist) ctx
                                           wrld state)))
               (if (and pair new-pair)
                   (assert$ (and (eq name 'acl2-defaults-table)
                                 (eq (caar alist) :ttag))
                            (er soft ctx
                                "It is illegal to specify the :ttag twice in ~
                                 the acl2-defaults-table."))
                 (chk-table-guards-rec name (cdr alist) ctx new-pair wrld
                                       state)))
    (value pair)))

(defun chk-table-guards (name alist ctx wrld state)

; Consider the case that name is 'acl2-defaults-table.  We do not allow a
; transition from a non-nil (ttag wrld) to a nil (ttag wrld) at the top level,
; but no such check will be made by chk-table-guard if :ttag is not bound in
; alist.  See chk-acceptable-ttag.

  (er-let* ((pair (cond ((and (eq name 'acl2-defaults-table)
                              (null (assoc-eq :ttag alist)))
                         (chk-acceptable-ttag nil nil ctx wrld state))
                        (t (value nil)))))
            (chk-table-guards-rec name alist ctx pair wrld state)))

(defun put-assoc-equal-fast (name val alist)

; If there is a large number of table events for a given table all with
; different keys, the use of assoc-equal to update the table (in table-fn1)
; causes a quadratic amount of cons garbage.  The following is thus used
; instead.

  (declare (xargs :guard (alistp alist)))
  (if (assoc-equal name alist)
      (put-assoc-equal name val alist)
    (acons name val alist)))

(defun global-set? (var val wrld old-val)
  (if (equal val old-val)
      wrld
    (global-set var val wrld)))

(defun cltl-def-from-name2 (fn stobj-function axiomatic-p wrld)

; Normally we expect to find the cltl definition of fn at the first
; 'cltl-command 'global-value triple.  But if fn is introduced by encapsulate
; then we may have to search further.  Try this, for example:

; (encapsulate ((f (x) x))
;              (local (defun f (x) x))
;              (defun g (x) (f x)))
; (cltl-def-from-name 'f nil (w state))

  (cond ((endp wrld)
         nil)
        ((and (eq 'cltl-command (caar wrld))
              (eq 'global-value (cadar wrld))
              (let ((cltl-command-value (cddar wrld)))
                (assoc-eq fn
                          (if stobj-function
                              (nth (if axiomatic-p 6 4)
                                   cltl-command-value)
                            (cdddr cltl-command-value))))))
        (t (cltl-def-from-name2 fn stobj-function axiomatic-p (cdr wrld)))))

(defrec absstobj-info
  (st$c . logic-exec-pairs)
  t)

(defun cltl-def-from-name1 (fn stobj-function axiomatic-p wrld)

; See cltl-def-from-name, which is a wrapper for this function in which
; axiomatic-p is nil.  When axiomatic-p is t, then we are to return a function
; suitable for oneify, which in the stobj case is the axiomatic definition
; rather than the raw Lisp definition.

  (and (function-symbolp fn wrld)
       (let* ((event-number
               (getprop (or stobj-function fn) 'absolute-event-number nil
                        'current-acl2-world wrld))
              (wrld
               (and event-number
                    (lookup-world-index 'event event-number wrld)))
              (def
               (and wrld
                    (cltl-def-from-name2 fn stobj-function axiomatic-p wrld))))
         (and def
              (or (null stobj-function)
                  (and (not (member-equal *stobj-inline-declare* def))
                       (or axiomatic-p
                           (not (getprop stobj-function 'absstobj-info nil
                                         'current-acl2-world wrld)))))
              (cons 'defun def)))))

(defun cltl-def-from-name (fn wrld)

; This function returns the raw Lisp definition of fn.  If fn does not have a
; 'stobj-function property in wrld, then the returned definition is also the
; definition that is oneified to create the corresponding *1* function.

  (cltl-def-from-name1 fn
                       (getprop fn 'stobj-function nil 'current-acl2-world
                                wrld)
                       nil
                       wrld))

(defun table-cltl-cmd (name key val op ctx wrld)

; WARNING: For the case that name is 'memoize-table, keep this in sync with
; memoize-fn.

; Currently this function returns nil if name is 'memoize-table except in a
; hons-enabled (#+hons) version, because memoize-table has a table guard of nil
; (actually a hard-error call) in the #-hons version.

  (let ((unsupported-str
         "Unsupported operation, ~x0, for updating table ~x1."))
    (case name
      (memoize-table
       (cond ((eq op :guard) nil)
             ((not (eq op :put))
              (er hard ctx unsupported-str op name))
             (val

; We store enough in the cltl-cmd so that memoize-fn can be called (by
; add-trip) without having to consult the world.  This is important because in
; the hons version of Version_3.3, hence before we stored the cl-defun and
; condition-defun in this cltl-cmd tuple, we saw an error in the following, as
; explained below.

; (defun foo (x) (declare (xargs :guard t)) x)
; (defun bar (x) (declare (xargs :guard t)) x)
; (progn (defun foo-memoize-condition (x)
;          (declare (xargs :guard t))
;          (eq x 'term))
;        (table memoize-table 'foo (list 'foo-memoize-condition 't 'nil))
;        (progn (defun h (x) x)
;               (defun bar (x) (cons x x))))

; Why did this cause an error?  The problem was that when restoring the world
; from after bar up to the inner progn (due to its protection by
; revert-world-on-error), memoize-fn was calling cltl-def-from-name on (w
; *the-live-state*), but this world did not contain enough information for that
; call.  (Note that set-w! calls find-longest-common-retraction with event-p =
; nil in that case, which is why we roll back to the previous command, not
; event.  We might consider rolling back to the previous event in all cases,
; not just when certifying or including a book.  But perhaps that's risky,
; since one can execute non-events like defuns-fn in the loop that one cannot
; execute in a book without a trust tag (or in make-event; hmmmm...).)

; See add-trip for a call of memoize-fn using the arguments indicated below.
; We have seen an error result due to revert-world-on-error winding back to a
; command landmark.  See set-w! for a comment about this, which explains how
; problem was fixed after Version_3.6.1.  However, we prefer to fix the problem
; here as well, by avoiding the call of cltl-def-from-name in memoize-fn that
; could be attempting to get a name during extend-world1 from a world not yet
; installed.  So we make that call here, just below, and store the result in
; the cltl-command tuple.

              (let* ((condition-fn (cdr (assoc-eq :condition-fn val)))
                     (condition-def (and condition-fn
                                         (not (eq condition-fn t))
                                         (cltl-def-from-name condition-fn
                                                             wrld)))
                     (condition (or (eq condition-fn t) ; hence t
                                    (car (last condition-def))))) ; maybe nil
                `(memoize ,key ; fn
                          ,condition
                          ,(cdr (assoc-eq :inline val))
                          ,(cdr (assoc-eq :trace val))
                          ,(cltl-def-from-name key wrld) ; cl-defun
                          ,(getprop key 'formals t 'current-acl2-world
                                    wrld) ; formals
                          ,(getprop key 'stobjs-in t 'current-acl2-world
                                    wrld) ; stobjs-in
                          ,(getprop key 'stobjs-out t 'current-acl2-world

; Normally we would avoid getting the stobjs-out of return-last.  But
; return-last is rejected for mamoization anyhow (by memoize-table-chk).

                                    wrld) ; stobjs-out
                          ,(and (symbolp condition)
                                condition
                                (not (eq condition t))
                                (cltl-def-from-name
                                 condition wrld)) ; condition-defun
                          ,(and (cdr (assoc-eq :commutative val)) t)
                          ,(cdr (assoc-eq :forget val))
                          ,(cdr (assoc-eq :memo-table-init-size val))
                          ,(cdr (assoc-eq :aokp val)))))
             (t `(unmemoize ,key))))
      (t nil))))

(defun table-fn1 (name key val op term ctx wrld state event-form)

; Warning: If the table event ever generates proof obligations, remove it from
; the list of exceptions in install-event just below its "Comment on
; irrelevance of skip-proofs".

; This is just the rational version of table-fn, with key, val, op and
; term all handled as normal (evaluated) arguments.  The chart in
; table-fn explains the legal ops and arguments.

  (case op
        (:alist
         (er-progn
          (chk-table-nil-args :alist
                              (or key val term)
                              (cond (key '(2)) (val '(3)) (t '(5)))
                              ctx state)
          (value (table-alist name wrld))))
        (:get
         (er-progn
          (chk-table-nil-args :get
                              (or val term)
                              (cond (val '(3)) (t '(5)))
                              ctx state)
          (value
           (cdr (assoc-equal key
                             (getprop name 'table-alist nil
                                      'current-acl2-world wrld))))))
        (:put
         (with-ctx-summarized
          (if (output-in-infixp state) event-form ctx)
          (let* ((tbl (getprop name 'table-alist nil
                               'current-acl2-world wrld)))
            (er-progn
             (chk-table-nil-args :put term '(5) ctx state)
             (cond
              ((let ((pair (assoc-equal key tbl)))
                 (and pair (equal val (cdr pair))))
               (stop-redundant-event ctx state))
              (t (er-let*
                  ((pair (chk-table-guard name key val ctx wrld state))
                   (wrld1 (cond
                           ((null pair)
                            (value wrld))
                           (t (let ((ttags-allowed1 (car pair))
                                    (ttags-seen1 (cdr pair)))
                                (pprogn (f-put-global 'ttags-allowed
                                                      ttags-allowed1
                                                      state)
                                        (value (global-set?
                                                'ttags-seen
                                                ttags-seen1
                                                wrld
                                                (global-val 'ttags-seen
                                                            wrld)))))))))
                  (install-event
                   name
                   event-form
                   'table
                   0
                   nil
                   (table-cltl-cmd name key val op ctx wrld)
                   nil ; theory-related events do their own checking
                   nil
                   (putprop name 'table-alist
                            (put-assoc-equal-fast
                             key val tbl)
                            wrld1)
                   state))))))))
        (:clear
         (with-ctx-summarized
          (if (output-in-infixp state) event-form ctx)
          (er-progn
           (chk-table-nil-args :clear
                               (or key term)
                               (cond (key '(2)) (t '(5)))
                               ctx state)
           (cond
            ((equal val (table-alist name wrld))
             (stop-redundant-event ctx state))
            ((not (alistp val))
             (er soft 'table ":CLEAR requires an alist, but ~x0 is not." val))
            (t
             (let ((val (if (duplicate-keysp val)
                            (reverse (clean-up-alist val nil))
                          val)))
               (er-let*
                ((wrld1
                  (er-let* ((pair (chk-table-guards name val ctx wrld state)))
                           (cond
                            ((null pair)
                             (value wrld))
                            (t (let ((ttags-allowed1 (car pair))
                                     (ttags-seen1 (cdr pair)))
                                 (pprogn (f-put-global 'ttags-allowed
                                                       ttags-allowed1
                                                       state)
                                         (value (global-set? 'ttags-seen
                                                             ttags-seen1
                                                             wrld
                                                             (global-val
                                                              'ttags-seen
                                                              wrld))))))))))
                (install-event name event-form 'table 0 nil
                               (table-cltl-cmd name key val op ctx wrld)
                               nil ; theory-related events do their own checking
                               nil
                               (putprop name 'table-alist val wrld1)
                               state))))))))
        (:guard
         (cond
          ((eq term nil)
           (er-progn
            (chk-table-nil-args op
                                (or key val)
                                (cond (key '(2)) (t '(3)))
                                ctx state)
            (value (getprop name 'table-guard *t* 'current-acl2-world wrld))))
          (t
           (with-ctx-summarized
            (if (output-in-infixp state) event-form ctx)
            (er-progn
             (chk-table-nil-args op
                                 (or key val)
                                 (cond (key '(2)) (t '(3)))
                                 ctx state)
             (er-let* ((tterm (translate term '(nil) nil nil ctx wrld state)))

; known-stobjs = nil.  No variable is treated as a stobj in tterm.
; But below we check that the only vars mentioned are KEY, VAL and
; WORLD.  These could, in principle, be declared stobjs by the user.
; But when we ev tterm in the future, we will always bind them to
; non-stobjs.

                      (let ((old-guard
                             (getprop name 'table-guard nil
                                      'current-acl2-world wrld)))
                        (cond
                         ((equal old-guard tterm)
                          (stop-redundant-event ctx state))
                         (old-guard
                          (er soft ctx
                              "It is illegal to change the :guard on a table ~
                               after it has been given an explicit :guard.  ~
                               The :guard of ~x0 is ~x1 and this can be ~
                               changed only by undoing the event that set it.  ~
                               See :DOC table."
                              name
                              (untranslate (getprop name 'table-guard nil
                                                    'current-acl2-world wrld)
                                           t wrld)))
                         ((getprop name 'table-alist nil
                                   'current-acl2-world wrld)

; At one time Matt wanted the option of setting the :val-guard of a
; non-empty table, but he doesn't recall why.  Perhaps we'll add such
; an option in the future if others express such a desire.

                          (er soft ctx
                              "It is illegal to set the :guard of the ~
                               non-empty table ~x0.  See :DOC table."
                              name))
                         (t
                          (let ((legal-vars '(key val world))
                                (vars (all-vars tterm)))
                            (cond ((not (subsetp-eq vars legal-vars))
                                   (er soft ctx
                                       "The only variables permitted in the ~
                                        :guard of a table are ~&0, but your ~
                                        guard uses ~&1.  See :DOC table."
                                       legal-vars vars))
                                  (t (install-event
                                      name
                                      event-form
                                      'table
                                      0
                                      nil
                                      (table-cltl-cmd name key val op ctx wrld)
                                      nil ; theory-related events do the check
                                      nil
                                      (putprop name
                                               'table-guard
                                               tterm
                                               wrld)
                                      state)))))))))))))
        (otherwise (er soft ctx
                       "Unrecognized table operation, ~x0.  See :DOC table."
                       op))))

(defun table-fn (name args state event-form)

; Warning: If this event ever generates proof obligations, remove it from the
; list of exceptions in install-event just below its "Comment on irrelevance of
; skip-proofs".

; This is an unusual "event" because it sometimes has no effect on
; STATE and thus is not an event!  In general this function applies
; an operation, op, to some arguments (and to the table named name).
; Ideally, args is of length four and of the form (key val op term).
; But when args is shorter it is interpreted as follows.

; args              same as args
; ()                (nil nil :alist nil)
; (key)             (key nil :get   nil)
; (key val)         (key val :put   nil)
; (key val op)      (key val op     nil)

; Key and val are both treated as forms and evaluated to produce
; single results (which we call key and val below).  Op and term are
; not evaluated.  A rational version of this function that takes key,
; val, op and term all as normal arguments is table-fn1.  The odd
; design of this function with its positional interpretation of op and
; odd treatment of evaluation is due to the fact that it represents
; the macroexpansion of a form designed primarily to be typed by the
; user.

; Op may be any of :alist, :get, :put, :clear, or :guard.  Each op
; enforces certain restrictions on the other three arguments.

; op         restrictions and meaning
; :alist     Key val and term must be nil.  Return the table as an
;            alist pairing keys to their non-nil vals.
; :get       Val and term must be nil.Return the val associated with
;            key.
; :put       Key and val satisfy :guard and term must be nil.  Store
;            val with key.
; :clear     Key and term must be nil.  Clear the table, setting it
;            to val if val is supplied (else to nil).  Note that val
;            must be an alist, and as with :put, the keys and entries
;            must satisfy the :guard.
; :guard     Key and val must be nil, term must be a term mentioning
;            only the variables KEY, VAL, and WORLD, and returning one
;            result.  The table must be empty.  Store term as the
;            table's :guard.

; Should table events be permitted to have documentation strings?  No.
; The reason is that we do not protect other names from being used as
; tables.  For example, the user might set up a table with the name
; defthm.  If we permitted a doc-string for that table, :DOC defthm
; would be overwritten.

  (let* ((ctx (cons 'table name))
         (wrld (w state))
         (event-form (or event-form
                         `(table ,name ,@args)))
         (n (length args))
         (key-form (car args))
         (val-form (cadr args))
         (op (cond ((= n 2) :put)
                   ((= n 1) :get)
                   ((= n 0) :alist)
                   (t (caddr args))))
         (term (cadddr args)))
    (er-progn
     (cond ((not (symbolp name))
            (er soft ctx
                "The first argument to table must be a symbol, but ~
                 ~x0 is not.  See :DOC table."
                name))
           ((< 4 (length args))
            (er soft ctx
                "Table may be given no more than five arguments.  In ~
                 ~x0 it is given ~n1.  See :DOC table."
                event-form
                (1+ (length args))))
           (t (value nil)))
     (er-let* ((key-pair
                (simple-translate-and-eval
                 key-form
                 (if (eq name 'acl2-defaults-table)
                     nil
                     (list (cons 'world wrld)))
                 nil
                 (if (eq name 'acl2-defaults-table)
                     "In (TABLE ACL2-DEFAULTS-TABLE key ...), key"
                     "The second argument of TABLE")
                 ctx wrld state nil))
               (val-pair
                (simple-translate-and-eval
                 val-form
                 (if (eq name 'acl2-defaults-table)
                     nil
                     (list (cons 'world wrld)))
                 nil
                 (if (eq name 'acl2-defaults-table)
                     "In (TABLE ACL2-DEFAULTS-TABLE key val ...), val"
                     "The third argument of TABLE")
                 ctx wrld state nil)))
              (table-fn1 name (cdr key-pair) (cdr val-pair) op term
                         ctx wrld state event-form)))))

(defun set-override-hints-fn (lst at-end ctx wrld state)
  (er-let*
   ((tlst (translate-override-hints 'override-hints lst ctx wrld
                                    state))
    (new (case at-end
           ((t)
            (value (append (override-hints wrld) tlst)))
           ((nil)
            (value (append tlst (override-hints wrld))))
           (:clear
            (value tlst))
           (:remove
            (let ((old (override-hints wrld)))
              (value (set-difference-equal old tlst))))
           (otherwise
            (er soft ctx
                "Unrecognized operation in ~x0: ~x1."
                'set-override-hints-fn at-end)))))
   (er-progn
    (table-fn 'default-hints-table (list :override (kwote new)) state nil)
    (table-fn 'default-hints-table (list :override) state nil))))
