#!/usr/bin/env python3
"""Static checks for the H536 lsd journal-recovery retry shim."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHIM = ROOT / "LsdRecoveryAsync.mm"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    text = SHIM.read_text(encoding="utf-8")
    for marker in (
        'strncmp(process, "lsd", 3)',
        '"_LSInstallProgressService"',
        '"performJournalRecovery"',
        'h536_line("recovery skipped pid=%d", getpid())',
        "method_setImplementation(method, (IMP) h536_recovery_skip)",
        "pthread_create(&worker, NULL, h536_recovery_worker",
        "install_recovery_skip",
        "recovery skip installed",
        "recovery install failed",
    ):
        require(marker in text, "missing shim marker: " + marker)
    for forbidden in (
        "restoreInactiveInstalls",
        "dispatch_sync",
        "setImplementation(0)",
        "SpringBoard",
        "dispatch_get_global_queue",
        "gOriginalRecovery(retained, command)",
        "IOMobileFramebuffer",
        "NativeLegacyDisplay",
    ):
        require(forbidden not in text, "shim exceeds its single operation: " + forbidden)
    print("H536 lsd recovery retry gate: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
