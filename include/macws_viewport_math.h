#ifndef MACWS_VIEWPORT_MATH_H
#define MACWS_VIEWPORT_MATH_H

#include <math.h>
#include <stdbool.h>

// Pure, SDK-independent presentation math shared by MacWSHost and its local
// tests.  The returned rectangle is normalized to the producer texture.  It
// always fills the destination: an aspect-ratio mismatch crops the source and
// never introduces letterboxing.
typedef struct {
    float x;
    float y;
    float width;
    float height;
} MacWSNormalizedRect;

typedef struct {
    MacWSNormalizedRect visibleSource;
    float centerX;
    float centerY;
    float zoom;
} MacWSViewport;

typedef struct {
    float x;
    float y;
} MacWSNormalizedPoint;

// Window mode is a native-size surface, not a video player.  While iPadOS is
// interactively resizing a Scene, keep one macOS backing pixel mapped to the
// same number of physical iPad pixels selected by the density mode.  The
// destination can temporarily extend beyond, or sit inside, the Scene while
// the two native window managers settle; it must never be aspect-fitted and
// visually zoomed merely because their geometry generations differ.
typedef struct {
    float x;
    float y;
    float width;
    float height;
} MacWSNativePresentationRect;

typedef struct {
    float width;
    float height;
} MacWSPresentationDrawableSize;

static inline float MacWSClampFloat(float value, float minimum,
                                    float maximum) {
    return fminf(fmaxf(value, minimum), maximum);
}

// Project one pixel-domain point into another without changing its normalized
// location. This is used when an application's authoritative AppKit backing
// geometry differs from the internal resolution of its direct drawable.
static inline bool MacWSMapPixelPointBetweenDomains(
        float sourceX, float sourceY,
        float sourceWidth, float sourceHeight,
        float destinationWidth, float destinationHeight,
        float *destinationX, float *destinationY) {
    if (!destinationX || !destinationY || !isfinite(sourceX) ||
        !isfinite(sourceY) || !isfinite(sourceWidth) ||
        !isfinite(sourceHeight) || !isfinite(destinationWidth) ||
        !isfinite(destinationHeight) || sourceWidth <= 0.0f ||
        sourceHeight <= 0.0f || destinationWidth <= 0.0f ||
        destinationHeight <= 0.0f) return false;
    float mappedX = sourceX / sourceWidth * destinationWidth;
    float mappedY = sourceY / sourceHeight * destinationHeight;
    if (!isfinite(mappedX) || !isfinite(mappedY)) return false;
    *destinationX = mappedX;
    *destinationY = mappedY;
    return true;
}

// Recover the destination point represented by a source point after Host has
// mapped a normalized source crop over the complete destination. Absolute
// fullscreen system input needs this inverse transform: the renderer may show
// an entire direct drawable inside a desktop canvas rectangle while the input
// record was initially expressed in the retained AppKit window domain.
static inline bool MacWSMapVisibleSourcePointToDestination(
        float sourceX, float sourceY,
        float sourceWidth, float sourceHeight,
        float visibleSourceX, float visibleSourceY,
        float visibleSourceWidth, float visibleSourceHeight,
        float destinationWidth, float destinationHeight,
        float *destinationX, float *destinationY) {
    if (!destinationX || !destinationY || !isfinite(sourceX) ||
        !isfinite(sourceY) || !isfinite(sourceWidth) ||
        !isfinite(sourceHeight) || !isfinite(visibleSourceX) ||
        !isfinite(visibleSourceY) || !isfinite(visibleSourceWidth) ||
        !isfinite(visibleSourceHeight) || !isfinite(destinationWidth) ||
        !isfinite(destinationHeight) || sourceWidth <= 1.0f ||
        sourceHeight <= 1.0f || visibleSourceWidth <= 0.0f ||
        visibleSourceHeight <= 0.0f || destinationWidth <= 1.0f ||
        destinationHeight <= 1.0f) return false;
    float normalizedSourceX = sourceX / (sourceWidth - 1.0f);
    float normalizedSourceY = sourceY / (sourceHeight - 1.0f);
    float normalizedDestinationX =
        (normalizedSourceX - visibleSourceX) / visibleSourceWidth;
    float normalizedDestinationY =
        (normalizedSourceY - visibleSourceY) / visibleSourceHeight;
    if (!isfinite(normalizedDestinationX) ||
        !isfinite(normalizedDestinationY)) return false;
    normalizedDestinationX = MacWSClampFloat(
        normalizedDestinationX, 0.0f, 1.0f);
    normalizedDestinationY = MacWSClampFloat(
        normalizedDestinationY, 0.0f, 1.0f);
    *destinationX = normalizedDestinationX * (destinationWidth - 1.0f);
    *destinationY = normalizedDestinationY * (destinationHeight - 1.0f);
    return true;
}

