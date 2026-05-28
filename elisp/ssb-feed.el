;;; ssb-feed.el --- Browse SSB feeds via a local erlbutt node.

;;; Commentary:
;;
;; Provides `ssb-browse-feed', an interactive command that fetches messages
;; from a feed stored in a running erlbutt node and displays them in a
;; read-only buffer.
;;
;; Prerequisites:
;;   - A running erlbutt node reachable via Erlang distribution.
;;   - The maxbutt.beam module loaded into that node.
;;   - distel connected to the node (M-x erl-choose-nodename).
;;
;; Usage:
;;   M-x ssb-browse-feed  RET  @<pubkey>=.ed25519  RET
;;   n / p   — step through messages; selected message opens below.
;;   RET     — open the message under point.

(require 'erl)
(require 'erl-service)
(require 'markdown-mode)

;;; Customization

(defgroup maxbutt nil
  "Emacs client for the SSB protocol via a local erlbutt node."
  :prefix "ssb-"
  :group 'applications
  :link '(info-link "(maxbutt)Top"))

(defun ssb--set-node (sym val)
  "Set `ssb-node' to VAL and seed `erl-nodename-cache' so C-c C-d n defaults to it."
  (set-default sym val)
  (when (boundp 'erl-nodename-cache)
    (setq erl-nodename-cache val)))

