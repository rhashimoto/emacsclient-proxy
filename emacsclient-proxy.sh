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
# Debian, and Fedora, and its default stdio<->TCP relay behavior already
# matches what we need: forward stdin, half-close the write side on EOF,
# keep reading the socket until the peer closes, then exit.

set -euo pipefail

DEFAULT_HOST_ADDRESS="127.0.0.1:3649"
DEFAULT_PORT=3649

host_address="$DEFAULT_HOST_ADDRESS"
prefix=""

print_usage() {
    cat <<EOF
usage: $(basename "$0") [-h] [-a HOST_ADDRESS] [-p PREFIX] filepath

Emacsclient Proxy Script

positional arguments:
  filepath          The path of the file to open.

options:
  -h                show this help message and exit
  -a HOST_ADDRESS    Specify the host where emacs is running (format
                      host:port or host, default port ${DEFAULT_PORT}).
  -p PREFIX          Specify the prefix to prepend to the file path
                      (default is empty string).
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
#     connection, discarding whatever (if anything) it sends back. ----
if ! error_output=$(printf '%s' "$payload" | socat - "TCP:${host}:${port}" 2>&1 1>/dev/null); then
    echo "Error communicating with Emacs server at ${host}:${port}: ${error_output}" >&2
    exit 1
fi
