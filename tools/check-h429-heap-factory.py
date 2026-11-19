#!/usr/bin/env python3
"""Validate H429's explicit newHeapWithDescriptor contract."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "A540TracePlugin.mm"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    text = SOURCE.read_text(encoding="utf-8")
    require(any(f'caller("builder", "build", "{build}");' in text
                for build in ("H429", "H430", "H431", "H432", "H433", "H434")),
            "H429/H430 plugin marker missing")
    for marker in (
        "- (id)newHeapWithDescriptor:(id)descriptor",
        'caller("dev", "newHeapWithDescriptor:", detail);',
        'trace_object_of("_MTLHeap", "heap")',
    ):
        require(marker in text, f"H429 heap factory missing: {marker}")
    require('objc_getClass("CMMTLDevice")' not in text,
            "H429 must repair the underlying device, not patch CMMTLDevice")
    print("H429 newHeapWithDescriptor contract gate: PASS")


if __name__ == "__main__":
    main()
