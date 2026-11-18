#!/usr/bin/env python3
"""Static gate for the H416 observation-only CoreAnimation probe."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'A540TracePlugin.mm'


def main():
    text = SOURCE.read_text(encoding='utf-8')
    assert 'caller("builder", "build", "H416");' in text
    assert 'const double delays[] = {30.0, 120.0, 300.0};' in text

    start = text.index('probe_display_frame(const char *why)')
    start = text.rfind('static', 0, start)
    end = text.index('caller("disp", "observe-only"', start)
    active = text[start:end]
    forbidden = (
        '@selector(@"setContext:")',
        '@selector(@"presentSurface:withOptions:")',
        '@selector(@"addSublayer:")',
        '@selector(@"setContents:")',
        '@selector(@"nextDrawable")',
        'clientPortOfContextId:',
        'gpu_selftest()',
    )
    for token in forbidden:
        assert token not in active, token

    retired_start = text.index('#if 0', end)
    retired_end = text.index('#endif', retired_start)
    retired = text[retired_start:retired_end]
    assert 'id layer =' in retired
    assert 'presentSurface:withOptions:' in retired

    schedule_start = text.index('static void schedule_display_probes(void)')
    schedule_end = text.index('/** H236hi:', schedule_start)
    schedule = text[schedule_start:schedule_end]
    assert 'observer-schedule-owned-by-constructor' in schedule
    for token in ('probe_first_frame(', 'probe_scenes(', 'probe_drawable(',
                  'fix_persona(', 'gpu_selftest()'):
        assert token not in schedule, token

    print('H416 CoreAnimation observer write and schedule gate: PASS')


if __name__ == '__main__':
    main()
