;;; goose.el --- Integrate Emacs with Goose CLI via EAT -*- lexical-binding: t; -*-
;;; goose.el --- Integrate Emacs with Goose CLI via vterm -*- lexical-binding: t; -*-

;; Author: Daisuke Terada <pememo@gmail.com>
;; Package-Requires: ((emacs "29") (eat "0.9.4") (transient "0.9.1") (consult "2.5"))
;; Version: 0.1.0
;; Keywords: tools, convenience, ai
;; URL: https://github.com/aq2bq/goose.el

;;; Commentary:
;; Seamless integration of the Goose CLI within Emacs using the EAT terminal emulator.
;;
;; Provides:
;; - Intuitive session management: start and restart Goose CLI sessions with easy labeling (name or timestamp)
;; - Immediate context injection (file path, buffer, region, template, text) into the Goose prompt, sent directly (no internal queueing)
;; - Prompt templates (consult-based), auto-detected from ~/.config/goose/prompts/
;; - Customizable context formatting, prompt directory, and keybinding (transient menu)
;; - Designed for rapid AI prompt iteration and CLI-interactive workflows from Emacs
;;
;; Usage example:
;;   M-x goose-start-session
;;   M-x goose-add-context-buffer ; send current buffer to the Goose session
;;

;;; Code:
(require 'vterm)
(require 'transient)
(require 'consult)

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

(defcustom goose-disable-spinner nil
  "When non-nil, pass `--no-spinner` to Goose to disable spinner output."
  :type 'boolean
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

(defcustom goose-transient-key (kbd "C-c g")
  "Keybinding to invoke the Goose transient interface."
  :type 'key-sequence
  :group 'goose)

(defvar goose--last-args nil
  "Last Goose CLI argument list for restart.")

(defvar goose--last-label nil
  "Last session label for restart.")

(defun goose--session-label (name)
  "Return session label for NAME, or timestamp string if NAME is empty."
  (if (and name (not (string-empty-p name)))
      name
    (format-time-string "%Y%m%d-%H%M%S")))

(defun goose--build-args (name)
  "Construct Goose CLI argument list for 'session --name LABEL'."
  (let* ((label (goose--session-label name))
         (base-args (list "session" "--name" label)))
    (when goose-disable-spinner
      (setq base-args (append base-args '("--no-spinner"))))
    base-args))

(defun goose--run-session (label args)
  "Start or restart a Goose session buffer labelled LABEL with ARGS list."
  (let ((bufname (format "%s<%s>" goose-default-buffer-name label)))
    (when (get-buffer bufname)
      (kill-buffer bufname))
    (let ((vterm-buffer (generate-new-buffer bufname)))
      (with-current-buffer vterm-buffer
        (let ((vterm-shell "/bin/bash")) ; vtermはSHELL起動
          (vterm-mode)
          (rename-buffer bufname t)
          (vterm-send-string
           (mapconcat #'identity (cons goose-program-name args) " "))
          (vterm-send-return)))
      (setq goose--last-label label
            goose--last-args  args)
      (switch-to-buffer vterm-buffer)
      (message "Goose session started in buffer %s" bufname))))

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
Applies `goose-context-format` to TEXT before sending."
  (let* ((bufname (goose--session-buffer-name))
         (buf     (get-buffer bufname)))
    (unless buf (error "No Goose session buffer found"))
    (with-current-buffer buf
      (vterm-send-string (format goose-context-format text))
      (vterm-send-C-j))))

;;;###autoload
(defun goose-add-context-file-path ()
  "Insert the current buffer's file path into the Goose prompt."
  (interactive)
  (unless (buffer-file-name) (error "Buffer is not visiting a file"))
  (goose--insert-context (format "File path: %s" (buffer-file-name)))
  (message "Inserted file path into prompt"))

;;;###autoload
(defun goose-add-context-buffer ()
  "Insert the current buffer's content and file path into the Goose prompt."
  (interactive)
  (goose--insert-context
   (format "File: %s\n%s"
           (or (buffer-file-name) "<no file>")
           (buffer-string)))
  (message "Inserted buffer content into prompt"))

;;;###autoload
(defun goose-add-context-region ()
  "Insert the active region's content and file path into the Goose prompt."
  (interactive)
  (unless (use-region-p) (error "No region selected"))
  (goose--insert-context
   (format "File: %s\nRegion:\n%s"
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

;;;###autoload
(global-set-key goose-transient-key 'goose-transient)

(provide 'goose)
;;; goose.el ends here
