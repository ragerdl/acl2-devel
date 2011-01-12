; ACL2 Version 4.2 -- A Computational Logic for Applicative Common Lisp
; Copyright (C) 2011  University of Texas at Austin

; This version of ACL2 is a descendent of ACL2 Version 1.9, Copyright
; (C) 1997 Computational Logic, Inc.  See the documentation topic
; NOTE-2-0.

; This program is free software; you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation; either version 2 of the License, or
; (at your option) any later version.

; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.

; You should have received a copy of the GNU General Public License
; along with this program; if not, write to the Free Software
; Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

; Regarding authorship of ACL2 in general:

; Written by:  Matt Kaufmann               and J Strother Moore
; email:       Kaufmann@cs.utexas.edu      and Moore@cs.utexas.edu
; Department of Computer Sciences
; University of Texas at Austin
; Austin, TX 78712-1188 U.S.A.

; hons-raw.lisp -- Raw lisp implementation of hash cons and fast alists.  Note
; that the memoization and watch functionality previously provided by this file
; have been moved into memoize-raw.lisp.  This file has undergone a number of
; updates and changes since its original creation in about 2005.

; The original version of this file was contributed by Bob Boyer and Warren
; A. Hunt, Jr.  The design of this system of Hash CONS, function memoization,
; and fast association lists (applicative hash tables) was initially
; implemented by Boyer and Hunt.  The code has since been improved by Boyer and
; Hunt, and also by Sol Swords, Jared Davis, and Matt Kaufmann.

; Current owners:  Jared Davis and Warren Hunt

(in-package "ACL2")

;; We use the static honsing scheme on 64-bit CCL.
#+(and Clozure x86_64)
(push :static-hons *features*)

; NOTES ABOUT HL-HONS
;
; The "HL-" prefix was introduced when Jared Davis revised the Hons code, and
; "HL" originally meant "Hons Library."  The revision included splitting the
; Hons code from the function memoization code, and took place in early 2010.
; We will now use the term to refer to the new Hons implementation that is
; found below.  Some changes made in HL-Hons, as opposed to the old Hons
; system, include:
;
;   - We combine all of the special variables used by the Hons code into an
;     explicit Hons-space structure.
;
;   - We no longer separately track the length of sbits.  This change appears
;     to incur an overhead of 3.35 seconds in a 10-billion iteration loop, but
;     gives us fewer invariants to maintain and makes Ctrl+C safety easier.
;
;   - We have a new static honsing scheme where every normed object has an
;     address, and NIL-HT, CDR-HT, and CDR-HT-EQL aren't needed when static
;     honsing is used.
;
;   - Since normed strings are EQ comparable, we now place cons pairs whose
;     cdrs are strings into the CDR-HT hash table instead of the CDR-HT-EQL
;     hash table in classic honsing.
;
;   - Previously fast alists were essentially implemented as flex alists.  Now
;     we always create a hash table instead.  This slightly simplifies the code
;     and results in trivially fewer runtime type checks in HONS-GET and
;     HONS-ACONS.  I think it makes sense to use flex alists in classic
;     honsing, where we can imagine often finding cdrs for which we don't have
;     at least 18 separate cars.  But fast alists are much more targeted; if
;     an ACL2 user is building a fast alist, it seems very likely that they
;     know they are doing something big (or probably big) -- otherwise they
;     wouldn't be bothering with fast alists.


; ESSAY ON CTRL+C SAFETY
;
; The HL-Hons implementation involves certain impure operations.  Sometimes, at
; intermediate points during a sequence of updates, the invariants on a Hons
; Space are violated.  This is dangerous because a user can interrupt at any
; time using 'Ctrl+C', leaving the system in an inconsistent state.
;
; We have tried to avoid sequences of updates that violate invariants.  In the
; rare cases where this isn't possible, we need to protect the sequence of
; updates with 'without-interrupts'.  We assume that SETF itself does not
; suffer from this kind of problem and that the Lisp implementation should
; ensure that, e.g., (SETF (GETHASH ...)) does not leave a hash table in an
; internally inconsistent state.

(defconstant *hl-mht-default-rehash-size* 1.5)
(defconstant *hl-mht-default-rehash-threshold* 0.7)

