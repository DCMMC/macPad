"""Guard the version-safe AGX selector-0x100 size negotiation."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "libmachook/mac_hooks.m").read_text()


class AGXDeviceInfoContract(unittest.TestCase):
    def test_original_ventura_shape_is_always_attempted_first(self):
        helper = SOURCE[SOURCE.index(
            "static BOOL MacWSIOGPUDeviceInfoNeedsLegacyRetry"):
            SOURCE.index("\n\nbool MacWSAGXNoCopyABIReady")]
        self.assertIn("requested_output != 0x78", helper)
        self.assertIn("result == kIOReturnBadArgument", helper)
        self.assertNotIn("kern.osversion", helper)

    def test_both_iokit_entry_points_use_the_same_narrow_retry(self):
        method = SOURCE[SOURCE.index("IOReturn IOConnectCallMethod_new"):
                        SOURCE.index("IOReturn IOConnectCallScalarMethod_new")]
        struct = SOURCE[SOURCE.index("IOReturn IOConnectCallStructMethod_new"):
                        SOURCE.index("IOReturn IOConnectCallAsyncMethod_new")]
        for body in (method, struct):
            self.assertEqual(
                body.count("MacWSIOGPUDeviceInfoNeedsLegacyRetry("), 1)
            self.assertIn("*outStructCnt = 0x70;", body)
            self.assertLess(body.index("device_info_requested_output, r)"),
                            body.index("*outStructCnt = 0x70;"))

    def test_old_unconditional_clamp_is_gone(self):
        self.assertNotIn(
            "*outStructCnt == 0x78) *outStructCnt = 0x70", SOURCE)

    def test_native_78_profile_preserves_type_zero_resource_shape(self):
        helper = SOURCE[SOURCE.index(
            "static BOOL MacWSIOGPUDeviceInfoNeedsLegacyRetry"):
            SOURCE.index("\n\nbool MacWSAGXNoCopyABIReady")]
        self.assertIn("MacWSIOGPUDeviceInfoNative78", helper)
        self.assertIn("result == KERN_SUCCESS", helper)

        type_zero = SOURCE[SOURCE.index(
            "MacWSIOGPUDeviceInfoProfile device_info_profile"):
            SOURCE.index("// type=0 with args+0x40 already set")]
        self.assertIn(
            "device_info_profile == MacWSIOGPUDeviceInfoLegacy70",
            type_zero)
        self.assertIn("*(uint64_t *)(shadowbuf + 0x40) = nb;", type_zero)
        self.assertIn("type0 native-0x78 preserve", type_zero)
        self.assertNotIn("kern.osversion", type_zero)

    def test_open_time_probe_precedes_resource_translation(self):
        profile = SOURCE[SOURCE.index(
            "static void MacWSProbeIOGPUDeviceInfoProfile"):
            SOURCE.index("static BOOL IOConnectIsIOGPU")]
        self.assertIn("client, 0x100, NULL, 0", profile)
        self.assertIn("output_size = 0x70", profile)
        self.assertIn("MacWSIOGPUDeviceInfoNative78", profile)
        self.assertIn("MacWSIOGPUDeviceInfoLegacy70", profile)

        open_body = SOURCE[SOURCE.rindex("kern_return_t IOServiceOpen_new"):
                           SOURCE.rindex("DYLD_INTERPOSE(IOServiceOpen_new")]
        self.assertEqual(
            open_body.count("MacWSProbeIOGPUDeviceInfoProfile(*connect)"), 2)

    def test_unknown_profile_does_not_enable_legacy_mutation(self):
        resource = SOURCE[SOURCE.index(
            "MacWSIOGPUDeviceInfoProfile device_info_profile"):
            SOURCE.index("if(patched) inStruct = shadowbuf;",
                         SOURCE.index(
                             "MacWSIOGPUDeviceInfoProfile device_info_profile"))]
        self.assertIn(
            "device_info_profile == MacWSIOGPUDeviceInfoLegacy70", resource)
        self.assertNotIn(
            "device_info_profile != MacWSIOGPUDeviceInfoNative78", resource)
        self.assertRegex(
            resource,
            r"agxType == 0x82 &&\s+"
            r"device_info_profile == MacWSIOGPUDeviceInfoLegacy70")

        submit = SOURCE[SOURCE.index("int translated_agx_submit"):
                        SOURCE.index("unsigned queue_qos_diag_sequence")]
        self.assertIn(
            "submit_device_info_profile == MacWSIOGPUDeviceInfoLegacy70",
            submit)
        self.assertIn("native-0x78 SUBMIT-ABI", submit)

    def test_successful_legacy_retry_records_the_legacy_profile(self):
        method = SOURCE[SOURCE.index("IOReturn IOConnectCallMethod_new"):
                        SOURCE.index("IOReturn IOConnectCallScalarMethod_new")]
        struct = SOURCE[SOURCE.index("IOReturn IOConnectCallStructMethod_new"):
                        SOURCE.index("IOReturn IOConnectCallAsyncMethod_new")]
        for body in (method, struct):
            retry = body[body.index("*outStructCnt = 0x70;"):]
            self.assertIn("MacWSIOGPUDeviceInfoLegacy70", retry)
            self.assertIn("if (r == KERN_SUCCESS)", retry)


if __name__ == "__main__":
    unittest.main()
