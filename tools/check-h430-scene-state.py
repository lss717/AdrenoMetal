#!/usr/bin/env python3
"""Validate H430's read-only SpringBoard scene-state gate."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "A540TracePlugin.mm"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    text = SOURCE.read_text(encoding="utf-8")
    require(any(f'caller("builder", "build", "{build}");' in text
                for build in ("H430", "H431", "H432", "H433", "H434", "H435", "H436")),
            "H430-H436 plugin marker missing")
    require("const double delays[] = {30.0, 120.0, 300.0, 480.0};" in text,
            "H430 did not add the post-BKS scene gate")
    require('if (process && !strcmp(process, "SpringBoard"))' in text,
            "H430 scene probe is not restricted to SpringBoard")
    require('probe_scenes("observer");' in text,
            "H430 does not invoke the existing FBSWorkspace scene probe")
    require("@selector(sharedWorkspace)" not in text,
            "H430 must use the existing bounded NSString selector path")
    print("H430 SpringBoard scene-state gate: PASS")


if __name__ == "__main__":
    main()
