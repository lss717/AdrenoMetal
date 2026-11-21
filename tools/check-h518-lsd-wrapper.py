#!/usr/bin/env python3
"""Static checks for the H518 lsd wrapper and recovery-async injection."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "LsdBootstrap.mm"
SHIM = ROOT / "LsdRecoveryAsync.mm"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    wrapper = WRAPPER.read_text(encoding="utf-8")
    shim = SHIM.read_text(encoding="utf-8")
    for marker in (
        '"/private/var/ngpu/lib/LsdRecoveryAsync.dylib"',
        '"/System/Library/xpc/lsd.real"',
        'setenv("DYLD_INSERT_LIBRARIES", kShim, 1)',
        'setenv("DYLD_FORCE_FLAT_NAMESPACE", "1", 1)',
        'arguments[0] = (char *) "lsd"',
        "execv(kLsd, arguments)",
        "H518_LSDWRAP",
    ):
        require(marker in wrapper, "missing lsd wrapper marker: " + marker)
    for forbidden in (
        "performJournalRecovery",
        "LaunchServices",
        "IOMobileFramebuffer",
        "NativeLegacyDisplay",
    ):
        require(forbidden not in wrapper,
                "lsd wrapper exceeds its single launch operation: " + forbidden)

    for marker in (
        'strncmp(process, "lsd", 3)',
        '"_LSInstallProgressService"',
        '"performJournalRecovery"',
        'lsd_line("recovery skipped pid=%d", getpid())',
        "method_setImplementation(method, (IMP) h491_recovery_skip)",
        "H491_LSD",
    ):
        require(marker in shim, "missing recovery shim marker: " + marker)
    for forbidden in (
        "restoreInactiveInstalls",
        "dispatch_sync",
        "setImplementation(0)",
        "SpringBoard",
    ):
        require(forbidden not in shim,
                "recovery shim exceeds its single operation: " + forbidden)
    print("H522 lsd wrapper and recovery-skip gate: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
