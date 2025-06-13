;;; goose.el --- Integrate Goose CLI via vterm -*- lexical-binding: t; -*-

;; Author: Daisuke Terada <pememo@gmail.com>
;; Package-Requires: ((emacs "29") (vterm "0.0.2") (transient "0.9.1") (consult "2.5"))
;; Version: 0.1.0
;; Keywords: tools, convenience, ai
;; URL: https://github.com/aq2bq/goose.el

;;; Commentary:
;; Seamless integration of the Goose CLI within Emacs using the `vterm` terminal emulator.
;;
;; Provides:
;; - Intuitive session management: start and restart Goose CLI sessions with easy labeling (name or timestamp)
;; - Immediate context injection (file path, buffer, region, template, text) into the Goose prompt, sent directly (no internal queuing)
;; - Prompt templates (consult-based), auto-detected from ~/.config/goose/prompts/
;; - Customizable context formatting, prompt directory, and keybinding (transient menu)
;; - Designed for rapid AI prompt iteration and CLI-interactive workflows from Emacs
;;
;; Usage example:
;;   M-x goose-start-session
;;   M-x goose-add-context-buffer ; send current buffer to the Goose session
;;

;; The MIT License (MIT)
;;
;; Copyright (c) 2025 Daisuke Terada
;;
;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Code:
(require 'vterm)
(require 'transient)
(require 'consult)

(define-derived-mode goose-mode vterm-mode "Goose"
  "Major mode for Goose terminal (inherits `vterm-mode').
This mode provides `goose-mode-hook` for customizations.
Do not call this mode interactively.  Use `goose-start-session` instead."
  (when (called-interactively-p 'interactive)
    (user-error "`goose-mode` is an internal mode.  Use `M-x goose-start-session` instead")))

;; Prevent interactive use from misapplying to the current buffer
(put 'goose-mode 'function-documentation
     "Goose terminal mode. Do not call directly. Use `goose-start-session` instead.")
(put 'goose-mode 'interactive-form
     '(progn (user-error "`goose-mode` is not meant to be called interactively.  Use `M-x goose-start-session` instead")))


(defgroup goose nil
  "Goose CLI integration using vterm."
  :group 'tools)

(defcustom goose-program-name "goose"
  "Name or path of the Goose CLI executable."
  :type 'string
  :group 'goose)

(defcustom goose-default-buffer-name "*goose*"
  "Default buffer name prefix for Goose sessions."
  :type 'string
  :group 'goose)

(defcustom goose-prompt-directory (expand-file-name "~/.config/goose/prompts/")
  "Directory containing prompt templates for Goose integration."
  :type 'directory
  :group 'goose)

(defcustom goose-context-format "%s"
  "Format string applied to CONTEXT text before sending to Goose.
Use %s as placeholder for the raw text."
  :type 'string
  :group 'goose)

(defcustom goose-context-file-path-prefix "File from path: %s"
  "Prefix format for inserting file path into Goose.  %s will be replaced by the file path."
  :type 'string
  :group 'goose)

(defcustom goose-context-buffer-prefix "File: %s\n%s"
  "Prefix format for inserting buffer content into Goose.  %s will be replaced by file path and buffer content."
  :type 'string
  :group 'goose)

(defcustom goose-context-region-prefix "File: %s\nRegion:\n%s"
  "Prefix format for inserting region content into Goose.  %s will be replaced by file path and region."
  :type 'string
  :group 'goose)

(defvar goose--last-args nil
  "Last Goose CLI argument list for restart.")

(defvar goose--last-label nil
  "Last session label for restart.")

(defun goose--session-label (name)
  "Return session label for NAME, or timestamp string if NAME is empty."
  (if (and name (not (string-empty-p name)))
      (shell-quote-argument name)
    (format-time-string "%Y%m%d-%H%M%S")))

(defun goose--build-args (name)
  "Construct Goose CLI argument list for 'session --name NAME'."
  (let* ((label (goose--session-label name))
         (base-args (list "session" "--name" label)))
    base-args))

(defun goose--run-session (label args)
  "Start or restart a Goose session buffer labeled LABEL with ARGS list."
  (let ((bufname (format "%s<%s>" goose-default-buffer-name label)))
    (when (get-buffer bufname)
      (kill-buffer bufname))
    (let* ((proj (when (fboundp 'project-current) (project-current)))
           (root (when proj (project-root proj)))
           (default-directory (or root default-directory))
           (vterm-buffer (generate-new-buffer bufname)))
      (with-current-buffer vterm-buffer
        (let ((vterm-shell "/bin/bash"))
          (goose-mode)
          (rename-buffer bufname t)
          (vterm-send-key "l" nil nil :ctrl) ;; suppress any previous output
          (vterm-send-string
           (mapconcat #'identity (cons goose-program-name args) " "))
          (vterm-send-return)))
      (setq goose--last-label label
            goose--last-args  args)
      (pop-to-buffer vterm-buffer)
      (message "Goose session started in buffer %s (dir: %s)" bufname default-directory))))

;;;###autoload
(defun goose-start-session (&optional name)
  "Start a new Goose session with optional NAME, or switch if exists."
  (interactive "sSession name (optional): ")
  (let ((label (goose--session-label name))
        (args  (goose--build-args   name)))
    (goose--run-session label args)))

;;;###autoload
(defun goose-restart-session ()
  "Restart the last Goose session using previous NAME and ARGS, with confirmation."
  (interactive)
  (unless (and goose--last-label goose--last-args)
    (error "No Goose session to restart"))
  (when (yes-or-no-p (format "Restart Goose session <%s>? " goose--last-label))
    (goose--run-session goose--last-label goose--last-args)))

(defun goose--session-buffer-name ()
  "Return the current Goose session buffer name."
  (format "%s<%s>" goose-default-buffer-name goose--last-label))

(defun goose--insert-context (text)
  "Send TEXT as input to the current Goose session, deferring execution until RET.
Applies `goose-context-format` to TEXT before sending.
If the session is not started, starts it automatically."
  (let* ((bufname (goose--session-buffer-name))
         (buf     (get-buffer bufname)))
    (unless buf
      (goose-start-session)
      (setq buf (get-buffer (goose--session-buffer-name))))
    (with-current-buffer buf
      (vterm-send-string (format goose-context-format text))
      (vterm-send-key "j" nil nil :ctrl))))

;;;###autoload
(defun goose-add-context-file-path ()
  "Insert the current buffer's file path into the Goose prompt."
  (interactive)
  (unless (buffer-file-name) (error "Buffer is not visiting a file"))
  (goose--insert-context (format goose-context-file-path-prefix (buffer-file-name)))
  (message "Inserted file path into prompt"))

;;;###autoload
(defun goose-add-context-buffer ()
  "Insert the current buffer's content and file path into the Goose prompt."
  (interactive)
  (goose--insert-context
   (format goose-context-buffer-prefix
           (or (buffer-file-name) "<no file>")
           (buffer-string)))
  (message "Inserted buffer content into prompt"))

;;;###autoload
(defun goose-add-context-region ()
  "Insert the active region's content and file path into the Goose prompt."
  (interactive)
  (unless (use-region-p) (error "No region selected"))
  (goose--insert-context
   (format goose-context-region-prefix
           (or (buffer-file-name) "<no file>")
           (buffer-substring-no-properties
            (region-beginning)
            (region-end))))
  (message "Inserted region into prompt"))

;;;###autoload
(defun goose-add-context-template ()
  "Insert a prompt template from `goose-prompt-directory' into the Goose prompt."
  (interactive)
  (unless (file-directory-p goose-prompt-directory)
    (error "Prompt directory %s does not exist" goose-prompt-directory))
  (let* ((files (directory-files goose-prompt-directory nil "^[^.].*"))
         (choice (consult--read files :prompt "Choose template: "))
         (content (with-temp-buffer
                    (insert-file-contents
                     (expand-file-name choice goose-prompt-directory))
                    (buffer-string))))
    (goose--insert-context content)
    (message "Inserted template %s into prompt" choice)))

;;;###autoload
(defun goose-add-context-text (text)
  "Prompt for and insert arbitrary TEXT into the Goose prompt."
  (interactive "sText to insert: ")
  (goose--insert-context text)
  (message "Inserted text into prompt"))

;;;###autoload
(transient-define-prefix goose-transient ()
  "Transient interface for Goose commands."
  ["Goose Session"
   ("s" "Start session" goose-start-session)
   ("r" "Restart session" goose-restart-session)]
  ["Insert Context"
   ("f" "File path" goose-add-context-file-path)
   ("b" "Buffer" goose-add-context-buffer)
   ("e" "Region" goose-add-context-region)
   ("t" "Template" goose-add-context-template)
   ("x" "Text" goose-add-context-text)])


(provide 'goose)
;;; goose.el ends here
