"""Exercise MacWS software-toolbar arrows and modifier chords end to end.

The probe writes only input records. The target Terminal must create the
result files itself, which makes their contents a visible delivery witness.
"""

import socket
import struct
import sys
import time


MAGIC = 0x4D574556
WIRE_VERSION = 5
ACTIVATE_TARGET = 8
KEY_DOWN = 11
KEY_UP = 12
SOFTWARE_KEYBOARD = 5
WINDOW_SCENE_FLAG = 0x80000000
CONTROL = 0x00040000
COMMAND = 0x00100000
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
SPECIAL_KEYS = {
    "return": (0xFF0D, 36),
    "left": (0xFF51, 123),
    "up": (0xFF52, 126),
    "right": (0xFF53, 124),
    "down": (0xFF54, 125),
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


class Sender:
    def __init__(self, pid, window_id, path):
        self.pid = pid
        self.window_id = window_id
        self.path = path
        self.sequence = 2000
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)

    def record(self, kind, symbol=0, keycode=0, modifiers=0):
        record = struct.pack(
            "<IHHQdfffIIIiHHIffffII",
            MAGIC,
            WIRE_VERSION,
            kind,
            (self.window_id << 32) | WINDOW_SCENE_FLAG | modifiers,
            time.monotonic(),
            445.0,
            306.0,
            float(keycode),
            symbol,
            1780,
            1226,
            self.pid,
            SOFTWARE_KEYBOARD,
            0,
            0,
            0.0,
            0.0,
            0.0,
            0.0,
            self.sequence,
            0,
        )
        if len(record) != 84:
            raise RuntimeError("MacWS input ABI size changed")
        self.socket.sendto(record, self.path)
        self.sequence += 1

    def activate(self):
        self.record(ACTIVATE_TARGET)
        time.sleep(0.08)

    def key(self, symbol, keycode, modifiers=0):
        self.record(KEY_DOWN, symbol, keycode, modifiers)
        time.sleep(0.012)
        self.record(KEY_UP, symbol, keycode, modifiers)
        time.sleep(0.012)

    def text(self, value):
        for character in value:
            self.key(ord(character), mac_keycode(character))

    def special(self, name):
        self.key(*SPECIAL_KEYS[name])

    def chord(self, character, modifiers):
        self.key(ord(character), mac_keycode(character), modifiers)


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit("usage: probe.py PID WINDOW_ID [SOCKET]")
    sender = Sender(
        int(sys.argv[1]),
        int(sys.argv[2]),
        sys.argv[3] if len(sys.argv) == 4 else DEFAULT_SOCKET,
    )
    sender.activate()

    # Right and Left must edit the middle of the current readline buffer.
    # Control-A/Control-E provide deterministic anchors without depending on
    # the toolbar's separate Home/End key support.
    sender.text("echo ac > /tmp/macws-soft-horizontal.txt")
    sender.chord("a", CONTROL)
    for _ in range(7):
        sender.special("right")
    sender.special("left")
    sender.text("b")
    sender.chord("e", CONTROL)
    sender.special("return")
    time.sleep(0.25)

    # Up recalls the prior command; Down restores the in-progress buffer.
    sender.text("echo up >> /tmp/macws-soft-vertical.txt")
    sender.special("return")
    time.sleep(0.2)
    sender.special("up")
    sender.special("return")
    time.sleep(0.2)
    sender.text("echo down >> /tmp/macws-soft-vertical.txt")
    sender.special("up")
    sender.special("down")
    sender.special("return")
    time.sleep(0.25)

    # Control-C must interrupt the child before the follow-up command arrives.
    sender.text("sleep 20")
    sender.special("return")
    time.sleep(0.5)
    sender.chord("c", CONTROL)
    time.sleep(0.25)
    sender.text("printf ctrl > /tmp/macws-soft-control.txt")
    sender.special("return")
    time.sleep(0.75)

    # Command-N has an externally observable result: Terminal creates another
    # real AppKit window in the WindowServer catalog.
    sender.chord("n", COMMAND)
    print("sent arrow/control/command software-toolbar probe to pid=%d window=%d" %
          (sender.pid, sender.window_id))


if __name__ == "__main__":
    main()
