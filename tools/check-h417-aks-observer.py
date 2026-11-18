#!/usr/bin/env python3
"""Static gate for the H417 AKS + typed CoreAnimation observer."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'A540TracePlugin.mm'


def main():
    text = SOURCE.read_text(encoding='utf-8')
    assert 'caller("builder", "build", "H417");' in text
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

    assert 'method_getTypeEncoding(method)' in text
    assert 'observer_u32(entry, "pointScale"' in text
    assert '((double (*)(id, SEL)) objc_msgSend)(entry, pointScaleSel)' not in text
    assert '@selector(pixelWidth)' not in text
    assert '@selector(pixelHeight)' not in text
    assert 'pixelWidth=%s pixelHeight=%s' in text
    assert 'UNSUPPORTED' in text
    assert 'dump_layer_tree(clay, 0, &visited);' in text
    assert 'depth > 3' in text and '*visited >= 64' in text

    print('H417 AKS + typed CoreAnimation observer gate: PASS')


if __name__ == '__main__':
    main()
