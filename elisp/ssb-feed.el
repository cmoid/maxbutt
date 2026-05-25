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

;;; Configuration

(defvar ssb-node 'erlbutt@localhost
  "Erlang node name of the running erlbutt instance.")

(defvar ssb-browse-limit 20
  "Number of messages to fetch per `ssb-browse-feed' call.")

;;; Public commands

(defun ssb-browse-feed (feed-id)
  "Browse the SSB feed FEED-ID from the local erlbutt node.
FEED-ID should be the full @<pubkey>=.ed25519 string.
Prompts interactively if called with M-x."
  (interactive "sSSB Feed ID (@...=.ed25519): ")
  (erl-rpc #'ssb--display-feed (list feed-id)
           ssb-node
           'maxbutt 'browse_feed
           (list (erl-binary feed-id) ssb-browse-limit)))

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
  (let ((content (get-text-property (point) 'ssb-content))
        (seq     (get-text-property (point) 'ssb-seq)))
    (when content
      (ssb--show-message seq content))))

(defun ssb--show-message (seq content)
  "Render the full JSON CONTENT of message SEQ in a split window below."
  (let ((buf (get-buffer-create "*ssb-message*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Message [%d]\n" seq))
        (insert (make-string 72 ?-) "\n\n")
        (let ((json-start (point)))
          (insert content)
          (when (fboundp 'json-pretty-print)
            (ignore-errors (json-pretty-print json-start (point)))))
        (special-mode)
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
  "Insert one {Seq, Author, ContentJson} tuple into the current buffer.
Stores full content and seq as text properties for navigation."
  ;; erlext decodes {Seq, Author, ContentJson} as a plain 0-indexed vector.
  ;; Binaries arrive as plain elisp strings — no erl-binary wrapper.
  (let* ((seq     (elt msg 0))
         (content (elt msg 2))
         (snippet (ssb--content-snippet content))
         (start   (point)))
    (insert (format "[%5d] %s\n" seq snippet))
    (put-text-property start (1- (point)) 'ssb-content content)
    (put-text-property start (1- (point)) 'ssb-seq seq)))

(defun ssb--error-p (reply)
  "True if REPLY is an {error, Reason} tuple from maxbutt."
  (and (vectorp reply)
       (> (length reply) 0)
       (eq (elt reply 0) 'error)))

(defun ssb--content-snippet (json-str)
  "Return a single-line display snippet from JSON-STR."
  (let* ((oneline (replace-regexp-in-string "[\n\r]+" " " json-str))
         (max 72))
    (if (> (length oneline) max)
        (concat (substring oneline 0 max) "…")
      oneline)))

(defun ssb--short-id (feed-id)
  "Return a short prefix of FEED-ID for use in buffer names."
  (substring feed-id 0 (min 16 (length feed-id))))

;;; Major mode

(define-derived-mode ssb-feed-mode special-mode "SSB-Feed"
  "Major mode for viewing SSB feed messages.
\\{ssb-feed-mode-map}")

(let ((map ssb-feed-mode-map))
  (define-key map (kbd "n")   #'ssb-next-message)
  (define-key map (kbd "p")   #'ssb-prev-message)
  (define-key map (kbd "RET") #'ssb--show-current-message))

(provide 'ssb-feed)
;;; ssb-feed.el ends here

;; Local Variables:
;; byte-compile-warnings: (not free-vars)
;; End:
