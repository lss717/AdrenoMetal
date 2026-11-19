#!/usr/bin/env python3
"""Validate H432's SpringBoard launch wrapper and scene observer."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TRACE = ROOT / "A540TracePlugin.mm"
OBSERVER = ROOT / "SpringBoardSceneObserver.mm"
BOOTSTRAP = ROOT / "SceneBootstrap.mm"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    trace = TRACE.read_text(encoding="utf-8")
    observer = OBSERVER.read_text(encoding="utf-8")
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")

    require('caller("builder", "build", "H432");' in trace,
            "H432 trace marker missing")
    for marker in (
        'strcmp(process, "SpringBoard")',
        "FBSWorkspace",
        "_sharedWorkspaceIfExists",
        'read_object(workspace, "scenes")',
        '"context", "layer", "layerManager"',
        "UIApplication",
        "connectedScenes",
        "CADisplay",
        "build=H432",
    ):
        require(marker in observer, f"H432 observer missing: {marker}")
    for forbidden in (
        "NSSetUncaughtExceptionHandler",
        "requestSceneCreation",
        "createScene",
        "setScene",
        "class_addMethod",
    ):
        require(forbidden not in observer,
                f"H432 observer is not read-only: {forbidden}")

    for marker in (
        "H432_SBWRAP",
        'setenv("DYLD_INSERT_LIBRARIES"',
        '"/System/Library/CoreServices/SpringBoard.app/SpringBoard"',
        "execv(kSpringBoard, arguments)",
        "--launch-springboard",
        "DYLD_INSERT_LIBRARIES",
        "SpringBoardSceneObserver.dylib",
    ):
        require(marker in bootstrap, f"H432 wrapper missing: {marker}")
    print("H432 SpringBoard launch wrapper gate: PASS")


if __name__ == "__main__":
    main()
