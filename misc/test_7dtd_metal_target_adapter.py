"""Static contract tests for the exact 7DTD Unity Metal target adapter."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "MTLCompilerBypassOSCheck/Tweak.x").read_text()
METAL_HOOKS = (ROOT / "libmachook/Metal_hooks.x").read_text()


class SevenDaysMetalTargetAdapter(unittest.TestCase):
    def setUp(self):
        self.classifier = SOURCE.split(
            "static bool MacWSIsSevenDaysUnitySourceRequest(", 1
        )[1].split("static void DumpCompilerRequest", 1)[0]
        self.request_path = SOURCE.split(
            "static uintptr_t MacWSMTLCodeGenServiceBuildRequest(", 1
        )[1].split("static void InstallMacOSMetalTargetAdapter", 1)[0]

    def test_classifier_is_locked_to_prepared_runtime(self):
        self.assertIn(
            'steamapps/macws-runtime/7 Days To Die/7DaysToDie-ARM.app/Contents/',
            self.classifier,
        )
        self.assertIn('"Resources\\\"";', self.classifier)
        self.assertIn("argumentLength == 335", self.classifier)
        self.assertIn("layoutDelta == 0 || layoutDelta == 4", self.classifier)

    def test_overlay_classifier_is_source_and_abi_exact(self):
        classifier = SOURCE.split(
            "static bool MacWSIsSevenDaysOverlaySourceRequest(", 1
        )[1].split("static void DumpCompilerRequest", 1)[0]
        self.assertIn(
            'steamapps/macws-runtime/7 Days To Die/7DaysToDie-ARM.app/Contents/',
            classifier,
        )
        self.assertIn("requestSize == 2407", classifier)
        self.assertIn("sourceLength == 2189", classifier)
        self.assertIn("argumentLength == 199", classifier)
        self.assertIn("sourceHash == UINT64_C(0xc9b090f289e24745)", classifier)

    def test_adapter_selects_real_compiler_target_without_result_bypass(self):
        self.assertIn("sevenDaysUnityRequest", self.request_path)
        self.assertIn("sevenDaysOverlayRequest", self.request_path)
        self.assertIn("memcpy(bytes + workingOffset, targetArgument", self.request_path)
        self.assertIn("OrigMTLCodeGenServiceBuildRequest(", self.request_path)
        self.assertNotIn("vertexFunction must not be nil", self.request_path)

    def test_present_only_trace_is_available_without_full_encoder_trace(self):
        predicate = METAL_HOOKS.split(
            "static BOOL macws_stray_present_trace_enabled(void)", 1
        )[1].split("static BOOL macws_catalyst_direct_drawable_enabled", 1)[0]
        self.assertIn("macws_is_7dtd_process()", predicate)
        self.assertIn('access("/tmp/macws_7dtd_present_trace", F_OK)', predicate)


if __name__ == "__main__":
    unittest.main()
