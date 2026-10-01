#ifndef MACWS_KEYBOARD_TEXT_INPUT_H
#define MACWS_KEYBOARD_TEXT_INPUT_H

#include <stdbool.h>
#include <stdint.h>

// UIKit modifier bits are part of MacWSInputRecord's established ABI. Keep
// this responder-routing policy framework-free so every HID usage/modifier
// combination can be exercised on the build host.
enum {
    MacWSUIKitModifierShift = 1u << 17,
    MacWSUIKitModifierControl = 1u << 18,
    MacWSUIKitModifierAlternate = 1u << 19,
    MacWSUIKitModifierCommand = 1u << 20,
};

static inline bool MacWSHIDUsageIsKeyboardModifier(uint32_t usage) {
    return usage >= 224u && usage <= 231u;
}

// While the hidden UITextField owns first responder, unmodified printable
// hardware keys must still reach UIKit so an iOS IME can compose them. Raw
// navigation and shortcut keys instead belong to the represented macOS
// window. Pure modifier edges remain visible to UIKit and are mirrored by the
// separate modifier-snapshot path. Command-Tab and Command-Space deliberately
// remain iPadOS system shortcuts, matching the normal MacWS keyboard mode.
static inline bool MacWSHardwareKeyRequiresMacRouteDuringTextInput(
        uint32_t usage, uint32_t modifiers) {
    if (MacWSHIDUsageIsKeyboardModifier(usage)) return false;
    if (usage >= 74u && usage <= 82u) return true; // Home..arrow cluster

    bool command = (modifiers & MacWSUIKitModifierCommand) != 0;
    bool control = (modifiers & MacWSUIKitModifierControl) != 0;
    if (command && (usage == 43u || usage == 44u))
        return false; // iPadOS app switcher / system search
    return command || control;
}

#endif
