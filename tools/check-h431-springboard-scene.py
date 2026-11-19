#!/usr/bin/env python3
"""Validate H431's SpringBoard scene observer and one-shot bootstrap."""

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

    require('caller("builder", "build", "H431");' in trace,
            "H431 trace marker missing")
    for marker in (
        'strcmp(process, "SpringBoard")',
        "FBSWorkspace",
        "_sharedWorkspaceIfExists",
        'read_object(workspace, "scenes")',
        '"context", "layer", "layerManager"',
        "UIApplication",
        "connectedScenes",
        "CADisplay",
        "build=H431",
    ):
        require(marker in observer, f"H431 observer missing: {marker}")
    for forbidden in (
        "NSSetUncaughtExceptionHandler",
        "requestSceneCreation",
        "createScene",
        "setScene",
        "class_addMethod",
    ):
        require(forbidden not in observer,
                f"H431 observer is not read-only: {forbidden}")

    for marker in (
        "h431-scenebootstrap.done",
        "launchctl",
        "DYLD_INSERT_LIBRARIES",
        "SpringBoardSceneObserver.dylib",
        "kill(pid, SIGTERM)",
        "SpringBoard restarted",
    ):
        require(marker in bootstrap, f"H431 bootstrap missing: {marker}")
    require("O_CREAT | O_EXCL" in bootstrap,
            "H431 bootstrap must be one-shot")
    print("H431 SpringBoard scene injection gate: PASS")


if __name__ == "__main__":
    main()
