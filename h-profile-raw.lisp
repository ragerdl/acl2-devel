;; BOZO copyright stuff.

; h-profile-raw.lisp
;
; Profiler stuff.

(in-package "ACL2")


(defv *profile-reject-ht* (mht :test 'eq)
  "The user may freely add to the hash table *PROFILE-REJECT-HT*, which
  inhibits the collection of functions into lists of functions to be memoized
  and/or profiled.

  Here are some reasons for adding a function fn to *PROFILE-REJECT-HT*.

  1. A call of fn is normally so fast or fn is called so often that the extra
  instructions executed when a profiled or memoized version of fn is run will
  distort measurements excessively.  We tend not to profile any function that
  runs in under 6000 clock ticks or about 2 microseconds.  The number of extra
  instructions seem to range between 20 and 100, depending upon what is being
  measured.  Counting function calls is relatively fast.  But if one measures
  elapsed time, one might as well measure everything else too.  Or so it seems
  in 2007 on terlingua.csres.utexas.edu.

  2. fn is a subroutine of another function being profiled, and we wish to
  reduce the distortion that profiling fn will cause.

  3. fn is 'transparent', like EVAL.  Is EVAL fast or slow?  The answer, of
  course, is that it mostly depends upon what one is EVALing.

  4. fn's name ends in '1', meaning 'auxiliary' to some folks.

  5. fn is boring.

  Our additions to *PROFILE-REJECT-HT* are utterly capricious.  The user should
  feel free to set *PROFILE-REJECT-HT* ad lib, at any time.")

(declaim (hash-table *profile-reject-ht*))

(defn1 input-output-number-warning (fn)
  (format *debug-io*
          "Can't determine the number of inputs and outputs of ~a.~%To assert ~
           ~a takes, say, 2 inputs and returns 1 output, do:~%~a.~%"
          fn fn `(set-number-of-arguments-and-values ',fn 2 1)))

(defn1 dubious-to-profile (fn)
  (cond ((not (symbolp fn)) "not a symbol.")
        ((not (fboundp fn)) "not fboundp.")
        ((eq (symbol-package fn) *main-lisp-package*)
         (format nil "~%;~10tin *main-lisp-package*."))
        #+Clozure
        ((ccl::%advised-p fn)
         (format nil "~%;10tadvised, and it will so continue."))
        ((member fn (eval '(trace)))
         (format nil "~%;~10ta member of (trace), and it will so continue."))
        ((member fn (eval '(old-trace)))
         (format nil "~%;~10ta member of (old-trace), and it will so continue."))
        ((eq fn 'return-last)
         "the function RETURN-LAST.")
        ((gethash fn *never-profile-ht*)
         (format nil "~%;~10tin *NEVER-PROFILE-HT*."))
        ((gethash fn *profile-reject-ht*)
         (format nil "in~%;~10t*PROFILE-REJECT-HT*.  Override with ~%;~10t~a"
                 `(remhash ',fn *profile-reject-ht*)))
        ((macro-function fn) "a macro.")
        ((compiler-macro-function fn) "a compiler-macro-function.")
        ((special-form-or-op-p fn) "a special operator.")
        ((getprop fn 'constrainedp nil 'current-acl2-world
                  (w *the-live-state*))
         "constrained.")
        ((memoizedp-raw fn)
         (format nil "~%;~10tmemoized or profiled, and it will so continue."))
        #+Clozure
        ((multiple-value-bind (req opt restp keys)
             (ccl::function-args (symbol-function fn))
           (if (or restp
                   keys
                   (not (integerp req))
                   (not (eql opt 0)))
               (format nil "~%;~10thas non-simple arguments, e.g., &key or &rest.")
             nil)))
        ((null (number-of-arguments fn))
         (input-output-number-warning fn))))




(defun profile-fn (fn &rest r &key (condition nil) (inline nil)
                      &allow-other-keys)
  (apply #'memoize-fn fn
         :condition condition
         :inline inline
         r))

(defn1 profiled-functions ()

  ; The profiled functions are hereby arbitrarily defined as those produced by
  ; MEMOIZE-FN with null :CONDITION and :INLINE fields.

  (let (l)
    (maphash
     (lambda (k v)
       (when (and (symbolp k)
                  (null (access memoize-info-ht-entry v :condition))
                  (null (access memoize-info-ht-entry v :inline)))
         (push k l)))
     *memoize-info-ht*)
    l))

(defn1 unmemoize-profiled ()

  "UNMEMOIZE-PROFILED is a raw Lisp function.  (UNMEMOIZE-PROFILED)
  unmemoizes and unprofiles all functions currently memoized with
  :CONDITION=NIL and :INLINE=NIL."

  (loop for x in (profiled-functions) do
        (unmemoize-fn (car x))))


(defn1 event-number (fn)
  (cond ((symbolp fn)
         (fgetprop fn 'absolute-event-number t (w *the-live-state*)))
        (t
         (error "EVENT-NUMBER: ** ~a is not a symbol." fn))))

(defun profile-acl2 (&key (start 0)
                          trace
                          watch-ifs
                          forget)

  "PROFILE-ACL2 is a raw Lisp function.  (PROFILE-ACL2 :start 'foo)
   profiles many functions that have been accepted by ACL2, starting
   with the acceptance of the function foo.  However, if a function is
   regarded as DUBIOUS-TO-PROFILE, then it is not profiled and an
   explanation is printed."

  (unless (integerp start)
    (unless (symbolp start)
      (error "~%; PROFILE-ACL2: ** ~a is not an event." start))
    (setq start (event-number start))
    (unless (integerp start)
      (error "~%; PROFILE-ACL2: ** ~a is not an event." start)))
  (let ((fns-ht (make-hash-table :test 'eq)))
    (declare (hash-table fns-ht))
    (loop for p in (set-difference-equal
                    (strip-cars (known-package-alist *the-live-state*))
                    '("ACL2-INPUT-CHANNEL" "ACL2-OUTPUT-CHANNEL"
                      "COMMON-LISP" "KEYWORD"))
          do
          (do-symbols (fn p)
                      (cond ((gethash fn fns-ht) nil)
                            ((or (not (fboundp fn))
                                 (macro-function fn)
                                 (special-form-or-op-p fn))
                             (setf (gethash fn fns-ht) 'no))
                            ((or (not (integerp (event-number fn)))
                                 (< (event-number fn) start))
                             (setf (gethash fn fns-ht) 'no))
                            ((dubious-to-profile fn)
                             (setf (gethash fn fns-ht) 'no)
                             (ofv "Not profiling '~a' because it's ~a"
                                  (shorten fn 20)
                                  (dubious-to-profile fn)))
                            (t (setf (gethash fn fns-ht) 'yes)))))
    (maphash (lambda (k v)
               (if (eq v 'no) (remhash k fns-ht)))
             fns-ht)
    (ofv "Profiling ~:d functions." (hash-table-count fns-ht))
    (memoize-here-come (hash-table-count fns-ht))
    (maphash
     (lambda (k v)
       (declare (ignore v))
       (profile-fn k
                   :trace trace
                   :watch-ifs watch-ifs
                   :forget forget))
     fns-ht)
    (clear-memoize-call-array)
    (format nil "~a function~:p newly profiled."
            (hash-table-count fns-ht))))

(defun profile-all (&key trace forget watch-ifs pkg)

  "PROFILE-ALL is a raw Lisp function.  (PROFILE-ALL) profiles each
  symbol that has a function-symbol and occurs in a package known
  to ACL2, unless it is

   1. memoized,
   2. traced,
   3. in the package COMMON-LISP,
   4. in *NEVER-PROFILE-HT*, or
   5. in *PROFILE-REJECT-HT*
   6. otherwise rejected by DUBIOUS-TO-PROFILE."

  (let ((fns-ht (make-hash-table :test 'eq)))
    (declare (hash-table fns-ht))
    (loop for p in
          (if pkg
              (if (stringp pkg) (list pkg) pkg)
            (set-difference-equal
             (strip-cars (known-package-alist *the-live-state*))
             '("ACL2-INPUT-CHANNEL" "ACL2-OUTPUT-CHANNEL"
               "COMMON-LISP" "KEYWORD")))
          do
          (do-symbols (fn p)
                      (cond ((gethash fn fns-ht) nil)
                            ((or (not (fboundp fn))
                                 (macro-function fn)
                                 (special-form-or-op-p fn))
                             (setf (gethash fn fns-ht) 'no))
                            ((dubious-to-profile fn)
                             (setf (gethash fn fns-ht) 'no)
                             (ofv "Not profiling '~a' because it's ~a"
                                  (shorten fn 20)
                                  (dubious-to-profile fn)))
                            (t (setf (gethash fn fns-ht) 'yes)))))
    (maphash (lambda (k v)
               (if (eq v 'no) (remhash k fns-ht)))
             fns-ht)
    (ofv "Profiling ~:d functions." (hash-table-count fns-ht))
    (memoize-here-come (hash-table-count fns-ht))
    (maphash
     (lambda (k v) (declare (ignore v))
       (profile-fn k
                   :trace trace
                   :watch-ifs watch-ifs
                   :forget forget))
     fns-ht)
    (clear-memoize-call-array)
    (format nil "~a function~:p newly profiled."
            (hash-table-count fns-ht))))

(defn functions-defined-in-form (form)
  (cond ((consp form)
         (cond ((and (symbolp (car form))
                     (fboundp (car form))
                     (cdr form)
                     (symbolp (cadr form))
                     (fboundp (cadr form))
                     (eql 0 (search "def" (symbol-name (car form))
                                    :test #'char-equal)))
                (list (cadr form)))
               ((member (car form) '(progn progn!))
                (loop for z in (cdr form) nconc
                      (functions-defined-in-form z)))))))

(defn functions-defined-in-file (file)
  (let ((x nil)
        (avrc (cons nil nil)))
    (our-syntax ; protects against changes to *package*, etc.
     (let ((*readtable* (copy-readtable nil)))
       (set-dispatch-macro-character
        #\# #\, #'(lambda (stream char n)
                    (declare (ignore stream char n))
                    (values)))
       (set-dispatch-macro-character
        #\#
        #\.
        #'(lambda (stream char n)
            (declare (ignore stream char n))
            (values)))
       (with-open-file (stream file)
         (ignore-errors
           (loop until (eq avrc (setq x (read stream nil avrc)))
                 nconc
                 (functions-defined-in-form x))))))))

(defun profile-file (file &rest r)

  "PROFILE-FILE is a raw Lisp function.  (PROFILE-FILE file) calls
  PROFILE-FN on 'all the functions defined in' FILE, a relatively vague
  concept.  However, if packages are changed in FILE as it is read, in
  a sneaky way, or if macros are defined and then used at the top of
  FILE, who knows which functions will be profiled?  Functions that do
  not pass the test DUBIOUS-TO-PROFILE are not profiled.  A list of
  the names of the functions profiled is returned."

  (loop for fn in (functions-defined-in-file file)
        unless (dubious-to-profile fn)
        collect (apply #'profile-fn fn r)))



(defun initialize-profile-reject-ht ()
  ;; [Jared]: ugh, horrible! we should get rid of this kind of nonsense!
  (loop for sym in
        '(ld-fn0
          protected-eval
          hons-read-list-top
          hons-read-list
          raw-ev-fncall
          read-char$
          1-way-unify
          hons-copy1
          grow-static-conses
          bytes-used
          lex->
          gc-count
          outside-p
          shorten
          date-string
          strip-cars1
          short-symbol-name
          memoize-condition
          1-way-unify-top
          absorb-frame
          access-command-tuple-number
          access-event-tuple-depth
          access-event-tuple-form
          access-event-tuple-number
          accumulate-ttree-and-step-limit-into-state
          acl2-macro-p
          acl2-numberp
          add-car-to-all
          add-cdr-to-all
          add-command-landmark
          add-event-landmark
          add-g-prefix
          add-literal
          add-literal-and-pt
          add-name
          add-new-fc-pots
          add-new-fc-pots-lst
          add-timers
          add-to-pop-history
          add-to-set-eq
          add-to-set-equal
          add-to-tag-tree
          advance-fc-activations
          advance-fc-pot-lst
          all-args-occur-in-top-clausep
          all-calls
          all-fnnames1
          all-nils
          all-ns
          all-quoteps
          all-runes-in-ttree
          all-vars
          all-vars1
          all-vars1-lst
          alphorder
          ancestors-check
          and-macro
          and-orp
          apply-top-hints-clause
          approve-fc-derivations
          aref1
          aref2
          arglistp
          arglistp1
          arith-fn-var-count
          arith-fn-var-count-lst
          arity
          assoc-eq
          assoc-equal
          assoc-equal-cdr
          assoc-equiv
          assoc-equiv+
          assoc-keyword
          assoc-no-error-at-end
          assoc-type-alist
          assume-true-false
          assume-true-false1
          atoms
          augment-ignore-vars
          backchain-limit
          bad-cd-list
          not-pat-p
          basic-worse-than
          being-openedp-rec
          big-n
          binary-+
          binary-append
          bind-macro-args
          bind-macro-args-after-rest
          bind-macro-args-keys
          bind-macro-args-keys1
          bind-macro-args-optional
          bind-macro-args1
          binding-hyp-p
          binop-table
          body
          boolean-listp
          booleanp
          boundp-global
          boundp-global1
          brkpt1
          brkpt2
          built-in-clausep
          built-in-clausep1
          bytes-allocated
          bytes-allocated/call
          call-stack
          canonical-representative
          car-cdr-nest
          case-list
          case-split-limitations
          case-test
          change-plist
          change-plist-first-preferred
          character-listp
          chars-for-int
          chars-for-num
          chars-for-pos
          chars-for-pos-aux
          chars-for-rat
          chase-bindings
          chk-acceptable-defuns
          chk-acceptable-ld-fn
          chk-acceptable-ld-fn1
          chk-acceptable-ld-fn1-pair
          chk-all-but-new-name
          chk-arglist
          chk-assumption-free-ttree
          chk-dcl-lst
          chk-declare
          chk-defun-mode
          chk-defuns-tuples
          chk-embedded-event-form
          chk-free-and-ignored-vars
          chk-free-and-ignored-vars-lsts
          chk-irrelevant-formals
          chk-just-new-name
          chk-just-new-names
          chk-legal-defconst-name
          chk-length-and-keys
          chk-no-duplicate-defuns
          chk-table-guard
          chk-table-nil-args
          chk-xargs-keywords
          chk-xargs-keywords1
          clausify
          clausify-assumptions
          clausify-input
          clausify-input1
          clausify-input1-lst
          clean-type-alist
          clear-memoize-table
          clear-memoize-tables
          cltl-def-from-name
          coerce-index
          coerce-object-to-state
          coerce-state-to-object
          collect-assumptions
          collect-dcls
          collect-declarations
          collect-non-x
          comm-equal
          complementaryp
          complex-rationalp
          compute-calls-and-times
          compute-inclp-lst
          compute-inclp-lst1
          compute-stobj-flags
          cond-clausesp
          cond-macro
          conjoin
          conjoin-clause-sets
          conjoin-clause-to-clause-set
          conjoin2
          cons-make-list
          cons-ppr1
          cons-term
          cons-term2
          const-list-acc
          constant-controller-pocketp
          constant-controller-pocketp1
          contains-guard-holdersp
          contains-guard-holdersp-lst
          contains-rewriteable-callp
          controller-complexity
          controller-complexity1
          controller-pocket-simplerp
          controllers
          convert-clause-to-assumptions
          csh
          current-package
          dcls
          def-body
          default-defun-mode
          default-hints
          default-print-prompt
          default-verify-guards-eagerness
          defconst-fn
          defined-constant
          defn-listp
          defnp
          defun-fn
          defuns-fn
          defuns-fn0
          delete-assumptions
          delete-assumptions-1
          digit-to-char
          disjoin
          disjoin-clause-segment-to-clause-set
          disjoin-clauses
          disjoin-clauses1
          disjoin2
          distribute-first-if
          doc-stringp
          doubleton-list-p
          dumb-assumption-subsumption
          dumb-assumption-subsumption1
          dumb-negate-lit
          dumb-negate-lit-lst
          dumb-occur
          dumb-occur-lst
          duplicate-keysp
          eapply
          enabled-numep
          enabled-xfnp
          ens
          eoccs
          eqlable-listp
          eqlablep
          equal-mod-alist
          equal-mod-alist-lst
          er-progn-fn
          ev
          ev-fncall
          ev-fncall-rec
          ev-for-trans-eval
          ev-rec
          ev-rec-lst
          eval-bdd-ite
          eval-event-lst
          eval-ground-subexpressions
          eval-ground-subexpressions-lst
          evens
          every-occurrence-equiv-hittablep1
          every-occurrence-equiv-hittablep1-listp
          eviscerate
          eviscerate-stobjs
          eviscerate-stobjs1
          eviscerate1
          eviscerate1-lst
          eviscerate1p
          eviscerate1p-lst
          evisceration-stobj-marks
          expand-abbreviations
          expand-abbreviations-lst
          expand-abbreviations-with-lemma
          expand-and-or
          expand-any-final-implies1
          expand-any-final-implies1-lst
          expand-clique-alist
          expand-clique-alist-term
          expand-clique-alist-term-lst
          expand-clique-alist1
          expand-permission-result
          expand-some-non-rec-fns
          expand-some-non-rec-fns-lst
          explode-atom
          extend-car-cdr-sorted-alist
          extend-type-alist
          extend-type-alist-simple
          extend-type-alist-with-bindings
          extend-type-alist1
          extend-with-proper/improper-cons-ts-tuple
          extract-and-clausify-assumptions
          f-and
          f-booleanp
          f-ite
          f-not
          fc-activation
          fc-activation-lst
          fc-pair-lst
          fc-pair-lst-type-alist
          fetch-from-zap-table
          ffnnamep
          ffnnamep-hide
          ffnnamep-hide-lst
          ffnnamep-lst
          ffnnamep-mod-mbe
          ffnnamep-mod-mbe-lst
          ffnnamesp
          ffnnamesp-lst
          fgetprop
          filter-geneqv-lst
          filter-with-and-without
          find-abbreviation-lemma
          find-alternative-skip
          find-alternative-start
          find-alternative-start1
          find-alternative-stop
          find-and-or-lemma
          find-applicable-hint-settings
          find-clauses
          find-clauses1
          find-mapping-pairs-tail
          find-mapping-pairs-tail1
          find-rewriting-equivalence
          find-subsumer-replacement
          first-assoc-eq
          first-if
          fix-declares
          flpr
          flpr1
          flpr11
          flsz
          flsz-atom
          flsz-integer
          flsz1
          flush-hons-get-hash-table-link
          fms
          fmt
          fmt-char
          fmt-ctx
          fmt-hard-right-margin
          fmt-ppr
          fmt-soft-right-margin
          fmt-symbol-name
          fmt-symbol-name1
          fmt-var
          fmt0
          fmt0&v
          fmt0*
          fmt1
          fn-count-1
          fn-count-evg-rec
          fn-rune-nume
          fnstack-term-member
          formal-position
          formals
          free-varsp
          free-varsp-lst
          function-symbolp
          gatom
          gatom-booleanp
          gen-occs
          gen-occs-list
          geneqv-lst
          geneqv-lst1
          geneqv-refinementp
          geneqv-refinementp1
          general
          gentle-binary-append
          gentle-atomic-member
          gentle-caaaar
          gentle-caaadr
          gentle-caaar
          gentle-caadar
          gentle-caaddr
          gentle-caadr
          gentle-caar
          gentle-cadaar
          gentle-cadadr
          gentle-cadar
          gentle-caddar
          gentle-cadddr
          gentle-caddr
          gentle-cadr
          gentle-car
          gentle-cdaaar
          gentle-cdaadr
          gentle-cdaar
          gentle-cdadar
          gentle-cdaddr
          gentle-cdadr
          gentle-cdar
          gentle-cddaar
          gentle-cddadr
          gentle-cddar
          gentle-cdddar
          gentle-cddddr
          gentle-cdddr
          gentle-cddr
          gentle-cdr
          gentle-getf
          gentle-length
          gentle-revappend
          gentle-reverse
          gentle-strip-cars
          gentle-strip-cdrs
          gentle-take
          genvar
          get-and-chk-last-make-event-expansion
          get-declared-stobj-names
          get-doc-string
          get-docs
          get-global
          get-guards
          get-guards1
          get-guardsp
          get-ignorables
          get-ignores
          get-integer-from
          get-level-no
          get-package-and-name
          get-stobjs-in-lst
          get-string
          get-timer
          get-unambiguous-xargs-flg
          get-unambiguous-xargs-flg1
          get-unambiguous-xargs-flg1/edcls
          getprop-default
          gify
          gify-all
          gify-file
          gify-list
          global-set
          global-val
          good-defun-mode-p
          gsal
          gtrans-atomic
          guard
          guard-clauses
          guard-clauses-for-clique
          guard-clauses-for-fn
          guard-clauses-lst
          guess-and-putprop-type-prescription-lst-for-clique
          guess-and-putprop-type-prescription-lst-for-clique-step
          guess-type-prescription-for-fn-step
          hide-ignored-actuals
          hide-noise
          hits/calls
          hons
          hons-acons
          hons-acons!
          hons-acons-summary
          hons-copy-restore
          hons-copy2-consume
          hons-copy3-consume
          hons-copy1-consume
          hons-copy1-consume-top
          hons-copy2
          hons-copy3
          hons-copy1
          hons-copy1-top
          hons-copy
          hons-copy-list-cons
          hons-copy-r
          hons-copy-list-r
          hons-copy
          hons-dups-p
          hons-dups-p1
          hons-gentemp
          hons-get-fn-do-hopy
          hons-get-fn-do-not-hopy
          hons-int1
          hons-intersection
          hons-intersection2
          hons-len
          hons-member-equal
          hons-normed
          hons-put-list
          hons-sd1
          hons-set-diff
          hons-set-diff2
          hons-set-equal
          hons-shrink-alist
          hons-shrink-alist!
          hons-subset
          hons-subset2
          hons-union1
          hons-union2
          if-compile
          if-compile-formal
          if-compile-lst
          if-interp
          if-interp-add-clause
          if-interp-assume-true
          if-interp-assumed-value
          if-interp-assumed-value-x
          if-interp-assumed-value1
          if-interp-assumed-value2
          ignorable-vars
          ignore-vars
          in-encapsulatep
          increment-timer
          induct-msg/continue
          initialize-brr-stack
          initialize-summary-accumulators
          initialize-timers
          inst
          install-event
          install-global-enabled-structure
          intern-in-package-of-symbol
          intersection-eq
          intersectp-eq
          irrelevant-non-lambda-slots-clique
          keyword-param-valuep
          keyword-value-listp
          known-package-alist
          known-whether-nil
          kwote
          lambda-nest-hidep
          latch-stobjs
          latch-stobjs1
          ld-error-triples
          ld-evisc-tuple
          ld-filter-command
          ld-fn-alist
          ld-fn-body
          ld-loop
          ld-post-eval-print
          ld-pre-eval-filter
          ld-pre-eval-print
          ld-print-command
          ld-print-prompt
          ld-print-results
          ld-prompt
          ld-read-command
          ld-read-eval-print
          ld-skip-proofsp
          ld-verbose
          legal-case-clausesp
          legal-constantp
          legal-variable-or-constant-namep
          legal-variablep
          len
          let*-macro
          lexorder
          list*-macro
          list-fast-fns
          list-macro
          list-to-pat
          listify
          listlis
          locn-acc
          look-in-type-alist
          lookup-hyp
          lookup-world-index
          lookup-world-index1
          loop-stopperp
          macro-args
          macroexpand1
          main-timer
          make-bit
          make-clique-alist
          make-event-ctx
          make-event-debug-post
          make-event-debug-pre
          make-event-fn
          make-fmt-bindings
          make-list-of-symbols
          make-list-with-tail
          make-occs-map1
          make-slot
          make-symbol-with-number
          map-type-sets-via-formals
          match-free-override
          max-absolute-command-number
          max-absolute-event-number
          max-form-count
          max-form-count-lst
          max-level-no
          max-level-no-lst
          max-width
          may-need-slashes
          maybe-add-command-landmark
          maybe-add-space
          maybe-gify
          maybe-reduce-memoize-tables
          maybe-str-hash
          maybe-zify
          member-complement-term
          member-complement-term1
          member-eq
          member-equal
          member-equal-+-
          member-symbol-name
          member-term
          memoizedp-raw
          mer-star-star
          merge-runes
          merge-sort
          merge-sort-car->
          merge-sort-length
          merge-sort-runes
          most-recent-enabled-recog-tuple
          mv-atf
          mv-nth
          mv-nth-list
          n2char
          nat-list-to-list-of-chars
          nat-to-list
          nat-to-string
          nat-to-v
          natp
          new-backchain-limit
          newline
          next-absolute-event-number
          next-tag
          next-wires
          nfix
          nmake-if
          nmerge
          no-duplicatesp
          no-duplicatesp-equal
          no-op-histp
          nominate-destructor-candidates
          non-linearp
          non-stobjps
          normalize
          normalize-lst
          normalize-with-type-set
          not-instance-name-p
          not-pat-receiving
          dubious-to-profile
          not-safe-for-synthesis-list
          not-to-be-rewrittenp
          not-to-be-rewrittenp1
          nth-update-rewriter
          nth-update-rewriter-target-lstp
          nth-update-rewriter-targetp
          nu-rewriter-mode
          num-0-to-9-to-char
          num-to-bits
          number-of-arguments
          number-of-calls
          number-of-hits
          number-of-memoized-entries
          number-of-mht-calls
          number-of-return-values
          number-of-strings
          obfb
          obj-table
          odds
          ofe
          ofnum
          ofv
          ofvv
          ofw
          ok-to-force
          oncep
          one-way-unify
          one-way-unify-restrictions
          one-way-unify1
          one-way-unify1-equal
          one-way-unify1-equal1
          one-way-unify1-lst
          open-input-channel
          open-output-channel
          open-output-channel-p
          or-macro
          output-ignored-p
          output-in-infixp
          pairlis$
          pairlis2
          pal
          partition-according-to-assumption-term
          permute-occs-list
          pons
          pop-accp
          pop-clause
          pop-clause-msg
          pop-clause-msg1
          pop-clause1
          pop-timer
          pop-warning-frame
          posp
          ppr
          ppr1
          ppr1-lst
          ppr2
          ppr2-column
          ppr2-flat
          prefix
          preprocess-clause
          preprocess-clause-msg1
          prin1$
          princ$
          print-alist
          print-base-p
          print-call-stack
          print-defun-msg
          print-defun-msg/collect-type-prescriptions
          print-defun-msg/type-prescriptions
          print-defun-msg/type-prescriptions1
          print-prompt
          print-rational-as-decimal
          print-redefinition-warning
          print-rules-summary
          print-summary
          print-time-summary
          print-timer
          print-verify-guards-msg
          print-warnings-summary
          profile-g-fns
          progn-fn
          progn-fn1
          program-term-listp
          program-termp
          proofs-co
          proper/improper-cons-ts-tuple
          prove
          prove-guard-clauses
          prove-loop
          prove-loop1
          pseudo-term-listp
          pseudo-termp
          pseudo-variantp
          pseudo-variantp-list
          pt-intersectp
          pt-occur
          pts-to-ttree-lst
          puffert
          push-accp
          push-ancestor
          push-io-record
          push-lemma
          push-timer
          push-warning-frame
          put-assoc-eq
          put-global
          put-ttree-into-pspv
          putprop
          putprop-defun-runic-mapping-pairs
          quickly-count-assumptions
          quote-listp
          quotep
          qzget-sign-abs
          raw-mode-p
          read-acl2-oracle
          read-object
          read-run-time
          read-standard-oi
          recompress-global-enabled-structure
          recompress-stobj-accessor-arrays
          record-accessor-function-name
          recursive-fn-on-fnstackp
          redundant-or-reclassifying-defunsp1
          relevant-slots-call
          relevant-slots-clique
          relevant-slots-clique1
          relevant-slots-def
          relevant-slots-term
          relevant-slots-term-lst
          relieve-hyp
          relieve-hyps
          relieve-hyps1
          remove-evisc-marks
          remove-evisc-marks-al
          remove-invisible-fncalls
          remove-keyword
          remove-one-+-
          remove-strings
          replace-stobjs
          replace-stobjs1
          replaced-stobj
          ret-stack
          return-type-alist
          rewrite
          rewrite-args
          rewrite-fncall
          rewrite-fncallp
          rewrite-fncallp-listp
          rewrite-if
          rewrite-if1
          rewrite-if11
          rewrite-primitive
          rewrite-recognizer
          rewrite-solidify
          rewrite-solidify-plus
          rewrite-solidify-rec
          rewrite-stack-limit
          rewrite-with-lemma
          rewrite-with-lemmas
          rewrite-with-lemmas1
          rewrite-with-linear
          rune-<
          runep
          safe-1+
          safe-1-
          safe-<
          safe-<=
          safe-binary-+
          safe-binary--
          safe-caaaar
          safe-caaadr
          safe-caaar
          safe-caadar
          safe-caaddr
          safe-caadr
          safe-caar
          safe-cadaar
          safe-cadadr
          safe-cadar
          safe-caddar
          safe-cadddr
          safe-caddr
          safe-cadr
          safe-car
          safe-cdaaar
          safe-cdaadr
          safe-cdaar
          safe-cdadar
          safe-cdaddr
          safe-cdadr
          safe-cdar
          safe-cddaar
          safe-cddadr
          safe-cddar
          safe-cdddar
          safe-cddddr
          safe-cdddr
          safe-cddr
          safe-cdr
          safe-code-char
          safe-coerce
          safe-floor
          safe-intern-in-package-of-symbol
          safe-lognot
          safe-max
          safe-mod
          safe-nthcdr
          safe-rem
          safe-strip-cars
          safe-symbol-name
          saved-output-token-p
          scan-past-whitespace
          scan-to-cltl-command
          scan-to-landmark-number
          scons-tag-trees
          scons-tag-trees1
          search-type-alist
          search-type-alist-rec
          set-cl-ids-of-assumptions
          set-difference-eq
          set-timer
          set-w
          set-w!
          sgetprop
          simple-translate-and-eval
          simplify-clause-msg1
          simplify-clause1
          slot-member
          some-congruence-rule-disabledp
          some-controller-pocket-constant-and-non-controller-simplerp
          some-geneqv-disabledp
          some-subterm-worse-than-or-equal
          some-subterm-worse-than-or-equal-lst
          sort-approved
          sort-approved1
          sort-approved1-rating1
          sort-occurrences
          spaces
          splice-instrs
          splice-instrs1
          split-on-assumptions
          ssn
          standard-co
          standard-oi
          state-p1
          std-apart
          std-apart-top
          step-limit
          stobjp
          stobjs-in
          stobjs-out
          stop-redundant-event
          store-clause
          store-clause1
          string-append-lst
          string-from-list-of-chars
          string-listp
          strip-assumption-terms
          strip-branches
          strip-cadrs
          strip-cars
          strip-cdrs
          subcor-var
          subcor-var-lst
          subcor-var1
          sublis-expr
          sublis-expr-lst
          sublis-occ
          sublis-pat
          sublis-var
          sublis-var-lst
          subsetp-eq
          subsumption-replacement-loop
          suffix
          sweep-clauses
          sweep-clauses1
          symbol-<
          symbol-alistp
          symbol-class
          symbol-listp
          symbol-package-name
          t-and
          t-fix
          t-ite
          t-list
          t-not
          t-or
          table-alist
          table-fn
          table-fn1
          tag-tree-occur
          tagged-object
          tagged-objects
          tame-symbolp
          term-and-typ-to-lookup
          term-order
          termp
          thm-fn
          tilde-*-preprocess-phrase
          tilde-*-simp-phrase
          tilde-*-simp-phrase1
          tilde-@-abbreviate-object-phrase
          time-for-non-hits/call
          time-limit5-reached-p
          time/call
          to
          to-be-ignoredp
          to-if-error-p
          too-long
          total-time
          trans-alist
          trans-alist1
          trans-eval
          translate-bodies
          translate-bodies1
          translate-dcl-lst
          translate-deref
          translate-doc
          translate-hints
          translate-term-lst
          translate1
          translate11
          translate11-lst
          translate11-mv-let
          translated-acl2-unwind-protectp
          translated-acl2-unwind-protectp4
          tree-occur
          true-listp
          type-alist-clause-finish
          type-alist-clause-finish1
          type-alist-equality-loop
          type-alist-equality-loop1
          type-alist-fcd-lst
          type-set
          type-set-<
          type-set-<-1
          type-set-and-returned-formals
          type-set-and-returned-formals-with-rule
          type-set-car
          type-set-cdr
          type-set-cons
          type-set-equal
          type-set-finish
          type-set-lst
          type-set-not
          type-set-primitive
          type-set-quote
          type-set-recognizer
          type-set-relieve-hyps
          type-set-with-rule
          type-set-with-rule1
          type-set-with-rules
          unencumber-assumptions
          unify
          unify-sa-p
          union-eq
          union-equal
          untranslate
          untranslate-lst
          untranslate-preprocess-fn
          untranslate1
          untranslate1-lst
          update-world-index
          us
          user-stobj-alist
          user-stobj-alist-safe
          user-stobjsp
          v-to-nat
          var-fn-count
          var-fn-count-lst
          var-lessp
          var-to-tree
          var-to-tree-list
          vars-of-fal-aux
          verify-guards-fn1
          vx2
          w
          warning-off-p
          wash-memory
          watch-count
          maybe-watch-dump
          incf-watch-count
          set-watch-count
          watch-help
          time-of-last-watch-update
          watch-shell-command
          time-since-watch-start
          make-watchdog
          watch
          watch-kill
          watch-condition
          waterfall
          waterfall-msg
          waterfall-msg1
          waterfall-print-clause
          waterfall-step
          waterfall-step1
          waterfall0
          waterfall1
          waterfall1-lst
          widen
          watch-real-time
          watch-run-time
          world-evisceration-alist
          worse-than
          worth-hashing
          worth-hashing1
          x-and
          x-buf
          x-ff
          x-latch+
          x-latch-
          x-latch-+
          x-mux
          x-not
          x-or
          x-xor
          xor
          xxxjoin
          zip-variable-type-alist
          zp)
        do
        (setf (gethash sym *profile-reject-ht*) t)))