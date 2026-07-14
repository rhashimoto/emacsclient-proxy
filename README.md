# emacsclient-proxy

When working inside a sandbox (like a Docker container), I sometimes want to edit files using Emacs on the host (e.g., when running `git commit`). 

This is often done by using `emacsclient` on the remote context over a network or unix socket. However, this is a security risk:
* The standard Emacs server protocol allows clients to send and execute arbitrary Emacs Lisp code (via the `-e` / `--eval` flags or direct socket commands).
* If an untrusted process or dependency inside your container gains access to the Emacs socket, it can execute arbitrary commands on your host machine with your host user's privileges (e.g., executing shell commands, reading private keys, or modifying host files).

emacsclient-proxy is a minimal bridge to use Emacs as your `EDITOR` from sandboxed contexts (such as Docker containers or virtual machines) without exposing your host machine to arbitrary code execution.

This repository contains:
* **`emacsclient-proxy.el`**: A lightweight TCP server running inside your host Emacs.
* **`emacsclient-proxy.py`**: A client Python script to be placed in untrusted environments and set as your `EDITOR` variable.

## How it works

Instead of exposing the Emacs server port, this proxy acts as a secure single-purpose firewall:

1. **Custom Server (`emacsclient-proxy.el`)**: Runs on the host and exposes a minimal TCP port. Unlike the standard Emacs server, it does not understand or allow Lisp evaluation.
2. **Strict Protocol**: It only accepts a single line of text representing the absolute path of the file to open. 
3. **Double-Dash Protection**: The server invokes the host's real `emacsclient` by prepending `--` to the argument (e.g., `emacsclient -- <file>`). This forces Emacs to treat the input strictly as a file path, rendering option injection (such as passing `-e` or `--eval`) entirely impossible.

## Setup

### 1. Host Setup (Emacs)

Place `emacsclient-proxy.el` in your Emacs load path and load it in your init file (e.g., `~/.emacs` or `~/.emacs.d/init.el`):

```elisp
(add-to-list 'load-path "/path/to/directory-containing-file")

(use-package emacsclient-proxy
  :config
  (server-start)
  (emacsclient-proxy-start "192.168.64.1"))
```

You can customize the binding address when starting:
* `"localhost:3649"`: Listen on loopback only (safest for local use).
* `"0.0.0.0:3649"`: Listen on all interfaces (use with caution).

### 2. Sandbox Setup (The `EDITOR` Variable)

Install python3 if missing. Copy `emacsclient-proxy.py` into your container or sandbox context, ensure it is executable, and configure your shell to use it as the default editor, e.g. in `~/.bashrc`:

```bash
# Automatically detect the default routing gateway (useful in Docker/VMs)
_GATEWAY=$(ip route show 2>/dev/null | grep default | awk '{print $3}')
if [ -z "$_GATEWAY" ]; then
    _GATEWAY="192.168.64.1" # Fallback gateway address
fi

# Set the EDITOR environment variable
export EDITOR="/path/to/emacsclient-proxy.py -a $_GATEWAY -p /docker:$(hostname):"
```

#### Client Options:
* `-a <host:port>`: Specifies the address of the host machine running the Emacs proxy server (defaults to `127.0.0.1:3649` if omitted).
* `-p <prefix>`: Specifies an optional prefix to prepend to the absolute path of the file being edited (useful for informing Emacs that the file is located on a specific TRAMP path, e.g., `/docker:my-container-name:`).