(defcustom ssb-node 'erlbutt@localhost
  "Erlang node name of the running erlbutt instance.
Must match the sname used when starting the erlbutt release,
e.g. erlbutt@localhost for a local dev node."
  :type 'symbol
  :group 'maxbutt
  :set #'ssb--set-node)

(defcustom ssb-browse-limit 2000
  "Default number of messages to fetch per `ssb-browse-feed' call.
Can be overridden interactively when invoking the command."
  :type 'integer
  :group 'maxbutt)

;;; Public commands

(defun ssb-browse-feed (feed-id &optional limit)
  "Browse the SSB feed FEED-ID from the local erlbutt node.
FEED-ID should be the full @<pubkey>=.ed25519 string.
LIMIT defaults to `ssb-browse-limit'; prompts interactively for both."
  (interactive
   (list (read-string "SSB Feed ID (@...=.ed25519): ")
         (read-number "Message limit: " ssb-browse-limit)))
  (let ((n (or limit ssb-browse-limit)))
    (erl-rpc #'ssb--display-feed (list feed-id)
             ssb-node
             'maxbutt 'browse_feed
             (list (erl-binary feed-id) n))))

(defun ssb-my-id ()
  "Show the local erlbutt node's own feed ID in the minibuffer."
  (interactive)
  (erl-rpc (lambda (reply)
             (message "My ID: %s" reply))
           nil
           ssb-node
           'maxbutt 'my_id '()))

;;; Navigation

(defun ssb-next-message ()
  "Move to the next message line and display its content below."
  (interactive)
  (forward-line 1)
  (ssb--show-current-message))

(defun ssb-prev-message ()
  "Move to the previous message line and display its content below."
  (interactive)
  (forward-line -1)
  (ssb--show-current-message))

(defun ssb--show-current-message ()
  "Display the full content of the message at point in a window below."
  (interactive)
  (let ((parsed (get-text-property (point) 'ssb-parsed))
        (content (get-text-property (point) 'ssb-content))
        (seq     (get-text-property (point) 'ssb-seq)))
    (when content
      (ssb--show-message seq content parsed))))

(defun ssb--show-message (seq content parsed)
  "Render message SEQ in a split window below.
Shows the text field as markdown when available, raw JSON otherwise."
  (let* ((text (and parsed (alist-get 'text parsed)))
         (buf (get-buffer-create "*ssb-message*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Message [%d]\n" seq))
        (insert (make-string 72 ?-) "\n\n")
        (if text
            (insert text)
          (let ((json-start (point)))
            (insert content)
            (when (fboundp 'json-pretty-print)
              (ignore-errors (json-pretty-print json-start (point))))))
        (if text
            (markdown-mode)
          (special-mode))
        (setq buffer-read-only t)
        (goto-char (point-min))))
    (display-buffer buf '(display-buffer-below-selected
                          (window-height . 0.4)))))

;;; Internal — RPC callback and rendering

(defun ssb--display-feed (reply feed-id)
  "Render REPLY (from maxbutt:browse_feed) into a feed buffer."
  (let ((buf (get-buffer-create (format "*ssb %s*" (ssb--short-id feed-id)))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Feed: " feed-id "\n")
        (insert (make-string 72 ?-) "\n\n")
        (cond
         ((ssb--error-p reply)
          (insert "Error: feed not found\n"))
         ((null reply)
          (insert "(no messages)\n"))
         (t
          (dolist (msg reply)
            (ssb--insert-msg msg))))
        (ssb-feed-mode)
        (goto-char (point-min))))
    (pop-to-buffer buf)))

(defun ssb--insert-msg (msg)
  "Insert one {Seq, Key, Author, ContentJson} tuple into the current buffer.
Stores content, parsed content, key, and seq as text properties for navigation."
  ;; erlext decodes {Seq, Key, Author, ContentJson} as a plain 0-indexed vector.
  ;; Binaries arrive as plain elisp strings — no erl-binary wrapper.
  (let* ((seq     (elt msg 0))
         (key     (elt msg 1))
         (content (elt msg 3))
         (parsed  (ssb--parse-content content))
         (snippet (ssb--content-snippet parsed content))
         (start   (point)))
    (insert (format "[%5d] %s\n" seq snippet))
    (put-text-property start (1- (point)) 'ssb-content content)
    (put-text-property start (1- (point)) 'ssb-parsed  parsed)
    (put-text-property start (1- (point)) 'ssb-seq     seq)
    (put-text-property start (1- (point)) 'ssb-key     key)))

(defun ssb--error-p (reply)
  "True if REPLY is an {error, Reason} tuple from maxbutt."
  (and (vectorp reply)
       (> (length reply) 0)
       (eq (elt reply 0) 'error)))

(defun ssb--parse-content (json-str)
  "Parse JSON-STR and return an alist of content fields, or nil on failure."
  (condition-case nil
      (json-parse-string json-str :object-type 'alist)
    (error nil)))

(defun ssb--content-snippet (parsed json-str)
  "Return a single-line display snippet.
Uses the first line of the text field from PARSED when available,
falls back to collapsing JSON-STR to one line."
  (let* ((text (and parsed (alist-get 'text parsed)))
         (source (or text json-str))
         (first-line (car (split-string source "[\n\r]+" t)))
         (max 72))
    (if (and first-line (> (length first-line) max))
        (concat (substring first-line 0 max) "…")
      (or first-line ""))))

(defun ssb--short-id (feed-id)
  "Return a short prefix of FEED-ID for use in buffer names."
  (substring feed-id 0 (min 16 (length feed-id))))

;;; Thread tracing

(defun ssb-show-thread ()
  "Show the tangle thread rooted at the message under point.
In a thread buffer, uses the stored tangle root so descendants are found correctly."
  (interactive)
  (let ((key      (get-text-property (point) 'ssb-key))
        (root-key (get-text-property (point) 'ssb-tangle-root)))
    (cond
     ((not key)
      (message "No message key at point"))
     (root-key
      ;; Inside a thread: show sub-thread from this message using the tangle root.
      (erl-rpc #'ssb--display-thread (list key)
               ssb-node
               'maxbutt 'thread_from
               (list (erl-binary key) (erl-binary root-key))))
     (t
      ;; Top-level feed: this message IS the tangle root.
      (erl-rpc #'ssb--display-thread (list key)
               ssb-node
               'maxbutt 'thread
               (list (erl-binary key)))))))

(defun ssb--display-thread (reply key)
  "Render REPLY (from maxbutt:thread/1 or thread_from/2) into a thread buffer.
KEY is the tangle root used for sub-thread navigation."
  (let* ((root-key (or (and (get-text-property (point) 'ssb-tangle-root)
                            (get-text-property (point) 'ssb-tangle-root))
                       key))
         (buf (get-buffer-create (format "*ssb-thread %s*" (ssb--short-id key)))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Thread: " key "\n")
        (insert (make-string 72 ?-) "\n\n")
        (cond
         ((null reply)
          (insert "(no replies)\n"))
         (t
          (dolist (entry (if (vectorp reply) (list reply) reply))
            (ssb--insert-thread-entry entry root-key))))
        (ssb-thread-mode)
        (goto-char (point-min))))
    (pop-to-buffer buf)))

(defun ssb--insert-thread-entry (entry root-key)
  "Insert one {Key, Author, Text, Depth} tuple into the thread buffer.
ROOT-KEY is the tangle root, stored so sub-thread navigation works."
  ;; 0-indexed: Key=0, Author=1, Text=2, Depth=3
  (let* ((key     (elt entry 0))
         (author  (elt entry 1))
         (text    (elt entry 2))
         (depth   (elt entry 3))
         (indent  (make-string (* depth 2) ?\s))
         (snippet (ssb--text-snippet text))
         (start   (point)))
    (insert (format "%s[%s] %s\n" indent (ssb--short-id author) snippet))
    (put-text-property start (1- (point)) 'ssb-key         key)
    (put-text-property start (1- (point)) 'ssb-content     text)
    (put-text-property start (1- (point)) 'ssb-depth       depth)
    (put-text-property start (1- (point)) 'ssb-tangle-root root-key)))

(defun ssb--show-thread-current-message ()
  "Display the full text of the thread entry at point in a window below."
  (interactive)
  (let ((text (get-text-property (point) 'ssb-content))
        (key  (get-text-property (point) 'ssb-key)))
    (when text
      (let ((buf (get-buffer-create "*ssb-message*")))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (when key
              (insert (format "Key: %s\n" key))
              (insert (make-string 72 ?-) "\n\n"))
            (insert (if (string= text "") "(no text)" text))
            (markdown-mode)
            (setq buffer-read-only t)
            (goto-char (point-min))))
        (display-buffer buf '(display-buffer-below-selected
                              (window-height . 0.4)))))))

(defun ssb--text-snippet (text)
  "Return a single-line display snippet from TEXT, truncated to 72 chars."
  (let* ((first-line (car (split-string (or text "") "[\n\r]+" t)))
         (max 72))
    (if (and first-line (> (length first-line) max))
        (concat (substring first-line 0 max) "…")
      (or first-line "(no text)"))))

;;; Major mode

(define-derived-mode ssb-feed-mode special-mode "SSB-Feed"
  "Major mode for viewing SSB feed messages.
\\{ssb-feed-mode-map}")

(let ((map ssb-feed-mode-map))
  (define-key map (kbd "n")   #'ssb-next-message)
  (define-key map (kbd "p")   #'ssb-prev-message)
  (define-key map (kbd "RET") #'ssb--show-current-message)
  (define-key map (kbd "t")   #'ssb-show-thread))

(define-derived-mode ssb-thread-mode special-mode "SSB-Thread"
  "Major mode for viewing a Plumtree/tangle discussion thread.
\\{ssb-thread-mode-map}")

(let ((map ssb-thread-mode-map))
  (define-key map (kbd "n")   #'ssb-next-message)
  (define-key map (kbd "p")   #'ssb-prev-message)
  (define-key map (kbd "RET") #'ssb--show-thread-current-message)
  (define-key map (kbd "t")   #'ssb-show-thread))

(provide 'ssb-feed)
;;; ssb-feed.el ends here

;; Local Variables:
;; byte-compile-warnings: (not free-vars)
;; End:
