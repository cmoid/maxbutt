;;; derl.el --- Distributed Erlang networking code.

;;; Commentary:
;;
;; This module implements a useful subset of the Erlang distribution
;; protocol, and provides a small API for sending messages to remote
;; nodes.

(require 'net-fsm)
(require 'epmd)
(require 'erlext)
(require 'md5)
(require 'erl)

;;; Code:

(defvar erl-nodeup-hook nil
  "Called when peer appears.
Called with two args, NODE and FSM.  NODE is a symbol of the form
mynode@cockatoo, FSM is the net-fsm process of the connection.")

(defvar erl-nodedown-hook nil
  "Called when peer disappears.
Called with one arg, NODE, a symbol of the form mynode@cockatoo")

(defcustom derl-use-trace-buffer t
  "*Store erlang message communication in a trace buffer."
  :type 'boolean
  :group 'distel)

(defvar derl-cookie nil
  "*Cookie to use in distributed erlang connections, or NIL.
When NIL, we read ~/.erlang.cookie.")

;; Local variables

(defvar-local derl-connection-node nil
  "Local variable recording the node name of the connection.")

(defvar-local derl-hdrlen 2
  "Size in bytes of length headers of packets. Set to 2 during
handshake, 4 when connected.")

(defvar-local derl-alive nil
  "Local variable set to t after handshaking.")

(defvar-local derl-shutting-down nil
  "Set to T during shutdown, when no longer servicing requests.")

(defvar-local derl-request-queue nil
  "Messages waiting to be sent to node.")

(defvar-local derl-remote-links '()
  "List of (LOCAL-PID . REMOTE-PID) for all distributed links (per-node.)
Used for sending exit signals when the node goes down.")

;; Optional feature flags
(defconst derl-flag-published           #x01)
(defconst derl-flag-atom-cache          #x02)
(defconst derl-flag-extended-references #x04)
(defconst derl-flag-dist-monitor        #x08)
(defconst derl-flag-fun-tags            #x10)
(defconst derl-flag-dist-monitor-name   #x20)
(defconst derl-flag-hidden-atom-cache   #x40)
(defconst derl-flag-new-fun-tags        #x80)
(defconst derl-flag-extended-pids-ports #x100)
(defconst derl-flag-export-ptr-tag      #x200)
(defconst derl-flag-bit-binaries        #x400)
(defconst derl-flag-new-floats          #x800)
(defconst derl-flag-utf8-atoms          #x10000)
(defconst derl-flag-map-tag             #x20000)
(defconst derl-flag-big-creation        #x40000)
(defconst derl-flag-handshake-23        #x1000000)
(defconst derl-flag-unlink-id           #x2000000)
(defconst derl-flag-V4-NC               (ash 1 34))

;; ------------------------------------------------------------
;; External API
;; ------------------------------------------------------------

(defun erl-connect (node)
  "Asynchronously connect to NODE. If the connection succeeds,
`erl-nodeup-hook' is run. If the connection fails, or goes down
some time later, `erl-nodedown-hook' is run."
  (when (eq node erl-node-name)
    (error "Remote node has the same node name as Emacs: %S" node))
  (let* ((name (derl-node-name node))
         (host (derl-node-host node))
         (buffer (get-buffer-create (derl-buffer-name node)))
         ;; faking a closure with backtick. fun eh?
         ;; NB: (funcall '(lambda () 1))
         ;;       => 1
         ;;     (let ((n 1)) `(lambda () ,n))
         ;;       => (lambda () 1)
         (fail-cont `(lambda ()
                       (kill-buffer ,buffer)
                       (derl-nodedown ',node))))
    (epmd-port-please name host
                      ;; success continuation
                      `(lambda (port)
                         (fsm-connect ,host port #'derl-state0 ',node
                                      nil
                                      ,fail-cont
                                      ,buffer))
                      fail-cont)))

(defun erl-dist-send (pid msg)
  "Send a message to a process on a remote node."
  (derl-dist-request (erl-pid-node pid) #'derl-send pid msg))

(defun erl-dist-reg-send (node name msg)
  "Send a message to a registered process on a remote node."
  (derl-dist-request node #'derl-reg-send erl-self name msg))

(defun erl-dist-link (pid)
  "Link the current process with the remote PID."
  (derl-dist-request (erl-pid-node pid) #'derl-link erl-self pid))

(defun erl-dist-unlink (pid)
  "Link the current process with the remote PID."
  (derl-dist-request (erl-pid-node pid) #'derl-unlink erl-self pid))

(defun erl-dist-exit (from to reason)
  "Send an exit signal to a remote process."
  (derl-dist-request (erl-pid-node to) #'derl-exit from to reason))

(defun erl-dist-exit2 (from to reason)
  "Send an `exit2' signal to a remote process.
Use the distribution protocol's EXIT2 message."
  ;; I don't know exactly how EXIT2 differs from EXIT. Browsing the
  ;; emulator code, it looks like EXIT is for propagating a process
  ;; crash, and EXIT2 is for the exit/2 BIF (where FROM isn't
  ;; necessarily linked with TO).
  (derl-dist-request (erl-pid-node to) #'derl-exit2 from to reason))

;; -----------------------------------------------------------
;; Handshake protocol states. These follow the protocol diagram in
;; the distributed_handshake.txt file of lib/kernel/internal_doc/ in
;; Erlang/OTP.
;; -----------------------------------------------------------

(defun derl-state0 (event node-name)
  "Start state: send-name and then transition."
  (fsm-check-event event 'init)
  (setq derl-connection-node node-name)
  (setq fsm-put-data-in-buffer t)
  ;; Do nodedown when the buffer is killed in an unexpected way
  ;; (e.g. by user)
  (add-hook 'kill-buffer-hook
            (lambda () (when derl-alive (derl-nodedown derl-connection-node))))
  (derl-send-name)
  (fsm-change-state #'derl-recv-status))

(defun derl-recv-status (event data)
  "Wait for status message."
  (fsm-check-event event 'data)
  (let ((msg (derl-take-msg)))
    (when msg
      (if (string= msg "sok")
          (fsm-change-state #'derl-recv-challenge t)
        (fsm-fail)))))

(defun derl-recv-challenge (event data)
  "Receive challenge message, send response and our challenge."
  (fsm-check-event event 'data)
  (when (derl-have-msg)
    (goto-char (point-min))
    (erlext-read2)                      ; skip length
    (let ((tag (erlext-read1)))
      (unless (equal 78 tag)   ; tag-check (N)
        ;; NOTE: this function is called in an unwind-protect and so the call
        ;; to fsm-fail gets buried and one never sees the wrong tag error msg
        (fsm-fail (format nil "wrong-tag: %S" tag))))
    (let ((flags   (erlext-readn 8))
          (challenge (erlext-readn 4))
          (creation (erlext-readn 4))
          (rem-node (buffer-substring (point) (derl-msg-end))))
      (derl-eat-msg)
      (derl-send-challenge-reply challenge)
      (fsm-change-state #'derl-recv-challenge-ack))))

(defun derl-string-make-unibyte (string)
  (if (fboundp 'string-make-unibyte)
      (string-make-unibyte string)
    string))

(defun derl-recv-challenge-ack (event data)
  "Receive and check challenge ack. If it's OK then the handshake is
complete and we become live."
  (if (equal event 'closed)
      ;; this error message is misleading the socket could be closed for other
      ;; reasons
      (message "Distel thinks the cookie is %s. Erlang seems to disagree with %s"
               (derl-cookie) data))
  (fsm-check-event event 'data)
  (when (derl-have-msg)
    (goto-char (point-min))
    (erlext-read2)                      ; skip length
    (unless (equal 97 (erlext-read1))   ; tag-check (a)
      (fsm-fail 'wrong-tag))
    (let ((digest (buffer-substring (point) (+ (point) 16))))
      (derl-eat-msg)
      (if (equal (derl-string-make-unibyte (derl-gen-digest (string 0 0 0 42))) digest)
          (derl-go-live)
        (fsm-fail)))))

;; Handshake support code

(defun derl-send-name ()
  (erase-buffer)
  (derl-send-msg
   (fsm-build-message
     (fsm-encode1 78)                  ; tag (N)
     (fsm-encode8 (logior derl-flag-extended-references
                          derl-flag-extended-pids-ports
                          derl-flag-new-fun-tags
                          derl-flag-utf8-atoms
                          derl-flag-unlink-id
                          derl-flag-handshake-23
                          derl-flag-big-creation
                          derl-flag-map-tag
                          derl-flag-new-floats
                          derl-flag-bit-binaries
                          derl-flag-export-ptr-tag
                          derl-flag-fun-tags
                          derl-flag-V4-NC))
     (fsm-encode4 37)
     (fsm-encode2(length (symbol-name erl-node-name)))
     (fsm-insert (symbol-name erl-node-name)))))

(defun derl-send-challenge-reply (challenge)
  (derl-send-msg (fsm-build-message
                   (fsm-encode1 114)    ; 114 = ?r
                   (fsm-encode4 42)
                   (fsm-insert (derl-gen-digest challenge)))))

(defun derl-gen-digest (challenge)
  "Generate a message digest as required for the specification's
gen_digest() function:
  (md5 (concat challenge-as-ascii-decimal cookie))"
  (derl-hexstring-to-binstring
   (md5 (concat (derl-cookie) (derl-int32-to-decimal challenge)))))

(defun derl-cookie ()
  (or derl-cookie
      (with-temp-buffer
        (insert-file-contents (concat (getenv "HOME") "/.erlang.cookie"))
        (while (search-forward "\n" nil t)
          (replace-match ""))
        (buffer-string))))

;; ------------------------------------------------------------
;; Alive/connected state
;; ------------------------------------------------------------

(defun derl-go-live ()
  (setq derl-alive t)
  (setq derl-hdrlen 4)
  (derl-nodeup derl-connection-node)
  (mapc #'derl-do-request derl-request-queue)
  (setq derl-request-queue nil)
  (fsm-change-state #'derl-alive t))

(defun derl-alive (event data)
  (fsm-check-event event 'data 'closed)
  (if (eq event 'closed)
      (progn (derl-nodedown derl-connection-node)
             (setq derl-alive nil)
             (fsm-fail))
    (while (derl-handle-tick))
    (when (derl-have-msg)
      (let ((msg (derl-take-msg))
            ctl
            req)
        ;; Decode the control message, and the request if it's present
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert msg)
          (goto-char (point-min))
          (cl-assert (= (erlext-read1) 112)) ; type = pass through..
          (setq ctl (erlext-read-whole-obj))
          (when (< (point) (point-max))
            (setq req (erlext-read-whole-obj))))
        (cl-ecase (tuple-elt ctl 1)
          ((1) ;; link: [1 FROM TO]
           (let ((from (tuple-elt ctl 2))
                 (to   (tuple-elt ctl 3)))
             (derl-trace-input "LINK: %S %S" from to)
             (add-to-list 'derl-remote-links (cons to from))
             (erl-add-link to from)))
          ((2) ;; send: [2 COOKIE TO-PID]
           (let ((to-pid (tuple-elt ctl 3)))
             (derl-trace-input "SEND: %S %S" to-pid req)
             (erl-send to-pid req)))
          ((3) ;; exit: [FROM TO REASON]
           (let ((from (tuple-elt ctl 1))
                 (to   (tuple-elt ctl 2))
                 (rsn  (tuple-elt ctl 3)))
             (derl-trace-input "EXIT: %S %S %S" from to rsn)
             (erl-send-exit from to rsn)))
          ((4) ;; unlink: [4 FROM TO]
           (let ((from (tuple-elt ctl 2))
                 (to   (tuple-elt ctl 3)))
             (derl-trace-input "UNLINK: %S %S %S" from to)
             (erl-remove-link to from)))
          ((6) ;; reg_send: [6 FROM COOKIE NAME]
           (let ((from (tuple-elt ctl 2))
                 (name (tuple-elt ctl 4)))
             (derl-trace-input "REG_SEND: %S %S %S" from name req)
             (condition-case data
                 (erl-send name req)
               (erl-exit-signal
                ;; Ignore the error if the name isn't registered -
                ;; that's what the real nodes do. Seems reasonable,
                ;; since the send is async, and who knows what the
                ;; sender is up to now.
                t))))))
      ;; Recursively handle other messages
      (fsm-event 'data 'continue))))

(defun derl-handle-tick ()
  (when (derl-have-tick)
    (derl-eat-msg)
    (derl-send-msg "")
    t))

(defun derl-have-tick ()
  (goto-char (point-min))
  (and (>= (buffer-size) derl-hdrlen)
       (= 0 (erlext-read4))))

;; ------------------------------------------------------------
;; Message buffer helpers
;; ------------------------------------------------------------

(defun derl-send-msg (string)
  "Send a message (with a length header)."
  (fsm-send-string (fsm-build-message
                     (fsm-encode (length string) derl-hdrlen)
                     (fsm-insert string))))

(defun derl-take-msg ()
  "Read and return a message, removing it from the input buffer. If no
complete message is available, nil is returned and the buffer isn't
modified."
  (when (derl-have-msg)
    (goto-char (point-min))
    (let* ((length (erlext-read derl-hdrlen))
           (start  (point))
           (end    (+ start length)))
      (prog1 (buffer-substring start end)
        (derl-eat-msg)))))

(defun derl-have-msg ()
  (goto-char (point-min))
  (when (>= (buffer-size) derl-hdrlen)
    (let ((len (erlext-read derl-hdrlen)))
      (>= (buffer-size) (+ derl-hdrlen len)))))

(defun derl-msg-end ()
  (goto-char (point-min))
  (+ (point-min) derl-hdrlen (erlext-read derl-hdrlen)))

(defun derl-eat-msg ()
  (delete-region (point-min) (derl-msg-end)))

;; ------------------------------------------------------------
;; Distributed erlang protocol requests
;; ------------------------------------------------------------

(defun derl-dist-request (node &rest request)
  "Make REQUEST to NODE. If the node isn't live, a connection is
initiated if necessary and the request is queued."
  (let ((derl-bufname (derl-buffer-name node)))
    (unless (get-buffer derl-bufname)
      (erl-connect node))
    (with-current-buffer derl-bufname
      (cond (derl-shutting-down
             nil)
            (derl-alive
             (derl-do-request request))
            (t
             (push request derl-request-queue))))))

(defun derl-do-request (req)
  (apply (car req) (cdr req)))

(defun derl-send (pid msg)
  (derl-trace-output "SEND: %S %S" pid msg)
  (derl-send-request (tuple 2 erlext-empty-symbol pid) msg))

(defun derl-reg-send (from to term)
  (derl-trace-output "REG_SEND: %S %S %S" from to term)
  (derl-send-request (tuple 6 from erlext-empty-symbol to) term))

(defun derl-link (from to)
  (derl-trace-output "LINK: %S %S" from to)
  (add-to-list 'derl-remote-links (cons from to))
  (derl-send-request (tuple 1 from to) nil t))

(defun derl-unlink (from to)
  (derl-trace-output "UNLINK: %S %S" from to)
  (derl-send-request (tuple 4 from to) nil t))

(defun derl-exit (from to reason)
  (derl-trace-output "EXIT: %S %S %S" from to reason)
  (derl-send-request (tuple 3 from to reason) nil t))

(defun derl-exit2 (from to reason)
  (derl-trace-output "EXIT2: %S %S %S" from to reason)
  (derl-send-request (tuple 8 from to reason) nil t))

(defun derl-send-request (control message &optional skip-message)
  (let* ((ctl (erlext-term-to-binary control))
         (msg (if skip-message "" (erlext-term-to-binary message)))
         (len (+ 1 (length ctl) (length msg))))
    (fsm-send-string
     (fsm-build-message
       (fsm-encode4 len)
       (fsm-encode1 121) ; type = pass-through (whatever that means..)
       (fsm-insert ctl)
       (fsm-insert msg)))))

;; Tracing

(defface derl-trace-output-face '((t (:inherit font-lock-string-face)))
  "Face for outgoing messages in the distributed erlang trace buffer."
  :group 'erl)

(defface derl-trace-input-face '((t (:inherit font-lock-comment-face)))
  "Face for incoming messages in the distributed erlang trace buffer."
  :group 'erl)

(defun derl-trace-output (fmt &rest args)
  (let ((msg (format ">> %s" (apply #'format (cons fmt args)))))
    (put-text-property 0 (length msg) 'face 'derl-trace-output-face msg)
    (derl-trace msg)))

(defun derl-trace-input (fmt &rest args)
  (let ((msg (format "<< %s" (apply #'format (cons fmt args)))))
    (put-text-property 0 (length msg) 'face 'derl-trace-input-face msg)
    (derl-trace msg)))

(defun derl-trace (string)
  (if derl-use-trace-buffer
      (with-current-buffer (get-buffer-create
                            (format "*trace %S*" derl-connection-node))
        (goto-char (point-max))
        (insert string)
        (insert "\n"))))

;; ------------------------------------------------------------
;; Utility
;; ------------------------------------------------------------

(defun derl-nodedown (node)
  (setq derl-shutting-down t)
  (dolist (link derl-remote-links)
    (let ((local  (car link))
          (remote (cdr link)))
      (message "LOCAL: %S REMOTE %S" local remote)
      (erl-send-exit remote local 'noconnection)))
  (run-hook-with-args 'erl-nodedown-hook node))

(defun derl-nodeup (node)
  ;; NB: only callable from the state machine
  (run-hook-with-args 'erl-nodeup-hook node fsm-process))

(defun derl-int32-to-decimal (s)
  "Converts a 32-bit number (represented as a 4-byte string) into its
decimal printed representation."
  (format "%.0f" (+ (+ (aref s 3) (* 256 (aref s 2)))
                    (* (+ 0.0 (aref s 1) (* 256 (aref s 0)))
                       65536))))

;; Try to establish whether we have enough precision in floating-point
;; The test is pretty lame, even if it succeeds we cannot be sure
;; it'll work for all int32's
;; alas, i'm too ignorant to write a good test
;; the previous version of the test was nicer, but FSFmacs-specific :<

(unless (string= "1819634533" (derl-int32-to-decimal "luke"))
  (error "Can't use Emacs's floating-point for `derl-int32-to-decimal'."))

(defun derl-hexstring-to-binstring (s)
  "Convert the hexidecimal string S into a binary number represented
as a string of octets."
  (let ((halves (mapcar #'derl-hexchar-to-int (string-to-list s))))
    (derl-merge-halves halves)))

(defun derl-merge-halves (halves &optional acc)
  (if (null halves)
      (apply #'string (reverse acc))
    (derl-merge-halves (cddr halves)
                       (cons (+ (ash (car halves) 4)
                                (cadr halves))
                             acc))))

(defun derl-hexchar-to-int (c)
  (cond ((and (<= ?0 c) (<= c ?9))
         (- c ?0))
        ((and (<= ?a c) (<= c ?f))
         (+ 10 (- c ?a)))
        (t
         (error "Not hexchar: %c" c))))

(defun derl-node-p (node)
  "Check if `node' is a node name, e.g. \"foo@bar\". The @ character
is not allowed in the node or host name."
  (and (symbolp node)
       (string-match "^[^@]+@[^@]+$" (symbol-name node))))

(defun derl-node-name (node)
  "Take the atom node part of a node name, e.g.
  (derl-node-name \"foo@bar\") => \"foo\""
  (cl-assert (derl-node-p node))
  (let ((string (symbol-name node)))
    (string-match "^[^@]+" string)
    (match-string 0 string)))

(defun derl-node-host (node)
  "Take the host part of a node name, e.g.
  (derl-node-host \"foo@bar\") => \"bar\""
  (cl-assert (derl-node-p node))
  (let ((string (symbol-name node)))
    (string-match "[^@]+$" string)
    (match-string 0 string)))

(defun derl-buffer-name (node)
  (format "*derl %s*" node))

;; ------------------------------------------------------------
;; Testing and playing around
;; ------------------------------------------------------------

(defun derl-go (port)
  (fsm-connect "localhost" port #'derl-state0
               nil
               (lambda (result)
                 (message "RESULT: %S" result))
               (lambda ()
                 (message "FAIL"))))

(provide 'derl)
;;; derl.el ends here
