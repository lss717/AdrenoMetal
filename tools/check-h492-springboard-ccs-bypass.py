#!/usr/bin/env python3
"""Static checks for the H492 SpringBoard CCS launch-services bypass."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHIM = ROOT / "SpringBoardCCSBypass.mm"
BUILD = ROOT.parents[1] / "scripts/build-h436-springboard-bundle.py"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    text = SHIM.read_text(encoding="utf-8")
    for marker in (
        'strncmp(process, "SpringBoard", 11)',
        '"CCSModuleRepository"',
        '"_queue_filterModuleMetadataByAssociatedBundleAvailability:"',
        "return value",
        "method_setImplementation(method, (IMP) h492_return_input)",
        "filter method missing",
    ):
        require(marker in text, "missing bypass marker: " + marker)
    for forbidden in (
        "performJournalRecovery",
        "dispatch_sync",
        "SpringBoardSceneObserver",
        "IOMobileFramebuffer",
        "NativeLegacyDisplay",
        "CCSModuleRepository sharedInstance",
    ):
        require(forbidden not in text, "bypass exceeds its single operation: " + forbidden)
    build = BUILD.read_text(encoding="utf-8")
    require(
        "drivers/NativeMetal/SpringBoardCCSBypass.mm" in build,
        "SpringBoard bundle build does not link the CCS bypass",
    )
    require(
        'b"H492_CCS"' in build,
        "SpringBoard bundle build does not verify the final dylib marker",
    )
    print("H492 SpringBoard CCS bypass gate including final-dylib guard: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
