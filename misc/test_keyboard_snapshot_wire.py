"""Execute the production wire classifier, including drawable-free key release."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class KeyboardSnapshotWireTests(unittest.TestCase):
    def test_real_broker_validation_and_rolling_abi(self):
        compiler = shutil.which('clang') or shutil.which('cc')
        if not compiler:
            self.skipTest('C compiler unavailable')
        source = (ROOT / 'macwsinputd/main.c').read_text()
        start = source.index('static bool IsNativeKeyboardProxyRecord(')
        end = source.index('\nstatic CGPoint QuartzPointForRecord', start)
        self.assertEqual(source.count('IsNativeKeyboardProxyRecord(&record)'), 2)
        program = '''
#include <assert.h>
#include <stdbool.h>
#include <math.h>
#include <string.h>
#include "macws_host_protocol.h"
#include "macws_text_input.h"
''' + source[start:end] + r'''
int main(void) {
    assert(sizeof(MacWSInputRecord)==84);
    assert(MacWSInputWireVersionForKind(MacWSInputKindKeyUp)==5);
    assert(MacWSInputWireVersionForKind(MacWSInputKindOpenDocuments)==6);
    assert(MacWSInputWireVersionForKind(MacWSInputKindPerformQuit)==7);
    assert(MacWSInputWireVersionForKind(MacWSInputKindModifierSnapshot)==8);
    for (unsigned version=5;version<=8;version++)
        assert(MacWSInputVersionSupportsKind(version,MacWSInputKindKeyUp));
    MacWSInputRecord r={.magic=MACWS_INPUT_MAGIC,.version=8,
        .kind=MacWSInputKindModifierSnapshot,.timestamp=1,
        .source=MacWSInputSourceHardwareKeyboard,.contactID=1};
    // No PID, window, point or drawable may prevent a focus-loss release.
    assert(RecordIsValid(&r));
    r.version=7;assert(!RecordIsValid(&r));r.version=8;
    r.source=MacWSInputSourceVNC;assert(!RecordIsValid(&r));
    r.source=MacWSInputSourceHardwareKeyboard;
    r.reserved=4;assert(!RecordIsValid(&r));
    r.contactID=0;assert(RecordIsValid(&r));
    r.reserved=256;assert(!RecordIsValid(&r));r.reserved=0;
    r.contactID=2;assert(!RecordIsValid(&r));r.contactID=0;
    r.timestamp=NAN;assert(!RecordIsValid(&r));r.timestamp=1;
    r.magic=0;assert(!RecordIsValid(&r));

    // Both actual broker call sites use this one production predicate.
    // Empty PID/geometry cannot swallow a physical release. Every software
    // toolbar key retains its exact AppInput pair, including special keys and
    // Control/Option/Command chords.
    assert(!IsNativeKeyboardProxyRecord(NULL));
    const uint32_t modifiers[]={0,0x10000u,0x20000u,0x30000u,
        0x40000u,0x80000u,0x100000u,0x1e0000u};
    const uint32_t symbols[]={
        'a','A',0xfeffu,0xff00u,0xff1bu,0xffffu,0x01004f60u,0x0101f600u};
    for(unsigned source=0;source<=MacWSInputSourceMax;source++)
    for(unsigned m=0;m<sizeof(modifiers)/sizeof(*modifiers);m++)
    for(unsigned k=0;k<sizeof(symbols)/sizeof(*symbols);k++) {
        r=(MacWSInputRecord){.kind=MacWSInputKindKeyDown,.source=source,
            .contactID=symbols[k],.sceneID=MacWSInputSceneForWindow(0,modifiers[m])};
        bool expected=source==MacWSInputSourceHardwareKeyboard;
        assert(IsNativeKeyboardProxyRecord(&r)==expected);
        r.kind=MacWSInputKindKeyUp;
        assert(IsNativeKeyboardProxyRecord(&r)==expected);
        r.targetPID=1234;r.frameWidth=1920;r.frameHeight=1080;
        assert(IsNativeKeyboardProxyRecord(&r)==expected);
        r.kind=MacWSInputKindModifierSnapshot;
        assert(!IsNativeKeyboardProxyRecord(&r));
        r.kind=MacWSInputKindTap;
        assert(!IsNativeKeyboardProxyRecord(&r));
    }
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            (path/'probe.c').write_text(program)
            subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=undefined', '-I'+str(ROOT/'include'),
                            str(path/'probe.c'), '-o', str(path/'probe')], check=True)
            subprocess.run([str(path/'probe')], check=True, timeout=5)


if __name__ == '__main__':
    unittest.main()
