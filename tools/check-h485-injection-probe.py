#!/usr/bin/env python3
"""Static checks for the minimal H485 Mach-O dependency probe."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "SpringBoardInjectionProbe.mm"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    text = PROBE.read_text(encoding="utf-8")
    for marker in (
        "__attribute__((constructor))",
        "getprogname",
        'open("/dev/console", O_WRONLY | O_NOCTTY)',
        "H485_LCPROBE: load process=%s pid=%d build=H485",
    ):
        require(marker in text, "missing probe marker: " + marker)
    for forbidden in (
        "#import <Foundation",
        "#include <Foundation",
        "#import <IOKit",
        "#include <IOKit",
        "objc/",
        "IOService",
        "dispatch_",
        "SpringBoardSceneObserver",
    ):
        require(forbidden not in text, "probe is not minimal: " + forbidden)
    print("H485 minimal dependency probe gate: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
