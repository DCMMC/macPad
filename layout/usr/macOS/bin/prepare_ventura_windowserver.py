"""Prepare the verified Ventura 13.4 WindowServer for the iOS arm64 ABI.

The stock Ventura image is a universal x86_64 + ARM64/E executable.  MacWS's
WindowServer launch contract deliberately uses an ARM64/ALL main executable,
which in turn selects the packaged ARM64/ALL libmachook and ObjC trampoline
closure.  Extract only the verified ARM64/E slice and change its Mach header
subtype to ARM64/ALL.  The caller must re-sign and trust the resulting image.

This file intentionally has no shebang: AMFI rejects script shebang execs on
the target.  Invoke it explicitly with /var/jb/usr/bin/python3.
"""

from __future__ import annotations

import argparse
import os
import stat
import struct
import sys
import uuid


FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_MASK = 0x00FFFFFF
CPU_SUBTYPE_ARM64_ALL = 0
CPU_SUBTYPE_ARM64E = 2
LC_UUID = 0x1B

# RE/runtime identity captured from the stock Ventura 13.4 rootfs on the
# iPad14,4 Office deployment.  Refuse every other WindowServer build so a
# future rootfs cannot be silently transformed under offsets we did not test.
EXPECTED_UUID = uuid.UUID("465422c7-3cfc-3e9f-9c04-813f3a265aa6").bytes


class FormatError(RuntimeError):
    pass


def subtype_base(value: int) -> int:
    return value & CPU_SUBTYPE_MASK


def read_thin_uuid(data: bytes) -> bytes:
    if len(data) < 32:
        raise FormatError("Mach-O slice is shorter than its header")
    magic, cputype, _cpusubtype, _filetype, ncmds, sizeofcmds, _flags, _reserved = \
        struct.unpack_from("<IIIIIIII", data, 0)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64:
        raise FormatError("slice is not a little-endian ARM64 Mach-O")
    cursor = 32
    commands_end = cursor + sizeofcmds
    if ncmds > 4096 or commands_end > len(data):
        raise FormatError("invalid Mach-O load-command extent")
    for _index in range(ncmds):
        if cursor + 8 > commands_end:
            raise FormatError("truncated Mach-O load command")
        command, command_size = struct.unpack_from("<II", data, cursor)
        if command_size < 8 or cursor + command_size > commands_end:
            raise FormatError("invalid Mach-O load-command size")
        if command == LC_UUID:
            if command_size < 24:
                raise FormatError("truncated LC_UUID")
            return data[cursor + 8:cursor + 24]
        cursor += command_size
    raise FormatError("Mach-O slice has no LC_UUID")


def read_fat_arches(data: bytes) -> list[tuple[int, int, int, int, int]]:
    if len(data) < 8:
        raise FormatError("file is shorter than a fat header")
    magic, count = struct.unpack_from(">II", data, 0)
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        raise FormatError("file is not a supported universal Mach-O")
    entry_size = 20 if magic == FAT_MAGIC else 32
    if count == 0 or count > 64 or 8 + count * entry_size > len(data):
        raise FormatError(f"invalid fat architecture count {count}")
    arches = []
    for index in range(count):
        offset = 8 + index * entry_size
        if magic == FAT_MAGIC:
            cputype, cpusubtype, slice_offset, size, alignment = \
                struct.unpack_from(">IIIII", data, offset)
        else:
            cputype, cpusubtype, slice_offset, size, alignment, _reserved = \
                struct.unpack_from(">IIQQII", data, offset)
        if slice_offset + size > len(data):
            raise FormatError("fat slice lies outside the file")
        arches.append((cputype, cpusubtype, slice_offset, size, alignment))
    return arches


def preparation_state(data: bytes) -> str:
    if len(data) >= 12 and struct.unpack_from("<I", data, 0)[0] == MH_MAGIC_64:
        _magic, cputype, cpusubtype = struct.unpack_from("<III", data, 0)
        if cputype != CPU_TYPE_ARM64 or \
                subtype_base(cpusubtype) != CPU_SUBTYPE_ARM64_ALL:
            raise FormatError("thin image is not ARM64/ALL")
        if read_thin_uuid(data) != EXPECTED_UUID:
            raise FormatError("unsupported thin WindowServer UUID")
        return "ready"

    arches = read_fat_arches(data)
    source = next((
        entry for entry in arches
        if entry[0] == CPU_TYPE_ARM64 and
        subtype_base(entry[1]) == CPU_SUBTYPE_ARM64E
    ), None)
    if source is None:
        raise FormatError("universal image has no ARM64/E slice")
    _cputype, _cpusubtype, offset, size, _alignment = source
    if read_thin_uuid(data[offset:offset + size]) != EXPECTED_UUID:
        raise FormatError("unsupported universal WindowServer UUID")
    return "needs-conversion"


def prepare_bytes(data: bytes) -> bytes:
    state = preparation_state(data)
    if state == "ready":
        return data
    arches = read_fat_arches(data)
    source = next(
        entry for entry in arches
        if entry[0] == CPU_TYPE_ARM64 and
        subtype_base(entry[1]) == CPU_SUBTYPE_ARM64E)
    _cputype, _cpusubtype, offset, size, _alignment = source
    result = bytearray(data[offset:offset + size])
    # CPU_SUBTYPE_ARM64_ALL has no pointer-auth capability bits.
    struct.pack_into("<I", result, 8, CPU_SUBTYPE_ARM64_ALL)
    if preparation_state(result) != "ready":
        raise FormatError("converted WindowServer failed its postcondition")
    return bytes(result)


def replace_atomically(path: str, data: bytes) -> None:
    current = os.stat(path, follow_symlinks=True)
    temporary = f"{path}.macws-arm64-new-{os.getpid()}"
    try:
        with open(temporary, "xb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, stat.S_IMODE(current.st_mode))
        try:
            os.chown(temporary, current.st_uid, current.st_gid)
        except PermissionError:
            pass
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("path")
    arguments = parser.parse_args()
    try:
        with open(arguments.path, "rb") as source:
            original = source.read()
        state = preparation_state(original)
        if state == "ready":
            print(f"[SKIP] {arguments.path}: verified ARM64/ALL WindowServer")
            return 0
        if arguments.check:
            print(f"[NEEDS-REPAIR] {arguments.path}: verified ARM64/E universal image")
            return 1
        prepared = prepare_bytes(original)
        replace_atomically(arguments.path, prepared)
        print(
            f"[PATCH] {arguments.path}: extracted verified ARM64/E slice and "
            f"published ARM64/ALL ({len(original)} -> {len(prepared)} bytes)")
        return 0
    except (OSError, FormatError) as error:
        print(f"[ERROR] {arguments.path}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