// AppKit window geometry and UIKit Scene geometry are both expressed in
// logical points. Retina backing scale belongs only to the IOSurface/drawable
// pixel conversion; feeding it into native Scene geometry made the requested
// size change when UIKit changed a Scene's render scale during attachment.
// The user's macPad density preference is therefore the sole logical-point
// conversion used by window mode.
static inline float MacWSLogicalWindowDensity(float modeFactor) {
    if (!isfinite(modeFactor) || modeFactor < 0.5f ||
        modeFactor > 2.0f) modeFactor = 1.0f;
    return modeFactor;
}

static inline bool MacWSComputeNativeWindowPresentationRect(
        float sourcePixelWidth, float sourcePixelHeight,
        float sourceBackingScale, float densityScale,
        float viewWidth, float viewHeight,
        MacWSNativePresentationRect *result) {
    if (!result || !isfinite(sourcePixelWidth) ||
        !isfinite(sourcePixelHeight) || !isfinite(sourceBackingScale) ||
        !isfinite(densityScale) || !isfinite(viewWidth) ||
        !isfinite(viewHeight) || sourcePixelWidth <= 0.0f ||
        sourcePixelHeight <= 0.0f || sourceBackingScale < 0.5f ||
        sourceBackingScale > 8.0f || densityScale < 0.5f ||
        densityScale > 2.0f || viewWidth <= 0.0f || viewHeight <= 0.0f)
        return false;

    float width = sourcePixelWidth / sourceBackingScale * densityScale;
    float height = sourcePixelHeight / sourceBackingScale * densityScale;
    if (!isfinite(width) || !isfinite(height) || width <= 0.0f ||
        height <= 0.0f) return false;
    *result = (MacWSNativePresentationRect){
        .x = (viewWidth - width) * 0.5f,
        .y = (viewHeight - height) * 0.5f,
        .width = width,
        .height = height,
    };
    return true;
}

// Compute a destination pixel budget from independent source/display inputs.
// MTKView.contentScaleFactor is an output of setting drawableSize and must
// never be used here: fitting a differently shaped source with the previous
// drawable's scale shrinks the pixel budget on each layout pass.
//
// Both drawable axes use one scale in UIKit coordinates. Window mode always
// allocates the panel-native drawable budget. In particular, a Retina Larger
// source must be enlarged by MacWSHost's quality-controlled Metal pass rather
// than allocating a smaller CAMetalDrawable which UIKit enlarges a second
// time. Fullscreen draws an aspect-fitted desktop. Capping at the display's
// scale prevents needless offscreen supersampling.
static inline bool MacWSComputePresentationDrawableSize(
        float viewWidth, float viewHeight,
        float sourcePixelWidth, float sourcePixelHeight,
        float sourceBackingScale, float densityScale,
        float displayScale, bool nativeWindow,
        MacWSPresentationDrawableSize *result) {
    if (!result || !isfinite(viewWidth) || !isfinite(viewHeight) ||
        !isfinite(sourcePixelWidth) || !isfinite(sourcePixelHeight) ||
        !isfinite(displayScale) || viewWidth <= 0.0f ||
        viewHeight <= 0.0f || sourcePixelWidth <= 0.0f ||
        sourcePixelHeight <= 0.0f || displayScale < 0.5f ||
        displayScale > 8.0f) return false;

    float sourcePixelsPerViewPoint;
    if (nativeWindow) {
        if (!isfinite(sourceBackingScale) || sourceBackingScale < 0.5f ||
            sourceBackingScale > 8.0f || !isfinite(densityScale) ||
            densityScale < 0.5f || densityScale > 2.0f) return false;
        sourcePixelsPerViewPoint = displayScale;
    } else {
        sourcePixelsPerViewPoint = fmaxf(sourcePixelWidth / viewWidth,
                                         sourcePixelHeight / viewHeight);
    }
    float pixelsPerViewPoint = fminf(displayScale, sourcePixelsPerViewPoint);
    float width = roundf(viewWidth * pixelsPerViewPoint);
    float height = roundf(viewHeight * pixelsPerViewPoint);
    if (!isfinite(width) || !isfinite(height) || width < 1.0f ||
        height < 1.0f) return false;
    *result = (MacWSPresentationDrawableSize){ width, height };
    return true;
}

