;; Write a TCP server in Emacs elisp using make-network-process. When
;;  a client connects to the server and sends a string followed by a
;;  newline character, the server should invoke a platform shell
;;  command to invoke emacsclient with the string argument. When the
;;  shell command exits, the server should close the client
;;  connection.

(defvar emacsclient-proxy-process nil
  "Holds the active server process.")

(defun emacsclient-proxy-sentinel (client-proc event)
  "Sentinel to handle connection changes for the client network processes."
  (message "Client process %s event: %s" client-proc (string-trim-right event)))

(defun my-emacsclient-sentinel (sub-proc event)
  "Sentinel for the spawned emacsclient process.
   When the shell command exits, delete/close the corresponding client network connection."
  (when (memq (process-status sub-proc) '(exit signal))
    (let ((client-proc (process-get sub-proc 'client-proc)))
      (when (and client-proc (member (process-status client-proc) '(open run)))
        (ignore-errors
          ;; Optionally notify the client before closing
          (process-send-string client-proc "Command execution complete. Closing connection.\n")
          (delete-process client-proc))))
    ;; Clean up the subprocess process object
    (delete-process sub-proc)))

(defun emacsclient-proxy--find-emacsclient ()
  "Locate the emacsclient executable.
Checks in `exec-directory` first, then in `../bin/` relative to `exec-directory`,
and finally on the system PATH."
  (let* ((suffix (if (eq system-type 'windows-nt) ".exe" ""))
         (name (concat "emacsclient" suffix))
         (path1 (expand-file-name name exec-directory))
         (path2 (expand-file-name name (expand-file-name "../bin/" exec-directory)))
         (path3 (executable-find name)))
    (cond
     ((and path1 (file-executable-p path1)) path1)
     ((and path2 (file-executable-p path2)) path2)
     ((and path3 (file-executable-p path3)) path3)
     (t name))))

(defun emacsclient-proxy-filter (client-proc string)
  "Filter to accumulate client input and trigger emacsclient on newline."
  (let* ((accumulated (concat (or (process-get client-proc 'accumulated) "") string)))
    (if (string-match "\n" accumulated)
      (let* ((lines (split-string accumulated "\n"))
              (arg (car lines)))
        ;; Strip carriage returns (handles CRLF / Windows-style line endings)
        (setq arg (replace-regexp-in-string "\r$" "" arg))

        ;; Stop accepting/processing further input from this client
        (set-process-filter client-proc nil)

        ;; Start the platform shell process with safely escaped arguments
        (message "Invoking emacsclient with arg: %s" arg)
        (let* ((emacsclient-bin (emacsclient-proxy--find-emacsclient))
               (quoted-bin (shell-quote-argument emacsclient-bin))
               (quoted-arg (shell-quote-argument arg))
               (shell-command (concat quoted-bin " -- " quoted-arg))
               (sub-proc (start-process-shell-command "emacsclient-runner" nil shell-command)))
          ;; Save a reference to the network client in the runner process
          (process-put sub-proc 'client-proc client-proc)
          ;; Attach sentinel to detect when shell execution ends
          (set-process-sentinel sub-proc #'my-emacsclient-sentinel)))
      ;; If newline not reached yet, keep accumulating buffer
      (process-put client-proc 'accumulated accumulated))))

   ;;;###autoload
(defun emacsclient-proxy-start (address)
  "Start the TCP server listening on ADDRESS.
ADDRESS is a string specifying the interface and port to listen on.
Examples of ADDRESS:
  \"192.168.2.1\"      - Listen on 192.168.2.1 and default port 3649.
  \"192.168.2.1:1234\" - Listen on 192.168.2.1 and explicit port 1234.
  \":1234\"            - Listen on loopback (127.0.0.1) and port 1234.
  \"0.0.0.0\"          - Listen on all interfaces on default port 3649.

When called interactively, default is \"localhost:3649\"."
  (interactive
   (list (let ((input (read-string "Listen address (default localhost:3649): " nil nil "localhost:3649")))
           (if (string= input "") "localhost:3649" input))))
  (when (and emacsclient-proxy-process (process-status emacsclient-proxy-process))
    (error "Server is already running"))
  (let* ((addr (or address "localhost:3649"))
         (host "127.0.0.1")
         (port 3649))
    ;; Parse host and port from the address string
    (if (string-match "\\(.*\\):\\([0-9]+\\)" addr)
        (let ((h (match-string 1 addr))
              (p (string-to-number (match-string 2 addr))))
          (setq host (if (string= h "") "127.0.0.1" h))
          (setq port p))
      (setq host addr))
    (setq emacsclient-proxy-process
          (make-network-process
           :name "emacsclient-proxy"
           :buffer nil
           :family 'ipv4
           :server t
           :host host
           :service port
           :filter #'emacsclient-proxy-filter
           :sentinel #'emacsclient-proxy-sentinel))
    (message "TCP server started on %s (port %d)" host port)))

(defun emacsclient-proxy-stop ()
  "Stop the TCP server."
  (interactive)
  (if emacsclient-proxy-process
    (progn
      (delete-process emacsclient-proxy-process)
      (setq emacsclient-proxy-process nil)
      (message "TCP server stopped."))
    (message "No server is currently running.")))

(provide 'emacsclient-proxy)
