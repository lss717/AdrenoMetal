#!/usr/bin/env python3
"""Validate the repaired H420 read-only main-scene observer."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "A540TracePlugin.mm"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    text = SOURCE.read_text(encoding="utf-8")
    require(any(f'caller("builder", "build", "{build}");' in text
                for build in ("H420", "H425", "H426", "H427", "H428", "H429", "H430", "H431")),
            "H420 plugin build marker missing")
    require("if (index == sizeof observed_contexts / sizeof observed_contexts[0]) {"
            in text, "context free-slot fix missing")
    require("if (index == free_index) index = free_index;" not in text,
            "H419 broken index comparison remains")
    require(any(schedule in text for schedule in (
                "const double delays[] = {30.0, 120.0, 300.0};",
                "const double delays[] = {30.0, 120.0, 300.0, 480.0};")),
            "fixed observation schedule changed")
    require("dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)" in text,
            "observer is not on the utility queue")

    start = text.index("probe_display_frame(const char *why)")
    start = text.rfind("static", 0, start)
    end = text.index('caller("disp", "observe-only"', start)
    active = text[start:end]
    for token in (
        '@selector(@"setContext:")',
        '@selector(@"presentSurface:withOptions:")',
        '@selector(@"addSublayer:")',
        '@selector(@"setContents:")',
        '@selector(@"nextDrawable")',
        "gpu_selftest()",
        '@selector(@"present")',
    ):
        require(token not in active, f"write-capable selector in active probe: {token}")

    for marker in (
        "observed_contexts[cursor].used",
        "observe_context_state(why, srv, cid",
        'caller("srv", "ctxchange"',
        '"contextIdHostingContextId:"',
        '"clientPortOfContextId:"',
        '"taskNamePortOfContextId:"',
        "dump_layer_tree(clay, 0, &visited, &nodes_with_contents);",
    ):
        require(marker in text, f"main-scene observation missing: {marker}")

    print("H420 repaired main-scene observation plugin gate: PASS")


if __name__ == "__main__":
    main()
