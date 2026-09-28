"""Execute the real optional getter against partial AppKit-style objects."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WindowMetricsObservationTests(unittest.TestCase):
    def compile_run(self, fixture):
        with tempfile.TemporaryDirectory(prefix='macws-window-observation-') as directory:
            binary = Path(directory) / 'observation'
            subprocess.run(['clang', '-x', 'objective-c', '-fobjc-arc',
                            '-Wall', '-Werror', '-framework', 'Foundation',
                            '-framework', 'CoreGraphics', '-', '-o', str(binary)],
                           input=fixture, text=True, check=True)
            subprocess.run([str(binary)], check=True, timeout=5)

    def test_optional_size_observation_preserves_capability_and_exact_values(self):
        source = (ROOT / 'libmachook/AppInputBridge.m').read_text()
        start = source.index('static CGSize MacWSOptionalDiagnosticWindowSize(')
        end = source.index('\nstatic void MacWSPublishWindowMetrics(void) {', start)
        helper = source[start:end]
        fixture = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <assert.h>
#include <math.h>
typedef BOOL (*MacWSMsgBoolSEL)(id, SEL, SEL);
typedef CGSize (*MacWSMsgSize)(id, SEL);
static unsigned queries;
@interface PartialWindow : NSObject
- (CGSize)minSize;
@end
@implementation PartialWindow
- (CGSize)minSize { ++queries; return (CGSize){17.25, 38.5}; }
@end
@interface ResizableWindow : PartialWindow
- (CGSize)resizeIncrements;
@end
@implementation ResizableWindow
- (CGSize)resizeIncrements { ++queries; return (CGSize){3, 7}; }
@end
'''
        fixture += helper
        fixture += r'''
int main(void) { @autoreleasepool {
    id partial = [PartialWindow new];
    id complete = [ResizableWindow new];
    SEL increments = sel_registerName("resizeIncrements");
    CGSize missing = MacWSOptionalDiagnosticWindowSize(partial, increments);
    assert(isnan(missing.width) && isnan(missing.height) && queries == 0);
    missing = MacWSOptionalDiagnosticWindowSize(nil, increments);
    assert(isnan(missing.width) && isnan(missing.height) && queries == 0);
    CGSize minimum = MacWSOptionalDiagnosticWindowSize(partial, sel_registerName("minSize"));
    assert(minimum.width == 17.25 && minimum.height == 38.5 && queries == 1);
    CGSize actual = MacWSOptionalDiagnosticWindowSize(complete, increments);
    assert(actual.width == 3 && actual.height == 7 && queries == 2);
} return 0; }
'''
        self.compile_run(fixture)

    def test_native_limit_log_dedup_does_no_work_with_diagnostics_off(self):
        source = (ROOT / 'libmachook/AppInputBridge.m').read_text()
        anchor = source.index('// The witness is only a log deduplicator.')
        start = source.index('if (MacWSRuntimeDiagnosticsEnabled()) {', anchor)
        depth = 0
        for end in range(source.index('{', start), len(source)):
            depth += (source[end] == '{') - (source[end] == '}')
            if depth == 0:
                break
        block = source[start:end + 1]
        fixture = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <assert.h>
#include <unistd.h>
typedef NSInteger (*MacWSMsgInteger)(id, SEL);
static BOOL diagnostic;
static unsigned reads, writes;
static BOOL MacWSRuntimeDiagnosticsEnabled(void) { return diagnostic; }
static id observedRead(id object, const void *key) { ++reads; return nil; }
static void observedWrite(id object, const void *key, id value, objc_AssociationPolicy policy) { ++writes; }
#define objc_getAssociatedObject observedRead
#define objc_setAssociatedObject observedWrite
@interface MetricWindow : NSObject
- (NSInteger)windowNumber;
@end
@implementation MetricWindow
- (NSInteger)windowNumber { return 17; }
@end
static void observe(id window) {
    CGSize minimum = {17, 29}, maximum = {100, 200};
'''
        fixture += block
        fixture += r'''
    assert(minimum.width == 17 && minimum.height == 29);
    assert(maximum.width == 100 && maximum.height == 200);
}
int main(void) { @autoreleasepool {
    id window = [MetricWindow new];
    observe(window);
    assert(reads == 0 && writes == 0);
    diagnostic = YES;
    observe(window);
    assert(reads == 1 && writes == 1);
} return 0; }
'''
        self.compile_run(fixture)

    def test_all_optional_diagnostic_size_queries_use_capability_helper(self):
        source = (ROOT / 'libmachook/AppInputBridge.m').read_text()
        block = source.split('if (diagnosticEntries) {', 1)[1].split(
            '[diagnosticEntries addObject:', 1)[0]
        for variable in ('apiMinimum', 'apiMaximum', 'apiContentMinimum',
                         'apiContentMaximum', 'apiIncrements'):
            self.assertIn('CGSize ' + variable +
                          ' = MacWSOptionalDiagnosticWindowSize(', block)

    def test_logical_group_observes_existing_stack_without_creating_one(self):
        source = (ROOT / 'libmachook/AppInputBridge.m').read_text()
        start = source.index('static uint32_t MacWSLogicalWindowGroupID(')
        end = source.index('\nstatic void MacWSSendDisplayInvalidation(',
                           start)
        helper = source[start:end]
        self.assertIn('sel_registerName("_windowStackController")', helper)
        self.assertNotIn('sel_registerName("tabGroup")', helper)
        self.assertIn('sel_registerName("windows")', helper)


if __name__ == '__main__':
    unittest.main()
