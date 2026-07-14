;;; emacsclient-proxy.el --- Minimal TCP proxy for emacsclient -*- lexical-binding: t; -*-

;; Keywords: tools, unix
;; Package-Requires: ((emacs "26.1"))

;;; Commentary:

;; A deliberately dumb TCP server that pairs with emacsclient-proxy.py
;; (or any bash equivalent) running in an untrusted sandbox/container.
;;
;; Unlike the real Emacs server protocol, this one understands exactly
;; one thing: a single line of text terminated by "\n", which it treats
;; strictly as a file path and hands to the host's real `emacsclient'
;; via `start-process' (never a shell, never `eval') with "--" in front
;; of it, so it can never be parsed as a flag such as -e/--eval.  The
;; connection is held open until emacsclient exits, then closed, which
;; is what lets a blocking client (EDITOR=... git commit, etc.) work.
;;
;; A connection that never finishes sending its request line is dropped
;; after `emacsclient-proxy-request-timeout' seconds (default 5); once
;; a line has been received and handed to emacsclient, that timeout no
;; longer applies, so a slow-to-close buffer is never killed for it.
;;
;; The server, and everything it spawns, is stopped automatically and
;; without any "active processes" confirmation prompt when Emacs exits.
;;
;; Usage:
;;   (require 'emacsclient-proxy)
;;   (server-start)
;;   (emacsclient-proxy-start "localhost:3649")

;;; Code:

(require 'subr-x)

(defgroup emacsclient-proxy nil
  "Minimal, eval-free TCP proxy in front of emacsclient."
  :group 'external
  :prefix "emacsclient-proxy-")

(defcustom emacsclient-proxy-default-host "127.0.0.1"
  "Host/interface `emacsclient-proxy-start' binds to when ADDRESS omits one."
  :type 'string
  :group 'emacsclient-proxy)

