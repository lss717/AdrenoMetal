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

    require('caller("builder", "build", "H519");' in trace,
            "H519 trace marker missing")
    for marker in (
        "state->owner_status = pid_for_task(",
        'proc_name(state->owner_pid, state->owner_name',
        'owner=%d/0x%x/%.20s',
        'install_server_ca_event_hooks();',
        'caller("srv", "event_context_layer", detail);',
        'caller("srv", "event_context_slot", detail);',
        'caller("srv", "event_context_commit_wait", detail);',
        'caller("srv", "event_layer_commit", detail);',
        'caller("srv", "event_display_surface", detail);',
    ):
        require(marker in trace, f"H506 server event marker missing: {marker}")
    for marker in (
        'strncmp(process, "SpringBoard", 11)',
        "FBSWorkspace",
        "_sharedWorkspaceIfExists",
        'read_object(workspace, "scenes")',
        '"context", "layer", "layerManager"',
        "UIApplication",
        "connectedScenes",
        "CADisplay",
        "build=H519",
        "if (sample == 0) {",
        "inventory_springboard_classes();",
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
        "snapshot_dictionary(\"contextoptions\", options);",
        '"inheritsSecurity"',
        '"preservesFlip"',
        '"applicationState"',
        '"activationState"',
        'install_ca_event_hooks();',
        'event=ca_host_context_bind',
        'event=ca_host_visible',
        'event=ca_context_remote_create',
        'event=ca_context_set_layer',
        'event=ca_layer_set_contents',
        '"ca_layer_commit"',
        'event=ca_transaction_flush',
        '"uiwindow_set_hidden"',
        '"uiwindow_make_key_visible"',
        '"uiwindow_scene_visible"',
        'event=root_visibility_state',
        'event=root_visibility_window',
        'event=h513_constructor_enter',
        'event=h513_constructor_skip',
        'event=h513_constructor_accepted',
        'event=h513_snapshot_enter',
        'event=h513_dlopen',
        'event=h513_snapshot_exit',
        'event=h515_shared_application_enter',
        'event=h515_shared_application_return',
        'event=h515_application_notification',
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
        "probe_context_server(",
        "dispatch_after(",
        "pthread_create(",
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
    print("H519 SpringBoard observer gate: PASS")


if __name__ == "__main__":
    main()
