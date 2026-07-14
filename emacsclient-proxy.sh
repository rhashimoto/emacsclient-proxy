#!/usr/bin/env bash
#
# emacsclient-proxy.sh
#
# Drop-in bash replacement for emacsclient-proxy.py.
#
# Connects to the emacsclient-proxy.el TCP server, sends a single line
# consisting of an optional prefix followed by the absolute path of the
# file to open, and blocks until the server closes the connection.
#
# Uses `socat` rather than `nc`: `nc` is really three incompatible
# programs (BSD netcat, GNU netcat, busybox netcat on Alpine) that
# disagree on flags and, more importantly, on half-close behavior after
# stdin EOF. `socat` has one consistent implementation across Alpine,
# Debian, and Fedora. Getting it to actually block until the *server*
# closes the connection needs two overrides beyond the defaults -- see
# the comment above the socat invocation below for why.

set -euo pipefail

DEFAULT_HOST_ADDRESS="127.0.0.1:3649"
DEFAULT_PORT=3649
# How long socat should keep waiting for the *server* to close its side
# once our side has finished sending. socat's own default for this is a
# mere 0.5s (its -t option), which is nowhere near long enough here: our
# payload is a single short line, so our sending side reaches EOF almost
# instantly, but the server intentionally keeps the connection open for
# as long as the user is editing the file -- anywhere from seconds to
# hours. Without overriding -t, socat gives up and exits early, well
# before the server actually closes the connection. A large-but-finite
# value avoids that while still eventually giving up on a truly wedged
# connection. Override with -w if a different bound is wanted.
DEFAULT_WAIT_TIMEOUT=604800  # 1 week

host_address="$DEFAULT_HOST_ADDRESS"
prefix=""
wait_timeout="$DEFAULT_WAIT_TIMEOUT"

print_usage() {
    cat <<EOF
usage: $(basename "$0") [-h] [-a HOST_ADDRESS] [-p PREFIX] [-w SECONDS] filepath

Emacsclient Proxy Script

positional arguments:
  filepath          The path of the file to open.

options:
  -h                show this help message and exit
  -a HOST_ADDRESS    Specify the host where emacs is running (format
                      host:port or host, default port ${DEFAULT_PORT}).
  -p PREFIX          Specify the prefix to prepend to the file path
                      (default is empty string).
  -w SECONDS         Safety-net timeout (socat's -t) for how long to keep
                      waiting once socat's own write side is shut down
                      (default ${DEFAULT_WAIT_TIMEOUT}s / 1 week). Rarely
                      matters in practice -- see the comment above the
                      socat invocation near the bottom of this script.
EOF
}

# --- Argument parsing (mirrors argparse: options may appear before or
#     after the positional filepath argument) -------------------------
positional=()
while [ $# -gt 0 ]; do
    case "$1" in
        -a)
            [ $# -ge 2 ] || { echo "Error: -a requires an argument" >&2; exit 2; }
            host_address="$2"
            shift 2
            ;;
        -a?*)
            host_address="${1#-a}"
            shift
            ;;
        -p)
            [ $# -ge 2 ] || { echo "Error: -p requires an argument" >&2; exit 2; }
            prefix="$2"
            shift 2
            ;;
        -p?*)
            prefix="${1#-p}"
            shift
            ;;
        -w)
            [ $# -ge 2 ] || { echo "Error: -w requires an argument" >&2; exit 2; }
            wait_timeout="$2"
            shift 2
            ;;
        -w?*)
            wait_timeout="${1#-w}"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        --)
            shift
            while [ $# -gt 0 ]; do
                positional+=("$1")
                shift
            done
            ;;
        -*)
            echo "Unknown option: $1" >&2
            print_usage >&2
            exit 2
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

if [ "${#positional[@]}" -lt 1 ]; then
    echo "Error: the following arguments are required: filepath" >&2
    print_usage >&2
    exit 2
fi

filepath="${positional[0]}"

# --- Parse host and port (mirrors host_address.rsplit(":", 1)) -------
host="127.0.0.1"
port="$DEFAULT_PORT"

if [[ "$host_address" == *:* ]]; then
    host="${host_address%:*}"
    port_part="${host_address##*:}"
    if [[ "$port_part" =~ ^[0-9]+$ ]]; then
        port="$port_part"
    else
        port="$DEFAULT_PORT"
    fi
else
    host="$host_address"
fi

# --- Compute absolute path, matching Python's os.path.abspath():
#     lexical normalization (collapse '.', '..', repeated slashes),
#     no symlink resolution, no requirement that the path exist. -------
abspath() {
    local path="$1"
    if [[ "$path" != /* ]]; then
        path="$(pwd)/$path"
    fi

    local IFS='/'
    local -a parts
    read -ra parts <<< "$path"

    local -a stack=()
    local part
    for part in "${parts[@]}"; do
        case "$part" in
            ""|".")
                ;;
            "..")
                if [ "${#stack[@]}" -gt 0 ]; then
                    unset 'stack[${#stack[@]}-1]'
                fi
                ;;
            *)
                stack+=("$part")
                ;;
        esac
    done

    if [ "${#stack[@]}" -eq 0 ]; then
        printf '/\n'
    else
        local IFS='/'
        printf '/%s\n' "${stack[*]}"
    fi
}

abs_path="$(abspath "$filepath")"
payload="${prefix}${abs_path}"$'\n'

# --- Send the payload, then block until the server closes the
#     connection, discarding whatever (if anything) it sends back.
#
#     shut-none on the TCP address stops socat from ever sending a
#     half-close (TCP FIN) once our side of the pipe reaches EOF. We
#     don't need the server to see that FIN -- it already knows we're
#     done as soon as it sees the newline -- but some VM/NAT network
#     layers (e.g. Lima/Colima's userland networking, recognizable by a
#     192.168.64.x gateway) don't propagate a half-close correctly and
#     instead tear down the *entire* connection the moment they see
#     that first FIN, well before the server ever gets to close its
#     side on its own terms. Not sending it at all sidesteps that.
#
#     -t is kept as a secondary safety net: it bounds how long socat
#     waits after ITS OWN write side is told to shut down (which now
#     only happens when the real server closes the connection), in the
#     unlikely case that shutdown itself somehow stalls. -------------
if ! error_output=$(printf '%s' "$payload" \
        | socat -t "$wait_timeout" - "TCP:${host}:${port},shut-none" 2>&1 1>/dev/null); then
    echo "Error communicating with Emacs server at ${host}:${port}: ${error_output}" >&2
    exit 1
fi
