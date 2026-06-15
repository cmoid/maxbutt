PACKAGE := maxbutt
VERSION := $(shell git describe --tags --always 2>/dev/null || echo dev)

DIST     := dist
DISTNAME := ${PACKAGE}-${VERSION}

## Install location.  Override on the command line, e.g.
##   make install prefix=/usr/local/share/emacs/site-lisp
prefix      ?= $(HOME)/.emacs.d
exec_prefix = ${prefix}
bindir      = ${exec_prefix}/bin
datadir     = ${prefix}
infodir     = ${prefix}/info
erlc        = erlc
emacs       = emacs

## markdown-mode is an external build dependency of ssb-feed.el (byte-compile
## needs it on the load path).  Auto-detect an ELPA install, else fall back to a
## manual checkout; override with `make MARKDOWN_DIR=/path/to/markdown-mode`.
MARKDOWN_DIR ?= $(firstword $(wildcard $(HOME)/.emacs.d/elpa/markdown-mode-*) \
                            $(HOME)/code/emacs-ext/markdown-mode)

ELISP_DIR   = ${datadir}/maxbutt/elisp
EBIN_DIR    = ${datadir}/maxbutt/ebin
ERL_SRC_DIR = ${datadir}/maxbutt/src

########################################
## Main part

ERL_SRC := $(wildcard src/*.erl)
ERL_OBJ := $(patsubst src/%.erl,ebin/%.beam,${ERL_SRC})

ELISP_SRC := $(wildcard elisp/*.el)
ELISP_OBJ := $(patsubst %.el,%.elc,${ELISP_SRC})

## Compile in explicit dependency order to avoid stale .elc loading issues.
ELISP_COMPILE_ORDER := \
	elisp/mcase.el \
	elisp/erlext.el \
	elisp/epmd.el \
	elisp/net-fsm.el \
	elisp/erl.el \
	elisp/erl-service.el \
	elisp/derl.el \
	elisp/distel.el \
	elisp/distel-debug.el \
	elisp/distel-ie.el \
	elisp/erl-example.el \
	elisp/erl-test.el \
	elisp/ssb-feed.el

ELISP_SOME_SRC := $(filter-out elisp/maxbutt%.el,${ELISP_SRC})
ELISP_SOME_OBJ := $(patsubst %.el,%.elc,${ELISP_SOME_SRC})

## Generated autoloads (maxbutt% is filtered out of byte-compilation above).
AUTOLOADS := elisp/maxbutt-autoloads.el

## Erlang tools emacs dir (for erlang-mode, needed by distel et al.)
ERLANG_EMACS_DIR := $(shell erl -eval 'io:format("~s/emacs",[code:lib_dir(tools)])' -s init stop -noshell 2>/dev/null)

DOC_SRC  := doc/maxbutt.texi
INFO_OBJ := doc/maxbutt.info
PS_OBJ   := doc/maxbutt.ps

OBJECTS := ${ERL_OBJ} ${ELISP_OBJ} ${INFO_OBJ} ${PS_OBJ} ${AUTOLOADS}

base: ebin ${ERL_OBJ} ${ELISP_SOME_OBJ} ${AUTOLOADS}
many: ebin ${ERL_OBJ} ${ELISP_OBJ} ${AUTOLOADS}
info: ${INFO_OBJ}
erl: ${ERL_OBJ}
autoloads: ${AUTOLOADS}
postscript: ${PS_OBJ}
all: base info postscript
ebin:
	mkdir ebin

########################################
## Rules
.PHONY: release release_patch release_minor release_major

release: release_patch

release_major:
	./release.sh major

release_minor:
	./release.sh minor

release_patch:
	./release.sh patch

## Erlang
ebin/%.beam: src/%.erl
	${erlc} -W -o ebin +debug_info $<

## Elisp — compile all in one session, in dependency order, without loading
## ~/.emacs (which would pull in stale .elc files and corrupt doc-string offsets).
${ELISP_SOME_OBJ}: ${ELISP_SOME_SRC}
	rm -f elisp/*.elc
	${emacs} -batch \
		-L "${ERLANG_EMACS_DIR}" \
		-L elisp \
		-L "${MARKDOWN_DIR}" \
		--eval "(require 'erlang-start)" \
		--eval "(setq byte-compile-dynamic-docstrings nil)" \
		-f batch-byte-compile ${ELISP_COMPILE_ORDER}

## Autoloads — lets users `(require 'maxbutt-autoloads)` and get the ssb-*
## entry commands as M-x-able autoloads without loading the package up front.
## Regenerated whenever a source .el changes; scans for ;;;###autoload cookies.
${AUTOLOADS}: ${ELISP_SOME_SRC}
	${emacs} -batch --eval "(loaddefs-generate \"elisp\" (expand-file-name \"${AUTOLOADS}\") (list \"maxbutt-autoloads.el\"))"

## Info documentation
doc/maxbutt.info: ${DOC_SRC}
	command -v makeinfo && makeinfo -o $@ $< || echo fail

## Postscript documentation
doc/maxbutt.ps: doc/maxbutt.dvi
	command -v dvips && dvips -o $@ $< || echo fail

doc/maxbutt.dvi: ${DOC_SRC}
	command -v texi2dvi && (cd doc; texi2dvi maxbutt.texi) || echo fail

########################################

clean:
	-rm -f ${OBJECTS} 2>/dev/null

distclean: clean
	-rm -f *~ */*~ 2>/dev/null
	-rm -rf ${DIST} 2>/dev/null

install: base
	@echo "* Installing Emacs Lisp Library"
	install -m 775 -d ${ELISP_DIR} ${EBIN_DIR} ${ERL_SRC_DIR}
	install -m 775 elisp/*.el elisp/*.elc ${ELISP_DIR}
	@echo
	@echo "* Installing Erlang Library"
	install -m 775 ebin/*.beam ${EBIN_DIR}
	install -m 775 src/*.erl ${ERL_SRC_DIR}
	@echo
	@echo "*** Successfully installed. See README for usage instructions."
	@echo

info_install: info
	  @echo "* Installing Info documentation"
	  install -m 775 -d ${infodir}
	  cp doc/maxbutt.info ${infodir}
# NB: Debian's not-GNU-compatible install-info needs "--section Emacs Emacs"
	  install-info --info-dir=${infodir} --section Emacs \
		       ${infodir}/maxbutt.info

## Self-contained source+built tarball under dist/ (elisp .el/.elc + autoloads,
## erlang .beam/.erl, info doc, README, Makefile), plus a sha256.
dist: base info
	@rm -rf ${DIST}/${DISTNAME}
	@mkdir -p ${DIST}/${DISTNAME}/elisp ${DIST}/${DISTNAME}/ebin \
	          ${DIST}/${DISTNAME}/src ${DIST}/${DISTNAME}/doc
	cp elisp/*.el elisp/*.elc ${DIST}/${DISTNAME}/elisp/
	cp ebin/*.beam            ${DIST}/${DISTNAME}/ebin/
	cp src/*.erl              ${DIST}/${DISTNAME}/src/
	cp doc/maxbutt.info doc/maxbutt.texi ${DIST}/${DISTNAME}/doc/
	cp README.md Makefile     ${DIST}/${DISTNAME}/
	cd ${DIST} && tar czf ${DISTNAME}.tar.gz ${DISTNAME} \
	  && shasum -a 256 ${DISTNAME}.tar.gz > ${DISTNAME}.tar.gz.sha256
	@rm -rf ${DIST}/${DISTNAME}
	@echo "==> ${DIST}/${DISTNAME}.tar.gz"

wc:
	@echo "* Emacs Lisp"
	@wc -l */*.el | sort -nr
	@echo "* Erlang"
	@wc -l */*.erl | sort -nr
	@echo "* C"
	@wc -l */*.c | sort -nr

.INTERMEDIATE: doc/maxbutt.dvi
.PHONY: base many info erl autoloads postscript all dist \
        install info_install clean distclean wc
