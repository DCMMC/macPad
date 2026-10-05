#pragma once

#import <Foundation/Foundation.h>

BOOL MacWSHostDiagnosticsEnabled(void);
BOOL MacWSHostTouchDiagnosticsEnabled(void);
BOOL MacWSHostKeyboardLatencyDiagnosticsEnabled(void);
BOOL MacWSHostGamePointerDiagnosticsEnabled(void);
double MacWSMachMilliseconds(uint64_t start, uint64_t end);
void MacWSLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// Gate at the call site: a quiet build must not evaluate diagnostic arguments
// (method inventories, array sorting, geometry descriptions, etc.).
#define MacWSDiagnosticLog(...) do { \
    if (MacWSHostDiagnosticsEnabled()) MacWSLog(__VA_ARGS__); \
} while (0)