(defcustom emacsclient-proxy-default-port 3649
  "TCP port `emacsclient-proxy-start' binds to when ADDRESS omits one."
  :type 'integer
  :group 'emacsclient-proxy)

(defcustom emacsclient-proxy-max-request-size 65536
  "Max bytes buffered from a client before a newline is seen.
A client that never sends a newline would otherwise make this process
buffer an unbounded amount of untrusted data in memory; once a
connection crosses this many bytes without completing a line, it is
dropped instead."
  :type 'integer
  :group 'emacsclient-proxy)

(defcustom emacsclient-proxy-close-message nil
  "If non-nil, a string sent to the client just before its socket is closed.
Left at nil by default so the wire protocol matches what is documented:
a single line in, then nothing but a closed connection."
  :type '(choice (const :tag "Send nothing" nil) string)
  :group 'emacsclient-proxy)

(defcustom emacsclient-proxy-request-timeout 5
  "Seconds a client has to finish sending its request line.
This only bounds the time spent waiting for the initial newline-
terminated file path.  Once a request has been dispatched to
emacsclient, this timeout no longer applies, so a slow-to-close buffer
never gets a connection killed out from under it.  Set to nil to
disable the timeout entirely."
  :type '(choice (const :tag "Disabled" nil) number)
  :group 'emacsclient-proxy)

(defvar emacsclient-proxy--process nil
  "The listening server process started by `emacsclient-proxy-start'.")

(defun emacsclient-proxy--find-emacsclient ()
  "Locate the real emacsclient executable.
Tries, in order:
  1. Next to the running Emacs binary itself (`invocation-directory').
  2. In a `bin/' subdirectory of `invocation-directory' -- this is
     where app-bundle builds such as emacsformacosx.com's Emacs.app
     put it, e.g. .../Emacs.app/Contents/MacOS/bin/emacsclient next to
     .../Emacs.app/Contents/MacOS/Emacs.
  3. Wherever `exec-path' turns it up, via `executable-find'.
If none of those succeed, return the bare program name and let
`start-process' report the failure at spawn time."
  (let* ((name (concat "emacsclient" (if (eq system-type 'windows-nt) ".exe" "")))
         (candidates
          (and invocation-directory
               (list (expand-file-name name invocation-directory)
                     (expand-file-name name (expand-file-name "bin" invocation-directory)))))
         (found (catch 'found
                  (dolist (candidate candidates)
                    (when (file-executable-p candidate)
                      (throw 'found candidate)))
                  nil)))
    (or found (executable-find name) name)))

(defun emacsclient-proxy--parse-address (address)
  "Parse ADDRESS into a (HOST . PORT) cons.
ADDRESS may be \"HOST\", \"HOST:PORT\", or \":PORT\"; a missing HOST
defaults to `emacsclient-proxy-default-host' and a missing PORT to
`emacsclient-proxy-default-port'.  Signal an error if ADDRESS contains
a colon that is not followed by a plain non-negative integer port,
rather than silently misparsing it."
  (cond
   ((string-match "\\`\\(.*\\):\\([0-9]+\\)\\'" address)
    (let ((host (match-string 1 address))
          (port (string-to-number (match-string 2 address))))
      (cons (if (string-empty-p host) emacsclient-proxy-default-host host)
            port)))
   ((string-match-p ":" address)
    (error "emacsclient-proxy: invalid address %S" address))
   (t (cons address emacsclient-proxy-default-port))))

(defun emacsclient-proxy--cancel-timeout (client-proc)
  "Cancel and clear any pending request timeout timer on CLIENT-PROC."
  (let ((timer (process-get client-proc 'emacsclient-proxy--timeout-timer)))
    (when timer
      (cancel-timer timer)
      (process-put client-proc 'emacsclient-proxy--timeout-timer nil))))

(defun emacsclient-proxy--timeout-client (client-proc)
  "Drop CLIENT-PROC if it never finished sending a request line.
Scheduled by `emacsclient-proxy--sentinel' when CLIENT-PROC is
accepted, and canceled by `emacsclient-proxy--filter' as soon as a
complete line arrives, so by the time this actually runs the
connection is known to have stalled."
  (process-put client-proc 'emacsclient-proxy--timeout-timer nil)
  (when (process-live-p client-proc)
    (message "emacsclient-proxy: client %s timed out waiting for a request line"
              client-proc)
    (delete-process client-proc)))

(defun emacsclient-proxy--sentinel (client-proc event)
  "Log connection state changes for CLIENT-PROC and manage its lifecycle.
EVENT is the event string Emacs supplies to network process sentinels.
CLIENT-PROC is exempted from the \"active processes exist\" kill-emacs
confirmation, and, on the initial \"open\" event, has a
`emacsclient-proxy-request-timeout' countdown started; any other event
means the connection is going away, so that timer (if still pending) is
canceled."
  (message "emacsclient-proxy: client %s: %s" client-proc (string-trim-right event))
  (set-process-query-on-exit-flag client-proc nil)
  (if (string-prefix-p "open" event)
      (when emacsclient-proxy-request-timeout
        (process-put client-proc 'emacsclient-proxy--timeout-timer
                     (run-at-time emacsclient-proxy-request-timeout nil
                                  #'emacsclient-proxy--timeout-client client-proc)))
    (emacsclient-proxy--cancel-timeout client-proc)))

(defun emacsclient-proxy--emacsclient-sentinel (sub-proc _event)
  "Sentinel for the emacsclient process SUB-PROC.
Once SUB-PROC exits, close the network client connection stashed on it
by `emacsclient-proxy--dispatch': the client is expected to block until
this happens, so we must close it whether emacsclient succeeded,
failed, or was killed."
  (when (memq (process-status sub-proc) '(exit signal))
    (let ((client-proc (process-get sub-proc 'emacsclient-proxy--client-proc)))
      (when (process-live-p client-proc)
        (when emacsclient-proxy-close-message
          (ignore-errors
            (process-send-string client-proc emacsclient-proxy-close-message)))
        (delete-process client-proc)))
    (delete-process sub-proc)))

(defun emacsclient-proxy--dispatch (client-proc filepath)
  "Run emacsclient on FILEPATH and close CLIENT-PROC once it exits.
If emacsclient cannot even be started, CLIENT-PROC is closed
immediately instead of being left open forever."
  (message "emacsclient-proxy: opening %s for client %s" filepath client-proc)
  (condition-case err
      (let* ((emacsclient-bin (emacsclient-proxy--find-emacsclient))
             ;; "--" forces emacsclient to treat FILEPATH as a plain
             ;; positional argument, never as a flag (e.g. -e/--eval),
             ;; even if FILEPATH itself starts with a dash.  This is
             ;; passed as its own argv element via `start-process', not
             ;; through a shell, so there is no quoting step that could
             ;; be gotten wrong or bypassed.
             (sub-proc (start-process "emacsclient-proxy-runner" nil
                                       emacsclient-bin "--" filepath)))
        (set-process-query-on-exit-flag sub-proc nil)
        (process-put sub-proc 'emacsclient-proxy--client-proc client-proc)
        (set-process-sentinel sub-proc #'emacsclient-proxy--emacsclient-sentinel))
    (error
     (message "emacsclient-proxy: failed to start emacsclient: %s"
              (error-message-string err))
     (delete-process client-proc))))

(defun emacsclient-proxy--filter (client-proc string)
  "Process filter that accumulates input from CLIENT-PROC.
Buffers STRING until a newline appears, then treats everything before
it as a single file path and dispatches emacsclient with it.  Anything
received after that first newline is ignored.  Connections that send
`emacsclient-proxy-max-request-size' bytes without ever completing a
line are dropped rather than buffered indefinitely."
  (let ((accumulated (concat (or (process-get client-proc 'emacsclient-proxy--accumulated) "")
                              string)))
    (cond
     ((> (length accumulated) emacsclient-proxy-max-request-size)
      (message "emacsclient-proxy: client %s exceeded max request size, dropping"
                client-proc)
      (emacsclient-proxy--cancel-timeout client-proc)
      (delete-process client-proc))
     ((string-match "\n" accumulated)
      (let ((line (string-remove-suffix "\r" (substring accumulated 0 (match-beginning 0)))))
        ;; Stop accepting further input from this client; do this via an
        ;; explicit no-op filter rather than relying on the default
        ;; filter's (undocumented-at-the-call-site) behavior for
        ;; bufferless processes.
        (set-process-filter client-proc #'ignore)
        ;; The request line is complete, so the "did the client ever
        ;; finish sending a line" timeout no longer applies -- whatever
        ;; happens next (including a slow emacsclient run) must not be
        ;; cut short by it.
        (emacsclient-proxy--cancel-timeout client-proc)
        (if (string-empty-p line)
            (progn
              (message "emacsclient-proxy: empty path from client %s" client-proc)
              (delete-process client-proc))
          (emacsclient-proxy--dispatch client-proc line))))
     (t
      (process-put client-proc 'emacsclient-proxy--accumulated accumulated)))))

;;;###autoload
(defun emacsclient-proxy-start (&optional address)
  "Start the TCP server, listening on ADDRESS.
ADDRESS is a string specifying the interface and port to listen on; it
defaults to `emacsclient-proxy-default-host' and
`emacsclient-proxy-default-port' when omitted.  Examples of ADDRESS:

  \"192.168.2.1\"      - listen on 192.168.2.1, default port.
  \"192.168.2.1:1234\" - listen on 192.168.2.1, port 1234.
  \":1234\"            - listen on the default host, port 1234.
  \"0.0.0.0\"          - listen on all interfaces, default port.

When called interactively, prompts for ADDRESS."
  (interactive
   (list (let ((input (read-string
                        (format "Listen address (default %s:%d): "
                                emacsclient-proxy-default-host
                                emacsclient-proxy-default-port))))
           (unless (string-empty-p input) input))))
  (when (process-live-p emacsclient-proxy--process)
    (error "emacsclient-proxy: server is already running"))
  (let* ((addr (or address (format "%s:%d" emacsclient-proxy-default-host
                                    emacsclient-proxy-default-port)))
         (parsed (emacsclient-proxy--parse-address addr))
         (host (car parsed))
         (port (cdr parsed)))
    (setq emacsclient-proxy--process
          (make-network-process
           :name "emacsclient-proxy"
           :buffer nil
           :family 'ipv4
           :server t
           :host host
           :service port
           :filter #'emacsclient-proxy--filter
           :sentinel #'emacsclient-proxy--sentinel))
    (set-process-query-on-exit-flag emacsclient-proxy--process nil)
    (message "emacsclient-proxy: listening on %s:%d" host port)))

(defun emacsclient-proxy-stop ()
  "Stop the TCP server started by `emacsclient-proxy-start'."
  (interactive)
  (if (process-live-p emacsclient-proxy--process)
      (progn
        (delete-process emacsclient-proxy--process)
        (setq emacsclient-proxy--process nil)
        (message "emacsclient-proxy: server stopped"))
    (message "emacsclient-proxy: no server is running")))

;; Emacs asks "Active processes exist; kill them?" before exiting if any
;; process still has its query-on-exit flag on; every process we create
;; has that flag turned off (see `emacsclient-proxy-start' and
;; `emacsclient-proxy--dispatch'), so that confirmation never fires on
;; our account.  This hook additionally makes shutdown explicit: it
;; releases the listening port and any pending timers up front rather
;; than leaving that entirely to the OS reclaiming the process's file
;; descriptors.
(add-hook 'kill-emacs-hook #'emacsclient-proxy-stop)

(provide 'emacsclient-proxy)
;;; emacsclient-proxy.el ends here
