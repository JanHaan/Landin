;;; landin-mode.el --- Major modes for the Landin language -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages
;; SPDX-License-Identifier: MIT OR Apache-2.0

;;; Commentary:
;; Regex highlighting works everywhere; `landin-ts-mode' is selected
;; automatically when the tree-sitter grammar has been installed.

;;; Code:

(require 'treesit nil t)

(defconst landin-mode-keywords
  '("addr" "align" "alignof" "and" "any" "arena" "as" "at" "atom" "begin"
    "big" "break" "caller" "complete" "concept" "continue" "dec"
    "defer" "distinct" "do" "else" "elsif" "end" "escaping" "extern"
    "fail" "fixed" "for" "from" "if" "import" "in" "inc" "inout" "is"
    "layout" "lenof" "link" "little" "loop" "match" "mut" "not" "of" "option"
    "or" "ptr" "public" "range" "register" "return" "set" "sink"
    "sizeof" "soa" "struct" "then" "try" "type" "unchecked" "undo"
    "variant" "volatile" "when" "while" "with"))

(defconst landin-mode-types
  '("bool" "cstring" "f16" "f32" "f64" "i8" "i16" "i32" "i64" "i128"
    "isize" "u8" "u16" "u32" "u64" "u128" "usize" "utf8" "utf16"))

(defconst landin-mode-constants '("false" "none" "noreturn" "true" "zeroed"))

(defgroup landin nil "Editing Landin source." :group 'languages)

(defcustom landin-treesit-revision "main"
  "Git revision used by `landin-ts-install-grammar'."
  :type 'string
  :group 'landin)

;;;###autoload
(defun landin-ts-install-grammar ()
  "Build and install the repository's Landin tree-sitter grammar."
  (interactive)
  (unless (fboundp 'treesit-install-language-grammar)
    (user-error "This Emacs does not provide tree-sitter grammar installation"))
  (add-to-list 'treesit-language-source-alist
               `(landin "https://github.com/JanHaan/Landin"
                        ,landin-treesit-revision "highlight/tree-sitter"))
  (treesit-install-language-grammar 'landin))

(defvar landin-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?_ "w" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?' "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?\n ">" table)
    table))

(defun landin--match-block-comment (limit)
  "Find one possibly nested block comment ending after LIMIT."
  (when (re-search-forward "--(" limit t)
    (let ((start (match-beginning 0)) (depth 1))
      (while (and (> depth 0) (re-search-forward "--(\\|)--" nil t))
        (if (string= (match-string-no-properties 0) "--(")
            (setq depth (1+ depth))
          (setq depth (1- depth))))
      (set-match-data (list start (point)))
      t)))

(defun landin--match-raw-string (limit)
  "Find one quote-counted raw string beginning before LIMIT."
  (when (re-search-forward "\"\{3,\}" limit t)
    (let ((start (match-beginning 0))
          (delimiter (match-string-no-properties 0)))
      (search-forward delimiter nil 'move)
      (set-match-data (list start (point)))
      t)))

(defconst landin-font-lock-keywords
  `((landin--match-block-comment (0 font-lock-comment-face t))
    (landin--match-raw-string (0 font-lock-string-face t))
    (,(regexp-opt landin-mode-keywords 'symbols) . font-lock-keyword-face)
    (,(regexp-opt landin-mode-types 'symbols) . font-lock-type-face)
    (,(regexp-opt landin-mode-constants 'symbols) . font-lock-constant-face)
    ("\\_<[ui]\\(?:0\\|[1-9][0-9]?[0-9]?\\)\\_>" . font-lock-type-face)
    ("^\\s-*\\(?:public\\s-+\\)?\\([a-z_][a-z0-9_]*\\)\\s-*:\\s-*\\(?:type\\|atom\\)\\_>" 1 font-lock-type-face)
    ("^\\s-*\\(?:public\\s-+\\)?\\([a-z_][a-z0-9_]*\\)\\s-*:\\s-*(" 1 font-lock-function-name-face)
    ("---.*$" . font-lock-doc-face)
    ("--.*$" . font-lock-comment-face)))

;;;###autoload
(define-derived-mode landin-mode prog-mode "Landin"
  "Major mode for Landin source."
  :syntax-table landin-mode-syntax-table
  (setq-local font-lock-defaults '(landin-font-lock-keywords))
  (setq-local comment-start "-- ")
  (setq-local comment-end "")
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width 4))

(when (and (fboundp 'treesit-ready-p) (treesit-ready-p 'landin))
  (define-derived-mode landin-ts-mode landin-mode "Landin[TS]"
    "Tree-sitter major mode for Landin source."
    (treesit-parser-create 'landin)
    (setq-local treesit-font-lock-feature-list
                '((comment definition) (keyword string type) (constant function operator)))
    (setq-local treesit-font-lock-settings
                (treesit-font-lock-rules
                 :language 'landin :feature 'comment '((comment) @font-lock-comment-face)
                 :language 'landin :feature 'definition
                 '((function_declaration name: (identifier) @font-lock-function-name-face)
                   (type_declaration name: (identifier) @font-lock-type-face))
                 :language 'landin :feature 'type '((scalar_type) @font-lock-builtin-face)
                 :language 'landin :feature 'constant
                 '((boolean_literal) @font-lock-constant-face
                   (zeroed_literal) @font-lock-constant-face
                   (integer_literal) @font-lock-number-face)))
    (treesit-major-mode-setup)))

;;;###autoload
(add-to-list 'auto-mode-alist
             '("\\.ldn\\'" . (lambda ()
                                (if (and (fboundp 'treesit-ready-p)
                                         (treesit-ready-p 'landin))
                                    (landin-ts-mode)
                                  (landin-mode)))))

(provide 'landin-mode)
;;; landin-mode.el ends here
