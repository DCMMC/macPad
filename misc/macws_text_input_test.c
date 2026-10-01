#include <assert.h>
#include <stdio.h>

#include "macws_text_input.h"

int main(void) {
    assert(MacWSClassifyKeyboardProxyEdit(3, true, true) ==
        MacWSKeyboardProxyEditAwaitingComposition); // sentinel + "ni"
    assert(MacWSClassifyKeyboardProxyEdit(2, true, false) ==
        MacWSKeyboardProxyEditCommitText); // sentinel + "你"
    assert(MacWSClassifyKeyboardProxyEdit(3, true, false) ==
        MacWSKeyboardProxyEditCommitText); // sentinel + "你好"
    assert(MacWSClassifyKeyboardProxyEdit(1, true, false) ==
        MacWSKeyboardProxyEditIdle);
    assert(MacWSClassifyKeyboardProxyEdit(0, false, false) ==
        MacWSKeyboardProxyEditRestoreSentinel);
    assert(MacWSClassifyKeyboardProxyEdit(1, false, false) ==
        MacWSKeyboardProxyEditCommitText); // IME replaced the sentinel

    assert(MacWSKeySymIsEncodedUnicode(UINT32_C(0x01004f60))); // 你
    assert(MacWSKeySymIsEncodedUnicode(UINT32_C(0x0101f600))); // 😀
    assert(!MacWSKeySymIsEncodedUnicode(UINT32_C(0xff0d)));
    assert(!MacWSKeySymIsEncodedUnicode(UINT32_C(0x0100d800)));
    assert(!MacWSSoftwareKeyRequiresNativeProxy(
        UINT32_C(0x01004f60), 0));
    assert(MacWSSoftwareKeyRequiresNativeProxy(UINT32_C(0xff0d), 0));
    assert(MacWSSoftwareKeyRequiresNativeProxy('v', UINT32_C(0x00100000)));
    assert(!MacWSSoftwareKeyRequiresNativeProxy('a', UINT32_C(0x00020000)));

    puts("text-input composition and exact Unicode routing PASS");
    return 0;
}
