maxbutt
=======

An Emacs client for [erlbutt](https://github.com/cmoid/erlbutt), the Erlang
implementation of the Secure Scuttlebutt (SSB) protocol. maxbutt talks to a
running erlbutt node over Erlang distribution (via [Distel][1]) and lets you
browse feeds and tangle threads, post and reply, follow/block, and manage the
node — all from Emacs.

Prerequisites
-------------

- **Erlang/OTP** with the bundled `erlang-mode` Emacs files (Distel needs them;
  they ship under `$(erl -eval 'io:format("~s/emacs",[code:lib_dir(tools)])' -s init stop -noshell)`).
- **Emacs 29+** (the autoloads target uses `loaddefs-generate`).
- **markdown-mode** — used to render post bodies. Install via your package
  manager (e.g. `M-x package-install RET markdown-mode`).
- A **running erlbutt node** reachable over distribution, with the maxbutt
  `.beam` files on its code path. For a local dev node, point erlbutt's
  `vm.args` at maxbutt's ebin, e.g. `-pa /path/to/maxbutt/ebin` (or set
  `SSB_EXTRA_PA`). The node's cookie must match the one Emacs uses (the erlbutt
  dev node defaults to `erlbutt`).

Build
-----

    make base      # erlang .beam + elisp .elc + maxbutt-autoloads.el
    make info      # build the Info manual (doc/maxbutt.info)
    make all       # base + info + postscript

Install
-------

    make install        # elisp/ebin/src -> $(prefix)/maxbutt/...
    make info_install   # Info manual -> $(prefix)/info, registered with install-info

`prefix` defaults to `~/.emacs.d` and is overridable:

    make install prefix=/usr/local/share/emacs/site-lisp

If your markdown-mode is not auto-detected from ELPA, point the build at it:

    make MARKDOWN_DIR=/path/to/markdown-mode base

Emacs configuration
-------------------

Add the installed elisp directory to `load-path`, load the autoloads, and run
Distel's setup. With the default `prefix`:

    (add-to-list 'load-path "~/.emacs.d/maxbutt/elisp")
    (require 'maxbutt-autoloads)   ; M-x ssb-browse-feed etc. become available
    (require 'distel)
    (distel-setup)

    ;; Point at your erlbutt node (this is the default).
    (setq ssb-node 'erlbutt@localhost)

    ;; So C-h i finds the manual.
    (add-to-list 'Info-additional-directory-list "~/.emacs.d/info")

`(require 'maxbutt-autoloads)` defers loading the package until you first invoke
a command; use `(require 'ssb-feed)` instead if you prefer to load it eagerly.

Connecting and using it
-----------------------

With the node running and `ssb-node` set, the entry commands are:

- `M-x ssb-browse-feed`   — browse a feed by its `@<pubkey>=.ed25519` id
- `M-x ssb-my-id`         — show the local node's own feed id
- `M-x ssb-following`     — list who a feed follows
- `M-x ssb-post`          — compose and publish a post
- `M-x ssb-dialer-toggle` — turn the node's automatic peer dialing on/off

Inside a feed buffer, `n`/`p` move between messages, `RET` opens one, `t` opens
its tangle thread, `f` browses an author's feed, `F`/`U`/`B` follow/unfollow/
block, and `W` lists who someone follows. See the Info manual (`C-h i`, then the
**Maxbutt** entry) or the commentary in `elisp/ssb-feed.el` for the full set.

Building a distribution
-----------------------

    make dist     # -> dist/maxbutt-<version>.tar.gz (+ .sha256)

produces a self-contained archive of the built elisp, erlang beams, source,
and the Info manual.

Origin
------

This code was originally forked from a branch of Distel, [otp-26][1]. The Erlang
folks had changed the term format, so Distel needed a few hacks to work again.

----
[1]: https://github.com/cmoid/distel/tree/otp-26
