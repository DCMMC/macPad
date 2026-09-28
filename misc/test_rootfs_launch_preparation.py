import importlib.util
import struct
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = ROOT / "layout/usr/macOS/bin/prepare_ventura_windowserver.py"
SPEC = importlib.util.spec_from_file_location("windowserver_prepare", HELPER_PATH)
HELPER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(HELPER)


def thin_windowserver(image_uuid=HELPER.EXPECTED_UUID, subtype=2):
    command = struct.pack("<II16s", HELPER.LC_UUID, 24, image_uuid)
    return (
        struct.pack(
            "<IIIIIIII",
            HELPER.MH_MAGIC_64,
            HELPER.CPU_TYPE_ARM64,
            subtype,
            2,
            1,
            len(command),
            0,
            0,
        )
        + command
        + b"verified-windowserver-text"
    )


def universal_windowserver(arm_slice):
    x86_offset = 128
    x86_slice = b"x86-placeholder".ljust(64, b"\0")
    arm_offset = 256
    header = struct.pack(">II", HELPER.FAT_MAGIC, 2)
    header += struct.pack(
        ">IIIII", 0x01000007, 3, x86_offset, len(x86_slice), 4)
    header += struct.pack(
        ">IIIII",
        HELPER.CPU_TYPE_ARM64,
        HELPER.CPU_SUBTYPE_ARM64E,
        arm_offset,
        len(arm_slice),
        4,
    )
    return (
        header.ljust(x86_offset, b"\0")
        + x86_slice
        + b"\0" * (arm_offset - x86_offset - len(x86_slice))
        + arm_slice
    )


class WindowServerPreparationTests(unittest.TestCase):
    def test_verified_universal_image_becomes_thin_arm64_all(self):
        source = thin_windowserver()
        result = HELPER.prepare_bytes(universal_windowserver(source))
        self.assertEqual(HELPER.preparation_state(result), "ready")
        self.assertEqual(struct.unpack_from("<I", result, 8)[0], 0)
        self.assertEqual(HELPER.read_thin_uuid(result), HELPER.EXPECTED_UUID)
        self.assertEqual(result[12:], source[12:])

    def test_ready_image_is_idempotent(self):
        source = thin_windowserver(subtype=0)
        self.assertEqual(HELPER.prepare_bytes(source), source)

    def test_unknown_uuid_is_rejected_before_rewrite(self):
        source = thin_windowserver(image_uuid=b"\x55" * 16)
        with self.assertRaisesRegex(HELPER.FormatError, "unsupported"):
            HELPER.prepare_bytes(universal_windowserver(source))


if __name__ == "__main__":
    unittest.main()
