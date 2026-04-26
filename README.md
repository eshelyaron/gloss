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

Download a Wiktextract JSONL dump for the language you want.  For English:

    curl -o data/en.jsonl https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl

Dumps for other languages are available at https://kaikki.org/

### 2. Build the database

    make data/en.db

This creates a Python virtual environment, installs the `wordfreq` library,
and builds a SQLite database from the JSONL file.  Subsequent `make` runs
only rebuild the database if the JSONL file has changed.

### 3. Configure Emacs

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
