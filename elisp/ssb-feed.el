;;; ssb-feed.el --- Browse SSB feeds via a local erlbutt node.

;;; Commentary:
;;
;; Provides commands for browsing SSB feeds and tangle threads via a running
;; erlbutt node connected through Erlang distribution (Distel).
;;
;; Prerequisites:
;;   - A running erlbutt node reachable via Erlang distribution.
;;   - The maxbutt.beam module loaded into that node.
;;   - distel connected to the node (M-x erl-choose-nodename).
;;     ssb-node is seeded automatically as the default node name.
;;
;; Feed browsing (ssb-feed-mode):
;;   M-x ssb-browse-feed  RET  @<pubkey>=.ed25519  RET  [limit RET]
;;   n / p   — step through messages.
;;   RET     — open the message at point in a window below.
;;   g       — refresh: refetch the feed and re-render the buffer.
;;   t       — open the tangle thread rooted at the message at point.
;;   f       — browse the feed of the author at point in its own buffer.
;;   F / U   — follow / unfollow the author at point.
;;   B       — block the author at point (asks for confirmation).
;;   W       — list who the author at point (or this feed) follows;
;;             falls back to the local node's own follows (ssb-following).
;;
;; Following list (ssb-following-mode):
;;   One line per followed feed, profile name first when known.
;;   n / p   — step through entries.
;;   RET / f — browse the feed at point.
;;   W       — drill into who the feed at point follows.
;;   g       — refresh the list.
;;   U / B   — unfollow / block the feed at point.
;;
;; Thread navigation (ssb-thread-mode):
;;   The thread buffer shows {Author, MsgKey} entries indented by depth.
;;   Message content is fetched lazily — only when you ask for it.
;;   n / p   — step through thread entries.
;;   RET     — fetch and display the message at point in a window below.
;;   c / t   — collapse or expand the subtree at point in place.
;;   f       — browse the feed of the author at point in its own buffer.

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
    (erl-rpc #'ssb--display-feed (list feed-id n)
             ssb-node
             'maxbutt 'browse_feed
             (list (erl-binary feed-id) n))))

(defvar-local ssb--feed-id nil
  "Feed id shown in this buffer, used by `ssb-refresh-feed'.")

(defvar-local ssb--feed-limit nil
  "Message limit used to fetch this buffer's feed.")

(defun ssb-refresh-feed ()
  "Refetch the feed shown in the current buffer and re-render it."
  (interactive)
  (if (not ssb--feed-id)
      (message "No feed to refresh")
    (message "Refreshing %s..." (ssb--short-id ssb--feed-id))
    (ssb-browse-feed ssb--feed-id ssb--feed-limit)))

