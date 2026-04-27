# gloss.el

This Emacs package provides dictionary lookup backed by
[Wiktextract](https://kaikki.org/) data stored in a local SQLite
database.

## Highlights

- Fast word lookup with frequency-based sorting
- Help buffer showing glosses, IPA, forms and synonyms for a word
- Completion-at-point function for in-buffer word completion
- ElDoc integration showing a brief sense for the word at point

## Setup

### 1. Get dictionary data

Run `M-x gloss-download-prebuilt-db` to download a pre-built SQLite database
directly into the package's data directory.  Pre-built databases are available
for English, Dutch, French, German and Italian.  Alternatively, gloss will
offer to download one automatically the first time you invoke
`gloss-describe-word` with no database in place.

To build a database yourself, download a Wiktextract JSONL dump from
https://kaikki.org/ and run `make data/<LANGUAGE CODE>.db`, e.g.:

    curl -o data/en.jsonl https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl
    make data/en.db

`make` creates a Python virtual environment, installs the `wordfreq` library,
and builds a SQLite database from the JSONL file.  Subsequent runs only
rebuild if the JSONL file has changed.

### 2. Configure Emacs

```elisp
;; Set the default dictionary (basename of the .db file under data/).
(setq gloss-default-dictionary "en") ; "en" is the default default.

;; Look up words interactively.
(keymap-global-set "M-#" #'gloss-describe-word)

;; Show a brief sense for the word at point via ElDoc.
(add-hook 'text-mode-hook
          (lambda ()
            (add-hook 'eldoc-documentation-functions #'gloss-eldoc nil t)))

;; Complete words at point.
(add-hook 'text-mode-hook
          (lambda ()
            (add-hook 'completion-at-point-functions
                      #'gloss-completion-at-point nil t)))
```
