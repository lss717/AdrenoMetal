#!/usr/bin/env python3
"""Validate the SpringBoard bundle wrapper and scene observer."""

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

    require('caller("builder", "build", "H436");' in trace,
            "H436 trace marker missing")
    for marker in (
        'strncmp(process, "SpringBoard", 11)',
        "FBSWorkspace",
        "_sharedWorkspaceIfExists",
        'read_object(workspace, "scenes")',
        '"context", "layer", "layerManager"',
        "UIApplication",
        "connectedScenes",
        "CADisplay",
        "build=H481",
    ):
        require(marker in observer, f"H436 observer missing: {marker}")
    for forbidden in (
        "NSSetUncaughtExceptionHandler",
        "requestSceneCreation",
        "createScene",
        "setScene",
        "class_addMethod",
    ):
        require(forbidden not in observer,
                f"H436 observer is not read-only: {forbidden}")

    for marker in (
        "H436_SBWRAP",
        "build=H481",
        'setenv("DYLD_INSERT_LIBRARIES"',
        '"/System/Library/CoreServices/SpringBoard.app/SpringBoard.real"',
        "execv(kSpringBoard, arguments)",
        "return launch_springboard()",
        "DYLD_INSERT_LIBRARIES",
        "SpringBoardSceneObserver.dylib",
    ):
        require(marker in bootstrap, f"H436 wrapper missing: {marker}")
    for forbidden in (
        "bootstrap already claimed",
        "terminate_springboard",
        "find_process",
        "posix_spawn",
    ):
        require(forbidden not in bootstrap,
                f"H481 wrapper retained one-shot behavior: {forbidden}")
    print("H436 SpringBoard bundle wrapper gate: PASS")


if __name__ == "__main__":
    main()
