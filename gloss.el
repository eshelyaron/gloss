;;; gloss.el --- Fast dictionary lookup and word completion  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Eshel Yaron

;; Author: Eshel Yaron <me@eshelyaron.com>
;; Maintainer: Eshel Yaron <me@eshelyaron.com>
;; Keywords: languages
;; URL: https://git.sr.ht/~eshel/gloss
;; Package-Version: 0.1.4
;; Package-Requires: ((emacs "30.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library provides dictionary lookup backed by Wiktextract data
;; stored in a local SQLite database.
;;
;; The main entry point is `gloss-describe-word', which prompts for a
;; word with frequency-ranked completion and displays its definitions,
;; IPA pronunciation, inflected forms and synonyms in a Help buffer.
;; Set `gloss-default-dictionary' to select which database to use, or
;; call `gloss-describe-word' with a prefix argument.
;;
;; `gloss-completion-at-point' is a `completion-at-point-functions'
;; function that completes the word at point against the dictionary.
;;
;; `gloss-eldoc' is an `eldoc-documentation-functions' function that
;; shows a brief sense for the word at point in the echo area.
;;
;; `gloss-download-prebuilt-db' downloads a pre-built database for a
;; given language; pre-built databases are available for English, Dutch,
;; French, German and Italian.

;;; Code:

(require 'external-completion)

(defgroup gloss nil
  "Fast dictionary lookup and word completion."
  :group 'text)

(defvar gloss--directory (file-name-directory load-file-name))

(defvar gloss-data-directory (expand-file-name "data/" gloss--directory))

(defcustom gloss-default-dictionary "en"
  "Dictionary to use by default for definition lookup and word completion."
  :type 'string)

(defcustom gloss-prebuilt-db-urls
  '(("en" . "https://github.com/eshelyaron/gloss/releases/latest/download/en.db")
    ("nl" . "https://github.com/eshelyaron/gloss/releases/latest/download/nl.db")
    ("fr" . "https://github.com/eshelyaron/gloss/releases/latest/download/fr.db")
    ("de" . "https://github.com/eshelyaron/gloss/releases/latest/download/de.db")
    ("it" . "https://github.com/eshelyaron/gloss/releases/latest/download/it.db"))
  "Alist mapping dictionary names to pre-built database download URLs."
  :type '(alist :key-type string :value-type string))

(defvar gloss-read-dictionary-history nil)

(defvar gloss--connections (make-hash-table :test #'equal))

(defvar gloss--prompted nil
  "List of dictionaries for which a missing-database prompt has been shown.")

(defun gloss--db (dictionary)
  "Return an open SQLite handle for DICTIONARY, opening it if needed."
  (or (gethash dictionary gloss--connections)
      (let ((path (expand-file-name (concat dictionary ".db") gloss-data-directory)))
        (unless (file-exists-p path)
          (if (and (assoc dictionary gloss-prebuilt-db-urls)
                   (not (member dictionary gloss--prompted))
                   (push dictionary gloss--prompted)
                   (y-or-n-p (format "No database for dictionary `%s'.  Download it now? " dictionary)))
              (progn
                (gloss-download-prebuilt-db dictionary)
                (user-error "Download started; try again once it completes"))
            (error "No database for dictionary `%s'" dictionary)))
        (puthash dictionary (sqlite-open path) gloss--connections))))

(defun gloss-dictionaries ()
  "Return a list of available dictionary names."
  (when (file-directory-p gloss-data-directory)
    (mapcar #'file-name-base
            (directory-files gloss-data-directory nil (rx ".db" eos)))))

