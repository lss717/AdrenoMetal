#!/usr/bin/env python3
"""Validate H428's explicit newBufferWithBytes contract."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "A540TracePlugin.mm"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    text = SOURCE.read_text(encoding="utf-8")
    require('caller("builder", "build", "H428");' in text,
            "H428 plugin marker missing")
    for marker in (
        "- (id)newBufferWithBytes:(const void *)pointer",
        "length:(NSUInteger)length",
        "options:(NSUInteger)options",
        "copy = malloc((size_t) length);",
        "memcpy(copy, pointer, (size_t) length);",
        "store->contents = copy;",
    ):
        require(marker in text, f"H428 buffer factory missing: {marker}")
    require('objc_getClass("CMMTLDevice")' not in text,
            "H428 must repair the underlying MTLDevice, not patch CMMTLDevice")
    print("H428 newBufferWithBytes contract gate: PASS")


if __name__ == "__main__":
    main()
