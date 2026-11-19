#!/usr/bin/env python3
"""Validate H427's explicit MTL command-queue priority methods."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "A540TracePlugin.mm"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    text = SOURCE.read_text(encoding="utf-8")
    require(any(f'caller("builder", "build", "{build}");' in text
                for build in ("H427", "H428", "H429", "H430", "H431", "H432", "H433")),
            "H427/H428 plugin marker missing")
    for marker in (
        "- (BOOL)setGPUPriority:(NSUInteger)priority",
        "- (BOOL)setBackgroundGPUPriority:(NSUInteger)priority",
        "- (NSUInteger)getGPUPriority",
        "- (NSUInteger)getBackgroundGPUPriority",
        'value("queue", "setGPUPriority:", "priority", priority)',
        'value("queue", "setBackgroundGPUPriority:", "priority", priority)',
        "return YES;",
    ):
        require(marker in text, f"H427 priority contract missing: {marker}")
    require('objc_getClass("CMMTLCommandQueue")' not in text,
            "H427 must repair the underlying queue, not patch CMMTLCommandQueue")
    require("setBackgroundGPUPriority:unrecognized" not in text,
            "H427 must not special-case exception text")
    print("H427 command-queue priority contract gate: PASS")


if __name__ == "__main__":
    main()
