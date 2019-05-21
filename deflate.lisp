(in-package 3bz)

#++(ql:quickload '3bz)
(defstruct-cached (deflate-state (:conc-name ds-))
  ;; current state machine state
  (current-state :start-of-block)

  ;; set when reading last block in stream
  (last-block-flag nil :type (or nil t))

  ;; storage for dynamic huffman tree, modified for each dynamic block
  (dynamic-huffman-tree (cons (make-huffman-tree) (make-huffman-tree))
                        :type (cons huffman-tree huffman-tree))
  ;; reference to either dynamic-huffman-tree or *static-huffman-tree*
  ;; depending on curret block
  (current-huffman-tree +static-huffman-trees+
                        :type (cons huffman-tree huffman-tree))
  ;; dynamic huffman tree parameters being read
  (dht-hlit 0 :type  (unsigned-byte 10))
  (dht-hlit+hdist 0 :type (unsigned-byte 10))
  (dht-hclen 0 :type (unsigned-byte 4))
  (dht-len-codes (make-array 19 :element-type '(unsigned-byte 4)
                                :initial-element 0)
                 :type (simple-array (unsigned-byte 4) (19)))

  (dht-len-tree (make-huffman-tree)) ;; fixme: reduce size
  (dht-lit/len/dist (make-array (+ 288 32) :element-type '(unsigned-byte 4)
                                           :initial-element 0)
   :type code-table-type)
  (dht-lit/len/dist-index 0 :type (mod 320))
  (dht-last-len #xff :type octet)

  ;; number of bytes left to copy (for uncompressed block, or from
  ;; history in compressed block)
  (bytes-to-copy 0 :type (unsigned-byte 16))

  ;; bitstream state: we read up to 64bits at a time to try to
  ;; minimize time spent interacting with input source relative to
  ;; decoding time.
  (partial-bits 0 :type (unsigned-byte 64))
  ;; # of valid bits remaining in partial-bits (0 = none)
  (bits-remaining 0 :type (unsigned-byte 7))

  (output-offset 0 :type fixnum))


(defmacro state-machine ((state) &body tagbody)
  (let ((tags (loop for form in tagbody when (atom form) collect form)))
    `(symbol-macrolet ((.current-state ,(list nil)))
       (macrolet ((next-state (next-state)
                    `(progn
                       (setf current-state ',next-state)
                       (go ,next-state)))
                  (%enter-state (s &environment env)
                    (setf (car (macroexpand '.current-state env)) s)
                    `(progn #++(format t "~s~%" ',s)))
                  (restart-state (&environment env)
                    `(go ,(car (macroexpand '.current-state env)))))
         (tagbody
            ;; possibly could do better than a linear search here, but
            ;; if state machine is being interrupted often enough to
            ;; matter, it probably won't matter anyway :/ at most,
            ;; maybe define more commonly interrupted states earlier
            (ecase (ds-current-state ,state)
              ,@(loop for i in tags
                      collect `(,i (go ,i))))
            ,@(loop for f in tagbody
                    collect f
                    when (atom f)
                      collect `(%enter-state ,f)))))))


(defparameter *stats* (make-hash-table))
(defun decompress (read-context state into)
  (declare (optimize speed))
  (check-type into octet-vector)
  (with-reader-contexts (read-context)
    (with-cached-state (state deflate-state save-state
                         partial-bits bits-remaining
                         current-huffman-tree
                         output-offset
                         current-state
                         bytes-to-copy)
      (macrolet ((bits* (&rest sizes)
                   ;; only valid for fixed sizes, but possibly should
                   ;; allow passing +constants+ and try to eval them
                   ;; at macroexpansion instead of requiring numbers?
                   (let ((n (reduce '+ sizes)))
                     `(let ((b (bits ,n)))
                        (declare (type (unsigned-byte ,n) b))
                        (values ,@(loop for o = 0 then (+ o s)
                                        for s in sizes
                                        collect `(ldb (byte ,s ,o) b))))))
                 (eoi () ;; end of input
                   #++ (error "eoi")
                   #++ (go :eoi)
                   `(progn
                      (save-state)
                      (throw :eoi nil))))
        (let ((ht-scratch (make-huffman-tree)))
          (declare (type octet-vector into))
          (labels ((bits-avail (n)
                     (<= n bits-remaining))
                   (byte-align ()
                     (let ((r (mod bits-remaining 8)))
                       (unless (zerop r)
                         (setf partial-bits (ash partial-bits (- r)))
                         (decf bits-remaining r))))

                   ;; called when temp is empty, read bits and update
                   ;; remaining
                   (%fill-bits ()
                     (multiple-value-bind (input octets)
                         (word64)
                       (declare (type (mod 9) octets))
                       (setf bits-remaining (* 8 octets)
                             partial-bits input)))
                   (%fill-bits32 (n)
                     (multiple-value-bind (input octets)
                         (word32)
                       (declare (type (mod 5) octets))
                       (setf partial-bits
                             (logior
                              (ash (ldb (byte 32 0) input)
                                   (min 32 bits-remaining))
                              partial-bits))

                       (incf bits-remaining (* 8 octets))
                       (>= bits-remaining n)))
                   ;; internals of bit reader, only call after
                   ;; ensuring there are enough bits available
                   (%bits (n)
                     (declare (optimize (speed 1)))
                     (prog1 (ldb (byte n 0) partial-bits)
                       (setf partial-bits (ash partial-bits (- n)))
                       (decf bits-remaining n)))
                   ;; fast path for bit reader, inlined
                   (bits (n)
                     (if (<= n bits-remaining)
                         (%bits n)
                         (bits-full n)))
                   ;; slow path for bit reader, not inlined (should
                   ;; only be called if we know there aren't enough
                   ;; bits in temp. usually called from BITS)
                   (bits-full (n)
                     ;; we could handle 64 bits, but we limit it to
                     ;; make it more likely to fit in a fixnum
                     (declare (type (mod 56) n))
                     ;; try to read (up to) 64 bits from input
                     ;; (returns 0 in OCTETS if no more input)
                     (multiple-value-bind (input octets)
                         (word64)
                       (declare (type (mod 9) octets)
                                (type (unsigned-byte 6) bits-remaining))
                       (let* ((bits (* octets 8))
                              (total (+ bits-remaining bits)))
                         ;; didn't read enough bits, save any bits we
                         ;; did get for later, then fail
                         (when (> n total)
                           (assert (<= total 64))
                           (setf partial-bits
                                 (ldb (byte 64 0)
                                      (logior (ash input bits-remaining)
                                              partial-bits)))
                           (setf bits-remaining total)
                           (eoi))
                         ;; if we get here, we have enough bits now,
                         ;; so combine them and store any leftovers
                         ;; for later
                         (let* ((n2 (- n bits-remaining))
                                (r (ldb (byte n 0)
                                        (logior (ash (ldb (byte n2 0) input)
                                                     bits-remaining)
                                                (ldb (byte bits-remaining 0)
                                                     partial-bits))))
                                (bits2 (- bits n2)))
                           (declare (type (unsigned-byte 6) n2)
                                    (type (unsigned-byte 64) r))
                           (setf partial-bits (ash input (- n2))
                                 bits-remaining bits2)
                           r))))

                   (out-byte (b)
                     (setf (aref into output-offset) b)
                     (setf output-offset (wrap-fixnum (1+ output-offset)))

                     nil)

                   (copy-byte-or-fail ()
                     (out-byte (bits 8)))

                   #++(copy-history (count offset)
                        (declare (ignorable count offset))
                        (loop repeat count
                              do (out-byte (aref into (- output-offset offset)))))
                   (copy-history (count offset)
                     (declare (type fixnum count offset))
                     (let* ((n count)
                            (o offset)
                            (d output-offset)
                            (s (- d o))
                            (e (length into)))
                       (declare (type (and fixnum unsigned-byte) d e)
                                (type fixnum s))
                       (cond
                         ((< s 0)
                          (error "no window?"))
                         ;; if copy won't fit (or oversized copy below
                         ;; might overrun buffer), use slow path for
                         ;; now
                         ((> (+ d n 8)
                             e)
                          (loop while (< d e)
                                do (setf (aref into d) (aref into s))
                                   (setf d (1+ d))
                                   (setf s (1+ s)))
                          ;; todo: store state so it can continue
                          (when (< d (+ output-offset n))
                            (error "output full")))
                         ;; to speed things up, we allow writing past
                         ;; current output index (but not past end of
                         ;; buffer), and read/write as many bytes at a
                         ;; time as possible.
                         ((> o 8)
                          (loop repeat (ceiling n 8)
                                do (setf (nibbles:ub64ref/le into d)
                                         (nibbles:ub64ref/le into s))
                                   (setf d (wrap-fixnum (+ d 8)))
                                   (setf s (wrap-fixnum (+ s 8)))))
                         ((= o 8)
                          (loop with x = (nibbles:ub64ref/le into s)
                                repeat (ceiling n 8)
                                do (setf (nibbles:ub64ref/le into d)
                                         x)
                                   (setf d (wrap-fixnum (+ d 8)))))
                         ((> o 4)
                          (loop repeat (ceiling n 4)
                                do (setf (nibbles:ub32ref/le into d)
                                         (nibbles:ub32ref/le into s))
                                   (setf d (wrap-fixnum (+ d 4)))
                                   (setf s (wrap-fixnum (+ s 4)))))

                         ((= o 1)
                          ;; if offset is 1, we are just repeating a
                          ;; single byte...
                          (loop with x of-type octet = (aref into s)
                                repeat n
                                do (setf (aref into d) x)
                                   (setf d (wrap-fixnum (1+ d)))))
                         ((= o 4)
                          (loop with x = (nibbles:ub32ref/le into s)
                                with xx = (dpb x (byte 32 32) x)
                                repeat (ceiling n 8)
                                do (setf (nibbles:ub64ref/le into d) xx)
                                   (setf d (wrap-fixnum (+ d 8)))))
                         ((= o 3)
                          (loop repeat (ceiling n 2)
                                do (setf (nibbles:ub16ref/le into d)
                                         (nibbles:ub16ref/le into s))
                                   (setf d (wrap-fixnum (+ d 2)))
                                   (setf s (wrap-fixnum (+ s 2)))))
                         ((= o 2)
                          (loop with x = (nibbles:ub16ref/le into s)
                                with xx = (dpb x (byte 16 16) x)
                                with xxxx = (dpb xx (byte 32 32) xx)
                                repeat (ceiling n 8)
                                do (setf (nibbles:ub64ref/le into d) xxxx)
                                   (setf d (wrap-fixnum (+ d 8))))))
                       ;; D may be a bit past actual value, so calculate
                       ;; correct offset
                       (setf output-offset
                             (wrap-fixnum (+ output-offset n)))))


                   (decode-huffman-full (ht old-bits old-count)
                     (declare (type huffman-tree ht)
                              (type (unsigned-byte 32) old-bits)
                              (type (or null (unsigned-byte 6)) old-count))
                     (let ((ht-bits (ht-start-bits ht))
                           (bits partial-bits)
                           ;; # of valid bits left in BITS
                           (avail bits-remaining)
                           ;; offset of next unused bit in BITS
                           (offset 0)
                           ;; if we had to refill bits, # we had before refill
                           (old 0)
                           (extra-bits nil)
                           (node 0)
                           (nodes (ht-nodes ht)))
                       (declare (type (unsigned-byte 64) bits)
                                (type (unsigned-byte 7) avail)
                                (type (unsigned-byte 7) old)
                                (type ht-bit-count-type ht-bits))
                       (loop
                         ;; if we don't have enough bits, add some
                         when (> ht-bits avail)
                           do (incf old bits-remaining)
                              (%fill-bits)
                          ;; dist + extra is max 28 bits, so just
                          ;; grab enough for that from new input
                          ;; if available
                          (assert (< old 32))
                          (setf bits
                                (logior bits
                                        (ash
                                         (ldb (byte (min 30 bits-remaining)
                                                    0)
                                              partial-bits)
                                         old)))
                          (setf avail
                                (min 64
                                     (+ avail (min 30 bits-remaining))))
                          (when (> ht-bits avail)
                            ;; still not enough bits, push bits back
                            ;; onto tmp if we read more, and EOI
                            (assert (< old 64))
                            (assert (< (+ bits-remaining old) 64))

                            (setf partial-bits
                                  (ldb (byte 64 0)
                                       (ash partial-bits old)))
                            (setf (ldb (byte old 0) partial-bits)
                                  (ldb (byte old 0) bits))
                            (incf bits-remaining old)
                            ;; if we are reading a dist, put bits
                            ;; from len back too so we don't need
                            ;; separate states for lit/len and dist
                            (locally
                                (declare #+sbcl (sb-ext:muffle-conditions
                                                 sb-ext:code-deletion-note))
                              (when old-count
                                ;; (lit/len + dist + extras is max 48
                                ;; bits, so just
                                (assert (< (+ old-count bits-remaining) 64))
                                (setf partial-bits
                                      (ldb (byte 64 0)
                                           (ash partial-bits old-count)))
                                (setf (ldb (byte old-count 0) partial-bits)
                                      (ldb (byte old-count 0) old-bits))
                                (incf bits-remaining old-count)))
                            (eoi))
                         if extra-bits
                           do (setf extra-bits (ldb (byte ht-bits offset) bits))
                              (incf offset ht-bits)
                              (decf avail ht-bits)
                              (loop-finish)
                         else
                           do (let* ((b (ldb (byte ht-bits offset) bits)))
                                (setf node (aref nodes (+ node b)))
                                (incf offset ht-bits)
                                (decf avail ht-bits)
                                (ecase (ht-node-type node)
                                  (#.+ht-link/end+
                                   (when (ht-endp node)
                                     (loop-finish))
                                   (setf ht-bits (ht-link-bits node))
                                   (setf node (ht-link-offset node)))
                                  (#.+ht-literal+
                                   (loop-finish))
                                  (#.+ht-len/dist+
                                   (let ((x (ht-extra-bits node)))
                                     (when (zerop x)
                                       (loop-finish))
                                     (setf ht-bits x
                                           extra-bits x))))))
                       (let ((s (- offset old)))
                         (assert (< 0 s 64))
                         (setf partial-bits (ash partial-bits (- s)))
                         (decf bits-remaining s))
                       (assert (< offset 32))
                       (values (ht-value node)
                               (or extra-bits 0)
                               (ht-node-type node)
                               (ldb (byte offset 0) bits)
                               offset)))

                   ;; specialized version when we know we have enough bits
                   ;; (up to 28 depending on tree)
                   (%decode-huffman-fast (ht)
                     (declare (type huffman-tree ht))
                     (let ((ht-bits (ht-start-bits ht))
                           (bits partial-bits)
                           ;; # of valid bits left in BITS
                           (avail bits-remaining)
                           ;; offset of next unused bit in BITS
                           (offset 0)
                           (extra-bits nil)
                           (node 0)
                           (nodes (ht-nodes ht)))
                       (declare (type (unsigned-byte 64) bits)
                                (type (unsigned-byte 7) avail)
                                (type ht-bit-count-type ht-bits))
                       (loop
                         for b = (ldb (byte ht-bits offset) bits)
                         do (setf node (aref nodes (+ node b)))
                            (incf offset ht-bits)
                            (decf avail ht-bits)
                            (ecase (ht-node-type node)
                              (#.+ht-link/end+
                               (when (ht-endp node)
                                 (loop-finish))
                               (setf ht-bits (ht-link-bits node)
                                     node (ht-link-offset node)))
                              (#.+ht-literal+
                               (loop-finish))
                              (#.+ht-len/dist+
                               (let ((x (ht-extra-bits node)))
                                 (when (zerop x)
                                   (loop-finish))
                                 (setf extra-bits (ldb (byte x offset) bits))
                                 (incf offset x)
                                 (decf avail x)
                                 (loop-finish)))))
                       (setf partial-bits (ash partial-bits (- offset)))
                       (setf bits-remaining avail)
                       (assert (< offset 32))
                       (values (ht-value node)
                               (or extra-bits 0)
                               (ht-node-type node)
                               (ldb (byte offset 0) bits)
                               offset)))
                   (decode-huffman (ht old-bits old-count)
                     (if (let ((s (ht-max-bits ht)))
                           (or (bits-avail s)
                               (%fill-bits32 s)))
                         (%decode-huffman-fast ht)
                         (decode-huffman-full ht old-bits old-count))))
            (declare (inline bits-avail byte-align %fill-bits %bits bits
                             out-byte copy-byte-or-fail
                             decode-huffman %decode-huffman-fast
                             %fill-bits32)
                     (ignorable #'bits-avail))
            (catch :eoi
              (state-machine (state)
                :start-of-block
                (multiple-value-bind (final type) (bits* 1 2)
                  #++
                  (format t "block start ~s ~s~%" final type)
                  (setf last-block-flag (plusp final))
                  (ecase type
                    (0 (next-state :uncompressed-block))
                    (1 ;; static huffman tree
                     (setf current-huffman-tree +static-huffman-trees+)
                     (next-state :decode-compressed-data))
                    (2
                     (setf current-huffman-tree dynamic-huffman-tree)
                     (next-state :dynamic-huffman-block))))

;;; uncompressed block

                :uncompressed-block
                (byte-align)
                (multiple-value-bind (s n) (bits* 16 16)

                  (assert (= n (ldb (byte 16 0) (lognot s))))
                  (setf bytes-to-copy s)
                  (next-state :copy-block))
                :copy-block
                ;; todo: optimize this
                (loop while (plusp bytes-to-copy)
                      do (copy-byte-or-fail)
                         (decf bytes-to-copy))
                (next-state :block-end)

;;; dynamic huffman table block, huffman table

                :dynamic-huffman-block
                ;; we have at least 26 bits of fixed data, 3 length
                ;; fields, and first 4 code lengths, so try to read
                ;; those at once
                (multiple-value-bind (hlit hdist hclen l16 l17 l18 l0)
                    (bits* 5 5 4 3 3 3 3)
                  (let ((dlc dht-len-codes))
                    (fill dlc 0)
                    (setf (aref dlc 16) l16)
                    (setf (aref dlc 17) l17)
                    (setf (aref dlc 18) l18)
                    (setf (aref dlc 0) l0))
                  ;; possibly could optimize this a bit more, but
                  ;; should be fairly small part of any normal file
                  (setf dht-hlit (+ hlit 257)
                        dht-hlit+hdist (+ dht-hlit hdist 1)
                        dht-hclen hclen
                        dht-lit/len/dist-index 0)
                  (next-state :dht-len-table))

                :dht-len-table
                ;; we read 4 entries with header, so max 15 left = 45
                ;; bits. wait until we have at least that much
                ;; available and extract all at once
                (let* ((bitcount (* dht-hclen 3))
                       (bits (bits bitcount))
                       (permute +len-code-order+)
                       (lc dht-len-codes))
                  (declare (type (unsigned-byte 48) bits))
                  ;; extract length codes into proper elements of
                  ;; len-codes
                  (loop for i from 4
                        for o from 0 by 3 ;downfrom (- bitcount 3) by 3
                        repeat dht-hclen
                        do (setf (aref lc (aref permute i))
                                 (ldb (byte 3 o) bits)))
                  ;; and build a huffman tree out of them
                  (multiple-value-bind (count bits max)
                      (build-tree-part dht-len-tree 0
                                       dht-len-codes
                                       :dht-len 0 19
                                       ht-scratch
                                       +len-code-extra+)
                    (declare (ignore count))
                    (setf (ht-start-bits dht-len-tree) bits)
                    (setf (ht-max-bits dht-len-tree) max))
                  (setf dht-last-len #xff)
                  (next-state :dht-len-table-data))

                :dht-len-table-data
                (let ((ht dht-len-tree)
                      (end dht-hlit+hdist)
                      (lld dht-lit/len/dist))
                  ;; decode-huffman will EOI if not enough bits
                  ;; available, so we need to track state in loop to
                  ;; be able to continue
                  (loop while (< dht-lit/len/dist-index end)
                        do (multiple-value-bind (code extra)
                               (decode-huffman ht 0 nil)
                             (cond
                               ((< code 16)
                                (setf (aref lld dht-lit/len/dist-index)
                                      (setf dht-last-len code))
                                (incf dht-lit/len/dist-index))
                               ((= code 16)
                                (unless (< dht-last-len 16)
                                  (error "tried to repeat length without previous length"))
                                (let ((e (+ dht-lit/len/dist-index extra 3)))
                                  (assert (<= e dht-hlit+hdist))
                                  (loop for i from dht-lit/len/dist-index
                                        repeat (+ extra 3)
                                        do (setf (aref lld i) dht-last-len))
                                  #++(fill lld dht-last-len
                                           :start dht-lit/len/dist-index
                                           :end e)
                                  (setf dht-lit/len/dist-index e)))
                               (t
                                (let* ((c (if (= code 17) 3 11))
                                       (e (+ dht-lit/len/dist-index extra c)))
                                  (assert (<= e dht-hlit+hdist))
                                  (fill lld 0
                                        :start dht-lit/len/dist-index
                                        :end e)
                                  (setf dht-lit/len/dist-index e)
                                  (setf dht-last-len 0)))))))
                ;; if we get here, we have read whole table, build tree
                (build-trees* (car dynamic-huffman-tree)
                              (cdr dynamic-huffman-tree)
                              dht-lit/len/dist
                              dht-hlit
                              dht-lit/len/dist-index
                              ht-scratch)
                (next-state :decode-compressed-data)

;;; dynamic or static huffman block, compressed data

                :decode-compressed-data
                (let* (;;(ht current-huffman-tree)
                       ;;(bases +len/dist-bases+)
                       ;;(dist-offset (ht-dist-offset ht))
                       )
                  (symbol-macrolet (;;(dist-offset (ht-dist-offset ht))
                                    (bases +len/dist-bases+)
                                    (ht current-huffman-tree))
                    (loop
                      (multiple-value-bind (code extra type old-bits old-count)
                          (decode-huffman (car ht) 0 nil)
                        (ecase type
                          (#.+ht-len/dist+
                           ;; got a length code, read dist and copy
                           (let ((bytes-to-copy (+ extra (aref bases code))))
                             ;; try to read dist. decode-huffman* will
                             ;; push BITS back onto temp before calling
                             ;; EOI if it fails, so we can restart state
                             ;; at len code
                             (multiple-value-bind (dist extra)
                                 (decode-huffman (cdr ht)
                                                 old-bits old-count)
                               ;; got dist code
                               (copy-history bytes-to-copy (+ (aref bases dist)
                                                              extra)))))
                          (#.+ht-literal+
                           (out-byte code))
                          (#.+ht-link/end+
                           (assert (= code 0))
                           (assert (= extra 0))
                           (next-state :block-end)))))))

;;; end of a block, see if we are done with deflate stream
                :block-end
                (if last-block-flag
                    (next-state :done)
                    (next-state :start-of-block))

;;; normal exit from state machine
                :done)))))
      output-offset)))
