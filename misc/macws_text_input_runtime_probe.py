"""Send one Unicode shell command through the production MacWS input socket.

Run with the iOS-side Python interpreter after opening a fresh Terminal:
    python3 macws_text_input_runtime_probe.py PID WINDOW_ID [SOCKET]

The probe deliberately transports the Chinese character as an encoded
software-keyboard keysym.  Verifying the output file therefore exercises the
same macwsinputd -> exact AppInput window -> existing first-responder route as
an iOS IME commit; it does not write the output file itself.
"""

import socket
import struct
import sys
import time


MAGIC = 0x4D574556
WIRE_VERSION = 5
KEY_DOWN = 11
KEY_UP = 12
ACTIVATE_TARGET = 8
SOFTWARE_KEYBOARD = 5
WINDOW_SCENE_FLAG = 0x80000000
DEFAULT_SOCKET = "/var/mnt/rootfs/private/tmp/macws_host_input.sock"

LETTER_KEYCODES = (
    0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
    45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
)
DIGIT_KEYCODES = (18, 19, 20, 21, 23, 22, 26, 28, 25, 29)
PUNCTUATION_KEYCODES = {
    " ": 49, "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42,
    ";": 41, "'": 39, "`": 50, ",": 43, ".": 47, "/": 44,
    ">": 47,
}


def mac_keycode(character):
    lower = character.lower()
    if "a" <= lower <= "z":
        return LETTER_KEYCODES[ord(lower) - ord("a")]
    if "1" <= lower <= "9":
        return DIGIT_KEYCODES[ord(lower) - ord("1")]
    if lower == "0":
        return 29
    return PUNCTUATION_KEYCODES.get(character, 0)


def keysym(character):
    scalar = ord(character)
    return 0x01000000 | scalar if scalar > 0xFF else scalar


def send_key(datagram, path, pid, window_id, symbol, keycode, sequence):
    scene_id = (window_id << 32) | WINDOW_SCENE_FLAG
    for kind in (KEY_DOWN, KEY_UP):
        record = struct.pack(
            "<IHHQdfffIIIiHHIffffII",
            MAGIC,
            WIRE_VERSION,
            kind,
            scene_id,
            time.monotonic(),
            445.0,
            306.0,
            float(keycode),
            symbol,
            1780,
            1226,
            pid,
            SOFTWARE_KEYBOARD,
            0,
            0,
            0.0,
            0.0,
            0.0,
            0.0,
            sequence,
            0,
        )
        if len(record) != 84:
            raise RuntimeError("MacWS input ABI size changed")
        datagram.sendto(record, path)
        sequence += 1
        time.sleep(0.012)
    return sequence


def activate_target(datagram, path, pid, window_id, sequence):
    record = struct.pack(
        "<IHHQdfffIIIiHHIffffII",
        MAGIC,
        WIRE_VERSION,
        ACTIVATE_TARGET,
        (window_id << 32) | WINDOW_SCENE_FLAG,
        time.monotonic(),
        445.0,
        306.0,
        0.0,
        0,
        1780,
        1226,
        pid,
        SOFTWARE_KEYBOARD,
        0,
        0,
        0.0,
        0.0,
        0.0,
        0.0,
        sequence,
        0,
    )
    datagram.sendto(record, path)
    time.sleep(0.08)
    return sequence + 1


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit("usage: probe.py PID WINDOW_ID [SOCKET]")
    pid = int(sys.argv[1])
    window_id = int(sys.argv[2])
    path = sys.argv[3] if len(sys.argv) == 4 else DEFAULT_SOCKET
    command = "printf 你 > /tmp/macws-ime-probe.txt"
    datagram = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sequence = 1000
    sequence = activate_target(datagram, path, pid, window_id, sequence)
    for character in command:
        sequence = send_key(
            datagram,
            path,
            pid,
            window_id,
            keysym(character),
            mac_keycode(character),
            sequence,
        )
    send_key(datagram, path, pid, window_id, 0xFF0D, 36, sequence)
    print("sent exact-window Unicode command to pid=%d window=%d" %
          (pid, window_id))


if __name__ == "__main__":
    main()
