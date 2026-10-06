"""Execute the production shell fingerprint against owned filesystem fixtures."""
import os
from pathlib import Path
import hashlib
import shlex
import string
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "layout/usr/macOS/bin/ensure_metal2metal_compat.sh"


class MetalBootStamp(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="macws-metal-stamp-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        source = SCRIPT.read_text()
        start = source.index("metal2metal_runtime_stamp() {")
        end = source.index("\nmetal2metal_sha256()", start)
        self.function = source[start:end]
        self.function = self.function.replace("/var/jb/usr/macOS", str(self.base / "jb"))
        self.values = {
            "ROOTFS": str(self.base / "rootfs"),
            "METAL2METAL": str(self.base / "jb/bin/metal2metal.py"),
            "OFFICE_PROVISIONER": str(self.base / "jb/bin/ensure_office_metal2metal.py"),
            "APPLE_LLVM_DIS": str(self.base / "jb/bin/macws-llvm-dis"),
            "APPLE_LLVM_AS": str(self.base / "jb/bin/macws-llvm-as"),
            "ROUTE_DIR": str(self.base / "rootfs/usr/local/share/macws/metal2metal/routes"),
        }
        # Execute the actual required/optional loops; only OS tools are faked.
        required = self.function.split("for path in", 1)[1].split("; do", 1)[0]
        for token in shlex.split(required.replace("\\\n", "")):
            self.create(Path(string.Template(token).substitute(self.values)))
        self.stat = self.base / "stat.py"
        self.stat.write_text("import os,sys\ns=os.stat(sys.argv[-1])\n"
                            "assert sys.argv[sys.argv.index('-c')+1]=='%d:%i:%s:%y:%z'\n"
                            "print(f'{s.st_dev}:{s.st_ino}:{s.st_size}:{s.st_mtime_ns}:{s.st_ctime_ns}')\n")
        self.function = self.function.replace("/var/jb/usr/bin/stat", "python3 " + shlex.quote(str(self.stat)))
        self.function = self.function.replace("/var/jb/usr/bin/sha256sum", "shasum -a 256")
        self.function = self.function.replace("/var/jb/usr/bin/tr", "tr")
        self.function = self.function.replace("/var/jb/usr/bin/awk", "awk")

    def create(self, path, data=b"fixture"):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def stamp(self, boot="first-boot"):
        function = self.function.replace("/var/jb/usr/sbin/sysctl", "printf " + shlex.quote(boot))
        script = "set -o pipefail\n" + "\n".join(
            key + "=" + shlex.quote(value) for key, value in self.values.items())
        result = subprocess.run(["bash", "-c", script + "\n" + function +
                                 "\nmetal2metal_runtime_stamp"], text=True,
                                capture_output=True, timeout=10, check=True)
        self.assertRegex(result.stdout, r"^[0-9a-f]{64}\n$")
        return result.stdout

    def test_boot_helper_and_optional_app_install_invalidate(self):
        first = self.stamp()
        self.assertEqual(first, self.stamp())
        self.assertNotEqual(first, self.stamp("second-boot"))
        app = Path(self.values["ROOTFS"]) / "Applications/Microsoft Word.app/Contents/Resources/Arc.bundle/Metal2DShaders.metallib.zip"
        self.create(app)
        installed = self.stamp()
        self.assertNotEqual(first, installed)
        self.create(Path(self.values["OFFICE_PROVISIONER"]), b"updated helper")
        self.assertNotEqual(installed, self.stamp())

    def test_output_manifest_replacement_and_removal_invalidate(self):
        first = self.stamp()
        output = Path(self.values["ROOTFS"]) / "usr/local/share/macws/metal2metal/office/hash/output.metallib"
        route = Path(self.values["ROUTE_DIR"]) / "office-metal2d-hash.route.plist"
        self.create(output)
        self.create(route)
        present = self.stamp()
        self.assertNotEqual(first, present)
        replacement = self.create(output.with_suffix(".new"))
        os.replace(replacement, output)
        replaced = self.stamp()
        self.assertNotEqual(present, replaced)
        route.unlink()  # Only this test's owned tempfile fixture.
        self.assertNotEqual(replaced, self.stamp())

    def test_missing_required_helper_refuses_success_stamp(self):
        Path(self.values["OFFICE_PROVISIONER"]).unlink()
        with self.assertRaises(subprocess.CalledProcessError):
            self.stamp()

    def test_same_second_same_length_corruption_invalidates(self):
        output = Path(self.values["ROOTFS"]) / "usr/local/share/macws/metal2metal/office/hash/output.metallib"
        self.create(output, b"MTLBoriginal")
        # Model an APFS stat observation with a constant inode/size/whole-second
        # mtime/ctime and real varying nanoseconds. Pin ctime only in this owned
        # fixture to avoid wall-clock scheduling across a second making the
        # test accidentally pass with the old seconds-only format.
        self.stat.write_text(
            "import os,sys\ns=os.stat(sys.argv[-1])\n"
            "fmt=sys.argv[sys.argv.index('-c')+1]\n"
            "assert fmt=='%d:%i:%s:%y:%z'\n"
            f"ctime=1234567890000000000 if sys.argv[-1]=={str(output)!r} else s.st_ctime_ns\n"
            "print(f'{s.st_dev}:{s.st_ino}:{s.st_size}:{s.st_mtime_ns}:{ctime}')\n")
        second = 1234567890000000000
        os.utime(output, ns=(second, second + 100))
        before = output.stat()
        stamp = self.stamp()
        output.write_bytes(b"MTLBcorrupt!")
        os.utime(output, ns=(second, second + 200))
        after = output.stat()
        self.assertEqual((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns // 10**9),
                         (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns // 10**9))
        self.assertNotEqual(stamp, self.stamp())


class MetalOutputIdentity(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="macws-metal-hash-")
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / "output.metallib"
        self.output.write_bytes(b"stable translator output")
        source = SCRIPT.read_text()
        start = source.index("metal2metal_sha256() {")
        end = source.index("\nif [ ! -f \"$METAL2METAL\" ]", start)
        self.functions = source[start:end]

    def allowed(self, identities):
        result = subprocess.run(
            ["bash", "-c", self.functions +
             "\nmetal2metal_hash_allowed \"$1\" \"$2\"", "bash",
             str(self.output), identities],
            capture_output=True, text=True)
        return result.returncode == 0

    def test_output_identity_accepts_any_explicitly_pinned_hash(self):
        actual = hashlib.sha256(self.output.read_bytes()).hexdigest()
        self.assertTrue(self.allowed("0" * 64 + " " + actual))
        self.assertTrue(self.allowed(actual + " " + "f" * 64))
        self.assertFalse(self.allowed("0" * 64 + " " + "f" * 64))

    def test_unpinned_route_accepts_manifest_verified_output(self):
        self.assertTrue(self.allowed(""))

    def test_validated_ios_native_llvm_outputs_remain_pinned(self):
        source = SCRIPT.read_text()
        for identity in (
            # Runtime-confirmed on iPad14,5 / iPadOS 16.0.
            "bc05c6dfc851d5d6acf760c9edde8bb3f449af5e0834cdab81f9e2f4092a0187",
            "ff2d5117039292640d234037b4bc6f0081bb10d79d63a152ea72b1ec0de71ab1",
            # Runtime-confirmed on iPad14,4 / iPadOS 16.2. Both outputs also
            # pass their complete 4119/4119 and 148/148 runtime manifests.
            "8744686cc7981601f52f658578b9cd94cf9127c86530ee03a1e68883d2e3bb0c",
            "fa6c9b109e9ab2a7356654bd16ba66715d4ac5a04eea75dec220418a01f90736",
            # Runtime-manifest-confirmed on iPad14,3 / iPadOS 16.5.1. The
            # package's fail-closed boundary regenerated the same MPSCore
            # identity already present on disk before either was admitted.
            "742ba3df747c39148bf3c5bd93e4ae0f94375cffdf8fac4951dd1dbab479b3c3",
            "cd5b2086b26372a6486e1af69db612ac52f6228892673e15f5412643662498c5",
        ):
            self.assertIn(identity, source)


if __name__ == "__main__":
    unittest.main()
