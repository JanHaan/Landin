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
    "sizeof" "soa" "struct" "then" "try" "type" "unchecked" "undo" "uninit"
    "variant" "volatile" "when" "while" "with"))

(defconst landin-mode-types
  '("bool" "cstring" "f16" "f32" "f64" "i8" "i16" "i32" "i64" "i128"
    "isize" "u8" "u16" "u32" "u64" "u128" "usize" "utf8" "utf16"))

(defconst landin-mode-constants '("false" "none" "noreturn" "true" "zeroed"))

(defconst landin-mode-builtin-modules '("assembler" "compiler" "linker"))

(defgroup landin nil "Editing Landin source." :group 'languages)

(defcustom landin-treesit-revision "22e994a35c92d4a0b52fb64fcab27e6792a5e331"
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

(defvar-local landin--raw-scan-cache nil
  "Buffer tick and last scanned position for the raw matcher.")

(defun landin--skip-quoted-string ()
  "Move past one ordinary quoted string at point."
  (let ((quote (char-after))
        (done nil))
    (forward-char 1)
    (while (and (not done) (not (eobp)))
      (cond
       ((eq (char-after) ?\\)
        (forward-char (min 2 (- (point-max) (point)))))
       ((eq (char-after) quote)
        (forward-char 1)
        (setq done t))
       ((eq (char-after) ?\n)
        (setq done t))
       (t (forward-char 1))))))

(defun landin--match-raw-string (limit)
  "Find one quote-counted raw string beginning before LIMIT.
Scan from a known code position so comment quotes cannot open a raw string."
  (let* ((origin (point))
         (tick (buffer-chars-modified-tick))
         (cached landin--raw-scan-cache)
         (found nil))
    (goto-char (if (and cached (= (car cached) tick)
                        (<= (cdr cached) origin))
                   (cdr cached)
                 (point-min)))
    (while (and (not found) (< (point) limit))
      (cond
       ((looking-at "--(")
        (landin--match-block-comment (point-max)))
       ((looking-at "--")
        (forward-line 1))
       ((looking-at "\"\\\{3,\\\}")
        (let ((start (point))
              (delimiter (match-string-no-properties 0)))
          (goto-char (match-end 0))
          (when (search-forward delimiter nil 'move)
            (setq landin--raw-scan-cache (cons tick (point))))
          (when (>= start origin)
            (setq found (cons start (point))))))
       ((memq (char-after) (string-to-list "\"'"))
        (landin--skip-quoted-string))
       (t (forward-char 1))))
    (if found
        (progn
          (set-match-data (list (car found) (cdr found)))
          t)
      (setq landin--raw-scan-cache (cons tick (point)))
      nil)))

(defconst landin-font-lock-keywords
  `((landin--match-block-comment (0 font-lock-comment-face t))
    (landin--match-raw-string (0 font-lock-string-face t))
    (,(regexp-opt landin-mode-keywords 'symbols) . font-lock-keyword-face)
    (,(regexp-opt landin-mode-types 'symbols) . font-lock-type-face)
    (,(regexp-opt landin-mode-constants 'symbols) . font-lock-constant-face)
    (,(regexp-opt landin-mode-builtin-modules 'symbols) . font-lock-builtin-face)
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
                 '((type_declaration name: (identifier) @font-lock-type-face)
                   (concept_declaration name: (identifier) @font-lock-type-face))
                 :language 'landin :feature 'keyword
                 '(["addr" "alignof" "any" "as" "atom" "begin" "break" "complete"
                    "concept" "continue" "dec" "defer" "do" "else" "elsif" "end"
                    "escaping" "extern" "fail" "fixed" "for" "from" "if" "import"
                    "in" "inc" "inout" "is" "loop" "match" "mut" "none" "option"
                    "ptr" "public" "return" "sink" "sizeof" "struct" "then" "try"
                    "type" "unchecked" "undo" "variant" "when" "while" "with"]
                   @font-lock-keyword-face
                   (measurement_expression operator: (identifier) @font-lock-keyword-face
                                           (:match "\\`lenof\\'" @font-lock-keyword-face))
                   (of_keyword (identifier) @font-lock-keyword-face
                               (:match "\\`of\\'" @font-lock-keyword-face)))
                 :language 'landin :feature 'string
                 '([(text_literal) (raw_literal) (character_literal)]
                   @font-lock-string-face)
                 :language 'landin :feature 'type '((scalar_type) @font-lock-builtin-face)
                 :language 'landin :feature 'constant
                 '((boolean_literal) @font-lock-constant-face
                   (zeroed_literal) @font-lock-constant-face
                   (uninit_literal) @font-lock-constant-face
                   (integer_literal) @font-lock-number-face
                   (float_literal) @font-lock-number-face)
                 :language 'landin :feature 'function
                 '((function_declaration name: (identifier) @font-lock-function-name-face)
                   (extern_declaration name: (identifier) @font-lock-function-name-face)
                   (call_expression function: (indexed_expression
                                               (identifier) @font-lock-function-call-face))
                   (labeled_application function: (indexed_expression
                                                  (identifier) @font-lock-function-call-face)))
                 :language 'landin :feature 'operator
                 '(["=" ":=" "!" "|" "+" "*" "/" "%" "+%" "*%" "<<" ">>"
                    "&" "^" "~" "==" "<>" "<" "<=" ">" ">=" ".." "..<"
                    "+=" "*=" "/=" "%=" "&=" "|=" "^=" "<<=" ">>="
                    "+%=" "*%=" "and" "not" "or"
                    (minus) (minus_equals) (minus_percent) (minus_percent_equals)
                    (arrow)] @font-lock-operator-face)))
    (treesit-major-mode-setup)))

;;;###autoload
(add-to-list 'auto-mode-alist
             '("\\.ldn\\'" . (lambda ()
                                (if (and (fboundp 'treesit-ready-p)
                                         (treesit-ready-p 'landin))
                                    (landin-ts-mode)
                                  (landin-mode)))))

;; `refine lsp`, the compiler's language server, for Eglot: diagnostics,
;; definitions, hover, formatting and quick fixes from the compiler's own
;; stages.  `M-x eglot` in a Landin buffer starts it with `refine` on the
;; path; `eglot-ensure` in `landin-mode-hook` starts it every time.
;;;###autoload
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '((landin-mode landin-ts-mode) . ("refine" "lsp"))))

(provide 'landin-mode)
;;; landin-mode.el ends here
