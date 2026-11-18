#!/usr/bin/env python3
"""Validate the H419 read-only main-scene observation plugin."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "A540TracePlugin.mm"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    text = SOURCE.read_text(encoding="utf-8")
    require('caller("builder", "build", "H419");' in text,
            "H419 plugin build marker missing")
    require("const double delays[] = {30.0, 120.0, 300.0};" in text,
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

    retired_start = text.index("#if 0", end)
    retired_end = text.index("#endif", retired_start)
    retired = text[retired_start:retired_end]
    require("id layer =" in retired and
            "presentSurface:withOptions:" in retired,
            "retired renderer history missing")

    require("observer_u32_arg" in text, "typed context-id argument helper missing")
    require('"contextIdHostingContextId:"' in text,
            "hosting-context observation missing")
    require('"clientPortOfContextId:"' in text,
            "client-port observation missing")
    require('"taskNamePortOfContextId:"' in text,
            "task-name-port observation missing")
    require('caller("srv", "ctxchange"' in text,
            "context change record missing")
    require("state=%s ctx=0x%x display=0x%x mask=0x%x host=0x%x "
            "client=0x%x task=0x%x root=0x%llx subs=%u nodes=%u contents=%u"
            in text, "context change fields incomplete")
    require("dump_layer_tree(clay, 0, &visited, &nodes_with_contents);" in text,
            "layer content accounting is not wired to the context sample")
    require("if (contents && nodes_with_contents) (*nodes_with_contents)++;" in text,
            "contents-bearing layer count missing")

    schedule_start = text.index("static void schedule_display_probes(void)")
    schedule_end = text.index("/** H236hi:", schedule_start)
    schedule = text[schedule_start:schedule_end]
    require("observer-schedule-owned-by-constructor" in schedule,
            "constructor schedule ownership marker missing")
    for token in ("probe_first_frame(", "probe_scenes(", "probe_drawable(",
                  "fix_persona(", "gpu_selftest()"):
        require(token not in schedule, f"unexpected scheduled probe: {token}")

    print("H419 main-scene observation plugin gate: PASS")


if __name__ == "__main__":
    main()
