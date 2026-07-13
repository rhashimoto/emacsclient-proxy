#!/usr/bin/env python3
import sys
import os
import argparse
import socket

def main():
    # Use standard argparse now that -h is free for help
    parser = argparse.ArgumentParser(description="Emacsclient Proxy Script")
    parser.add_argument("-a", dest="host_address", default="127.0.0.1:3649",
                        help="Specify the host where emacs is running (format host:port or host, default port 3649).")
    parser.add_argument("-p", dest="prefix", default="",
                        help="Specify the prefix to prepend to the file path (default is empty string).")
    parser.add_argument("filepath", help="The path of the file to open.")

    args = parser.parse_args()

    host_address = args.host_address
    prefix = args.prefix
    filepath = args.filepath

    # Parse host and port
    host = "127.0.0.1"
    port = 3649

    if ":" in host_address:
        parts = host_address.rsplit(":", 1)
        host = parts[0]
        try:
            port = int(parts[1])
        except ValueError:
            port = 3649
    else:
        host = host_address

    # Convert filepath to absolute path
    abs_path = os.path.abspath(filepath)
    payload = prefix + abs_path + "\n"

    # Connect to the Emacs server
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.connect((host, port))
        s.sendall(payload.encode("utf-8"))
        
        # Wait until the Emacs server closes the connection
        while True:
            data = s.recv(4096)
            if not data:
                break
    except Exception as e:
        print(f"Error communicating with Emacs server at {host}:{port}: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        s.close()

if __name__ == "__main__":
    main()