(defun hl-mht (&key (test             'eql)
                    (size             '60)
                    (rehash-size      *hl-mht-default-rehash-size*)
                    (rehash-threshold *hl-mht-default-rehash-threshold*)
                    (weak             'nil)
                    (shared           'nil)
                    (lock-free        'nil)
                    )

; Wrapper for make-hash-table.
;
; Because of our approach to threading, we generally don't need our hash tables
; to be protected by locks.  HL-MHT is essentially like make-hash-table, but on
; CCL creates hash tables that aren't shared between threads, which may result
; in slightly faster updates.

  (declare (ignorable shared weak))
  (make-hash-table :test             test
                   :size             size
                   :rehash-size      rehash-size
                   :rehash-threshold rehash-threshold
                   #+Clozure :weak   #+Clozure weak
                   #+Clozure :shared #+Clozure shared
                   #+Clozure :lock-free #+Clozure lock-free
                   ))



; ----------------------------------------------------------------------
;
;                           CACHE TABLES
;
; ----------------------------------------------------------------------

; A Cache Table is a relatively simple data structure that can be used to
; (partially) memoize the results of a computation.  Cache tables are used by
; the Hons implementation, but are otherwise independent from the rest of HONS.
; We therefore introduce them here, up front.
;
; The operations of a Cache Table are as follows:
;
;    (HL-CACHE-GET KEY TABLE)         Returns (MV PRESENT-P VAL)
;    (HL-CACHE-SET KEY VAL TABLE)     Destructively modifies TABLE
;
; In many ways, a Cache Table is similar to an EQ hash table, but there are
; also some important differences.  Unlike an ordinary hash table, a Cache
; Table may "forget" some of its bindings at any time.  This allows us to
; ensure that the Cache Table does not grow beyond a fixed size.
;
; Cache Tables are not thread safe.
;
; We have two implementations of Cache Tables.
;
; Implementation 1.  For Lisps other than 64-bit CCL.  (#-static-hons)
;
;    A Cache Table is essentially an ordinary hash table, along with a separate
;    field that tracks its count.
;
;    It is almost an invariant that this count should be equal to the
;    HASH-TABLE-COUNT of the hash table, but we do NOT rely upon this for
;    soundness and this property might occasionally be violated due to
;    interrupts.  In such cases, we ensure that the count is always more than
;    the HASH-TABLE-COUNT of the hash table.  (The only negative consequence of
;    this is that the table may be cleared more frequently.)
;
;    The basic scheme is as follows.  Whenever hl-cache-set is called, if the
;    count exceeds our desired threshold, we clear the hash table before we
;    continue.  The obvious disadvantage of this is that we may throw away
;    results that may be useful.  But the advantage is that we ensure that the
;    cache table does not grow.  On one benchmark, this approach was about
;    17% slower than letting the hash table grow without restriction (notably
;    ignoring all garbage collection costs), but it lowered the memory usage
;    from 2.8 GB to 92 MB.
;
;    We have considered improving the performance by experimenting with the
;    size of its cache.  A larger cache means less frequent clearing but
;    requires more memory.  We also looked into more smartly clearing out the
;    cache.  One idea was to throw away only half of the entries "at random" by
;    just allowing the maphash order to govern whether we throw out one entry
;    or another.  But when this was slow, we discovered that, at least on CCL,
;    iterating over a hash table is fairly expensive and requires the keys and
;    values of the hash table to be copied into a list.  For a 500k cache,
;    "clearing" half the entries required us to allocate 6 MB, and ruined
;    almost all memory savings we had hoped for.  Hence, we just use ordinary
;    clrhash.
;
; Implementation 2.  For 64-bit CCL (#+static-hons) we use a better scheme.
;
;    A Cache Table contains two arrays, KEYDATA and VALDATA.  These arrays
;    associate "hash codes" (array indicies) to keys and values, respectively.
;    We could have used a single array with (key . val) pairs as its entries,
;    but using two separate arrays allows us to implement hl-cache-set with no
;    consing.
;
;    These hash codes are based upon the actual machine address of KEY, and
;    hence (1) may easily collide and (2) are not reliable across garbage
;    collections.  To give a sensible semantics, in hl-cache-get, we must
;    explicitly check that this hash code has the proper KEY.
;
;    Our hashing function, hl-machine-hash, performs quite well.  According to
;    a rough test, it takes only about the same time as three or four fixnum
;    additions.  Here's the testing code we used:
;
;      (defun f (x) ;; (f '(1 . 2)) takes 8.709 seconds
;        (let ((acc 0))
;          (declare (type fixnum acc))
;          (time (loop for i fixnum from 1 to 1000000000
;                      do
;                      (setq acc (the fixnum (+ (the fixnum acc) (the fixnum (car x)))))
;                      (setq acc (the fixnum (+ (the fixnum acc) (the fixnum (cdr x)))))
;                      (setq acc (the fixnum (+ (the fixnum acc) (the fixnum (car x)))))
;                      (setq acc (the fixnum (+ (the fixnum acc) (the fixnum (cdr x)))))
;                      ))
;          acc))
;
;      (defun g (x) ;; (g '(1 . 2)) takes 8.005 seconds
;        (let ((acc 0))
;          (declare (type fixnum acc))
;          (time (loop for i fixnum from 1 to 1000000000
;                      do
;                      (setq acc (the fixnum (+ acc (the fixnum (hl-machine-hash x)))))))
;          acc))
;
;    However, in addition to fast execution speed, we want this function to
;    produce a good distribution so that we may hash on its result.  We have
;    hard-coded in a size of 2^20 for our data arrays, but it would not be very
;    to change this.  To determine how well it distributes addresses, we
;    computed the hash codes for a list of 2^24 objects, which is more than the
;    2^20 hash codes that we have made available.  We found that every hash
;    code was used precisely 16 times, a perfect distribution!  (Of course,
;    when this is used on actual data produced by a program, we do not expect
;    the results to be so good.)  Here is some basic testing code:
;
;      (defparameter *hashes* nil)
;
;      (let* ((tries        (expt 2 24))
;             (hashes       (time (loop for i fixnum from 1 to tries collect
;                                       (hl-machine-hash (cons 1 2)))))
;             (nhashes      (time (len (sets::mergesort hashes)))))
;        (setq *hashes* hashes)
;        (format t "Got ~:D entries for ~:D tries.~%" nhashes tries))
;
;      (defparameter *dupes* (hons-duplicity-alist *hashes*))
;      (sets::mergesort (strip-cdrs *dupes*))

; BOZO:  Implicitly, our cache table has NIL bound to NIL; this might not
;        be appropriate for "memoizing" other applications.

#-static-hons
(defconstant hl-cache-table-size
  ;; Size of the cache table
  400000)

#-static-hons
(defconstant hl-cache-table-cutoff
  ;; Clear the table for hl-norm when it gets to 3/4 full.
  (floor (* 0.75 hl-cache-table-size)))

(defstruct hl-cache

  #+static-hons
  (keydata   (make-array (expt 2 20) :initial-element nil) :type simple-vector)
  #+static-hons
  (valdata   (make-array (expt 2 20) :initial-element nil) :type simple-vector)

  #-static-hons
  (table     (hl-mht :test #'eq :size hl-cache-table-size) :type hash-table)
  #-static-hons
  (count     0 :type fixnum))


#+static-hons
(defabbrev hl-machine-hash (x)

; NOT A FUNCTION.  Note that (EQUAL (HL-MACHINE-HASH X) (HL-MACHINE-HASH X)) is
; not necessarily true, because objects may be moved during garbage collection
; in CCL.
;
; We use the machine address of an object to compute a hash code within [0,
; 2^20).  We obtain a good distribution on 64-bit CCL, but we have not tried
; this on 32-bit CCL.
;
; We right-shift the address by five places because smaller shifts led to worse
; distributions.  We think this is because the low 3 bits are just tag bits
; (which are not interesting), and the next 2 bits never add any information
; because conses are word-aligned.
;
; To change this from 2^20 to other powers of 2, you should only need to adjust
; the mask.  We think 2^20 is a good number, since a 2^20 element array seems
; to require about 8 MB of memory, e.g., our whole cache will take 16 MB.

  (let* ((addr    (ccl::%address-of x))
         (addr>>5 (the fixnum (ash (the fixnum addr) -5))))
    ;; (ADDR>>5) % 2^20
    (the fixnum (logand (the fixnum addr>>5) #xFFFFF))))

(defun hl-cache-set (key val cache)
  (declare (type hl-cache cache))

  #+static-hons
  (let ((keydata (hl-cache-keydata cache))
        (valdata (hl-cache-valdata cache))
        (code    (hl-machine-hash key)))
    (ccl::without-interrupts
     (setf (svref keydata (the fixnum code)) key)
     (setf (svref valdata (the fixnum code)) val)))

  #-static-hons
  (let ((table (hl-cache-table cache))
        (count (hl-cache-count cache)))
    ;; This is a funny ordering which is meant to ensure the count exceeds or
    ;; agrees with (hash-table-count table), even in the face of interrupts.
    (setf (hl-cache-count cache)
          (the fixnum (+ 1 (the fixnum count))))
    (when (> (the fixnum count)
             (the fixnum hl-cache-table-cutoff))
      (clrhash table)
      ;; We set count to one, not zero, because we're about to add an element.
      (setf (hl-cache-count cache) 1))
    (setf (gethash key table) val)))

(defun hl-cache-get (key cache)

; (HL-CACHE-GET KEY CACHE) --> (MV PRESENT-P VAL)
;
; Note that this isn't thread-safe.  If we want a truly multithreaded hons,
; we'll need to think about how to protect access to the cache.

  (declare (type hl-cache cache))

  #+static-hons
  (let* ((keydata  (hl-cache-keydata cache))
         (code     (hl-machine-hash key))
         (elem-key (svref keydata (the fixnum code))))

    (if (eq elem-key key)
        (let* ((valdata  (hl-cache-valdata cache))
               (elem-val (svref valdata (the fixnum code))))
          (mv t elem-val))
      (mv nil nil)))

  #-static-hons
  (let* ((table (hl-cache-table cache))
         (val   (gethash key table)))
    (if val
        (mv t val)
      (mv nil nil))))

(defun hl-cache-clear (cache)
  (declare (type hl-cache cache))
  #+static-hons
  (let ((keydata (hl-cache-keydata cache))
        (valdata (hl-cache-valdata cache)))
    (loop for i fixnum from 0 to (expt 2 20) do
          (setf (svref keydata i) nil)
          (setf (svref valdata i) nil)))

  #-static-hons
  (progn
    ;; This ordering ensures count >= (hash-table-count table) even in
    ;; the face of interrupts
    (clrhash (hl-cache-table cache))
    (setf (hl-cache-count cache) 0)))




; ESSAY ON HONS SPACES
;
; The 'ACL2 Objects' are described in the ACL2 function bad-lisp-objectp;
; essentially they are certain "good" symbols, characters, strings, and
; numbers, recursively closed under consing.  Note that stobjs are not ACL2
; Objects under this definition.
;
; The 'Hons Spaces' are fairly complex structures, introduced with the
; defstruct for hl-hspace, which must satisfy certain invariants.  At any point
; in time there may be many active Hons Spaces, but separate threads may never
; access the same Hons Space!  This restriction is intended to minimize the
; need to lock while accessing Hons Spaces.
;
;    Aside.  Shareable Hons Spaces might have some advantages.  They might
;    result in lower overall memory usage and reduce the need to re-hons data
;    in multiple threads.  They might also be a better fit for Rager's
;    parallelism routines.  But acquiring locks might slow honsing in
;    single-threaded code and make our code more complex.  We should
;    investigate this later.
;
;
; Fundamental Operations.
;
; A Hons Space provides two fundamental operations.
;
; First, given any ACL2 Object, X, and any Hons Space HS, we must be able to
; determine whether X is 'normed' with respect to HS.  The fundamental
; invariant of normed objects is that if A and B are both normed with respect
; to HS, then (EQUAL A B) holds iff (EQL A B).
;
; Second, given any ACL2 Object, X, and any Hons Space HS, we must be able to
; 'norm' X to obtain an ACL2 Object that is EQUAL to X and which is normed with
; respect to HS.  Note that norming is 'impure' and destructively modifies HS.
; This modification is really an extension: any previously normed object will
; still be normed, but previously non-normed objects may now also be normed.
;
;
; Tracking Normed Objects.
;
; To support these operations, a Hons Space contains certain hash tables and
; arrays that record which ACL2 Objects are currently regarded as normed.
;
; Symbols, characters, and numbers.  These objects automatically and trivially
; satisfy the fundamental invariant of normed objects.  We therefore regard all
; symbols, characters, and numbers as normed with respect to any Hons Space,
; and nothing needs to be done to track whether particular symbols, characters,
; or numbers are normed.
;
; Strings.  Within each Hons Space, we may choose some particular string, X, as
; the normed version of all strings that are equal to X.  We record this choice
; in the STR-HT field of the Hons Space, which is an EQUAL hash table.  The
; details of what we record in the STR-HT actually depend on whether 'classic
; honsing' or 'static honsing' is being used.
;
; Conses.  Like strings, there are equal conses which are not EQL.  We could
; account for this by setting up another equal hash table, as we did for
; strings, but equal hashing of conses can be very slow.  More efficient
; schemes are possible if we insist upon two reasonable invariants:
;
;   INVARIANT C1.  The car of a normed cons must be normed.
;   INVARIANT C2.  The cdr of a normed cons must be normed.
;
; Using these invariants, we have developed two schemes for tracking which
; conses are normed.  One approach, called classic-honsing, makes use of only
; ordinary Common Lisp functions.  The second approach, static-honsing, is
; higher performance but requires features that are specific to Clozure Common
; Lisp.



; ESSAY ON CLASSIC HONSING
;
; Prerequisite: see the essay on hons spaces.
;
; Classic Honsing is a scheme for tracking normed conses that can be used in
; any Lisp.  Here, every normed cons is recorded in one of three hash tables.
; In particular, whenever X = (A . B) is normed, then X will be found in
; either:
;
;    NIL-HT, when B is NIL,
;    CDR-HT, when B is a non-NIL symbol, cons, or a string, or
;    CDR-HT-EQL otherwise.
;
; The NIL-HT binds A to X whenever X = (A . NIL) is a normed cons.  Thanks to
; Invariant C1, which assures us that A will be normed, we only need to use an
; EQL hash table for NIL-HT.
;
; For other conses, we basically implement a two-level hashing scheme.  To
; determine if an cons is normed, we first look up its CDR in the CDR-HT or
; CDR-HT-EQL, depending on its type.  Both of these tables bind B to the set of
; all normed X such that X = (A . B) for any A.  These sets are represented as
; 'flex alists', defined later in this file.  So, once we have found the proper
; set for B, we look through it and see whether there is a normed cons in it
; with A as its CAR.
;
; We use the CDR-HT (an EQ hash table) for objects whose CDRs are
; EQ-comparable, and the CDR-HT-EQL (an EQL hash table) for the rest.  We may
; use CDR-HT for both strings and conses since, by Invariant C2, we know that
; the CDR is normed and hence pointer equality suffices.
;
; The only other thing to mention is strings.  In the classic honsing scheme,
; the STR-HT simply associates each string to its normed version.  That is, a
; string X is normed exactly when (eq X (gethash X STR-HT)).  It is
; straightforward to norm a string X: a STR-HT lookup tells us whether a normed
; version of X exists, if so, what it is.  Otherwise, when no normed version of
; X exists, we effectively 'norm' X by extending the STR-HT by binding X to
; itself.
;
; Taken all together, the STR-HT, NIL-HT, CDR-HT, and CDR-HT-EQL completely
; determine which ACL2 objects are normed in the classic honsing scheme.



; ESSAY ON STATIC HONSING
;
; Prerequisite: see the essay on hons spaces.
;
; Static Honsing is a scheme for tracking normed conses that can be used only
; in Clozure Common Lisp.
;
; In CCL, one can use (ccl::static-cons a b) in place of (cons a b) to create a
; cons that will not be moved by the garbage collector.  The 'index' of such a
; cons, which is a fixnum exceeding 128, may be obtained with (ccl::%staticp x)
; and, per Gary Byers, will be forever fixed, even after garbage collection,
; even after saving an image.
;
; Static Honsing is an alternative to classic honsing that exploits static
; conses for greater efficiency.  Here, only static conses can be considered
; normed, and SBITS is a bit-array that records which static conses are
; currently normed.  That is, suppose X is a static cons and let I be the index
; of X.  Then X is considered normed exactly when the Ith bit of SBITS is 1.
; This is a very fast way to determine if a cons is normed!
;
;
; Addresses for Normed Objects.
;
; To support hons construction, we also need to be able to do the following:
; given two normed objects A and B, find the normed version of (A . B) or
; determine that none exists.
;
; Toward this goal, we first develop a reliable 'address' for every normed
; object; this address has nothing to do with machine (X86, PowerPC, or other)
; addresses.  To begin, we statically assign addresses to NIL, T, and certain
; small integers.  In particular:
;
;    Characters are given addresses 0-255, corresponding to their codes
;    NIL and T are given addresses 256 and 257, respectively
;    Integers in [-2^14, 2^23] are given the subsequent addresses
;
; All other objects are dynamically assigned addresses.  In particular, suppose
; that BASE is the start of the dynamically-allocated range.  Then,
;
;    The address of a static cons, C, is Index(C) + BASE, where Index(C) is the
;    index returned by ccl::%staticp.
;
;    For any other atom, X, we construct an associated static cons, say X_C,
;    and then use Index(X_C) + BASE as the address of X.
;
; This scheme gives us a way to generate a unique, reliable address for every
; ACL2 Object we encounter.  These addresses start small and increase as more
; static conses are created.
;
; We record the association of these "other atoms" to their corresponding
; static conses in different ways, depending upon their types:
;
;   For symbols, the static cons is stored in the 'hl-static-address property
;   for the symbol.  This results in something a little bizarre: symbol
;   addresses are implicitly shared across all Hons Spaces, and so we must take
;   care to ensure that our address-allocation code is thread safe.
;
;   For strings, the STR-HT binds each string X to the pair (NX . NX_C), where
;   NX is the normed version of X and NX_C is the static cons whose index is
;   being used as the address for NX.
;
;   For any other atoms, the Hons Space includes OTHER-HT, an EQL hash table
;   that associates each atom X with X_C, the static cons for X.
;
; In the future, we might want to think about the size of BASE.  Gary might be
; be able to extend static cons indicies so that they start well after 128,
; perhaps eliminating the need to add BASE when computing the addresses for
; static conses.  On the other hand, it's probably just a matter of who is
; doing the addition, and our current scheme gives us good control over the
; range.
;
;
; Address-Based Hashing.
;
; Given the addresses of two normed objects, A and B, the function
; hl-addr-combine generates a unique integer that can be used as a hash key.
;
; Each Hons Space includes ADDR-HT, an EQL hash table that associates these
; keys to the normed conses to which they correspond.  In other words, suppose
; C = (A . B) is a normed cons, and KEY is the key generated for the addresses
; of A and B.  Then ADDR-HT associates KEY to C.
;
; Hence, assuming A and B are normed, we can determine whether a normed cons of
; the form (A . B) exists by simply generating the proper KEY and then checking
; whether ADDR-HT includes an entry for this key.



; DEFAULT SIZES.  The user can always call hl-hons-resize to get bigger tables,
; but we still want good defaults.  These sizes are used in the structures that
; follow.

(defparameter *hl-hspace-str-ht-default-size*      1000)
(defparameter *hl-ctables-nil-ht-default-size*     5000)
(defparameter *hl-ctables-cdr-ht-default-size*     100000)
(defparameter *hl-ctables-cdr-ht-eql-default-size* 1000)
(defparameter *hl-hspace-addr-ht-default-size*     150000)
(defparameter *hl-hspace-sbits-default-size*       16000000)
(defparameter *hl-hspace-other-ht-default-size*    1000)
(defparameter *hl-hspace-fal-ht-default-size*      1000)
(defparameter *hl-hspace-persist-ht-default-size*  100)


(defun hl-initialize-fal-ht (fal-ht-size)

; Create the initial FAL-HT for a hons space.  See the Essay on Fast Alists,
; below, for more details.
;
; We now use a lock-free hash table for the FAL-HT:
;
; CCL has two hashing algorithms, "regular" and "lock-free."  The regular
; algorithm uses typical locking to support access by multiple threads.  The
; lock-free algorithm uses a more sophisticated scheme so that locking isn't
; necessary.  The general thinking is that the lock-free version is only
; slightly slower than the regular version (except for things like resizing
; where it is considerably slower.)
;
; Why use the lock-free algorithm?  After all, we know that hons-spaces are
; thread-local to begin with, and indeed we use :shared nil when we create hash
; tables with hl-mht.  Unfortunately there implementation of REMHASH for
; regular hash tables seems to suffer from a couple of bad problems.  The
; FAL-HT is the only place we use remhash, but we use it all the time: every
; time a fast alist is updated, we have to remhash its previous table and then
; install its updated table.
;
; Problem 1.  There is a special case for deleting the last remaining element
; from a regular hash table.  In particular, this triggers a linear walk of the
; hash table, where every element in the vector is overwritten with the
; free-hash-marker.  This is devestating when there is exactly one active fast
; alist: every "hons-acons" and "fast-alist-free" operation requires a linear
; walk over the FAL-HT.  It took Jared two whole days to figure out that this
; was the cause of painfully slow execution in a particular algorithm.  We have
; informed the CCL maintainers of this problem and, as a gross temporary
; solution, added some code to ensure that the FAL-HT always had at least one
; element in it so that the bad case would not be encountered.
;
; Problem 2.  Sol later discovered another problem that occurs when remhashes
; are mixed in with puthashes in certain patterns.  When a table grows to the
; threshold where it should be resized, it is instead rehashed in place if it
; contains any deleted elements -- so if you grow up to 99% of capacity and
; then repeatedly insert and delete elements, you're likely to spend a lot of
; time rehashing without growing the table.  The lock-free implementation does
; not seem to have this problem, so we have switched to it until the regular
; algorithm is improved.
;
; We now use a :weak :key hash table for the FAL-HT:
;
; Historically the garbage collector had performance problems for weak hash
; tables.  However, new regressions seem to indicate that these problems are
; resolved, or at least are not very severe when there is only one weak hash
; table.
;
; Having a weak FAL-HT is really appealing.  It reduces the penalty for
; forgetting to free a fast-alist.  It also allows you to memoize functions
; that produce fast alists and, after clearing their memoization tables like in
; a hons-wash, the hash tables can be reclaimed.

  (let ((fal-ht (hl-mht :test #'eq
                        :size (max 100 fal-ht-size)
                        :lock-free t
                        :weak :key)))

; Previous code for inserting a sentinel-element to ensure the table never
; becomes empty after a remhash.  This is no longer necessary with the
; lock-free algorithm.

    ;; #+Clozure
    ;; (let* ((entry       (cons t t))
    ;;        (sentinel-al (cons entry 'special-builtin-fal))
    ;;        (sentinel-ht (hl-mht :test #'eql)))
    ;;   (setf (gethash t sentinel-ht) entry)
    ;;   (setf (gethash sentinel-al fal-ht) sentinel-ht))

    fal-ht))



#-static-hons
(defstruct hl-ctables

; CTABLES STRUCTURE.  This is only used in classic honsing.  We aggregate
; together the NIL-HT, CDR-HT, and CDR-HT-EQL fields so that we can clear them
; out all at once in hl-hspace-hons-clear, for Ctrl+C safety.

  (nil-ht     (hl-mht :test #'eql :size *hl-ctables-nil-ht-default-size*)
              :type hash-table)

  (cdr-ht     (hl-mht :test #'eq :size *hl-ctables-cdr-ht-default-size*)
              :type hash-table)

  (cdr-ht-eql (hl-mht :test #'eql :size *hl-ctables-cdr-ht-eql-default-size*)
              :type hash-table))



(defstruct (hl-hspace (:constructor hl-hspace-init-raw))

; HONS SPACE STRUCTURE.  See the above essays on hons spaces, classic honsing,
; and static honsing above to understand this structure.

  (str-ht     (hl-mht :test #'equal :size *hl-hspace-str-ht-default-size*)
              :type hash-table)


  ;; Classic Honsing

  #-static-hons
  (ctables (make-hl-ctables) :type hl-ctables)


  ;; Static Honsing

  #+static-hons
  (addr-ht    (hl-mht :test #'eql :size *hl-hspace-addr-ht-default-size*)
              :type hash-table)

  #+static-hons
  (sbits      (make-array *hl-hspace-sbits-default-size*
                          :element-type 'bit :initial-element 0)
              :type (simple-array bit (*)))

  #+static-hons
  (other-ht   (hl-mht :test #'eql :size *hl-hspace-other-ht-default-size*)
              :type hash-table)


  ;; Miscellaneous Fields.

  ;; NORM-CACHE is described in the essay on HL-HSPACE-NORM, below.
  (norm-cache   (make-hl-cache) :type hl-cache)

  ;; FAL-HT is described in the documentation for fast alists.
  (fal-ht       (hl-initialize-fal-ht *hl-hspace-fal-ht-default-size*)
                :type hash-table)

  ;; PERSIST-HT is described in the documentation for hl-hspace-persistent-norm
  (persist-ht   (hl-mht :test #'eq :size *hl-hspace-persist-ht-default-size*)
                :type hash-table)

  )

(defun hl-hspace-init (&key (str-ht-size       *hl-hspace-str-ht-default-size*)
                            (nil-ht-size       *hl-ctables-nil-ht-default-size*)
                            (cdr-ht-size       *hl-ctables-cdr-ht-default-size*)
                            (cdr-ht-eql-size   *hl-ctables-cdr-ht-eql-default-size*)
                            (addr-ht-size      *hl-hspace-addr-ht-default-size*)
                            (sbits-size        *hl-hspace-sbits-default-size*)
                            (other-ht-size     *hl-hspace-other-ht-default-size*)
                            (fal-ht-size       *hl-hspace-fal-ht-default-size*)
                            (persist-ht-size   *hl-hspace-persist-ht-default-size*))

; (HL-HSPACE-INIT ...) --> Hons Space
;
; This is the proper constructor for hons spaces.  The arguments allow you to
; override the default sizes for the various tables, which may be useful if you
; have a good idea of what your application will need.
;
; Note that we enforce certain minimum sizes, just because it seems like
; smaller sizes wouldn't really be sensible.

  #+static-hons
  (declare (ignore nil-ht-size cdr-ht-size cdr-ht-eql-size))
  #+static-hons
  (hl-hspace-init-raw
   :str-ht           (hl-mht :test #'equal :size (max 100 str-ht-size))
   :addr-ht          (hl-mht :test #'eql   :size (max 100 addr-ht-size))
   :other-ht         (hl-mht :test #'eql   :size (max 100 other-ht-size))
   :sbits            (make-array (max 100 sbits-size)
                                 :element-type 'bit
                                 :initial-element 0)
   :norm-cache       (make-hl-cache)
   :fal-ht           (hl-initialize-fal-ht fal-ht-size)
   :persist-ht       (hl-mht :test #'eq :size (max 100 persist-ht-size))
   )

  #-static-hons
  (declare (ignore addr-ht-size sbits-size other-ht-size))
  #-static-hons
  (hl-hspace-init-raw
   #-static-hons
   :str-ht           (hl-mht :test #'equal :size (max 100 str-ht-size))
   :ctables          (make-hl-ctables
                      :nil-ht (hl-mht :test #'eql
                                      :size (max 100 nil-ht-size))
                      :cdr-ht (hl-mht :test #'eq
                                      :size (max 100 cdr-ht-size))
                      :cdr-ht-eql (hl-mht :test #'eql
                                          :size (max 100 cdr-ht-eql-size)))
   :norm-cache       (make-hl-cache)
   :fal-ht           (hl-initialize-fal-ht fal-ht-size)
   :persist-ht       (hl-mht :test #'eq :size (max 100 persist-ht-size))
   ))




; ESSAY ON FLEX ALISTS (Classic Honsing Only)
;
; Given certain restrictions, a 'flex alist' is similar to an EQL alist, except
; that it is converted into a hash table after reaching a certain size.
;
;   RESTRICTION 1.  A flex alist must be used according to the single threaded
;   discipline, i.e., you must always extend the most recently extended flex
;   alist.
;
;   RESTRICTION 2.  A flex alist must never be extended twice with the same
;   key.  This ensures that the entry returned by flex-assoc is always EQ to
;   the unique entry which was inserted by flex-acons and permits trivial
;   optimizations during the conversion to hash tables.
;
; Flex alists may be either ordinary, nil-terminated alists or hash tables.
; The idea is to avoid creating hash tables until there are enough elements to
; warrant doing so.  That is, a flex alist starts out as an alist, but may be
; dynamically promoted to a hash table after a certain size is reached.
;
; The main use of flex alists is in the CDR-HT and CDR-HT-EQL fields of a
; hons space.
;
; [Jared]: I wonder if a larger threshold would be better.  It might be worth
; having slow honsp checks when alists are in the 20-100 range in exchange for
; lower memory usage.

(defabbrev hl-flex-alist-too-long (x)

; (hl-flex-alist-too-long x) == (> (length x) 18) for proper lists.  It is
; inspired by the Milawa function len-over-250p.  Although it is ugly, it is
; faster than looping and counting.

   (let ((4cdrs (cddddr x)))
     (and (consp 4cdrs)
          (let ((8cdrs  (cddddr 4cdrs)))
            (and (consp 8cdrs)
                 (let* ((12cdrs (cddddr 8cdrs)))
                   (and (consp 12cdrs)
                        (let* ((16cdrs (cddddr 12cdrs))
                               (18cdrs (cddr 16cdrs)))
                          (consp 18cdrs)))))))))

(defabbrev hl-flex-assoc (key al)

; (hl-flex-assoc key al) returns the entry associated with key, or returns nil
; if key is not bound.  Note that the comparisons performed by flex-assoc are
; always done with EQL.

  (if (listp al)
      (assoc key al)
    (gethash key (the hash-table al))))

(defabbrev hl-flex-acons (elem al)

; (hl-flex-acons entry al) assumes that entry is a (key . val) pair, and
; extends the flex alist al by binding key to entry.
;
; Note: the caller must ensure to obey the restrictions described in the
; Essay on Flex Alists.
;
; Note about Ctrl+C Safety: this is locally safe assuming that (setf (gethash
; ...)) is safe.  In the alist case we're pure, so there aren't any problems.
; In the 'conversion' case, the hash table doesn't become visible to the caller
; unless it's been fully constructed, so we're ok.  In the hash table case,
; we're a single setf, which we assume is okay.

  (if (listp al)
      (cond ((hl-flex-alist-too-long al)
             ;; Because of uniqueness, we don't need to worry about shadowed
             ;; pairs; we can just copy all pairs into the new hash table.
             (let ((ht (hl-mht)))
               (declare (type hash-table ht))
               (loop for pair in al do
                     (setf (gethash (car pair) ht) pair))
               (setf (gethash (car elem) ht) elem)
               ht))
            (t
             (cons elem al)))
    (progn
      (setf (gethash (car elem) (the hash-table al))
            elem)
      al)))


; ----------------------------------------------------------------------
;
;                   DETERMINING IF OBJECTS ARE NORMED
;
; ----------------------------------------------------------------------

#+static-hons
(defabbrev hl-hspace-truly-static-honsp (x hs)

; (HL-HSPACE-TRULY-STATIC-HONSP X HS) --> BOOL
;
; Static Honsing only.  X must be an ACL2 Cons and HS must be a Hons Space.  We
; determine if X is a static cons whose bit is set in the SBITS array.  If so,
; we X is considered normed with respect to HS.

  (let* ((idx (ccl::%staticp x)))
    (and idx
         (let ((sbits (hl-hspace-sbits hs)))
           (and (< (the fixnum idx) (the fixnum (length sbits)))
                (= 1 (the fixnum (aref sbits (the fixnum idx)))))))))

#-static-hons
(defabbrev hl-hspace-find-alist-for-cdr (b ctables)

; (HL-HSPACE-FIND-ALIST-FOR-CDR B CTABLES) --> FLEX ALIST
;
; Classic Honsing only.  B is any ACL2 Object and CTABLES is the ctables
; structure from a Hons Space.  Suppose there is some ACL2 Object, X = (A . B).
; We return the flex alist that X must belong to for classic honsing.  Note
; that even though the NIL-HT starts out as a hash table, we can still regard
; it as a flex alist.

  (cond ((null b)
         (hl-ctables-nil-ht ctables))
        ((or (consp b)
             (symbolp b)
             (stringp b))
         (gethash b (hl-ctables-cdr-ht ctables)))
        (t
         (gethash b (hl-ctables-cdr-ht-eql ctables)))))

(defabbrev hl-hspace-honsp (x hs)

; (HL-HSPACE-HONSP X HS) --> BOOL
;
; X must be an ACL2 Cons and HS is a Hons Space.  We determine if X is normed
; with respect to HS.

  #+static-hons
  (hl-hspace-truly-static-honsp x hs)
  #-static-hons
  (let* ((a        (car x))
         (b        (cdr x))
         (ctables  (hl-hspace-ctables hs))
         (hons-set (hl-hspace-find-alist-for-cdr b ctables))
         (entry    (hl-flex-assoc a hons-set)))
    (eq x entry)))




; ----------------------------------------------------------------------
;
;                   EXTENDED EQUALITY OPERATIONS
;
; ----------------------------------------------------------------------

(defun hl-hspace-hons-equal-lite (x y hs)

; (HL-HSPACE-HONS-EQUAL-LITE X Y HS) --> BOOL
;
; X and Y may be any ACL2 Objects and HS must be a Hons Space.  We compute
; (EQUAL X Y).  If X and Y happen to be normed conses, we can settle the
; question of their equality via simple pointer equality; otherwise we just
; call (EQUAL X Y).

  (declare (type hl-hspace hs))
  (cond ((eq x y)
         t)
        ((and (consp x)
              (consp y)
              (hl-hspace-honsp x hs)
              (hl-hspace-honsp y hs))
         nil)
        (t
         (equal x y))))

(defun hl-hspace-hons-equal (x y hs)

; (HL-HSPACE-HONS-EQUAL X Y HS) --> BOOL
;
; X and Y may be any ACL2 Objects and HS must be a Hons Space.  We recursively
; check (EQUAL X Y), using pointer equality to determine the equality of any
; normed subtrees.

  (declare (type hl-hspace hs))
  (cond ((eq x y)
         t)
        ((consp x)
         (and (consp y)
              (not (and (hl-hspace-honsp x hs)
                        (hl-hspace-honsp y hs)))
              (hl-hspace-hons-equal (car x) (car y) hs)
              (hl-hspace-hons-equal (cdr x) (cdr y) hs)))
        ((consp y)
         nil)
        (t
         (equal x y))))




; ----------------------------------------------------------------------
;
;                       STATIC HONS ADDRESSING
;
; ----------------------------------------------------------------------

; Our hashing scheme (see hl-addr-combine) performs best when both addresses
; involved are under 2^30.  In other words, there are about 1,073 million
; "fast-hashing" addresses and the rest are "slow-hashing".
;
; Historic notes.
;
; We did not originally statically assign addresses to the characters, and do
; not think it is particularly important to do so.  But, we like the idea of
; using numbers besides 0 and 1 as the addresses for T and NIL, under the
; probably misguided and certainly untested theory that perhaps using larger
; numbers will result in a better hashing distribution.
;
; We originally assigned a static, fast-hashing address for all integers in
; [-2^24, 2^24], and this decision "used up" about 33.6 million or 1/32 of the
; available fast-hashing addresses.  We later decided that this seemed slightly
; excessive, and we scaled the range down to [-2^14, 2^23].  This new scheme
; uses up 8.4 million or 1/128 of the fast-hashing addresses.  As a picture, we
; have:
;
;    8m                                                  1.07 bn
;   -|------------------------------- ... -----------------|--------------- ...
;   ^          dynamic fast-hashing                          slow-hashing
;   |
;   |
;  static fast-hashing
;
; We think this change is pretty much irrelevant and you shouldn't spend your
; time thinking about how to improve it.  Why?
;
;   (1) For most reasonable computations, slow addresses are never even used
;       and so this change won't matter at all.
;
;   (2) On the other hand, imagine a really massive computation that needs,
;       say, 2 billion normed conses.  Here, we are already paying the price of
;       slow addresses for half the conses.  Our change might mean that 1.06
;       billion instead of 1.04 billion of these conses will have fast-hashing
;       addresses, but this is only about 1% of the conses, so its effect on
;       performance is likely minimal.
;
; Even for applications that just barely exceed the boundary of slow-hashing,
; we're only talking about whether a small percentage of the conses having
; fast- or slow-hashing addresses.


#+static-hons
(defconstant hl-minimum-static-int
  ;; Minimum "small integer" that has a statically determined address.
  (- (expt 2 14)))

#+static-hons
(defconstant hl-maximum-static-int
  ;; Maximum "small integer" that has a statically determined address.
  (expt 2 23))

#+static-hons
(defconstant hl-num-static-ints
  ;; Total number of statically determined addresses needed for small integers.
  (1+ (- hl-maximum-static-int hl-minimum-static-int)))

#+static-hons
(defconstant hl-dynamic-base-addr
  ;; Total number of statically determined addresses for all atoms.  This is
  ;; the sum of:
  ;;  - 256 characters
  ;;  - 2 special symbols (T and NIL)
  ;;  - The number of statically determined integers
  (+ 256 2 hl-num-static-ints))

#+static-hons
(defconstant hl-static-int-shift
  ;; For integers with static addresses, the address is computed by adding
  ;; static-int-shift to their value.  These integers are in [min, max] where
  ;; min < 0 and max > 0.  The min integer will be assigned to location 258 =
  ;; 256 characters + 2 special symbols.  We then count up from there.
  (+ 256 2 (- hl-minimum-static-int)))

#+static-hons
(ccl::defstatic *hl-symbol-addr-lock*
                ;; lock for hl-symbol-addr; see below.
                (ccl::make-lock '*hl-symbol-addr-lock*))

#+static-hons
(defabbrev hl-symbol-addr (s)

; (HL-SYMBOL-ADDR S) --> NAT
;
; S must be a symbol other than T or NIL.  If it already has an address, we
; look it up and return it.  Otherwise, we must allocate an address for S and
; return it.
;
; We store the addresses of symbols on the symbol's propertly list.  This could
; cause problems in multi-threaded code if two threads were simultaneously
; trying to generate a 'hl-static-address entry for the same symbol.  In
; particular, each thread would generate its own static cons and try to use its
; index; the first thread, whose hash key would be overwritten by the second,
; would then be using the wrong address for the symbol.
;
; We could address this by using OTHER-HT instead of property lists, but
; property lists seem to be really fast, and our feeling is that we will really
; not be creating new addresses for symbols very often.  So, it's probably
; better to pay the price of locking in this very limited case.
;
; Notes about Ctrl+C Safety.  This function does not need to be protected by
; without-interrupts because installing the new 'hl-static-address cons is a
; single setf.

  (let ((addr-cons (get (the symbol s) 'hl-static-address)))
    (if addr-cons
        ;; Already have an address.  ADDR-CONS = (S . TRUE-ADDR), where
        ;; TRUE-ADDR is Index(ADDR-CONS) + BASE.  So, we just need to
        ;; return the TRUE-ADDR.
        (cdr addr-cons)
      ;; We need to assign an address.  Must lock!
      (ccl::with-lock-grabbed
       (*hl-symbol-addr-lock*)
       ;; Some other thread might have assigned S an address before we
       ;; got the lock.  So, double-check and make sure that there still
       ;; isn't an address.
       (setq addr-cons (get (the symbol s) 'hl-static-address))
       (if addr-cons
           (cdr addr-cons)
         ;; Okay, safe to generate a new address.
         (let* ((new-addr-cons (ccl::static-cons s nil))
                (true-addr     (+ hl-dynamic-base-addr
                                  (ccl::%staticp new-addr-cons))))
           (rplacd (the cons new-addr-cons) true-addr)
           (setf (get (the symbol s) 'hl-static-address) new-addr-cons)
           true-addr))))))

#+static-hons
(defun hl-addr-of-unusual-atom (x str-ht other-ht)

; See hl-addr-of.  This function computes the address of any atom except for T
; and NIL.  Wrapping this in a function is mainly intended to avoid code blowup
; from inlining.

  (cond ((symbolp x)
         (hl-symbol-addr x))

        ((and (typep x 'fixnum)
              (<= hl-minimum-static-int (the fixnum x))
              (<= (the fixnum x) hl-maximum-static-int))
         (the fixnum
           (+ hl-static-int-shift (the fixnum x))))

        ((typep x 'array) ; <-- (stringp x), but twice as fast in CCL.
         ;; Since we assume X is normed, its entry in the STR-HT exists and has
         ;; the form XC = (NX . TRUE-ADDR), so we just need to return the
         ;; TRUE-ADDR.
         (cdr (gethash x str-ht)))

        ((characterp x)
         (char-code x))

        (t
         ;; Addresses for any other objects are stored in the OTHER-HT.  But
         ;; these objects do not necessarily have their addresses generated
         ;; yet.
         (let* ((entry (gethash x other-ht)))
           (if entry
               ;; ENTRY is a static cons that has the form (x . TRUE-ADDR)
               ;; where TRUE-ADDR is Index(ENTRY) + BASE.  So, we just need to
               ;; return the TRUE-ADDR.
               (cdr entry)
             ;; Else, we need to create an entry.
             (let* ((new-addr-cons (ccl::static-cons x nil))
                    (true-addr     (+ hl-dynamic-base-addr
                                      (ccl::%staticp new-addr-cons))))
               (rplacd (the cons new-addr-cons) true-addr)
               (setf (gethash x other-ht) new-addr-cons)
               true-addr))))))

#+static-hons
(defmacro hl-addr-of (x str-ht other-ht)

; (HL-ADDR-OF X STR-HT OTHER-HT) --> NAT and destructively updates OTHER-HT
;
; X is any normed ACL2 Object, and STR-HT and OTHER-HT are the corresponding
; fields of a Hons Space.  We determine and return the address of X.  This may
; require us to assign an address to X, which may require us to update the Hons
; Space.
;
; Ctrl+C Safety: this function need not be protected by without-interrupts.
; Even though it may modify the hons space, all invariants are preserved by the
; update; the only change is that OTHER-HT may be extended with a new entry,
; but the new entry is already valid by the time it is installed.

  `(let ((x ,x))
     (cond ((consp x)
            (+ hl-dynamic-base-addr (ccl::%staticp x)))
           ((eq x nil) 256)
           ((eq x t)   257)
           (t
            (hl-addr-of-unusual-atom x ,str-ht ,other-ht)))))

#+static-hons
(defun hl-nat-combine* (a b)
  ;; See books/system/hl-addr-combine.lisp for all documentation and a proof
  ;; that this function is one-to-one.  At one point, this was going to be an
  ;; inlined version of hl-nat-combine.  We later decided not to inline it,
  ;; since it's a rare case and slow anyway, to avoid excessive expansion in
  ;; hl-addr-combine*.
  (+ (let* ((a+b   (+ a b))
            (a+b+1 (+ 1 a+b)))
       (if (= (logand a+b 1) 0)
           (* (ash a+b -1) a+b+1)
         (* a+b (ash a+b+1 -1))))
     b))

#+static-hons
(defabbrev hl-addr-combine* (a b)
  ;; Inlined version of hl-addr-combine.  See books/system/hl-addr-combine.lisp
  ;; for all documentation and a proof that this function is one-to-one.  The
  ;; only change we make here is to use typep to see if the arguments are fixnums
  ;; in the comparisons, which speeds up our test loop by about 1/3.
  (if (and (typep a 'fixnum)
           (typep b 'fixnum)
           (< (the fixnum a) 1073741824)
           (< (the fixnum b) 1073741824))
      ;; Optimized version of the small case
      (the (signed-byte 61)
        (- (the (signed-byte 61)
             (logior (the (signed-byte 61)
                       (ash (the (signed-byte 31) a) 30))
                     (the (signed-byte 31) b)))))
    ;; Large case.
    (- (hl-nat-combine* a b)
       576460752840294399)))


; ----------------------------------------------------------------------
;
;                          HONS CONSTRUCTION
;
; ----------------------------------------------------------------------

#+static-hons
(defun hl-hspace-grow-sbits (idx hs)

; (HL-HSPACE-GROW-SBITS IDX HS) destructively updates HS
;
; Static Honsing only.  IDX must be a natural number and HS must be a Hons
; Space.  We generally expect this function to be called when SBITS has become
; too short to handle IDX, the ccl::%staticp index of some static cons.  We
; copy SBITS into a new, larger array and install it into the Hons Space.
;
; Growing SBITS is slow because we need to (1) allocate a new, bigger array,
; and (2) copy the old contents of SBITS into this new array.  Accordingly, we
; want to add enough indices so that we can accommodate IDX and also any
; additional static conses that are generated in the near future without having
; to grow again.  But at the same time, we don't want to consume excessive
; amounts of memory by needlessly growing SBITS beyond what will be needed.  We
; try to balance these factors by increasing our capacity by 30% per growth.
;
;    BOZO -- consider different growth factors?
;
; Ctrl+C Safety.  This is locally ctrl+c safe assuming (setf (hl-hspace-bits
; hs) ...) is, because we only install the new array into the HS at the very
; end, and the new array is already valid by that time.  But if we change this
; to use some kind of array resizing, we might need to add without-interrupts.

  (declare (type hl-hspace hs))
  (let* ((sbits     (hl-hspace-sbits hs))
         (curr-len  (length sbits))
         (want-len  (floor (* 1.3 (max curr-len idx))))
         (new-len   (min (1- array-total-size-limit) want-len)))
    (when (<= new-len curr-len)
      (error "Unable to grow static hons bit array."))
    ;; CHANGE -- added a growth message
    (time$ (let ((new-sbits (make-array new-len
                                        :element-type 'bit
                                        :initial-element 0)))
             (declare (type (simple-array bit (*)) new-sbits))
             (loop for i fixnum below curr-len do
                   (setf (aref new-sbits i) (aref sbits i)))
             (setf (hl-hspace-sbits hs) new-sbits))
           :msg "; Hons Note: grew SBITS to ~x0; ~st seconds, ~sa bytes.~%"
           :args (list new-len))))

(defun hl-hspace-norm-atom (x hs)

; (HL-HSPACE-NORM-ATOM X HS) --> X' and destructively updates HS.
;
; X is any ACL2 Atom and HS is a Hons Space.  We produce a normed version of X,
; extending the Hons Space if necessary.
;
; Ctrl+C Safety.  This function does not need to be protected with
; without-interrupts; even though it extends the STR-HT, the invariants on a
; Hons Space still hold after the update.

  (cond
   ((typep x 'array) ; <-- (stringp x)
    (let* ((str-ht (hl-hspace-str-ht hs))
           (entry  (gethash x str-ht)))

      #-static-hons
      ;; In classic honsing, STR-HT just associates strings to their normed
      ;; versions.  We make X the normed version of itself.
      (or entry
          (setf (gethash x str-ht) x))

      #+static-hons
      ;; In static honsing, STR-HT associates X with XC = (NX . TRUE-ADDR),
      ;; where NX is the normed version of X and TRUE-ADDR = Index(XC) + Base.
      (if entry
          (car entry)
        (let* ((new-addr-cons (ccl::static-cons x nil))
               (true-addr     (+ hl-dynamic-base-addr
                                 (ccl::%staticp new-addr-cons))))
          (rplacd (the cons new-addr-cons) true-addr)
          (setf (gethash x str-ht) new-addr-cons)
          x))))

   (t
    ;; All other atoms are already normed.
    x)))

(defun hl-hspace-hons-normed (a b hint hs)

; (HL-HSPACE-HONS-NORMED A B HINT HS) --> (A . B) and destructively updates HS.
;
; A and B may be any normed ACL2 objects and HS is a hons space.  HINT is
; either NIL, meaning no hint, or is a cons.
;
; HINT might have nothing to do with anything.  But if HINT happens to be a
; cons of the form (A . B), by which we mean its car is literally EQ to A and
; its cdr is literally EQ to B, then we might decide to make HINT become the
; normed version of (A . B).  The whole notion of a hint is mainly useful when
; we are re-norming previously normed objects, and might allow us to sometimes
; avoid constructing new conses when a suitable cons already exists.
;
; We produce a normed CONS that is equal to (A . B), possibly extending HS.
; This is the fundamental operation for what used to be called 'hopying' or
; 'hons copying,' and which is now referred to as 'norming' ACL2 objects.
;
; Ctrl+C Safety.  This function makes minimal use of without-interrupts to
; ensure its safety, and need not be protected by the caller.

  #+static-hons
  ;; Static Honsing Version
  (let* ((str-ht   (hl-hspace-str-ht hs))
         (other-ht (hl-hspace-other-ht hs))
         (addr-ht  (hl-hspace-addr-ht hs))
         (addr-a   (hl-addr-of a str-ht other-ht))
         (addr-b   (hl-addr-of b str-ht other-ht))
         (key      (hl-addr-combine* addr-a addr-b))
         (entry    (gethash key addr-ht)))
    (or entry
        (let* ((hint-idx (and (consp hint)
                              (eq (car hint) a)
                              (eq (cdr hint) b)
                              (ccl::%staticp hint)))
               (pair     (if hint-idx
                             ;; Safe to use hint.
                             hint
                           (ccl::static-cons a b)))
               (idx      (or hint-idx (ccl::%staticp pair)))
               (sbits    (hl-hspace-sbits hs)))
          ;; Make sure there are enough sbits.  Ctrl+C Safe.
          (when (>= (the fixnum idx)
                    (the fixnum (length sbits)))
            (hl-hspace-grow-sbits idx hs)
            (setq sbits (hl-hspace-sbits hs)))
          (ccl::without-interrupts
           ;; Since we must simultaneously update SBITS and ADDR-HT, the
           ;; installation of PAIR must be protected by without-interrupts.
           (setf (aref sbits idx) 1)
           (setf (gethash key addr-ht) pair))
          pair)))

  #-static-hons
  ;; Classic Honsing Version
  (let ((ctables (hl-hspace-ctables hs)))
    (if (eq b nil)
        (let* ((nil-ht (hl-ctables-nil-ht ctables))
               (entry  (gethash a nil-ht)))
          (or entry
              (let ((new-cons (if (and (consp hint)
                                       (eq (car hint) a)
                                       (eq (cdr hint) b))
                                  hint
                                (cons a b))))
                ;; Ctrl+C Safe since it's only a single setf.
                (setf (gethash a nil-ht) new-cons))))

      (let* ((main-table (if (or (consp b)
                                 (symbolp b)
                                 (typep b 'array)) ;; (stringp b)
                             (hl-ctables-cdr-ht ctables)
                           (hl-ctables-cdr-ht-eql ctables)))
             (flex-alist (gethash b main-table))
             (entry      (hl-flex-assoc a flex-alist)))
        (or entry
            (let* ((was-alistp     (listp flex-alist))
                   (new-cons       (if (and (consp hint)
                                            (eq (car hint) a)
                                            (eq (cdr hint) b))
                                       hint
                                     (cons a b)))
                   (new-flex-alist (hl-flex-acons new-cons flex-alist)))
              ;; Ctrl+C Safety is subtle here.  If was-alistp, then the above
              ;; flex-acons was applicative and didn't alter the Hons Space.
              ;; We'll go ahead and install the new flex alist, but this
              ;; installation occurs as an single update to the Hons Space.
              (when was-alistp
                (setf (gethash b main-table) new-flex-alist))
              ;; Otherwise, the flex-acons was non-applicative, and the Hons
              ;; Space has already been safely extended, so everything's ok.
              new-cons))))))


; ESSAY ON HL-HSPACE-NORM
;
; (HL-HSPACE-NORM X HS) --> X' and destructively updates HS.
;
; X is any ACL2 Object and might be normed or not; HS is a Hons Space.  We
; return an object that is EQUAL to X and is normed.  This may require us to
; destructively extend HS.
;
; This function is non-destructive with respect to X.  Because of this, we
; sometimes need to recons portions of X.  Why?
;
;   One reason is that in static honsing we may only regard static conses as
;   normed, so if X includes non-static conses we will need to produce static
;   versions of them.
;
;   Another scenario is as follows.  Suppose X is (A . B), where B is normed
;   but A is not normed, and further suppose that there exists some normed A'
;   which is EQUAL to A, but no normed X' that is equal to X.  Here, we cannot
;   simply extend HS to regard X as normed, because this would violate our
;   invariant that the car of any normed cons is also normed.  Instead, we must
;   construct a new cons whose car is A' and whose cdr is B, and then use this
;   new cons as X'.
;
; We memoize the norming process to some degree.  The NORM-CACHE field of the
; Hons Space is a Cache Table (see above) that associates some recently
; encountered conses with their normed versions.
;
; Historically, we used a hash table instead.  A basic problem with this was,
; when should the table be created?  We surely do not want to have to create a
; new hash table every time hons-copy is called -- after all, it's called twice
; in every call of hons!  On the other, we don't want to use a global hash
; table that never gets cleaned out, because such a table could grow very large
; over time.  Our first solution was to split norming into two functions.  An
; auxilliary function did all the work, and freely used a hash table without
; regard to how large it might grow.  Meanwhile, a top-level wrapper function
; examined the hash table after the auxillary function was finished, and if the
; table had been resized, we threw it away and started over.
;
; Using a global Cache Table nicely solves this problem.  The Cache Table keeps
; a fixed size and automatically forgets elements.

(defun hl-hspace-norm-aux (x cache hs)

; (HL-HSPACE-NORM-AUX X CACHE HS) --> X', destructively modifies CACHE and HS.
;
; X is an ACL2 Object to copy.  CACHE is the cache table from HS, and HS is the
; Hons Space we are updating.  We return the normed version of X.

  (declare (type hl-cache cache)
           (type hl-hspace hs))
  (cond ((atom x)
         (hl-hspace-norm-atom x hs))
        ((hl-hspace-honsp x hs)
         x)
        (t
         (mv-let (present-p val)
                 (hl-cache-get x cache)
           (if present-p
               val
             (let* ((a       (hl-hspace-norm-aux (car x) cache hs))
                    (d       (hl-hspace-norm-aux (cdr x) cache hs))
                    (x-prime (hl-hspace-hons-normed a d x hs)))
               (hl-cache-set x x-prime cache)
               x-prime))))))

(defun hl-hspace-norm-expensive (x hs)
  ;; X is assumed to be not an atom and not a honsp.  We put this in a separate
  ;; function, mainly so that hl-hspace-norm can be inlined without resulting
  ;; in too much code expansion.
  (let ((cache (hl-hspace-norm-cache hs)))
    (mv-let (present-p val)
            (hl-cache-get x cache)
            (if present-p
                val
              (hl-hspace-norm-aux x cache hs)))))

(defabbrev hl-hspace-norm (x hs)
  ;; See the essay on HL-HSPACE-NORM.
  (cond ((atom x)
         (hl-hspace-norm-atom x hs))
        ((hl-hspace-honsp x hs)
         x)
        (t
         (hl-hspace-norm-expensive x hs))))

(defun hl-hspace-persistent-norm (x hs)

; (HL-HSPACE-PERSISTENT-NORM X HS) --> X' and destructively updates HS.
;
; X is any ACL2 object and HS is a Hons Space.  We produce a new object that is
; EQUAL to X and is normed, which may require us to destructively modify HS.
;
; This function is essentially like hl-hspace-norm, except that when X is a
; cons, we also bind X' to T in the PERSIST-HT field of the Hons Space.  This
; ensures that X' will be restored in hl-hspace-hons-clear, and also that it
; cannot be garbage collected during hl-hspace-hons-wash.
;
;    INVARIANT P1: Every key in PERSIST-HT is a normed cons.
;
; Ctrl+C Safety.  An interrupt might cause X' to not be added to PERSIST-HT,
; but that's fine and doesn't violate any invariants of the hons space.

  (let ((x (hl-hspace-norm x hs)))
    (when (consp x)
      (let ((persist-ht (hl-hspace-persist-ht hs)))
        (setf (gethash x persist-ht) t)))
    x))

(defabbrev hl-hspace-hons (x y hs)

; (HL-HSPACE-HONS X Y HS) --> (X . Y) which is normed, and destructively
; updates HS.
;
; X and Y may be any ACL2 Objects, whether normed or not, and HS must be a Hons
; Space.  We produce a new cons, (X . Y), destructively extend HS so that it is
; considered normed, and return it.

  (declare (type hl-hspace hs))
  (hl-hspace-hons-normed (hl-hspace-norm x hs)
                         (hl-hspace-norm y hs)
                         nil hs))


; ----------------------------------------------------------------------
;
;                             FAST ALISTS
;
; ----------------------------------------------------------------------

; ESSAY ON FAST ALISTS
;
; Prerequisite: see :doc fast-alists for a user-level overview of fast alists,
; which for instance introduces the crucial notion of discipline.
;
; The implementation of fast alists is actually fairly simple.  Each Hons Space
; includes a EQ hash table named FAL-HT that associates each "fast alist" with
; an EQL hash table, called its "backing" hash table.
;
; INVARIANTS.  For every "fast alist" AL that is bound in FAL-HT,
;
;    1. AL is non-empty, i.e., atoms are never bound in FAL-HT.
;
;    2. AL consists entirely of conses (i.e., there are no "malformed" entries
;       in the alist).  We think of each entry as a (KEY . VALUE) pair.
;
;    3. Every KEY is normed.  This justifies our use of EQL-based backing hash
;       tables.
;
;    4. The backing hash table, HT, must "agree with" AL.  In particular, for
;       all ACL2 Objects, X, the following relation must be satisfied:
;
;        (equal (hons-assoc-equal X AL)
;               (gethash (hons-copy X) HT))
;
;       In other words, for every (KEY . VALUE) pair in AL, HT must associate
;       KEY to (KEY . VALUE).  Meanwhile, if KEY is not bound in AL, then it
;       must not be bound in HT.

(defun hl-slow-alist-warning (name)
  ;; Name is the name of the function wherein we noticed a problem.
  (let ((action (get-slow-alist-action *the-live-state*)))
    (when action
      (format *error-output* "
*****************************************************************
Fast alist discipline violated in ~a.
See the documentation for fast alists for how to fix the problem,
or suppress this warning message with~%  ~a~%
****************************************************************~%"
              name
              '(set-slow-alist-action nil))
      (when (eq action :break)
        (format *error-output* "
To avoid the following break and get only the above warning:~%  ~a~%"
                '(set-slow-alist-action :warning))
        (break$)))))



; ESSAY ON CTRL+C SAFETY FOR FAST ALISTS
;
; Ctrl+C safety is really difficult for fast alists.  The function
; hl-hons-acons, introduced immediately below, provides the simplest example of
; the problem.  You might think that the PROGN in this function should be a
; without-interrupts instead.  After all, an ill-timed interrupt by the user
; could cause us to remove the old hash table from FAL-HT without installing
; the new hash table, potentially leading to discipline failures even in
; otherwise perfectly disciplined user-level code.
;
; But the problem runs deeper than this.  Even if we used without-interrupts,
; it wouldn't be enough.  After all, an equally bad scenario is that we
; successfully install the new table into FAL-HT, but then are interrupted
; before ANS can be returned to the user's code.  It hardly matters that the
; hash table has been properly installed if they don't have the new handle to
; it.
;
; There really isn't any way for us, in the implementation of fast alists, to
; prevent interrupts from violating single-threaded discipline.  Consider for
; instance a sequence such as:
;
;   (defconst *foo* (make-fast-alist ...))
;   (defconst *bar* (do-something (hons-acons 0 t *foo*)))
;
; Here, if the user interrupts do-something at any time after the inner
; hons-acons has been executed, then the hash table for *foo* has already been
; extended and there's no practical way to maintain discipline.
;
; Because of this, we abandon the goal of trying to maintain discipline across
; interrupts, and set upon a much easier goal of ensuring that whatever hash
; tables happen to be in the FAL-HT are indeed accurate reflections of the
; alists that are bound to them.  This weaker criteria means that the progn
; below is adequate.

(defun hl-hspace-hons-acons (key value alist honsp hs)

; (HL-HSPACE-HONS-ACONS KEY VALUE ALIST HONSP HS) --> ALIST' and destructively
; modifies HS.
;
;  - KEY and VALUE are any ACL2 Objects, whether normed or not.
;
;  - ALIST is an ordinary ACL2 Object; for good discipline ALIST must have a
;    hash table supporting it in the FAL-HT.
;
;  - HONSP is a flag that is T if ALIST should be extended with honses, or NIL
;    if it should be extended with conses.
;
;  - HS is the Hons Space whose FAL-HT and other fields may be destructively
;    updated.
;
; When ALIST is a natural number, we interpret it as a size hint that says how
; large the new hash table should be, but we impose a minimum of 60 elements.
; We always begin by honsing the key, which justifies our use of EQL hash
; tables.

  (declare (type hl-hspace hs))
  (let* (;; The key must always normed regardless of honsp.
         (key    (hl-hspace-norm key hs))
         (entry  (if honsp
                     (hl-hspace-hons key value hs)
                   (cons key value)))
         (ans    (if honsp
                     (hl-hspace-hons entry alist hs)
                   (cons entry alist)))
         (fal-ht (hl-hspace-fal-ht hs)))

    (if (atom alist)
        ;; New fast alist.  Try to use the size hint if one was provided.
        (let* ((size (if (and (typep alist 'fixnum)
                              (<= 60 (the fixnum alist)))
                         alist
                       60))
               (tab (hl-mht :size size)))
          (setf (gethash key (the hash-table tab)) entry)
          (setf (gethash ans (the hash-table fal-ht)) tab))

      (let ((tab (gethash alist (the hash-table fal-ht))))
        (if (not tab)
            ;; Discipline failure, no valid backing alist.
            (hl-slow-alist-warning 'hl-hspace-hons-acons)
          (progn
            ;; Doing the remhash before changing TAB is crucial to ensure that
            ;; all hash tables in the FAL-HT are valid.
            (remhash alist (the hash-table fal-ht))
            (setf (gethash key (the hash-table tab)) entry)
            (setf (gethash ans (the hash-table fal-ht)) tab)))))

    ans))


; (HL-HSPACE-SHRINK-ALIST ALIST ANS HONSP HS) --> ANS' and destructively
; modifies HS.
;
; ALIST is either a fast or slow alist, and ANS should be a fast alist.  HONSP
; says whether our extension of ANS' should be made with honses or conses.  HS
; is a Hons Space and will be destructively modified.

(defun hl-shrink-alist-aux-really-slow (alist ans honsp hs)
  ;; This is our function of last resort and we only call it if discipline has
  ;; failed.  We don't try to produce a fast alist, because there may not even
  ;; be a valid way to produce one that corresponds to the logical definition
  ;; and satisfies the FAL-HT invariants.
  (cond ((atom alist)
         ans)
        ((atom (car alist))
         (hl-shrink-alist-aux-really-slow (cdr alist) ans honsp hs))
        (t
         (let* ((key   (hl-hspace-norm (caar alist) hs))
                (entry (hons-assoc-equal key ans)))
           (unless entry
             (if honsp
                 (progn
                   (setq entry (hl-hspace-hons key (cdar alist) hs))
                   (setq ans   (hl-hspace-hons entry ans hs)))
               (progn
                 (setq entry (cons key (cdar alist)))
                 (setq ans   (cons entry ans)))))
           (hl-shrink-alist-aux-really-slow (cdr alist) ans honsp hs)))))

(defun hl-shrink-alist-aux-slow (alist ans table honsp hs)
  ;; This is somewhat slower than the -fast version, because we don't assume
  ;; ALIST is well-formed or has normed keys.  This is the function we'll use
  ;; when shrinking an ordinary alist with an existing fast alist or with an
  ;; atom as the ANS.
  (declare (type hl-hspace hs)
           (type hash-table table))
  (cond ((atom alist)
         ans)
        ((atom (car alist))
         (hl-shrink-alist-aux-slow (cdr alist) ans table honsp hs))
        (t
         (let* ((key   (hl-hspace-norm (caar alist) hs))
                (entry (gethash key table)))
           (unless entry
             (if honsp
                 (progn
                  (setq entry (hl-hspace-hons key (cdar alist) hs))
                  (setq ans   (hl-hspace-hons entry ans hs))
                  (setf (gethash key table) entry))
               (progn
                 ;; We recons the entry so the resulting alist has normed keys.
                 (setq entry (cons key (cdar alist)))
                 (setq ans   (cons entry ans))
                 (setf (gethash key table) entry))))
           (hl-shrink-alist-aux-slow (cdr alist) ans table honsp hs)))))

(defun hl-shrink-alist-aux-fast (alist ans table honsp hs)
  ;; This is faster than the -slow version because we assume ALIST is
  ;; well-formed and has normed keys.  This is the function we use to merge two
  ;; fast alists.
  (declare (type hl-hspace hs)
           (type hash-table table))
  (if (atom alist)
      ans
    (let* ((key   (caar alist))
           (entry (gethash key table)))
      (unless entry
        (if honsp
            (progn
              (setq entry (hl-hspace-hons key (cdar alist) hs))
              (setq ans   (hl-hspace-hons entry ans hs))
              (setf (gethash key table) entry))
            (progn
             (setq entry (car alist))
             (setq ans   (cons entry ans))
             (setf (gethash key table) entry))))
      (hl-shrink-alist-aux-fast (cdr alist) ans table honsp hs))))


; If ANS is an atom, we are going to create a new hash table for the result.
; What size should we use?  If ALIST is a fast alist, we can see how large its
; table is and use the same size.  Otherwise, if ALIST is an ordinary alist,
; it's more difficult to estimate how large the table ought to be; we guess
; a hashtable size that is the maximum of 60 and 1/8 the length of ALIST.

(defun hl-hspace-shrink-alist (alist ans honsp hs)
  (declare (type hl-hspace hs))
  (if (atom alist)
      ans
    (let* ((fal-ht      (hl-hspace-fal-ht hs))
           (alist-table (gethash alist (the hash-table fal-ht)))
           (ans-table   (gethash ans (the hash-table fal-ht))))
      (if ans-table
          ;; We're going to steal the ans-table, so disassociate ANS.
          (remhash ans (the hash-table fal-ht))
        (setq ans-table
              (and (atom ans)
                   ;; Make a new hash table for ANS, with our size guess.
                   (hl-mht :size (cond ((natp ans)
                                        (max 60 ans))
                                       (alist-table
                                        ;; CHANGE -- this used to be based on
                                        ;; hash-table-count
                                        (hash-table-size
                                         (the hash-table alist-table)))
                                       (t
                                        (max 60
                                             (ash (len alist) -3))))))))

      (if ans-table
          ;; Good discipline.  Shove ALIST into ANS-TABLE.  If ALIST is fast,
          ;; then by the FAL-HT invariants we know it is a proper cons list and
          ;; already has normed keys, so we can use the fast version.  Else, we
          ;; can't make these assumptions, and have to use the slow one.
          (let ((ans (if alist-table
                         (hl-shrink-alist-aux-fast alist ans ans-table honsp hs)
                       (hl-shrink-alist-aux-slow alist ans ans-table honsp hs))))
            (unless (atom ans)
              ;; Tricky subtle thing.  If ALIST was a list of atoms, and ANS is
              ;; an atom, then what we arrive at is still an atom.  We don't
              ;; want any atoms bound in the fal-ht, so don't bind it.
              (setf (gethash ans (the hash-table fal-ht)) ans-table))
            ans)

        ;; Bad discipline.  ANS is not an atom or fast alist.
        (progn
          (hl-slow-alist-warning 'hl-hspace-shrink-alist)
          (hl-shrink-alist-aux-really-slow alist ans honsp hs))))))

(defun hl-hspace-hons-get (key alist hs)
  (declare (type hl-hspace hs))
  (if (atom alist)
      nil
    (let* ((fal-ht (hl-hspace-fal-ht hs))
           (tab    (gethash alist (the hash-table fal-ht))))
      (if (not tab)
          (progn
            (hl-slow-alist-warning 'hl-hspace-hons-get)
            (hons-assoc-equal key alist))
        (let* ((key   (hl-hspace-norm key hs))
               (entry (gethash key (the hash-table tab))))
          ;; Entry is already NIL or the desired cons.
          entry)))))

(defun hl-hspace-fast-alist-free (alist hs)
  (declare (type hl-hspace hs))
  (unless (atom alist)
    (remhash alist (hl-hspace-fal-ht hs)))
  alist)

(defun hl-hspace-fast-alist-len (alist hs)
  (declare (type hl-hspace hs))
  (if (atom alist)
      0
    (let* ((fal-ht (hl-hspace-fal-ht hs))
           (tab    (gethash alist (the hash-table fal-ht))))
      (if (not tab)
          (progn
            (hl-slow-alist-warning 'hl-hspace-fast-alist-len)
            (let* ((fast-alist (hl-hspace-shrink-alist alist nil nil hs))
                   (result     (hl-hspace-fast-alist-len fast-alist hs)))
              (hl-hspace-fast-alist-free fast-alist hs)
              result))
        (hash-table-count tab)))))


; CHANGE -- increased size of number-subtrees-ht to start at 10,000.  BOZO
; think about making this higher, or using a more aggressive rehashing size?

(defun hl-hspace-number-subtrees-aux (x seen)
  (declare (type hash-table seen))
  (cond ((atom x)
         nil)
        ((gethash x seen)
         nil)
        (t
         (progn
           (setf (gethash x seen) t)
           (hl-hspace-number-subtrees-aux (car x) seen)
           (hl-hspace-number-subtrees-aux (cdr x) seen)))))

(defun hl-hspace-number-subtrees (x hs)
  (declare (type hl-hspace hs))
  (let ((x    (hl-hspace-norm x hs))
        (seen (hl-mht :test 'eq :size 10000)))
    (hl-hspace-number-subtrees-aux x seen)
    (hash-table-count seen)))



; ----------------------------------------------------------------------
;
;                          GARBAGE COLLECTION
;
; ----------------------------------------------------------------------

(defun hl-system-gc ()
  ;; Note that ccl::gc only schedules a GC to happen.  So, we need to both
  ;; trigger one and wait for it to occur.
  #+Clozure
  (let ((current-gcs (ccl::full-gccount)))
    (ccl::gc)
    (loop do
          (progn
            (when (> (ccl::full-gccount) current-gcs)
              (loop-finish))
            (format t "; Hons Note: Waiting for GC to finish.~%")
            (finish-output)
            (sleep 1))))
  #-Clozure
  (gc$))


#-static-hons
(defun hl-hspace-classic-restore (x nil-ht cdr-ht cdr-ht-eql seen-ht)

; Returns X and destructively updates the other arguments.
;
; Classic honsing only.  This function is used to restore any persistent honses
; after clearing them.
;
; X is an ACL2 Object that we need to recursively reinstall.  We assume that X
; was previously normed, so it never contains non-EQL versions of any objects.
; We also assume that all of the strings in X are still normed.
;
; SEEN-HT is a hash table that says which conses we have already reinstalled.
;
; The other arguments are the correspondingly named fields in the hons space,
; which we assume are detatched from any hons space.  Because of this, we do
; not need to worry about interrupts and can freely update the fields in an
; order that violates the usual hons space invariants.

  (declare (type hash-table nil-ht)
           (type hash-table cdr-ht)
           (type hash-table cdr-ht-eql)
           (type hash-table seen-ht))

  (cond ((atom x)
         ;; Nothing to do because we assume all atoms have already been
         ;; installed.
         x)

        ((gethash x seen-ht)
         ;; Nothing to do because we have already reinstalled X.
         x)

        (t
         (let* ((a (hl-hspace-classic-restore (car x) nil-ht cdr-ht
                                              cdr-ht-eql seen-ht))
                (b (hl-hspace-classic-restore (cdr x) nil-ht cdr-ht
                                              cdr-ht-eql seen-ht)))
           (setf (gethash x seen-ht) t) ;; Mark X as seen.
           (if (eq b nil)
               (setf (gethash a nil-ht) x)
             (let* ((main-table (if (or (consp b)
                                        (symbolp b)
                                        (typep b 'array)) ;; (stringp b)
                                    cdr-ht
                                  cdr-ht-eql))
                    (flex-alist     (gethash b main-table))
                    (was-alistp     (listp flex-alist))
                    (new-flex-alist (hl-flex-acons x flex-alist)))
               ;; If was-alistp, then the flex-acons was applicative and we
               ;; have to install the new flex alist.  Otherwise, it's already
               ;; installed.
               (when was-alistp
                 (setf (gethash b main-table) new-flex-alist))
               x))))))

#-static-hons
(defun hl-hspace-hons-clear (gc hs)
  (declare (type hl-hspace hs))
  (let* ((ctables         (hl-hspace-ctables hs))
         (nil-ht          (hl-ctables-nil-ht ctables))
         (cdr-ht          (hl-ctables-cdr-ht ctables))
         (cdr-ht-eql      (hl-ctables-cdr-ht-eql ctables))
         (fal-ht          (hl-hspace-fal-ht hs))
         (persist-ht      (hl-hspace-persist-ht hs))
         (norm-cache      (hl-hspace-norm-cache hs))
         (temp-nil-ht     (hl-mht :test #'eql))
         (temp-cdr-ht     (hl-mht :test #'eq))
         (temp-cdr-ht-eql (hl-mht :test #'eql))
         (temp-ctables    (make-hl-ctables :nil-ht temp-nil-ht
                                           :cdr-ht temp-cdr-ht
                                           :cdr-ht-eql temp-cdr-ht-eql))
         (temp-fal-ht     (hl-mht :test #'eq))
         (temp-persist-ht (hl-mht :test #'eq))
         (seen-ht         (hl-mht :test #'eq :size 10000)))

    ;; Very subtle.  We're about to violate invariants, so we need to clear out
    ;; the hons space while we work.  Because we aggregated the ctables into a
    ;; single field, we can 'uninstall' the NIL-HT, CDR-HT, and CDR-HT-EQL all
    ;; together with a single setf.  This gives us Ctrl+C safety and means all
    ;; our invariants are preserved.

    ;; Order here is important.  We cannot clear ctables before norm-memo-ht,
    ;; because then we'd have stale allegedly-normed conses in the memo table.
    ;; Similarly we need to clear the fal-ht and persist-ht before the ctables,
    ;; or an interrupt might leave us with stale allegedly normed conses in
    ;; those tables.
    (hl-cache-clear norm-cache)
    (setf (hl-hspace-fal-ht hs) temp-fal-ht)
    (setf (hl-hspace-persist-ht hs) temp-persist-ht)
    (setf (hl-hspace-ctables hs) temp-ctables)

    (format t "; Hons Note: clearing normed objects.~%")

    (clrhash nil-ht)
    (clrhash cdr-ht)
    (clrhash cdr-ht-eql)

    (when gc
      (hl-system-gc))

    (format t "; Hons Note: re-norming persistently normed objects.~%")

    (maphash (lambda (key val)
               (declare (ignore val))
               (hl-hspace-classic-restore key nil-ht cdr-ht cdr-ht-eql seen-ht))
             persist-ht)

    (format t "; Hons Note: re-norming fast alist keys.~%")

    ;; BOZO we probably want to loop over the alist, rather than the associated
    ;; hash table, to avoid the maphash overhead
    (maphash (lambda (alist associated-hash-table)
               (declare (ignore alist))
               (maphash (lambda (key val)
                          (declare (ignore val))
                          (hl-hspace-classic-restore key nil-ht cdr-ht
                                                     cdr-ht-eql seen-ht))
                        associated-hash-table))
             fal-ht)

    (format t "; Hons Note: finished re-norming ~a conses.~%"
            (hash-table-count seen-ht))

    ;; Again order is critical.  Ctables must be installed before fal-ht or
    ;; persist-ht, since parts of fal-ht and persist-ht are expected to be
    ;; normed.
    (setf (hl-hspace-ctables hs) ctables)
    (setf (hl-hspace-fal-ht hs) fal-ht)
    (setf (hl-hspace-persist-ht hs) persist-ht))

  nil)


#+static-hons
(defun hl-hspace-static-restore (x addr-ht sbits str-ht other-ht)

; Returns X and destructively modifies ADDR-HT and SBITS.
;
; Static honsing only.  This function is used to restore any persistent honses
; after clearing them.
;
; X is an ACL2 Object that we need to recursively reinstall.  We assume that X
; was previously normed (so it never contains non-EQL versions of any objects.)
; We assume that all of the atoms in X are still normed and have addresses.
;
; The other fields are the corresponding fields from a Hons Space, but we
; assume they are detatched from any Hons Space and do not need to be updated
; in a manner that maintains their invariants in the face of interrupts.

  (declare (type hash-table addr-ht)
           (type (simple-array bit (*)) sbits))
  (if (atom x)
      ;; Nothing to do because we assume all atoms have already been
      ;; installed.
      x
    (let ((index (ccl::%staticp x)))
      (if (= (aref sbits index) 1)
          ;; Nothing to do; we've already reinstalled X.
          x
        (let* ((a (hl-hspace-static-restore (car x) addr-ht sbits
                                            str-ht other-ht))
               (b (hl-hspace-static-restore (cdr x) addr-ht sbits
                                            str-ht other-ht))
               (addr-a (hl-addr-of a str-ht other-ht))
               (addr-b (hl-addr-of b str-ht other-ht))
               (key    (hl-addr-combine* addr-a addr-b)))
          (setf (aref sbits index) 1)
          (setf (gethash key addr-ht) x)
          x)))))

#+static-hons
(defun hl-hspace-hons-clear (gc hs)
  (declare (type hl-hspace hs))
  (let* ((addr-ht         (hl-hspace-addr-ht hs))
         (sbits           (hl-hspace-sbits hs))
         (sbits-len       (length sbits))
         (fal-ht          (hl-hspace-fal-ht hs))
         (persist-ht      (hl-hspace-persist-ht hs))
         (str-ht          (hl-hspace-str-ht hs))
         (other-ht        (hl-hspace-other-ht hs))
         (norm-cache      (hl-hspace-norm-cache hs))
         (temp-fal-ht     (hl-mht :test #'eq))
         (temp-persist-ht (hl-mht :test #'eq))
         (temp-addr-ht    (hl-mht :test #'eql))
         (temp-sbits      (make-array 1 :element-type 'bit :initial-element 0)))

    ;; Very subtle.  We're about to violate invariants, so we need to clear out
    ;; the hons space while we work.

    ;; See also the classic version; order matters, you can't clear out addr-ht
    ;; and sbits before the other tables.
    (hl-cache-clear norm-cache)
    (setf (hl-hspace-fal-ht hs) temp-fal-ht)
    (setf (hl-hspace-persist-ht hs) temp-persist-ht)
    (ccl::without-interrupts
     (setf (hl-hspace-addr-ht hs) temp-addr-ht)
     (setf (hl-hspace-sbits hs) temp-sbits))

    (format t "; Hons Note: clearing normed objects.~%")

    (clrhash addr-ht)
    (loop for i fixnum below sbits-len do
          (setf (aref sbits i) 0))

    (when gc
      (hl-system-gc))

    (time$ (maphash (lambda (key val)
                      (declare (ignore val))
                      (hl-hspace-static-restore key addr-ht sbits str-ht other-ht))
                    persist-ht)
           :msg "; Hons Note: re-norm persistents: ~st seconds, ~sa bytes.~%")

    ;; BOZO we probably want to loop over the alist, rather than the associated
    ;; hash table, to avoid the maphash overhead
    (time$ (maphash (lambda (alist associated-hash-table)
                      (declare (ignore alist))
                      (maphash (lambda (key val)
                                 (declare (ignore val))
                                 (hl-hspace-static-restore key addr-ht sbits
                                                           str-ht other-ht))
                               associated-hash-table))
                    fal-ht)
           :msg "; Hons Note: re-norm fal keys: ~st seconds, ~sa bytes.~%")

    (format t "; Hons Note: finished re-norming ~:D conses.~%"
            (hash-table-count addr-ht))

    ;; Order matters, reinstall addr-ht and sbits before fal-ht and persist-ht!
    (ccl::without-interrupts
     (setf (hl-hspace-addr-ht hs) addr-ht)
     (setf (hl-hspace-sbits hs) sbits))
    (setf (hl-hspace-fal-ht hs) fal-ht)
    (setf (hl-hspace-persist-ht hs) persist-ht))

  nil)


(defun hl-hspace-hons-wash (hs)

; (HL-HSPACE-HONS-WASH HS) --> NIL and destructively modifies HS
;
; We implement a new scheme for washing honses that takes advantage of
; ccl::%static-inverse-cons.  Given the index of a static cons, such as
; produced by ccl::%staticp, static-inverse-cons produces the corresponding
; static cons.
;
; This function tries to GC normed conses, and ignores the static conses that
; might be garbage collected in the STR-HT and OTHER-HT.  We have considered
; how we might extend this function to also collect these atoms, but have
; concluded it probably isn't worth doing.  Basically, we would need to
; separately record the indexes of the static conses in these tables, which is
; fine but would require us to allocate some memory.

  (declare (type hl-hspace hs))

  #-static-hons
  (declare (ignore hs))
  #-static-hons
  (format t "; Hons Note: washing is not available for classic honsing.~%")

  #+static-hons
  (let* ((str-ht        (hl-hspace-str-ht hs))
         (addr-ht       (hl-hspace-addr-ht hs))
         (sbits         (hl-hspace-sbits hs))
         (other-ht      (hl-hspace-other-ht hs))
         (fal-ht        (hl-hspace-fal-ht hs))
         (persist-ht    (hl-hspace-persist-ht hs))
         (norm-cache    (hl-hspace-norm-cache hs))
         (temp-fal-ht     (hl-mht :test #'eq))
         (temp-addr-ht    (hl-mht :test #'eql))
         (temp-sbits      (make-array 1 :element-type 'bit :initial-element 0))
         (temp-persist-ht (hl-mht :test #'eq)))

    (format t "; Hons Note: Now washing ~:D normed conses.~%"
            (hash-table-count addr-ht))

    ;; Clear the memo table since it might prevent conses from being garbage
    ;; collected and it's unsound to leave it as the sbits/addr-ht are cleared.
    (hl-cache-clear norm-cache)

    ;; We need to remove SBITS, FAL-HT, and ADDR-HT from HS before continuing,
    ;; so that if a user interrupts they merely end up with a mostly empty hons
    ;; space instead of an invalid one.  Note that nothing we're about to do
    ;; invalidates the STR-HT or OTHER-HT, so we leave them alone.

    (setf (hl-hspace-fal-ht hs) temp-fal-ht)
    (setf (hl-hspace-persist-ht hs) temp-persist-ht)
    (ccl::without-interrupts
     ;; These two must be done together or not at all.
     (setf (hl-hspace-addr-ht hs) temp-addr-ht)
     (setf (hl-hspace-sbits hs) temp-sbits))

    ;; At this point, we can do anything we want with FAL-HT, ADDR-HT, and
    ;; SBITS, because they are no longer part of a Hons Space.
    (clrhash addr-ht)
    (hl-system-gc)

    ;; Now we need to restore each surviving object.
    (let ((max-index (length sbits)))
      (declare (type fixnum max-index))
      (format t "; Hons Note: Restoring conses; max index ~:D.~%" max-index)
      (finish-output)
      (loop for i fixnum below max-index do
            (when (= (aref sbits i) 1)
              ;; This object was previously normed.
              (let ((object (ccl::%static-inverse-cons i)))
                (cond ((not object)
                       ;; It got GC'd.  Take it out of sbits, don't put
                       ;; anything into ADDR-HT.
                       (setf (aref sbits i) 0))
                      (t
                       (let* ((a      (car object))
                              (b      (cdr object))
                              ;; It might be that A or B are not actually
                              ;; normed.  So why is it okay to call hl-addr-of?
                              ;; It turns out to be okay.  In the atom case,
                              ;; nothing has changed.  In the cons case, the
                              ;; address calculation only depends on the static
                              ;; index of a and b, which hasn't changed.
                              (addr-a (hl-addr-of a str-ht other-ht))
                              (addr-b (hl-addr-of b str-ht other-ht))
                              (key    (hl-addr-combine* addr-a addr-b)))
                         (setf (gethash key addr-ht) object))))))))
    (format t "; Hons Note: Done restoring~%")
    (finish-output)

    ;; All objects restored.  The hons space should now be in a fine state
    ;; once again.  Restore it.
    (ccl::without-interrupts
     (setf (hl-hspace-addr-ht hs) addr-ht)
     (setf (hl-hspace-sbits hs) sbits))
    (setf (hl-hspace-persist-ht hs) persist-ht)
    (setf (hl-hspace-fal-ht hs) fal-ht)

    (format t "; Hons Note: Done washing, ~:D normed conses remain.~%"
            (hash-table-count addr-ht))
    (finish-output))

  nil)



(defun hl-maybe-resize-ht (size src)

; (HL-MAYBE-RESIZE-HT SIZE SRC) --> HASH TABLE
;
; SRC is a hash table that we would perhaps like to resize, and SIZE is our new
; target size.  If SIZE is not sufficiently different from the current size of
; SRC, or if it seems too small for SRC, we just return SRC unchanged.
; Otherwise, we produce a new hash table that is a copy of SRC, but with the
; newly desired SIZE.

  (declare (type hash-table src))
  (let* ((src-size            (hash-table-size src))
         (src-count           (hash-table-count src))
         (min-reasonable-size (max 100 (* src-count 1.2)))
         (target-size         (max min-reasonable-size size)))
    (if (and (< (* src-size 0.8) target-size)
             (< target-size (* src-size 1.2)))
        ;; You're already pretty close to the target size.  Don't
        ;; bother resizing.
        src
      ;; Okay, size is different enough to warrant resizing.
      (let ((new-ht (hl-mht :test (hash-table-test src)
                            :size size)))
        (maphash (lambda (key val)
                   (setf (gethash key new-ht) val))
                 src)
        new-ht))))

(defun hl-hspace-resize (str-ht-size nil-ht-size cdr-ht-size cdr-ht-eql-size
                         addr-ht-size other-ht-size sbits-size
                         fal-ht-size persist-ht-size
                         hs)
  ;; This is mostly entirely straightforward.

  (declare (type hl-hspace hs)
           #+static-hons
           (ignore nil-ht-size cdr-ht-size cdr-ht-eql-size)
           #-static-hons
           (ignore addr-ht-size other-ht-size sbits-size))

  (when (natp str-ht-size)
    (setf (hl-hspace-str-ht hs)
          (hl-maybe-resize-ht str-ht-size (hl-hspace-str-ht hs))))

  (when (natp fal-ht-size)
    (setf (hl-hspace-fal-ht hs)
          (hl-maybe-resize-ht fal-ht-size (hl-hspace-fal-ht hs))))
  (when (natp persist-ht-size)
    (setf (hl-hspace-persist-ht hs)
          (hl-maybe-resize-ht persist-ht-size (hl-hspace-persist-ht hs))))

  #+static-hons
  (progn
    (when (natp addr-ht-size)
      (setf (hl-hspace-addr-ht hs)
            (hl-maybe-resize-ht addr-ht-size (hl-hspace-addr-ht hs))))
    (when (natp other-ht-size)
      (setf (hl-hspace-other-ht hs)
            (hl-maybe-resize-ht other-ht-size (hl-hspace-other-ht hs))))

    (when (natp sbits-size)
      ;; Tricky.  Need to be sure that all 1-valued sbits are preserved.
      ;; We won't try to support shrinking sbits.
      (let* ((sbits    (hl-hspace-sbits hs))
             (new-len  (min (1- array-total-size-limit) sbits-size))
             (curr-len (length sbits)))
        (when (> sbits-size curr-len)
          ;; User wants to grow sbits, so that's okay.
          (let ((new-sbits (make-array new-len
                                       :element-type 'bit
                                       :initial-element 0)))
            (declare (type (simple-array bit (*)) new-sbits))
            (loop for i fixnum below curr-len do
                  (setf (aref new-sbits i) (aref sbits i)))
            (setf (hl-hspace-sbits hs) new-sbits))))))

  #-static-hons
  (let ((ctables (hl-hspace-ctables hs)))
    (when (natp nil-ht-size)
      (setf (hl-ctables-nil-ht ctables)
            (hl-maybe-resize-ht nil-ht-size (hl-ctables-nil-ht ctables))))
    (when (natp cdr-ht-size)
      (setf (hl-ctables-cdr-ht ctables)
            (hl-maybe-resize-ht cdr-ht-size (hl-ctables-cdr-ht ctables))))
    (when (natp cdr-ht-eql-size)
      (setf (hl-ctables-cdr-ht-eql ctables)
            (hl-maybe-resize-ht cdr-ht-eql-size (hl-ctables-cdr-ht-eql ctables)))))

  nil)




; ----------------------------------------------------------------------
;
;                         STATISTICS GATHERING
;
; ----------------------------------------------------------------------

(defun hl-get-final-cdr (alist)
  (if (atom alist)
      alist
    (hl-get-final-cdr (cdr alist))))

(defun hl-hspace-fast-alist-summary (hs)
  (declare (type hl-hspace hs))
  (let ((fal-ht      (hl-hspace-fal-ht hs))
        (total-count 0)
        (total-sizes 0)
        (report-entries))
    (format t "~%Fast Alists Summary:~%~%")
    (format t " - Number of fast alists: ~15:D~%" (hash-table-count fal-ht))
    (format t " - Size of FAL-HT:        ~15:D~%" (hash-table-size fal-ht))
    (finish-output)
    (maphash
     (lambda (alist associated-ht)
       (let* ((final-cdr (hl-get-final-cdr alist))
              (size      (hash-table-size associated-ht))
              (count     (hash-table-count associated-ht)))
         (incf total-sizes size)
         (incf total-count count)
         (push (list count size final-cdr) report-entries)))
     fal-ht)
    (format t " - Total of counts:       ~15:D~%" total-count)
    (format t " - Total of sizes:        ~15:D~%" total-sizes)
    (format t "~%")
    (finish-output)
    (setq report-entries
          (sort report-entries (lambda (x y)
                                 (or (> (first x) (first y))
                                     (and (= (first x) (first y))
                                          (> (second x) (second y)))))))
    (format t "Summary of individual fast alists:~%~%")
    (format t "      Count           Size         Name~%")
    (format t "  (used slots)     (capacity)~%")
    (format t "--------------------------------------------------~%")
    (loop for entry in report-entries do
          (format t "~10:D ~16:D        ~:D~%" (first entry) (second entry) (third entry)))
    (format t "--------------------------------------------------~%")
    (format t "~%")
    (finish-output)))


(defun hl-hspace-hons-summary (hs)
  (declare (type hl-hspace hs))
  (format t "~%Normed Objects Summary~%~%")

  #+static-hons
  (let ((addr-ht  (hl-hspace-addr-ht hs))
        (sbits    (hl-hspace-sbits hs))
        (other-ht (hl-hspace-other-ht hs)))
    (format t " - SBITS array length:    ~15:D~%"
            (length sbits))
    (format t "   New static cons index: ~15:D~%~%"
            (ccl::%staticp (ccl::static-cons nil nil)))
    (format t " - ADDR-HT:      ~15:D count, ~15:D size (~5,2f% full)~%"
            (hash-table-count addr-ht)
            (hash-table-size addr-ht)
            (* (/ (hash-table-count addr-ht)
                  (hash-table-size addr-ht))
               100.0))
    (format t " - OTHER-HT:     ~15:D count, ~15:D size (~5,2f% full)~%"
            (hash-table-count other-ht)
            (hash-table-size other-ht)
            (* (/ (hash-table-count other-ht)
                  (hash-table-size other-ht))
               100.0))
    )

  #-static-hons
  (let* ((ctables    (hl-hspace-ctables hs))
         (nil-ht     (hl-ctables-nil-ht ctables))
         (cdr-ht     (hl-ctables-cdr-ht ctables))
         (cdr-ht-eql (hl-ctables-cdr-ht-eql ctables)))
    (format t " - NIL-HT:       ~15:D count, ~15:D size (~5,2f% full)~%"
            (hash-table-count nil-ht)
            (hash-table-size nil-ht)
            (* (/ (hash-table-count nil-ht)
                  (hash-table-size nil-ht))
               100.0))
    (format t " - CDR-HT:       ~15:D count, ~15:D size (~5,2f% full)~%"
            (hash-table-count cdr-ht)
            (hash-table-size cdr-ht)
            (* (/ (hash-table-count cdr-ht)
                  (hash-table-size cdr-ht))
               100.0))
    (format t " - CDR-HT-EQL:   ~15:D count, ~15:D size (~5,2f% full)~%"
            (hash-table-count cdr-ht-eql)
            (hash-table-size cdr-ht-eql)
            (* (/ (hash-table-count cdr-ht-eql)
                  (hash-table-size cdr-ht-eql))
               100.0))
    )

  (let ((str-ht       (hl-hspace-str-ht hs))
        (persist-ht   (hl-hspace-persist-ht hs))
        (fal-ht       (hl-hspace-fal-ht hs)))
    (format t " - STR-HT:       ~15:D count, ~15:D size (~5,2f% full)~%"
            (hash-table-count str-ht)
            (hash-table-size str-ht)
            (* (/ (hash-table-count str-ht)
                  (hash-table-size str-ht))
               100.0))
    (format t " - PERSIST-HT:   ~15:D count, ~15:D size (~5,2f% full)~%"
            (hash-table-count persist-ht)
            (hash-table-size persist-ht)
            (* (/ (hash-table-count persist-ht)
                  (hash-table-size persist-ht))
               100.0))
    (format t " - FAL-HT:       ~15:D count, ~15:D size (~5,2f% full)~%~%"
            (hash-table-count fal-ht)
            (hash-table-size fal-ht)
            (* (/ (hash-table-count fal-ht)
                  (hash-table-size fal-ht))
               100.0))
    )

  nil)



; ----------------------------------------------------------------------
;
;                         USER-LEVEL WRAPPERS
;
; ----------------------------------------------------------------------

(defparameter *default-hs*

; We hide the hons space from the ACL2 user by making all ACL2-visible
; functions operate with respect to *default-hs*, the "default hons space."
;
; For single-threaded versions of ACL2, we assume that *default-hs* is always
; bound to a valid Hons Space.
;
; But when ACL2-PAR is enabled, we allow *default-hs* to be either NIL or a
; valid hons space.  The consume-work-on-work-queue-when-there function in
; acl2-par is responsible for creating all worker threads, and immediately
; binds *default-hs* to NIL, which is quite cheap.  The idea is to allow
; threads that don't do any honsing to avoid the overhead of creating a hons
; space.
;
; Maybe we should make this a DEFVAR with no binding, and move it to whatever
; initialization function is run when ACL2 starts.  This would keep the hons
; space out of the default ACL2 image.  But that probably doesn't matter unless
; we want to adopt much larger defaults, which we don't.

  (hl-hspace-init))

(declaim
 #-acl2-par
 (type hl-hspace *default-hs*)
 #+acl2-par
 (type (or hl-hspace null) *default-hs*))

(defmacro hl-maybe-initialize-default-hs ()
  #-acl2-par
  nil
  #+acl2-par
  (unless *default-hs*
    (setq *default-hs* (hl-hspace-init))))


(defun hons (x y)
  ;; hl-hspace-hons is inlined via defabbrev
  (hl-maybe-initialize-default-hs)
  (hl-hspace-hons x y *default-hs*))

(defun hons-copy (x)
  ;; hl-hspace-norm is inlined via defabbrev
  (hl-maybe-initialize-default-hs)
  (hl-hspace-norm x *default-hs*))

(defun hons-copy-persistent (x)
  ;; no need to inline
  (hl-maybe-initialize-default-hs)
  (hl-hspace-persistent-norm x *default-hs*))

(declaim (inline hons-equal))
(defun hons-equal (x y)
  ;; hl-hspace-hons-equal is not inlined, so we inline the wrapper
  (hl-maybe-initialize-default-hs)
  (hl-hspace-hons-equal x y *default-hs*))

(declaim (inline hons-equal-lite))
(defun hons-equal-lite (x y)
  ;; hl-hspace-hons-equal-lite is not inlined, so we inline the wrapper
  (hl-maybe-initialize-default-hs)
  (hl-hspace-hons-equal-lite x y *default-hs*))

(defun hons-summary ()
  ;; no need to inline
  (hl-maybe-initialize-default-hs)
  (hl-hspace-hons-summary *default-hs*))

(defun hons-clear (gc)
  ;; no need to inline
  (hl-maybe-initialize-default-hs)
  (hl-hspace-hons-clear gc *default-hs*))

(defun hons-wash ()
  ;; no need to inline
  (hl-maybe-initialize-default-hs)
  (hl-hspace-hons-wash *default-hs*))

(defun hons-resize-fn (str-ht nil-ht cdr-ht cdr-ht-eql
                                 addr-ht other-ht sbits
                                 fal-ht persist-ht)
  ;; no need to inline
  (hl-maybe-initialize-default-hs)
  (hl-hspace-resize str-ht nil-ht cdr-ht cdr-ht-eql
                    addr-ht other-ht sbits
                    fal-ht persist-ht
                    *default-hs*))


(declaim (inline hons-acons))
(defun hons-acons (key val fal)
  ;; hl-hspace-hons-acons is not inlined, so we inline the wrapper
  (hl-maybe-initialize-default-hs)
  (hl-hspace-hons-acons key val fal nil *default-hs*))

(declaim (inline hons-acons!))
(defun hons-acons! (key val fal)
  ;; hl-hspace-hons-acons is not inlined, so we inline the wrapper
  (hl-maybe-initialize-default-hs)
  (hl-hspace-hons-acons key val fal t *default-hs*))

(defun hons-shrink-alist (alist ans)
  ;; no need to inline
  (hl-maybe-initialize-default-hs)
  (hl-hspace-shrink-alist alist ans nil *default-hs*))

(defun hons-shrink-alist! (alist ans)
  ;; no need to inline
  (hl-maybe-initialize-default-hs)
  (hl-hspace-shrink-alist alist ans t *default-hs*))

(declaim (inline hons-get))
(defun hons-get (key fal)
  ;; hl-hspace-hons-get is not inlined, so we inline the wrapper
  (hl-maybe-initialize-default-hs)
  (hl-hspace-hons-get key fal *default-hs*))

(declaim (inline fast-alist-free))
(defun fast-alist-free (fal)
  ;; hl-hspace-fast-alist-free is not inlined, so we inline the wrapper
  (hl-maybe-initialize-default-hs)
  (hl-hspace-fast-alist-free fal *default-hs*))

(declaim (inline fast-alist-len))
(defun fast-alist-len (fal)
  ;; hl-hspace-fast-alist-len is not inlined, so we inline the wrapper
  (hl-maybe-initialize-default-hs)
  (hl-hspace-fast-alist-len fal *default-hs*))

(declaim (inline number-subtrees))
(defun number-subtrees (x)
  ;; hl-hspace-number-subtrees is not inlined, so we inline the wrapper
  (hl-maybe-initialize-default-hs)
  (hl-hspace-number-subtrees x *default-hs*))

(defun fast-alist-summary ()
  ;; no need to inline
  (hl-maybe-initialize-default-hs)
  (hl-hspace-fast-alist-summary *default-hs*))


;  COMPATIBILITY WITH OLD HONS FUNCTIONS ------------------------

(defun clear-hash-tables ()
  (clear-memoize-tables)
  #+static-hons (hons-wash)
  #-static-hons (hons-clear t))

(defun wash-memory ()
  ;; Deprecated.
  (clear-memoize-tables)
  (hons-wash))

