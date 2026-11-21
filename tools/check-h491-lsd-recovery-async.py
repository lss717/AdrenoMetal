#!/usr/bin/env python3
"""Static checks for the H491 lsd journal-recovery async shim."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHIM = ROOT / "LsdRecoveryAsync.mm"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    text = SHIM.read_text(encoding="utf-8")
    for marker in (
        'strcmp(process, "lsd")',
        '"_LSInstallProgressService"',
        '"performJournalRecovery"',
        "gOriginalRecovery(retained, command)",
        "dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)",
        "method_setImplementation(method, (IMP) h491_recovery_async)",
        "recovery method missing",
    ):
        require(marker in text, "missing shim marker: " + marker)
    for forbidden in (
        "restoreInactiveInstalls",
        "dispatch_sync",
        "setImplementation(0)",
        "SpringBoard",
        "IOMobileFramebuffer",
        "NativeLegacyDisplay",
    ):
        require(forbidden not in text, "shim exceeds its single operation: " + forbidden)
    print("H491 lsd recovery async gate: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
