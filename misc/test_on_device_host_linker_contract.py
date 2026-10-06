"""Build contract for the iOS-native Host on Procursus devices."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class OnDeviceHostLinkerContractTests(unittest.TestCase):
    def test_host_uses_installed_apple_ld64_without_weak_undefined_bypasses(self):
        makefile = (ROOT / "MacWSHost/Makefile").read_text()

        self.assertIn("ifneq ($(wildcard /var/jb/usr/bin/ld64),)", makefile)
        self.assertIn(
            "MacWSHost_LDFLAGS += -fuse-ld=/var/jb/usr/bin/ld64", makefile
        )
        self.assertNotIn("MacWSHost_LDFLAGS += -U", makefile)
        self.assertNotIn("-undefined dynamic_lookup", makefile)

    def test_full_pipeline_repairs_only_a_drifted_theos_cache(self):
        pipeline = (ROOT / "misc/device_pipeline.sh").read_text()
        full = pipeline.split("build_full() {", 1)[1].split(
            "\n}\n\nverify_runtime_artifacts()", 1
        )[0]

        self.assertIn('find .theos ! -user "\\$(id -u)"', full)
        self.assertIn('sudo chown -R "\\$(id -u):\\$(id -g)" .theos', full)
        self.assertLess(full.index("find .theos"), full.index("build_on_ios.sh"))
        self.assertNotIn("`", full)

    def test_fresh_device_sync_keeps_policy_manifest_without_evidence_tree(self):
        pipeline = (ROOT / "misc/device_pipeline.sh").read_text()
        includes = pipeline.index("--include=docs/runtime-switches.tsv")
        excludes = pipeline.index("--exclude='docs/*'")

        self.assertLess(includes, excludes)
        self.assertNotIn("--exclude=docs/", pipeline)


if __name__ == "__main__":
    unittest.main()
