#ifndef MACWS_WINDOWING_PROTOCOL_H
#define MACWS_WINDOWING_PROTOCOL_H

#include <stdbool.h>
#include <stdint.h>

// Readiness is live service state, never a file enabling a production feature.
// The request plists are bounded, per-Scene IPC messages, not configuration.
#define MACWS_WINDOWING_STATE_NAME "com.macwsguide.windowing.capabilities.v1"
#define MACWS_WINDOWING_REFRESH_NAME "com.macwsguide.windowing.query-capabilities"
#define MACWS_WINDOWING_REQUEST_DIRECTORY "/tmp"
#define MACWS_WINDOWING_ABI 1u
#define MACWS_WINDOWING_MAGIC UINT64_C(0x4d57)

enum {
    MacWSWindowingFullscreen = 1u << 0,
    MacWSWindowingResize = 1u << 1,
    MacWSWindowingInitialSize = 1u << 2,
    MacWSWindowingSceneConstraints = 1u << 3,
    MacWSWindowingDenseGrid = 1u << 4,
    // Dynamic SpringBoard observation, not a static method-presence claim.
    // `Known` means the real layout calculator has supplied its
    // isChamoisWindowingUIEnabled argument at least once; `Active` mirrors
    // that latest value.  UIApplication.supportsMultipleScenes is true for
    // ordinary iPad Split View too, so it cannot authorize independent
    // macPad window Scenes by itself.
    MacWSWindowingChamoisKnown = 1u << 5,
    MacWSWindowingChamoisActive = 1u << 6,
    MacWSWindowingRequired = (1u << 5) - 1u,
};

static inline uint64_t MacWSWindowingState(uint32_t pid, uint8_t capabilities) {
    return (MACWS_WINDOWING_MAGIC << 48) |
        ((uint64_t)MACWS_WINDOWING_ABI << 40) |
        ((uint64_t)capabilities << 32) | pid;
}

static inline uint32_t MacWSWindowingPublisher(uint64_t state) {
    return (uint32_t)state;
}

static inline uint8_t MacWSWindowingStateCapabilities(uint64_t state) {
    return (uint8_t)(state >> 32);
}

static inline bool MacWSWindowingStateSupports(uint64_t state, uint8_t required) {
    return (state >> 48) == MACWS_WINDOWING_MAGIC &&
        ((state >> 40) & 0xffu) == MACWS_WINDOWING_ABI &&
        MacWSWindowingPublisher(state) > 1 &&
        (((state >> 32) & required) == required);
}

#endif
