"""Lock the MTLCompilerService adapter to RE-verified executable identities."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "MTLCompilerBypassOSCheck/Tweak.x").read_text()


class MTLCompilerServiceIdentity(unittest.TestCase):
    def setUp(self):
        self.adapter = SOURCE.split(
            "static void InstallMacOSMetalTargetAdapter(void) {", 1
        )[1].split("static void InstallLegacyTargetBypasses(void) {", 1)[0]

    def test_verified_ios_16_identities_are_profiled(self):
        self.assertIn(
            "0x6d, 0x2c, 0xfe, 0x56, 0x8d, 0x88, 0x39, 0xaa,",
            self.adapter,
        )
        self.assertIn(
            "0xb4, 0x74, 0x53, 0x94, 0x88, 0xd0, 0x37, 0x39,",
            self.adapter,
        )
        self.assertIn(
            "iOS 16.3.1 (20D67)  UUID 6D2CFE56-8D88-39AA-BC25-7FFE5058ED4E",
            self.adapter,
        )
        self.assertIn(
            "iOS 16.0   (20A8372) UUID B4745394-88D0-3739-9E17-4DE2FB12B00E",
            self.adapter,
        )
        self.assertIn(
            "0xb5, 0xcb, 0xf4, 0x57, 0xb3, 0x00, 0x3f, 0xd0,",
            self.adapter,
        )
        self.assertIn(
            "iOS 16.5.1 (20F75)  UUID B5CBF457-B300-3FD0-A646-1261DA6E86B0",
            self.adapter,
        )

    def test_unknown_service_builds_keep_stock_behavior(self):
        self.assertIn(
            "static const struct MacWSTargetAdapterProfile profiles[]",
            self.adapter,
        )
        self.assertIn("if (!profile)", self.adapter)
        self.assertIn("MTLCompilerService UUID mismatch", self.adapter)
        self.assertIn("return;", self.adapter)

    def test_each_allowlisted_build_still_requires_instruction_validation(self):
        for offset in ("0x20e8", "0x25f0", "0x2628"):
            self.assertIn(offset, self.adapter)
        for offset in ("0x2050", "0x2558", "0x2590"):
            self.assertIn(offset, self.adapter)
        self.assertIn(
            "if (*callSite != profile->callSites[i].expected)", self.adapter
        )
        self.assertIn(".replyOffset = 0x2770", self.adapter)
        self.assertIn(".expectedReplyCall = 0x9400047c", self.adapter)
        self.assertIn(".replyOffset = 0x26d8", self.adapter)
        self.assertIn(".expectedReplyCall = 0x940004ae", self.adapter)
        self.assertIn("target adapter: validation failed", self.adapter)


if __name__ == "__main__":
    unittest.main()
