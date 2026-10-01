import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROTOCOL = (ROOT / "include/macws_host_protocol.h").read_text()
VIEWPORT = (ROOT / "include/macws_viewport_math.h").read_text()
HOST = (ROOT / "MacWSHost/main.m").read_text()
METAL = (ROOT / "MacWSHost/Rendering/MacWSMetalView.m").read_text()


class RetinaDensityContractTests(unittest.TestCase):
    def test_only_standard_and_larger_are_selectable(self):
        self.assertIn('initWithItems:@[@"Retina 标准", @"Retina 放大"]', HOST)
        self.assertIn("MacWSHostDisplayDensityRetinaLarger", PROTOCOL)
        self.assertIn("return 1.25;", PROTOCOL)
        self.assertNotIn("Retina 更多空间", HOST)

    def test_larger_keeps_panel_native_drawable(self):
        self.assertIn("sourcePixelsPerViewPoint = displayScale;", VIEWPORT)
        self.assertNotIn(
            "sourcePixelsPerViewPoint = sourceBackingScale / densityScale;",
            VIEWPORT,
        )

    def test_quality_filter_is_magnification_only(self):
        self.assertIn("sourcePerPixelX >= 0.995f", METAL)
        self.assertIn("sourcePerPixelY >= 0.995f", METAL)
        self.assertIn("center.rgb * 1.4h", METAL)
        self.assertIn("clamp(sharpened, low, high)", METAL)

    def test_runtime_switches_use_product_path(self):
        self.assertIn('@"retina-standard"', HOST)
        self.assertIn('@"retina-larger"', HOST)
        self.assertIn("[self densityChanged:_densityControl]", HOST)


if __name__ == "__main__":
    unittest.main()
