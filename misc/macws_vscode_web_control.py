"""Send a bounded request to MacWS's private VS Code webview endpoint.

This controller-side helper deliberately uses the existing SSH connection and
the private Unix socket.  It does not enable Chromium remote debugging.
"""

from __future__ import annotations

import argparse
import shlex
import subprocess
import sys


SOCKET_PATH = "/var/mnt/rootfs/private/tmp/macws_vscode_url.sock"
CLOSE_REQUEST = "macws-control:close-test-webviews-v1"

REMOTE_CLIENT = r"""
import socket, struct, sys
path, value = sys.argv[1:]
payload = value.encode("utf-8")
if not payload or len(payload) > 8192:
    raise SystemExit("invalid payload length")
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(12.0)
try:
    client.connect(path)
    client.sendall(struct.pack("!I", len(payload)) + payload)
    acknowledgement = client.recv(1)
finally:
    client.close()
if acknowledgement != b"\x01":
    raise SystemExit(f"request rejected: {acknowledgement.hex()}")
print("accepted")
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--user", default="root")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--control-path")
    parser.add_argument("action", choices=("open", "close"))
    parser.add_argument("--url")
    args = parser.parse_args()

    if args.action == "open":
        if not args.url:
            parser.error("open requires --url")
        payload = args.url
    else:
        if args.url:
            parser.error("close does not accept --url")
        payload = CLOSE_REQUEST

    remote_command = " ".join(shlex.quote(value) for value in (
        "/var/jb/usr/bin/python3", "-c", REMOTE_CLIENT,
        SOCKET_PATH, payload,
    ))
    command = [
        "ssh", "-p", str(args.port), "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
    ]
    if args.control_path:
        command += ["-S", args.control_path]
    command += [f"{args.user}@{args.host}", remote_command]
    result = subprocess.run(command, text=True, capture_output=True, timeout=20)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
