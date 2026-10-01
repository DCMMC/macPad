#!/usr/bin/env python3
"""Source contract for keeping synchronous WindowServer hits off scroll frames."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "libmachook" / "AppInputBridge.m").read_text()


def main():
    start = SOURCE.index("BOOL exactPointerStart =")
    end = SOURCE.index("BOOL catalystContentInput =", start)
    policy = SOURCE[start:end]
    assert "BOOL processLocalPreciseScroll" in policy
    assert "MacWSWindowPointUsesProcessLocalPreciseScroll" in policy
    assert "BOOL beginsSystemScroll" in policy
    assert "MacWSInputFlagScrollBegan" in policy
    assert "!processLocalPreciseScroll" in policy
    assert "BOOL needsGlobalWindowHit = exactPointerStart || beginsSystemScroll" in policy
    assert "if (needsGlobalWindowHit && nativeWindowClass" in policy
    assert "windowNumberAtPoint:belowWindowWithWindowNumber:" in policy

    scroll_start = SOURCE.index("if (record.kind == MacWSInputKindScroll) {", end)
    scroll_end = SOURCE.index("if (record.kind == MacWSInputKindMagnify", scroll_start)
    scroll = SOURCE[scroll_start:scroll_end]
    assert "BOOL processLocalPreciseScroll" not in scroll
    assert "processLocalPreciseScroll" in scroll
    print("PASS: global WindowServer hit tests stay at input transaction boundaries")


if __name__ == "__main__":
    main()
