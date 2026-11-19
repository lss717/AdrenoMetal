#!/usr/bin/env python3
"""Validate H433's cached launchd wrapper and scene observer."""

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

    require('caller("builder", "build", "H433");' in trace,
            "H433 trace marker missing")
    for marker in (
        'strcmp(process, "SpringBoard")',
        "FBSWorkspace",
        "_sharedWorkspaceIfExists",
        'read_object(workspace, "scenes")',
        '"context", "layer", "layerManager"',
        "UIApplication",
        "connectedScenes",
        "CADisplay",
        "build=H433",
    ):
        require(marker in observer, f"H433 observer missing: {marker}")
    for forbidden in (
        "NSSetUncaughtExceptionHandler",
        "requestSceneCreation",
        "createScene",
        "setScene",
        "class_addMethod",
    ):
        require(forbidden not in observer,
                f"H433 observer is not read-only: {forbidden}")

    for marker in (
        "H433_SBWRAP",
        'setenv("DYLD_INSERT_LIBRARIES"',
        '"/System/Library/CoreServices/SpringBoard.app/SpringBoard"',
        "execv(kSpringBoard, arguments)",
        "--launch-springboard",
        "DYLD_INSERT_LIBRARIES",
        "SpringBoardSceneObserver.dylib",
    ):
        require(marker in bootstrap, f"H433 wrapper missing: {marker}")
    print("H433 cached launchd wrapper gate: PASS")


if __name__ == "__main__":
    main()