(defun ssb-my-id ()
  "Show the local erlbutt node's own feed ID in the minibuffer."
  (interactive)
  (erl-rpc (lambda (reply)
             (message "My ID: %s" reply))
           nil
           ssb-node
           'maxbutt 'my_id '()))

(defun ssb-following (&optional feed-id)
  "List the feeds FEED-ID follows, with profile names.
Interactively, FEED-ID is the author at point when there is one, else
the feed shown in the current buffer; with neither (e.g. M-x from an
unrelated buffer) it falls back to the local node's own feed."
  (interactive (list (or (ssb--author-at-point) ssb--feed-id)))
  (if feed-id
      (erl-rpc #'ssb--display-following (list feed-id)
               ssb-node 'maxbutt 'following (list (erl-binary feed-id)))
    (erl-rpc #'ssb--display-following nil
             ssb-node 'maxbutt 'following '())))

(defun ssb-refresh-following ()
  "Refetch the following list shown in the current buffer."
  (interactive)
  (ssb-following ssb--feed-id))

(defun ssb--display-following (reply &optional feed-id)
  "Render REPLY (from maxbutt:following/0,1) into the *ssb-following* buffer.
Each entry is a {FeedId, Name} tuple; Name is the symbol `undefined'
when the feed has not set a profile name.  FEED-ID is the queried feed,
nil for the local node's own."
  (let ((buf (get-buffer-create "*ssb-following*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Following: " (or feed-id "(this node)") "\n")
        (insert (make-string 72 ?-) "\n\n")
        (if (null reply)
            (insert "(not following anyone)\n")
          (dolist (entry reply)
            (let* ((id    (elt entry 0))
                   (name  (elt entry 1))
                   (label (if (and (stringp name) (not (string= name "")))
                              (decode-coding-string name 'utf-8 t)
                            ""))
                   (start (point)))
              (insert (format "%-24s %s\n" label id))
              (put-text-property start (1- (point)) 'ssb-author id))))
        ;; The major-mode switch kills buffer-locals, so set them after it.
        (ssb-following-mode)
        (setq ssb--feed-id feed-id)
        (goto-char (point-min))))
    (pop-to-buffer buf)))

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

(defun ssb--display-feed (reply feed-id &optional limit)
  "Render REPLY (from maxbutt:browse_feed) into a feed buffer.
LIMIT is remembered buffer-locally so `ssb-refresh-feed' can refetch."
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
        ;; The major-mode switch kills buffer-locals, so set them after it.
        (ssb-feed-mode)
        (setq ssb--feed-id feed-id
              ssb--feed-limit limit)
        (goto-char (point-min))))
    (pop-to-buffer buf))
  ;; Fetch the profile name asynchronously and update the header.
  ;; The file is dynamically bound, so the callback cannot close over
  ;; feed-id — pass it through erl-rpc's callback args instead.
  (erl-rpc (lambda (name fid) (ssb--update-feed-header fid name))
           (list feed-id) ssb-node 'maxbutt 'profile_name
           (list (erl-binary feed-id))))

(defun ssb--update-feed-header (feed-id name)
  "Insert NAME into the feed buffer header for FEED-ID."
  (when (and name (not (eq name 'undefined)) (not (string= name "")))
    (let ((buf (get-buffer (format "*ssb %s*" (ssb--short-id feed-id)))))
      (when buf
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (save-excursion
              (goto-char (point-min))
              (when (re-search-forward "^Feed: " nil t)
                (end-of-line)
                (insert (format "  [%s]" (decode-coding-string name 'utf-8 t)))))))))))

(defun ssb--author-at-point ()
  "Author id of the entry on the current line, or nil.
Falls back to the line start so the command works with point anywhere
on the line, including at end of line where the property is absent."
  (let ((author (or (get-text-property (point) 'ssb-author)
                    (get-text-property (line-beginning-position) 'ssb-author))))
    (and (stringp author) author)))

(defun ssb-browse-author-feed ()
  "Browse the feed of the author on the current line in its own buffer."
  (interactive)
  (let ((author (ssb--author-at-point)))
    (if author
        (ssb-browse-feed author ssb-browse-limit)
      (message "No author at point"))))

(defun ssb--insert-msg (msg)
  "Insert one {Seq, Key, Author, ContentJson} tuple into the current buffer.
Stores content, parsed content, key, author, and seq as text properties."
  ;; erlext decodes {Seq, Key, Author, ContentJson} as a plain 0-indexed vector.
  ;; Binaries arrive as plain elisp strings — no erl-binary wrapper.
  (let* ((seq     (elt msg 0))
         (key     (elt msg 1))
         (author  (elt msg 2))
         (content (elt msg 3))
         (parsed  (ssb--parse-content content))
         (snippet (ssb--content-snippet parsed content))
         (start   (point)))
    (insert (format "[%5d] %s\n" seq snippet))
    (put-text-property start (1- (point)) 'ssb-content content)
    (put-text-property start (1- (point)) 'ssb-parsed  parsed)
    (put-text-property start (1- (point)) 'ssb-seq     seq)
    (put-text-property start (1- (point)) 'ssb-key     key)
    (put-text-property start (1- (point)) 'ssb-author  author)))

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
  "Open the tangle thread rooted at the message under point.
Fetches the tree structure only — no message content is loaded yet.
Use RET on a thread entry to fetch and display its content.
Use c or t to collapse/expand subtrees in place."
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
  "Insert one {Key, Author, Name, Depth} tuple into the thread buffer.
Also handles legacy 3-tuple {Key, Author, Depth} from older beam.
ROOT-KEY is the tangle root, stored so sub-thread navigation works."
  (let* ((key      (elt entry 0))
         (author   (elt entry 1))
         (has-name (> (length entry) 3))
         (name     (when has-name (elt entry 2)))
         (depth    (if has-name (elt entry 3) (elt entry 2)))
         (label    (if (and (stringp name) (not (string= name "")))
                       (decode-coding-string name 'utf-8 t)
                     (ssb--short-id author)))
         (indent (make-string (* depth 2) ?\s))
         (start  (point)))
    (insert (format "%s[%s] %s\n" indent label (ssb--short-id key)))
    (put-text-property start (1- (point)) 'ssb-key         key)
    (put-text-property start (1- (point)) 'ssb-author      author)
    (put-text-property start (1- (point)) 'ssb-depth       depth)
    (put-text-property start (1- (point)) 'ssb-tangle-root root-key)))

(defun ssb--show-thread-current-message ()
  "Fetch and display the message at point in a window below."
  (interactive)
  (let ((key (get-text-property (point) 'ssb-key)))
    (when key
      (erl-rpc #'ssb--display-thread-msg nil
               ssb-node 'maxbutt 'get_msg_text
               (list (erl-binary key))))))

(defun ssb--display-thread-msg (reply)
  "Display message text REPLY in a split window below."
  (let ((buf (get-buffer-create "*ssb-message*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (if (or (null reply) (string= reply "")) "(no text)" reply))
        (markdown-mode)
        (setq buffer-read-only t)
        (goto-char (point-min))))
    (display-buffer buf '(display-buffer-below-selected
                          (window-height . 0.4)))))

(defun ssb-toggle-collapse ()
  "Collapse or expand the subtree at point in the thread buffer.
Bound to both c and t in ssb-thread-mode.  The cursor stays at point."
  (interactive)
  (let ((depth (get-text-property (point) 'ssb-depth)))
    (when depth
      (let* ((collapsed (get-text-property (point) 'ssb-collapsed))
             (new-state (not collapsed)))
        (let ((inhibit-read-only t))
          (put-text-property (line-beginning-position) (line-end-position)
                             'ssb-collapsed new-state))
        (save-excursion
          (forward-line 1)
          (while (and (not (eobp))
                      (let ((d (get-text-property (point) 'ssb-depth)))
                        (and d (> d depth))))
            (let ((inhibit-read-only t))
              (put-text-property (line-beginning-position)
                                 (min (1+ (line-end-position)) (point-max))
                                 'invisible new-state))
            (forward-line 1)))))))

(defun ssb--text-snippet (text)
  "Return a single-line display snippet from TEXT, truncated to 72 chars."
  (let* ((first-line (car (split-string (or text "") "[\n\r]+" t)))
         (max 72))
    (if (and first-line (> (length first-line) max))
        (concat (substring first-line 0 max) "…")
      (or first-line "(no text)"))))

;;; Compose

(defvar-local ssb--compose-action nil
  "Action to perform on send: symbol `post' or `reply'.")

(defvar-local ssb--compose-root-key nil
  "Tangle root key for `reply' actions.")

(defvar-local ssb--compose-start nil
  "Marker pointing to the start of user-editable text in the compose buffer.")

(define-minor-mode ssb-compose-mode
  "Minor mode for composing SSB posts and replies.
\\{ssb-compose-mode-map}"
  :lighter " SSB-Compose"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") #'ssb-compose-send)
            (define-key map (kbd "C-c C-k") #'ssb-compose-cancel)
            map))

(defun ssb--open-compose-buffer (action &optional root-key header)
  "Open the *ssb-compose* buffer for ACTION (`post' or `reply').
ROOT-KEY is required for replies.  HEADER is shown read-only at the top."
  (let ((buf (get-buffer-create "*ssb-compose*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (text-mode)
        (ssb-compose-mode 1)
        (setq ssb--compose-action action
              ssb--compose-root-key root-key)
        (when header
          (insert header "\n" (make-string 72 ?-) "\n")
          (add-text-properties (point-min) (point)
                               '(read-only t front-sticky (read-only)
                                 rear-nonsticky (read-only))))
        (setq ssb--compose-start (point-marker))
        (goto-char (point-max))))
    (pop-to-buffer buf)))

(defun ssb-post ()
  "Compose and publish a new SSB post."
  (interactive)
  (ssb--open-compose-buffer 'post nil
    "New post  (C-c C-c to send, C-c C-k to cancel)"))

(defun ssb-reply ()
  "Compose a reply to the message at point."
  (interactive)
  (let ((key (get-text-property (point) 'ssb-key)))
    (if (not key)
        (message "No message key at point")
      (ssb--open-compose-buffer
       'reply key
       (format "Replying to %s  (C-c C-c to send, C-c C-k to cancel)"
               (ssb--short-id key))))))

(defun ssb-compose-send ()
  "Send the composed text to the erlbutt node."
  (interactive)
  (let* ((text   (string-trim
                  (buffer-substring-no-properties ssb--compose-start (point-max))))
         (action ssb--compose-action)
         (root   ssb--compose-root-key))
    (when (string= text "") (user-error "Nothing to send"))
    (pcase action
      ('post
       (erl-rpc #'ssb--compose-sent nil ssb-node 'maxbutt 'post
                (list (erl-binary text))))
      ('reply
       (erl-rpc #'ssb--compose-sent nil ssb-node 'maxbutt 'reply
                (list (erl-binary root) (erl-binary text))))
      (_ (user-error "Unknown compose action: %s" action)))))

(defun ssb--compose-sent (reply)
  "Handle the RPC reply after a post or reply is published."
  (if (and (vectorp reply) (eq (elt reply 0) 'ok))
      (progn
        (message "Published: %s" (elt reply 1))
        (kill-buffer "*ssb-compose*"))
    (message "Publish failed: %s" reply)))

(defun ssb-compose-cancel ()
  "Discard the compose buffer without sending."
  (interactive)
  (kill-buffer (current-buffer)))

;;; Social actions

(defun ssb-follow ()
  "Follow the author at point."
  (interactive)
  (let ((author (ssb--author-at-point)))
    (if (not author)
        (message "No author at point")
      (erl-rpc (lambda (reply) (message "Followed: %s" (elt reply 1)))
               nil ssb-node 'maxbutt 'follow
               (list (erl-binary author))))))

(defun ssb-unfollow ()
  "Unfollow the author at point."
  (interactive)
  (let ((author (ssb--author-at-point)))
    (if (not author)
        (message "No author at point")
      (erl-rpc (lambda (reply) (message "Unfollowed: %s" (elt reply 1)))
               nil ssb-node 'maxbutt 'unfollow
               (list (erl-binary author))))))

(defun ssb-block ()
  "Block the author at point (asks for confirmation)."
  (interactive)
  (let ((author (ssb--author-at-point)))
    (if (not author)
        (message "No author at point")
      (when (yes-or-no-p (format "Block %s? " (ssb--short-id author)))
        (erl-rpc (lambda (reply) (message "Blocked: %s" (elt reply 1)))
                 nil ssb-node 'maxbutt 'block
                 (list (erl-binary author)))))))

(defun ssb-vote-like ()
  "Send a +1 like vote for the message at point."
  (interactive)
  (let ((key (get-text-property (point) 'ssb-key)))
    (if (not key)
        (message "No message key at point")
      (erl-rpc (lambda (reply) (message "Liked: %s" (elt reply 1)))
               nil ssb-node 'maxbutt 'vote
               (list (erl-binary key) 1)))))

(defun ssb-vote-unlike ()
  "Send a -1 unlike vote for the message at point."
  (interactive)
  (let ((key (get-text-property (point) 'ssb-key)))
    (if (not key)
        (message "No message key at point")
      (erl-rpc (lambda (reply) (message "Unliked: %s" (elt reply 1)))
               nil ssb-node 'maxbutt 'vote
               (list (erl-binary key) -1)))))

;;; Major mode

(define-derived-mode ssb-feed-mode special-mode "SSB-Feed"
  "Major mode for viewing SSB feed messages.
\\{ssb-feed-mode-map}")

(let ((map ssb-feed-mode-map))
  (define-key map (kbd "n")   #'ssb-next-message)
  (define-key map (kbd "p")   #'ssb-prev-message)
  (define-key map (kbd "RET") #'ssb--show-current-message)
  (define-key map (kbd "g")   #'ssb-refresh-feed)
  (define-key map (kbd "t")   #'ssb-show-thread)
  (define-key map (kbd "f")   #'ssb-browse-author-feed)
  (define-key map (kbd "r")   #'ssb-reply)
  (define-key map (kbd "+")   #'ssb-vote-like)
  (define-key map (kbd "-")   #'ssb-vote-unlike)
  (define-key map (kbd "F")   #'ssb-follow)
  (define-key map (kbd "U")   #'ssb-unfollow)
  (define-key map (kbd "B")   #'ssb-block)
  (define-key map (kbd "W")   #'ssb-following))

(define-derived-mode ssb-thread-mode special-mode "SSB-Thread"
  "Major mode for viewing a Plumtree/tangle discussion thread.
\\{ssb-thread-mode-map}")

(let ((map ssb-thread-mode-map))
  (define-key map (kbd "n")   #'ssb-next-message)
  (define-key map (kbd "p")   #'ssb-prev-message)
  (define-key map (kbd "RET") #'ssb--show-thread-current-message)
  (define-key map (kbd "c")   #'ssb-toggle-collapse)
  (define-key map (kbd "t")   #'ssb-toggle-collapse)
  (define-key map (kbd "f")   #'ssb-browse-author-feed)
  (define-key map (kbd "r")   #'ssb-reply)
  (define-key map (kbd "+")   #'ssb-vote-like)
  (define-key map (kbd "-")   #'ssb-vote-unlike)
  (define-key map (kbd "F")   #'ssb-follow)
  (define-key map (kbd "U")   #'ssb-unfollow)
  (define-key map (kbd "B")   #'ssb-block)
  (define-key map (kbd "W")   #'ssb-following))

(define-derived-mode ssb-following-mode special-mode "SSB-Following"
  "Major mode for the list of feeds the local node follows.
\\{ssb-following-mode-map}")

(let ((map ssb-following-mode-map))
  (define-key map (kbd "n")   #'next-line)
  (define-key map (kbd "p")   #'previous-line)
  (define-key map (kbd "RET") #'ssb-browse-author-feed)
  (define-key map (kbd "f")   #'ssb-browse-author-feed)
  (define-key map (kbd "g")   #'ssb-refresh-following)
  (define-key map (kbd "W")   #'ssb-following)
  (define-key map (kbd "U")   #'ssb-unfollow)
  (define-key map (kbd "B")   #'ssb-block))

(provide 'ssb-feed)
;;; ssb-feed.el ends here

;; Local Variables:
;; byte-compile-warnings: (not free-vars)
;; End:
