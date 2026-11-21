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
        "build=H499",
        "if (sample == 0) inventory_springboard_classes();",
        "probe_nonblocking_shared_instances();",
        'snapshot_windows("scene", delegate, sample);',
        'snapshot_windows("application", application, sample);',
        "snapshot_window_views(",
        "snapshot_view_tree(",
        "snapshot_layer_tree(",
        'read_object(rootViewController, "view")',
        'read_object(view, "subviews")',
        'read_object(layer, "sublayers")',
        'read_integer(layer, "contextId"',
        'hierarchy=host',
        'hierarchy=context',
        'hierarchy=contextfields',
        'first_host_context((uint32_t) contextId)',
        'read_object(context, "layer")',
        'read_object(context, "renderContext")',
        "depth > 12",
        "cycle=1",
        "probe_context_server((uint32_t) contextId",
        "contextIdHostingContextId:",
        "clientPortOfContextId:",
        "taskNamePortOfContextId:",
        "pid_for_task(",
        'call_checked_class_selector("CAContext", "allContexts")',
        '"sharedInstanceIfExists"',
        "class_copyMethodList(object_getClass(cls), &methodCount)",
        'line("sbinventory begin")',
        '"SBMainWorkspace"',
        '"SBMainDisplaySceneManager"',
        '"SBSceneManagerCoordinator"',
        '"SBWindowSceneManager"',
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
        "build=H483",
        'setenv("DYLD_INSERT_LIBRARIES"',
        'getenv("DYLD_INSERT_LIBRARIES")',
        'getenv("DYLD_FORCE_FLAT_NAMESPACE")',
        "dlopen(kObserver, RTLD_NOW | RTLD_LOCAL)",
        'line("wrapper dlopen observer ok")',
        'line("wrapper dlopen observer failed error=%s"',
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
                f"H483 wrapper retained one-shot behavior: {forbidden}")
    print("H499 SpringBoard observer gate: PASS")


if __name__ == "__main__":
    main()