(defun gloss--read-dictionary-for-download (&optional prompt)
  "Prompt with PROMPT for a dictionary to download."
  (completing-read
   (format-prompt (or prompt "Dictionary") gloss-default-dictionary)
   (completion-table-with-metadata
    gloss-prebuilt-db-urls
    `((affixation-function
       . ,(lambda (cands)
            (mapcar
             (lambda (cand)
               (list cand (concat (gloss--lang-code-to-flag cand) " ") ""))
             cands)))))
   nil t nil nil gloss-default-dictionary))

(defun gloss-read-dictionary (prompt)
  "Prompt for a dictionary name with PROMPT."
  (let ((dicts (gloss-dictionaries)))
    (unless dicts
      (let ((dict (gloss--read-dictionary-for-download
                   "No dictionaries available.  Download dictionary")))
        (gloss-download-prebuilt-db dict)
        (when (y-or-n-p
               (format "Also set `%s' as the default dictionary?" dict))
          (customize-save-variable 'gloss-default-dictionary dict))
        (user-error "Download started; try again once it completes")))
    (completing-read
     (format-prompt prompt gloss-default-dictionary)
     dicts nil t nil
     'gloss-read-dictionary-history gloss-default-dictionary)))

(defun gloss--word-table (&optional dictionary)
  "Return completion table for DICTIONARY."
  (let ((db (gloss--db (or dictionary gloss-default-dictionary))))
    (external-completion-table
     'gloss-word
     (lambda (pattern _point)
       (gloss--completions pattern db))
     `((affixation-function
        . ,(lambda (cs)
             (let ((max (seq-max (cons 0 (mapcar #'string-width cs)))))
               (mapcar
                (lambda (c)
                  (list
                   c ""
                   (if-let* ((hint (get-text-property 0 'hint c)))
                       (concat (make-string (1+ (- max (string-width c))) ?\s)
                               (propertize hint 'face 'completions-annotations))
                     "")))
                cs))))
       (display-sort-function . identity)
       (cycle-sort-function . identity)))))

(defcustom gloss-word-completions-limit 2048
  "Maximum number of word completions to produce in a single dictionary query."
  :type '(choice natnum (const :tag "No limit" nil)))

;; The `gloss-match-face-N' faces and `gloss-match-faces' are copied
;; from the corresponding definitions in orderless.el
;; (https://github.com/oantolin/orderless)
(defface gloss-match-face-0
  '((((class color) (min-colors 88) (background dark)) :foreground "#72a4ff")
    (((class color) (min-colors 88) (background light)) :foreground "#223fbf")
    (t :foreground "blue"))
  "Face for matches of components numbered 0 mod 4.")

(defface gloss-match-face-1
  '((((class color) (min-colors 88) (background dark)) :foreground "#ed92f8")
    (((class color) (min-colors 88) (background light)) :foreground "#8f0075")
    (t :foreground "magenta"))
  "Face for matches of components numbered 1 mod 4.")

(defface gloss-match-face-2
  '((((class color) (min-colors 88) (background dark)) :foreground "#90d800")
    (((class color) (min-colors 88) (background light)) :foreground "#145a00")
    (t :foreground "green"))
  "Face for matches of components numbered 2 mod 4.")

(defface gloss-match-face-3
  '((((class color) (min-colors 88) (background dark)) :foreground "#f0ce43")
    (((class color) (min-colors 88) (background light)) :foreground "#804000")
    (t :foreground "yellow"))
  "Face for matches of components numbered 3 mod 4.")

(defcustom gloss-match-faces
  [gloss-match-face-0
   gloss-match-face-1
   gloss-match-face-2
   gloss-match-face-3]
  "Vector of faces used (cyclically) for component matches."
  :type '(vector face))

(defun gloss--highlight-completion (comp pref subs)
  "Highlight completion candidate COMP according to PREF and SUBS."
  (let ((res (copy-sequence comp)))
    (add-face-text-property 0 (length pref) 'completions-common-part nil res)
    (let ((i 0)
          (n (length gloss-match-faces)))
      (dolist (sub subs)
        (when-let* ((pos (string-search sub res)))
          (add-face-text-property
           pos (+ pos (length sub))
           (aref gloss-match-faces (mod i n))
           nil res))
        (setq i (1+ i))))
    res))

(defun gloss--completions-1 (db pref subs)
  "Return words in DB that start with PREF and contain all of SUBS."
  (let* ((query (concat "SELECT word, hint FROM words WHERE word LIKE ?"
                        (string-join (make-list (length subs) " AND word LIKE ?"))
                        " ORDER BY freq LIMIT ?"))
         (rows (sqlite-select
                db query
                (cons
                 (concat pref "%")
                 (append
                  (mapcar (lambda (sub) (concat "%" sub "%")) subs)
                  (list (or gloss-word-completions-limit most-positive-fixnum))))))
         a b)
    (pcase-dolist (`(,word ,hint) rows)
      (let ((annotated
             (if (and hint (not (string-empty-p hint)))
                 (propertize word 'hint (truncate-string-to-width hint 64 nil nil t))
               word)))
        (push annotated (if (string-prefix-p pref annotated) a b))))
    (nconc a b)))

(defun gloss--completions (pattern db)
  "Return completions for PATTERN from database DB.

PATTERN is split on whitespace: the first token is matched as a prefix
of the candidate, and each subsequent token must appear as a substring
anywhere in the candidate."
  (setq completion-lazy-hilit-fn nil)
  (let* ((parts (split-string pattern split-string-default-separators))
         (pref (car parts))
         (subs (cdr parts))
         (completions (gloss--completions-1 db pref subs)))
    (if completion-lazy-hilit
        (progn
          (setq completion-lazy-hilit-fn
                (lambda (comp) (gloss--highlight-completion comp pref subs)))
          completions)
      (mapcar
       (lambda (comp) (gloss--highlight-completion comp pref subs))
       completions))))

(with-eval-after-load 'help-mode
  (define-button-type 'gloss-word-xref
    :supertype 'help-xref
    'help-function #'gloss-describe-word
    'help-echo "mouse-2, RET: look up this word"))

(defun gloss--format-forms (forms-json)
  "Parse FORMS-JSON and return a display string, or nil if nothing useful."
  (when (and forms-json (not (string-empty-p forms-json)))
    (let* ((forms (json-parse-string forms-json :array-type 'list
                                     :object-type 'alist))
           (real (seq-remove
                  (lambda (f)
                    (seq-some (lambda (tag)
                                (member tag '("table-tags" "inflection-template")))
                              (alist-get 'tags f)))
                  forms)))
      (when real
        (mapconcat
         (lambda (f)
           (let ((form (alist-get 'form f))
                 (tags (alist-get 'tags f)))
             (if tags
                 (format "%s (%s)" form (string-join tags ", "))
               form)))
         real "; ")))))

(defun gloss--insert-entry (row dictionary)
  "Insert a formatted dictionary entry from ROW into the current buffer.
DICTIONARY is the name of the source dictionary, used for xref buttons."
  (pcase-let ((`(,pos ,glosses-json ,ipa ,forms-json ,synonyms-json)
               row))
    (insert pos "\n")
    (let ((glosses (json-parse-string glosses-json :array-type 'list))
          (i 1))
      (dolist (gloss glosses)
        (insert (format "  %d. %s\n" i gloss))
        (setq i (1+ i))))
    (when (and ipa (not (string-empty-p ipa)))
      (insert "  Pronunciation: " ipa "\n"))
    (when-let* ((forms-str (gloss--format-forms forms-json)))
      (insert "  Forms: " forms-str "\n"))
    (when (and synonyms-json (not (string-empty-p synonyms-json)))
      (let ((syns (json-parse-string synonyms-json :array-type 'list)))
        (when syns
          (insert "  Synonyms: ")
          (let ((first t))
            (dolist (syn syns)
              (unless first (insert ", "))
              (setq first nil)
              (insert-button syn
                             :type 'gloss-word-xref
                             'help-args (list syn dictionary))))
          (insert "\n"))))
    (insert "\n")))

(defun gloss--display-entries (word dictionary rows)
  "Render all ROWS for WORD from DICTIONARY into the current buffer."
  (insert word)
  (insert "\n\n")
  (if rows
      (dolist (row rows)
        (gloss--insert-entry row dictionary))
    (insert "No definitions found.\n")))

;;;###autoload
(defun gloss-describe-word (word &optional dictionary interactive)
  "Display definitions for WORD from DICTIONARY in a Help buffer.

DICTIONARY defaults to `gloss-default-dictionary'.
Interactively, prompt for WORD with frequency-ranked completion.
With a prefix argument, also prompt for DICTIONARY.

During completion, the minibuffer input is split into space-separated
tokens, all of which need to match for a candidate to appear.  The first
token must match as a prefix, each additional token filters further to
candidates that contain it as a substring anywhere in the word, in any
order.  For example, typing \"e tor di\" matches \"editor\", but not
\"director\" (which does not begin with \"e\").

Optional argument INTERACTIVE is non-nil for interactive calls.
Omit it when calling this function form Lisp."
  (interactive
   (let* ((dict (if current-prefix-arg
                    (gloss-read-dictionary "Dictionary")
                  gloss-default-dictionary))
          (def (thing-at-point 'word t))
          (word
           (minibuffer-with-setup-hook
               (lambda ()
                 (setq-local minibuffer-action
                             (cons (lambda (str)
                                     (gloss-describe-word str dict))
                                   "describe")))
             (completing-read
              (format-prompt "Word[%s]" def dict)
              (gloss--word-table dict) nil t nil
              (intern (format "gloss-describe-word-%s-history" dict))
              def))))
     (when current-prefix-arg (setq-local gloss-default-dictionary dict))
     (list word dict t)))
  (let* ((dictionary (or dictionary gloss-default-dictionary))
         (rows (sqlite-select
                (gloss--db dictionary)
                "SELECT pos, glosses, ipa, forms, synonyms FROM entries WHERE word LIKE ?"
                (list word)))
         (help-buffer-under-preparation t))
    (help-setup-xref (list #'gloss-describe-word word dictionary) interactive)
    (with-help-window (help-buffer)
      (with-current-buffer (help-buffer)
        (gloss--display-entries word dictionary rows)))))

;;;###autoload
(defun gloss-eldoc (callback)
  "ElDoc function showing a brief sense for the word at point.
Intended for use in `eldoc-documentation-functions'.
Looks up the word at point in `gloss-default-dictionary' and calls
CALLBACK with a one-line hint if a match is found."
  (when-let* ((wap (thing-at-point 'word t))
              (db (gloss--db gloss-default-dictionary))
              (hit (car (sqlite-select
                         db "SELECT word, hint FROM words WHERE word LIKE ? LIMIT 1"
                         (list wap))))
              (word (car hit))
              (hint (cadr hit)))
    (unless (string-empty-p hint)
      (funcall callback hint :thing word :face 'font-lock-keyword-face))))

;;;###autoload
(defun gloss-completion-at-point ()
  "Complete the word at point against `gloss-default-dictionary'.
Intended for use in `completion-at-point-functions'."
  (pcase (bounds-of-thing-at-point 'word)
    (`(,beg . ,end)
     (when (and (< beg (point)) (<= (point) end))
       (list beg end (gloss--word-table) :exclusive 'no)))))

(defun gloss--lang-code-to-flag (lc)
  "Return a flag (as a string) corresponding to language code LC."
  (when (equal lc "en") (setq lc "gb"))
  (substring-no-properties
   (compose-chars
    (char-from-name
     (concat "REGIONAL INDICATOR SYMBOL LETTER "
             (string (upcase (aref lc 0)))))
    (char-from-name
     (concat "REGIONAL INDICATOR SYMBOL LETTER "
             (string (upcase (aref lc 1))))))))

;;;###autoload
(defun gloss-download-prebuilt-db (dictionary)
  "Download the pre-built database for DICTIONARY.
Fetches the database file from `gloss-prebuilt-db-urls' into the gloss
data directory.  Interactively, prompt for DICTIONARY with completion."
  (interactive
   (list
    (gloss--read-dictionary-for-download)))
  (let ((url (alist-get dictionary gloss-prebuilt-db-urls nil nil #'equal))
        (curl (executable-find "curl")))
    (unless url
      (user-error "No pre-built database available for `%s'" dictionary))
    (unless curl
      (user-error "`curl' not found; download %s into %s manually"
                  url gloss-data-directory))
    (make-directory gloss-data-directory t)
    (message
     "Downloading %s database..."
     dictionary)
    (let ((buf (get-buffer-create (format "*gloss download %s*" dictionary))))
      (with-current-buffer buf
        (setq-local window-point-insertion-type t
                    mode-line-process ":running"))
      (setf (buffer-local-value 'window-point-insertion-type buf) t)
      (display-buffer buf)
      (make-process
       :name "gloss-setup"
       :buffer buf
       :command (list curl "-L" "-o"
                      (expand-file-name (concat dictionary ".db") gloss-data-directory)
                      url)
       :filter (lambda (proc string)
                 (with-current-buffer (process-buffer proc)
                   (insert (string-replace "\r" "\n" string))))
       :sentinel (lambda (proc _event)
                   (with-current-buffer (process-buffer proc)
                     (setq-local
                      mode-line-process
                      (if (zerop (process-exit-status proc))
                          (progn
                            (message "Dictionary DB download complete")
                            ":done")
                        (message "Dictionary DB download failed!")
                        ":failed"))))))))

(provide 'gloss)
;;; gloss.el ends here
