"""Execute the production wire classifier, including drawable-free key release."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class KeyboardSnapshotWireTests(unittest.TestCase):
    def test_physical_keyboard_latency_probe_covers_every_boundary(self):
        host = (ROOT / 'MacWSHost/Rendering/MacWSMetalView.m').read_text()
        host_diagnostics = (
            ROOT / 'MacWSHost/Support/MacWSHostDiagnostics.m').read_text()
        broker = (ROOT / 'macwsinputd/main.c').read_text()
        proxy = (ROOT / 'libmachook/mac_hooks.m').read_text()
        app = (ROOT / 'libmachook/AppInputBridge.m').read_text()
        self.assertIn('MacWSHostKeyboardLatencyDiagnosticsEnabled()', host)
        self.assertIn('/var/mnt/rootfs/private/tmp/macws_keyboard_latency_diagnostics',
                      host_diagnostics)
        self.assertIn(
            'record.flags |= MacWSInputFlagLatencyDiagnostic;', host)
        for source, witness in (
                (broker, 'stage=broker'),
                (proxy, 'stage=session-proxy'),
                (app, 'stage=app-dispatch')):
            self.assertIn('/tmp/macws_keyboard_latency_diagnostics', source)
            self.assertIn(witness, source)
        self.assertIn('stage=host-callback', host)
        self.assertIn('MacWSRegisterKeyboardCGSTraceSample(', app)
        self.assertIn('MacWSConsumeKeyboardCGSTraceSample(', app)
        self.assertIn('sample=%u kind=%s keycode=%ld', app)
        self.assertIn('route=%s', app)

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
    assert(MacWSInputWireVersionForKind(MacWSInputKindRelativePointer)==9);
    for (unsigned version=5;version<=9;version++)
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

    r=(MacWSInputRecord){.magic=MACWS_INPUT_MAGIC,.version=9,
        .kind=MacWSInputKindRelativePointer,.timestamp=1,
        .sceneID=MacWSInputSceneForWindow(521,0),.x=960,.y=540,
        .pressure=31,.altitude=-17,.frameWidth=1920,.frameHeight=1080,
        .targetPID=1234,.source=MacWSInputSourceIndirectPointer};
    assert(RecordIsValid(&r));
    r.version=8;assert(!RecordIsValid(&r));r.version=9;
    r.sceneID=MacWSInputSceneForWindow(0,0);assert(!RecordIsValid(&r));
    r.sceneID=MacWSInputSceneForWindow(521,0);
    r.source=MacWSInputSourceFinger;assert(RecordIsValid(&r));
    r.source=MacWSInputSourcePencil;assert(!RecordIsValid(&r));
    r.source=MacWSInputSourceIndirectPointer;
    r.flags=MacWSInputFlagGlobalSystemSurface;assert(!RecordIsValid(&r));
    r.flags=0;r.pressure=4097;assert(!RecordIsValid(&r));

    // Both actual broker call sites use this one production predicate.
    // Global physical input keeps the session route. Exact-window physical
    // input and every software-toolbar key retain their AppInput pair,
    // including special keys and Control/Option/Command chords.
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
        r.sceneID=MacWSInputSceneForWindow(521,modifiers[m]);
        assert(!IsNativeKeyboardProxyRecord(&r));
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