static inline bool MacWSComputeViewport(float sourceWidth, float sourceHeight,
                                        float viewWidth, float viewHeight,
                                        float requestedZoom,
                                        float requestedCenterX,
                                        float requestedCenterY,
                                        MacWSViewport *result) {
    if (!result || !isfinite(sourceWidth) || !isfinite(sourceHeight) ||
        !isfinite(viewWidth) || !isfinite(viewHeight) ||
        !isfinite(requestedZoom) || !isfinite(requestedCenterX) ||
        !isfinite(requestedCenterY) || sourceWidth <= 0 || sourceHeight <= 0 ||
        viewWidth <= 0 || viewHeight <= 0) return false;

    float sourceAspect = sourceWidth / sourceHeight;
    float viewAspect = viewWidth / viewHeight;
    float visibleWidth = 1.0f;
    float visibleHeight = 1.0f;
    if (sourceAspect > viewAspect)
        visibleWidth = viewAspect / sourceAspect;
    else
        visibleHeight = sourceAspect / viewAspect;

    // Product interaction is binary: 1x or one configured enlarged view.
    // Current settings expose 1.5x and 2x, so never admit an accidental
    // continuous-pinch scale outside that range.
    float zoom = MacWSClampFloat(requestedZoom, 1.0f, 2.0f);
    visibleWidth /= zoom;
    visibleHeight /= zoom;
    float centerX = MacWSClampFloat(requestedCenterX, visibleWidth * 0.5f,
                                    1.0f - visibleWidth * 0.5f);
    float centerY = MacWSClampFloat(requestedCenterY, visibleHeight * 0.5f,
                                    1.0f - visibleHeight * 0.5f);
    *result = (MacWSViewport){
        .visibleSource = {
            .x = centerX - visibleWidth * 0.5f,
            .y = centerY - visibleHeight * 0.5f,
            .width = visibleWidth,
            .height = visibleHeight,
        },
        .centerX = centerX,
        .centerY = centerY,
        .zoom = zoom,
    };
    return true;
}

static inline MacWSNormalizedPoint MacWSViewportMapPoint(
        const MacWSViewport *viewport, float normalizedViewX,
        float normalizedViewY) {
    if (!viewport) return (MacWSNormalizedPoint){0, 0};
    float x = MacWSClampFloat(normalizedViewX, 0.0f, 1.0f);
    float y = MacWSClampFloat(normalizedViewY, 0.0f, 1.0f);
    return (MacWSNormalizedPoint){
        .x = viewport->visibleSource.x + x * viewport->visibleSource.width,
        .y = viewport->visibleSource.y + y * viewport->visibleSource.height,
    };
}

// Returns the requested viewport center that keeps sourceAnchor under the
// same normalized point after changing zoom. Pass the visibleSource size
// computed at the new zoom; MacWSComputeViewport performs final edge clamps.
static inline MacWSNormalizedPoint MacWSViewportCenterKeepingAnchor(
        MacWSNormalizedRect enlargedVisibleSource,
        MacWSNormalizedPoint sourceAnchor, float normalizedViewX,
        float normalizedViewY) {
    float viewX = MacWSClampFloat(normalizedViewX, 0.0f, 1.0f);
    float viewY = MacWSClampFloat(normalizedViewY, 0.0f, 1.0f);
    return (MacWSNormalizedPoint){
        .x = sourceAnchor.x +
             (0.5f - viewX) * enlargedVisibleSource.width,
        .y = sourceAnchor.y +
             (0.5f - viewY) * enlargedVisibleSource.height,
    };
}

#endif
