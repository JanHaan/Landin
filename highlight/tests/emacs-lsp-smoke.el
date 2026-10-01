;;; emacs-lsp-smoke.el --- start refine lsp through Eglot -*- lexical-binding: t -*-
;; Opens LANDIN_FIXTURE, starts Eglot with the program the package
;; registers, and waits for refine lsp's L0301 to reach the buffer's
;; Flymake diagnostics.  Needs `refine' on the path; `../test.sh' runs it
;; when LANDIN_REFINE names one.
(require 'eglot)
(require 'landin-mode)
;; Emacs 30 runs no Flymake backend on content it was not told to trust.
(setq trusted-content :all)
(find-file (getenv "LANDIN_FIXTURE"))
(unless (eq major-mode 'landin-mode) (error "Landin mode was not selected"))
(unless (equal (cdr (assoc '(landin-mode landin-ts-mode) eglot-server-programs))
               '("refine" "lsp"))
  (error "The package did not register refine lsp with Eglot"))
;; eglot-ensure waits for a command loop a batch Emacs never runs.
(apply #'eglot (eglot--guess-contact))
(flymake-mode 1)
(let ((deadline (+ (float-time) 20)) found)
  (while (and (not found) (< (float-time) deadline))
    (accept-process-output nil 0.1)
    (flymake-start)
    (dolist (item (flymake-diagnostics))
      (when (string-match-p "bool" (flymake-diagnostic-text item))
        (setq found t))))
  (unless (eglot-current-server) (error "Eglot did not start refine lsp"))
  (unless found (error "refine lsp published no L0301 diagnostic")))
(message "emacs lsp smoke clean")
;;; emacs-lsp-smoke.el ends here
