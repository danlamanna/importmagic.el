;;; importmagic.el --- Fix Python imports using importmagic.

;; Copyright (c) 2016-2017 Nicolás Salas V.
;;
;; Author: Nicolás Salas V. <nikosalas@gmail.com>
;; URL: https://github.com/anachronic/importmagic.el
;; Keywords: languages, convenience
;; Version: 1.0
;; Package-Requires: ((f "0.11.0") (epc "0.1.0") (emacs "24.3"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; importmagic.el is a package intended to help in the Python
;; development process by providing a way to fix unresolved imports in
;; Python buffers, so if you had the following buffer:

;; os.path.join('path1', 'path2')

;; importmagic.el will provide you a set of functions that will let
;; you fix the unresolved 'os' symbol.

;; The functions can be read on the project's website:

;; https://github.com/anachronic/importmagic.el

;; It's worth noting that you will have to install two Python packages
;; for this to work:
;;
;; - importmagic
;; - epc
;;
;; If you don't have those, importmagic shall gracefully fail and let
;; you know.

;;; Code:

(require 'epc)
(require 'f)

;; This process of creating a mode is rather painless. Thank you
;; nullprogram!
;; http://nullprogram.com/blog/2013/02/06/

(defvar importmagic-auto-update-index t
  "Set to nil if you don't want to auto-update importmagic's symbol index after saving.")
(defvar importmagic-be-quiet nil
  "Set to t if you don't want to see non-error messages.")
(defvar importmagic-server nil
  "The importmagic index server.")
(defvar importmagic-index-ready nil
  "This variable is set to t when the importmagic index is ready to be queried.

Don't set this variable manually.")
(make-variable-buffer-local 'importmagic-server)
(make-variable-buffer-local 'importmagic-index-ready)

(defun importmagic--message (msg &rest args)
  "Show the message MSG with ARGS only if importmagic is set to not be quiet."
  (when (not importmagic-be-quiet)
    (message (concat "[importmagic] " msg) args)))

(defun importmagic--fail (msg)
  "Display an error message MSG and ring the bell when importmagic fails."
  (error (concat "[importmagic] " msg)))

;;;###autoload
(define-minor-mode importmagic-mode
  "A mode that lets you autoimport unresolved Python symbols."
  :init-value nil
  :lighter " import"
  :keymap (let ((keymap (make-sparse-keymap)))
            (define-key keymap (kbd "C-c C-l") 'importmagic-fix-imports)
            keymap)
  (when (not (derived-mode-p 'python-mode))
    (error "Importmagic only works with Python buffers"))
  (if (not importmagic-mode)
      (importmagic--stop-server)
    (condition-case nil
        (importmagic--setup)
      (error (progn
               (message "Importmagic and/or epc not found. importmagic.el will not be working.")
               (importmagic-mode -1) ;; This should take it to the stop server section.
               )))))

(defun importmagic--setup ()
  "Set up importmagic after enabling the minor mode."
  (progn
    (let ((importmagic-path (f-slash (f-dirname (locate-library "importmagic")))))
      (setq importmagic-server
            (epc:start-epc "python"
                           `(,(f-join importmagic-path "importmagicserver.py"))))
      (add-hook 'kill-buffer-hook 'importmagic--teardown-epc)
      (add-hook 'before-revert-hook 'importmagic--teardown-epc)
      (importmagic--build-index))
    t))

(defun importmagic--teardown-epc ()
  "Stop the EPC server for the current buffer."
  (when (and (derived-mode-p 'python-mode)
             importmagic-server
             (symbolp 'importmagic-mode)
             (symbol-value 'importmagic-mode)
             (epc:live-p importmagic-server))
    (epc:stop-epc importmagic-server)))

(defun importmagic--stop-server ()
  "Stop the importmagic EPC server and tear it down."
  (when (and importmagic-server
             (epc:live-p importmagic-server))
    (epc:stop-epc importmagic-server))
  (setq importmagic-server nil))

(defun importmagic--get-top-level ()
  "Get the top level python package for the current file."
  (let ((toplevel (f-dirname (f-this-file))))
    (while (f-exists-p (f-join toplevel "__init__.py"))
      (setq toplevel (f-dirname toplevel)))
    toplevel))

(defun importmagic--build-index ()
  "Build index for current file."
  (setq importmagic-index-ready nil)
  (deferred:$
    (epc:call-deferred importmagic-server
                       'build_index
                       `(,(importmagic--get-toplevel)))
    (deferred:nextc it
      (lambda (result)
        (setq importmagic-index-ready t)
        (importmagic--message "Index ready.")))))

(defun importmagic--buffer-as-string ()
  "Return the whole contents of the buffer as a single string."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun importmagic--call-epc (fun &rest args)
  "Call FUN with ARGS in the epc for the current buffer."
  (if importmagic-index-ready
      (epc:call-sync importmagic-server
                     fun
                     args)
    (importmagic--fail "Index not ready yet. Hang on...")))

(defun importmagic--fix-imports (import-block start end)
  "Insert given IMPORT-BLOCK with import fixups in the current buffer starting in line START and ending in line END."
  (save-restriction
    (save-excursion
      (widen)
      (goto-char (point-min))
      (forward-line start)
      (let ((start-pos (point))
            (end-pos (progn (forward-line (- end start)) (point))))
        (delete-region start-pos end-pos)
        (insert import-block)))))


(defun importmagic--query-imports-for-statement-and-fix (statement)
  "Query importmagic server for STATEMENT imports in the current buffer."
  (let* ((specs (importmagic--call-epc 'get_import_statement
                                       (importmagic--buffer-as-string) statement))
         (start (car specs))
         (end (cadr specs))
         (theblock (caddr specs)))
    (importmagic--fix-imports theblock start end)))

(defun importmagic-fix-symbol (symbol)
  "Fix imports for SYMBOL in current buffer."
  (interactive "sSymbol: ")
  (let ((options (importmagic--call-epc 'get_candidates_for_symbol
                                        symbol)))
    (if (not options)
        (error "No suitable candidates found for %s" symbol)
      (let ((choice (completing-read (concat "Querying for " symbol ": ")
                                     options
                                     nil
                                     t
                                     nil
                                     nil
                                     options)))
        (importmagic--query-imports-for-statement-and-fix choice)
        (importmagic--message "Inserted %s" choice)))))

(defun importmagic-fix-symbol-at-point ()
  "Fix imports for symbol at point."
  (interactive)
  (importmagic-fix-symbol (thing-at-point 'symbol t)))

(defun importmagic--get-unresolved-symbols ()
  "Query the RPC server for every unresolved symbol in the current file."
  (importmagic--call-epc 'get_unresolved_symbols (importmagic--buffer-as-string)))

(defun importmagic-fix-imports ()
  "Fix every possible import in the file."
  (interactive)
  (let ((unresolved (importmagic--get-unresolved-symbols))
        (no-candidates '()))
    (dolist (symbol unresolved)
      (condition-case nil
          (importmagic-fix-symbol symbol)
        (error (setq no-candidates (push symbol no-candidates)))))
    (when no-candidates
      (importmagic--message "Symbols with no candidates: %s" no-candidates))))

(defun importmagic--echo-test ()
  (importmagic--call-epc 'echo (concat "Hola" "wmazo")))


(provide 'importmagic)
;;; importmagic.el ends here
