#!/usr/bin/env python3
"""Validate H426's bounded first-throw and terminate evidence."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "A540TracePlugin.mm"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    text = SOURCE.read_text(encoding="utf-8")
    require('caller("builder", "build", "H426");' in text,
            "H426 plugin marker missing")
    for marker in (
        "#include <objc/objc-exception.h>",
        "objc_setExceptionPreprocessor(a540_exception_preprocessor)",
        "gPreviousExceptionPreprocessor(exception)",
        "NSGetUncaughtExceptionHandler()",
        "NSSetUncaughtExceptionHandler(a540_uncaught_exception)",
        "gPreviousUncaughtExceptionHandler(exception)",
        "std::set_terminate(a540_terminate_handler)",
        "gPreviousTerminateHandler()",
        "abi::__cxa_current_exception_type()",
        "uintptr_t pc[16];",
        "depth_limit=16",
        "sigaction(number, NULL, &gPreviousSignalActions[number])",
        "sigaction(number, &previous, NULL)",
        "report_return_site(\"newCommandQueue\"",
        "report_return_site(\"newCommandQueueWithMaxCommandBufferCount:\"",
        'caller("queue", "signature", detail);',
        "gPreviousExceptionPreprocessor != a540_exception_preprocessor",
        "gPreviousUncaughtExceptionHandler != a540_uncaught_exception",
        "gPreviousTerminateHandler != a540_terminate_handler",
    ):
        require(marker in text, f"H426 exception evidence missing: {marker}")

    for forbidden in (
        "NSSetUncaughtExceptionHandler(NULL)",
        "std::set_terminate(nullptr)",
        "force_return_success",
    ):
        require(forbidden not in text, f"H426 must not swallow failures: {forbidden}")

    require(text.index("report_exception_event(\"throw\"") <
            text.index("report_exception_event(\"uncaught\""),
            "first throw and uncaught boundary are not distinct")
    print("H426 exception forensics plugin gate: PASS")


if __name__ == "__main__":
    main()
