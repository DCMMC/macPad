#include <assert.h>
#include <math.h>
#include <stdio.h>

#include "macws_viewport_math.h"
#include "macws_host_protocol.h"

static bool Near(float a, float b) { return fabsf(a - b) < 0.01f; }

static void AssertNativeSampling(float viewWidth, float viewHeight,
                                 float sourceWidth, float sourceHeight,
                                 float density, float displayScale) {
    MacWSPresentationDrawableSize pixels = {0};
    MacWSNativePresentationRect content = {0};
    assert(MacWSComputePresentationDrawableSize(
        viewWidth, viewHeight, sourceWidth, sourceHeight, 2, density,
        displayScale, true, &pixels));
    assert(MacWSComputeNativeWindowPresentationRect(
        sourceWidth, sourceHeight, 2, density, viewWidth, viewHeight,
        &content));
    // Geometry may letterbox or clip, but the source's sampling density is
    // preserved up to the one-pixel rounding of the final drawable axes.
    float expectedScale = displayScale * density / 2.0f;
    assert(fabsf(content.width / viewWidth * pixels.width -
                 sourceWidth * expectedScale) <=
           content.width / viewWidth * 0.5f + 0.01f);
    assert(fabsf(content.height / viewHeight * pixels.height -
                 sourceHeight * expectedScale) <=
           content.height / viewHeight * 0.5f + 0.01f);
}

int main(void) {
    assert(MacWSNormalizedDisplayDensity(0) ==
        MacWSHostDisplayDensityRetinaStandard);
    assert(MacWSNormalizedDisplayDensity(MacWSHostDisplayDensityKeyboard) ==
        MacWSHostDisplayDensityRetinaLarger);
    assert(MacWSNormalizedDisplayDensity(MacWSHostDisplayDensityComfort) ==
        MacWSHostDisplayDensityRetinaStandard);
    assert(MacWSNormalizedDisplayDensity(
        MacWSHostDisplayDensityComfort125) ==
        MacWSHostDisplayDensityRetinaStandard);
    assert(MacWSNormalizedDisplayDensity(
        MacWSHostDisplayDensityComfort150) ==
        MacWSHostDisplayDensityRetinaStandard);
    assert(MacWSDisplayDensityFactor(
        MacWSHostDisplayDensityRetinaStandard) == 1);
    assert(MacWSDisplayDensityFactor(
        MacWSHostDisplayDensityRetinaLarger) == 1.25);
    MacWSPresentationDrawableSize pixels = {0};
    // Runtime first-frame regression: a Retina source was permanently
    // presented at one pixel/point after an awaiting-source drawable.
    assert(MacWSComputePresentationDrawableSize(
        938, 558, 1876, 1116, 2, 1, 2, true, &pixels));
    assert(Near(pixels.width, 1876) && Near(pixels.height, 1116));

    // Replay the observed old feedback calculation. At fixed Scene/source
    // geometry each MTKView setter publishes drawable.width/view.width as
    // contentScaleFactor, making the next aspect fit reduce the budget again.
    float oldWidth = 1693;
    const float oldExpectedWidths[] = {1663, 1634, 1605};
    for (unsigned i = 0; i < 3; i++) {
        float oldScale = oldWidth / 987.0f;
        float fit = fminf(1.0f, fminf(987 * oldScale / 1806,
                                      582 * oldScale / 1084));
        oldWidth = roundf(1806 * fit);
        assert(Near(oldWidth, oldExpectedWidths[i]));
    }
    for (unsigned pass = 0; pass < 100; pass++) {
        assert(MacWSComputePresentationDrawableSize(
            987, 582, 1806, 1084, 2, 1, 2, true, &pixels));
        assert(Near(pixels.width, 1974) && Near(pixels.height, 1164));
    }

    AssertNativeSampling(938, 558, 1876, 1116, 1, 2);
    AssertNativeSampling(1060, 760, 1806, 1084, 1, 2); // letterbox
    AssertNativeSampling(500, 300, 1806, 1084, 1, 2); // clipping
    // Retina Larger keeps a full panel-native 2x drawable. The former path
    // allocated only sourceBacking/density = 1.6 pixels per Scene point and
    // left UIKit to enlarge that smaller drawable again.
    AssertNativeSampling(850, 600, 1360, 960, 1.25f, 2);
    assert(MacWSComputePresentationDrawableSize(
        850, 600, 1360, 960, 2, 1.25f, 2, true, &pixels));
    assert(Near(pixels.width, 1700) && Near(pixels.height, 1200));
    assert(1360 < pixels.width && 960 < pixels.height);
    AssertNativeSampling(987, 582, 1806, 1084, 1, 1); // 1x display

    // Fullscreen source fit must preserve the drawable's Scene aspect even
    // when keyboard/accessory chrome changes only the available height.
    assert(MacWSComputePresentationDrawableSize(
        1341, 922, 2388, 1668, 2, 1, 2, false, &pixels));
    assert(Near(pixels.width, 2426) && Near(pixels.height, 1668));
    assert(fabsf(pixels.width / 1341 - pixels.height / 922) < 0.001f);
    assert(MacWSComputePresentationDrawableSize(
        1341, 748, 2388, 1668, 2, 1, 2, false, &pixels));
    assert(Near(pixels.width, 2682) && Near(pixels.height, 1496));

    assert(!MacWSComputePresentationDrawableSize(
        0, 558, 1876, 1116, 2, 1, 2, true, &pixels));
    assert(!MacWSComputePresentationDrawableSize(
        938, 558, 1876, 1116, 2, NAN, 2, true, &pixels));
    assert(!MacWSComputePresentationDrawableSize(
        938, 558, 1876, 1116, 2, 1, NAN, true, &pixels));
    assert(!MacWSComputePresentationDrawableSize(
        938, 558, 1876, 1116, 2, 1, 2, true, NULL));
    puts("drawable resolution regression and sampling invariants passed");
    return 0;
}
