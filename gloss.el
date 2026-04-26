;;; gloss.el --- Fast dictionary lookup and word completion  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Eshel Yaron

;; Author: Eshel Yaron <me@eshelyaron.com>
;; Maintainer: Eshel Yaron <me@eshelyaron.com>
;; Keywords: languages
;; URL: https://git.sr.ht/~eshel/gloss
;; Package-Version: 0.1.2
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

(defcustom gloss-english-db-url
  "https://github.com/eshelyaron/gloss/releases/latest/download/en.db"
  "URL from which `gloss-setup-english' downloads pre-built English database."
  :type 'string)

(defvar gloss-read-dictionary-history nil)

(defvar gloss--connections (make-hash-table :test #'equal))

(defvar gloss--prompted nil
  "List of dictionaries for which a missing-database prompt has been shown.")

(defun gloss--db (dictionary)
  "Return an open SQLite handle for DICTIONARY, opening it if needed."
  (or (gethash dictionary gloss--connections)
      (let ((path (expand-file-name (concat dictionary ".db") gloss-data-directory)))
        (unless (file-exists-p path)
          (if (and (equal dictionary "en")
                   (not (member dictionary gloss--prompted))
                   (push dictionary gloss--prompted)
                   (y-or-n-p "No database for dictionary `en'.  Download it now? "))
              (progn
                (gloss-setup-english)
                (user-error "Download started; try again once it completes"))
            (error "No database for dictionary `%s'" dictionary)))
        (puthash dictionary (sqlite-open path) gloss--connections))))

(defun gloss-dictionaries ()
  "Return a list of available dictionary names."
  (mapcar #'file-name-base
          (directory-files gloss-data-directory nil (rx ".db" eos))))

(defun gloss-read-dictionary (prompt)
  "Prompt for a dictionary name with PROMPT."
  (completing-read
   (format-prompt prompt gloss-default-dictionary)
   (let ((table 'unset))
     (lambda (str pred op)
       (when (eq table 'unset)
         (setq table (gloss-dictionaries)))
       (complete-with-action op table str pred)))
   nil t nil
   'gloss-read-dictionary-history gloss-default-dictionary))

(defun gloss--word-table (&optional dictionary)
  "Return completion table for DICTIONARY."
  (let ((db (gloss--db (or dictionary gloss-default-dictionary))))
    (external-completion-table
     'gloss-word
     (lambda (pattern _point)
       (gloss--word-completions pattern db))
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

(defun gloss--word-completions (word db)
  "Return completions for WORD from database DB."
  (mapcar
   (pcase-lambda (`(,word ,hint))
     (if (and hint (not (string-empty-p hint)))
         (propertize word 'hint (truncate-string-to-width hint 64 nil nil t))
       word))
   (sqlite-select
    db "SELECT word, hint FROM words WHERE word LIKE ? ORDER BY freq DESC"
    (list (concat word "%")))))

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

Optional argument INTERACTIVE is non-nil for interactive calls."
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
                                   "define")))
             (completing-read
              (format-prompt "Word[%s]" def dict)
              (gloss--word-table dict) nil t nil
              (intern (format "gloss-describe-word-%s-history" dict))
              def))))
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

;;;###autoload
(defun gloss-setup-english ()
  "Download the pre-built English dictionary database.
Fetches en.db from `gloss-english-db-url' into the gloss data directory."
  (interactive)
  (let ((curl (executable-find "curl")))
    (unless curl
      (user-error "`curl' not found; download %s into %s manually"
                  gloss-english-db-url gloss-data-directory))
    (make-directory gloss-data-directory t)
    (message "Downloading English database (see buffer `*gloss setup*' for progress)...")
    (make-process
     :name "gloss-setup"
     :buffer "*gloss setup*"
     :command (list curl "-L" "-o"
                    (expand-file-name "en.db" gloss-data-directory)
                    gloss-english-db-url)
     :filter (lambda (proc string)
               (with-current-buffer (process-buffer proc)
                 (insert (string-replace "\r" "\n" string))))
     :sentinel (lambda (proc _event)
                 (if (zerop (process-exit-status proc))
                     (message "English database ready.")
                   (message "gloss-setup-english failed; see buffer `%s' for details"
                            (buffer-name (process-buffer proc))))))))

(provide 'gloss)
;;; gloss.el ends here
