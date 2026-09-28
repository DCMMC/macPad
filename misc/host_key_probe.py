"""Send bounded keyboard input through the native MacWS Host ABI."""

import argparse
import os
import socket
import time

from host_input_matrix import (
    KEY_DOWN, KEY_UP, LATENCY_DIAGNOSTIC, MOD_CAPS_LOCK, MOD_COMMAND,
    MOD_CONTROL, MOD_SHIFT, SOURCE_HARDWARE_KEYBOARD, record, resolve_window,
)


KEY_CODES = {
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6,
    "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
    "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37,
    "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
    "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48,
    "space": 49, "`": 50, "grave": 50, "backspace": 51, "escape": 53,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
    "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
    "f11": 103, "f12": 111,
    "left": 123, "right": 124, "down": 125, "up": 126,
}

SPECIAL_SYMBOLS = {
    "return": 0xFF0D, "tab": 0xFF09, "backspace": 0xFF08,
    "escape": 0xFF1B, "space": ord(" "), "grave": ord("`"),
    "f1": 0xF704, "f2": 0xF705, "f3": 0xF706, "f4": 0xF707,
    "f5": 0xF708, "f6": 0xF709, "f7": 0xF70A, "f8": 0xF70B,
    "f9": 0xF70C, "f10": 0xF70D, "f11": 0xF70E, "f12": 0xF70F,
    "left": 0xFF51, "up": 0xFF52, "right": 0xFF53, "down": 0xFF54,
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--window", type=int, default=0)
    parser.add_argument(
        "--key-window", action="store_true",
        help=("leave the protocol window identifier at zero so the target "
              "application resolves its current AppKit keyWindow"),
    )
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--text")
    group.add_argument("--key", choices=sorted(KEY_CODES))
    parser.add_argument("--command", action="store_true")
    parser.add_argument("--control", action="store_true")
    parser.add_argument("--shift", action="store_true")
    parser.add_argument("--caps-lock", action="store_true")
    parser.add_argument(
        "--latency-diagnostic", action="store_true",
        help=("tag each record for the opt-in AppKit/Unity/world-state "
              "diagnostic logs; does not change input routing"))
    parser.add_argument(
        "--hold", type=float, default=0.0,
        help=("seconds to keep each key down before key-up; games that sample "
              "key state once per render tick need a nonzero hold"))
    parser.add_argument("--interval", type=float, default=0.012)
    parser.add_argument(
        "--trace-sentinel",
        help=("create this sentinel immediately before sending input and "
              "remove it after --trace-settle"))
    parser.add_argument(
        "--trace-settle", type=float, default=0.0,
        help="seconds to retain --trace-sentinel after the last key")
    parser.add_argument("--socket",
                        default="/var/mnt/rootfs/private/tmp/macws_host_input.sock")
    args = parser.parse_args()
    if args.key_window and args.window != 0:
        parser.error("--key-window cannot be combined with --window")
    if (args.pid <= 1 or args.width <= 0 or args.height <= 0 or
            args.interval < 0 or args.hold < 0 or args.trace_settle < 0):
        parser.error(
            "pid/geometry must be positive and timing values nonnegative")
    window = 0 if args.key_window else resolve_window(args.pid, args.window)
    modifiers = (MOD_COMMAND if args.command else 0) | \
        (MOD_CONTROL if args.control else 0) | \
        (MOD_SHIFT if args.shift else 0) | \
        (MOD_CAPS_LOCK if args.caps_lock else 0)
    values = [(args.key, modifiers)] if args.key else [
        (character, modifiers | (MOD_SHIFT if character.isupper() else 0))
        for character in args.text
    ]
    local = f"/tmp/macws_host_key.{os.getpid()}.sock"
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(local)
    sequence = 0
    sent = []
    try:
        if args.trace_sentinel:
            with open(args.trace_sentinel, "a", encoding="utf-8"):
                pass
        for value, flags in values:
            name = value.lower()
            if value == "\n":
                name = "return"
            elif value == "\t":
                name = "tab"
            elif value == " ":
                name = "space"
            code = KEY_CODES.get(name, 0)
            symbol = SPECIAL_SYMBOLS.get(
                name, ord(value) if len(value) == 1 else 0)
            for kind in (KEY_DOWN, KEY_UP):
                sequence += 1
                sock.sendto(record(
                    kind, sequence, args.pid, window, args.width, args.height,
                    args.width / 2, args.height / 2, pressure=code,
                    contact=symbol, source=SOURCE_HARDWARE_KEYBOARD,
                    modifiers=flags,
                    flags=(LATENCY_DIAGNOSTIC
                           if args.latency_diagnostic else 0)), args.socket)
                if kind == KEY_DOWN and args.hold:
                    time.sleep(args.hold)
            sent.append(value)
            if args.interval:
                time.sleep(args.interval)
        if args.trace_settle:
            time.sleep(args.trace_settle)
    finally:
        sock.close()
        os.unlink(local)
        if args.trace_sentinel:
            try:
                os.unlink(args.trace_sentinel)
            except FileNotFoundError:
                pass
    print(f"keys={len(sent)} records={sequence} pid={args.pid} window={window}")


if __name__ == "__main__":
    main()
