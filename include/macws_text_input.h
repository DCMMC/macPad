#ifndef MACWS_TEXT_INPUT_H
#define MACWS_TEXT_INPUT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    MacWSKeyboardProxyEditIdle,
    MacWSKeyboardProxyEditAwaitingComposition,
    MacWSKeyboardProxyEditCommitText,
    MacWSKeyboardProxyEditRestoreSentinel,
} MacWSKeyboardProxyEditAction;

// UIKit owns marked text and its candidate UI.  Only text outside that
// composition is a committed payload for the remote AppKit first responder.
// The one-unit sentinel keeps Backspace observable when the proxy otherwise
// contains no text.
static inline MacWSKeyboardProxyEditAction MacWSClassifyKeyboardProxyEdit(
        size_t utf16Length, bool beginsWithSentinel, bool hasMarkedText) {
    if (hasMarkedText)
        return MacWSKeyboardProxyEditAwaitingComposition;
    size_t payloadLength = utf16Length -
        ((beginsWithSentinel && utf16Length > 0) ? 1u : 0u);
    if (payloadLength > 0)
        return MacWSKeyboardProxyEditCommitText;
    if (utf16Length == 0 || !beginsWithSentinel)
        return MacWSKeyboardProxyEditRestoreSentinel;
    return MacWSKeyboardProxyEditIdle;
}

static inline bool MacWSKeySymIsEncodedUnicode(uint32_t keySym) {
    uint32_t scalar = keySym & UINT32_C(0x00ffffff);
    return (keySym & UINT32_C(0xff000000)) == UINT32_C(0x01000000) &&
        scalar > UINT32_C(0xff) && scalar <= UINT32_C(0x10ffff) &&
        !(scalar >= UINT32_C(0xd800) && scalar <= UINT32_C(0xdfff));
}

#endif
