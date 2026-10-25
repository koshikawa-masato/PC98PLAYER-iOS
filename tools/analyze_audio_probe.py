#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compare ReplayKit app-output waveforms with the generated PCM reference.
Requires numpy, scipy, soundfile and matplotlib. No game files are uploaded.
"""
import argparse
import json
from pathlib import Path
import numpy as np
import soundfile as sf
from scipy.signal import correlate
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt


def load(folder):
    report = json.loads((folder / 'report.json').read_text())
    if report['errors']:
        raise RuntimeError(report['errors'])
    output, rate = sf.read(folder / 'output.caf', always_2d=True)
    reference, reference_rate = sf.read(folder / 'reference.caf', always_2d=True)
    if rate != reference_rate:
        raise ValueError('Resample to a common rate before comparing source positions')
    start = next((e['hostTime'] for e in report['events'] if e['name'] == 'measurement-start'), report['events'][0]['hostTime'])
    events = [e for e in report['events'] if e['hostTime'] >= start]
    return report, output, reference, rate, events


def position(report, rate, time):
    chunk = min(report['chunks'], key=lambda c: abs(c['pts'] + c['frames'] / rate / 2 - time))
    return chunk['offset'] + round((time - chunk['pts']) * rate)


def window(report, output, reference, rate, event):
    center = position(report, rate, event['hostTime'])
    begin, end = max(0, center - rate // 20), min(len(output), center + round(rate * .4))
    samples = output[max(0, center):end]
    active = np.max(np.abs(samples), axis=1) > 1e-5
    nonzero = np.flatnonzero(active)
    edges = np.diff(np.r_[False, ~active, False].astype(int))
    gaps = []
    if len(nonzero):
        gaps = [{'startMs': round(a / rate * 1000, 2), 'durationMs': round((b - a) / rate * 1000, 2)}
                for a, b in zip(np.flatnonzero(edges == 1), np.flatnonzero(edges == -1))
                if a > nonzero[0] and b - a >= rate * .002]
    result = {'name': event['name'], 'firstOutputMs': round(nonzero[0] / rate * 1000, 2) if len(nonzero) else None,
              'zeroGapsAfterStart': gaps}
    # Match a stable, post-fade 1024-frame segment to the original PCM. This is
    # a waveform correlation, not a claim that every zero run is an underrun.
    if event['name'] == 'resume' and len(nonzero):
        first = center + nonzero[0]
        q0, length = first + 2048, 1024
        a = max(0, event['referenceFrames'] - rate // 3)
        b = min(len(reference), event['referenceFrames'] + rate // 3 + length)
        q, r = output[q0:q0 + length], reference[a:b]
        if len(q) == length and len(r) >= length:
            corr = sum(correlate(r[:, ch], q[:, ch], mode='valid', method='fft') for ch in range(2))
            norm = np.sqrt(np.convolve(np.sum(r * r, axis=1), np.ones(length), mode='valid') * np.sum(q * q))
            sim = np.divide(corr, norm, out=np.zeros_like(corr), where=norm > 1e-12)
            best = int(np.argmax(sim))
            result.update(correlation=float(sim[best]), sourcePositionReliable=bool(sim[best] >= .99))
            if sim[best] >= .99:
                result.update(inferredFirstSourceFrame=int(a + best - 2048), pauseSourceFrame=event['referenceFrames'])
    return (np.arange(begin, end) - center) / rate * 1000, output[begin:end, 0], result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--rotation', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fig, axes = plt.subplots(4, 2, figsize=(14, 9), constrained_layout=True)
    results = {}
    for col, (label, directory) in enumerate([('before', args.before), ('after', args.after)]):
        report, output, reference, rate, events = load(directory)
        resumes = [e for e in events if e['name'] == 'resume']
        chosen = resumes[1:3] + [next(e for e in events if e['name'] == n) for n in ['fullscreen-enter', 'fullscreen-exit']]
        rows = []
        for row, event in enumerate(chosen):
            t, y, result = window(report, output, reference, rate, event)
            ax = axes[row, col]
            ax.plot(t, y, lw=.5);ax.axvline(0, color='red', ls='--', lw=1)
            title = f'resume {row + 2}' if row < 2 else event['name']
            ax.set(title=f'{label}: {title}', xlabel='ms from command', ylabel='Amplitude', ylim=(-.6, .6))
            rows.append(result)
        sf.write(directory / 'output.wav', output, rate, subtype='PCM_16')
        results[label] = rows
    fig.savefig(args.output / 'audio-pause-comparison.png', dpi=150)
    if args.rotation:
        report, output, reference, rate, events = load(args.rotation)
        rotations = [e for e in events if e['name'] == 'rotation']
        if rotations:
            fig, axes = plt.subplots(len(rotations), 1, figsize=(12, 2.6 * len(rotations)), constrained_layout=True, squeeze=False)
            rows = []
            for i, event in enumerate(rotations):
                t, y, result = window(report, output, reference, rate, event)
                ax = axes[i, 0];ax.plot(t, y, lw=.5);ax.axvline(0, color='red', ls='--', lw=1)
                ax.set(title=f'iPhone rotation {i + 1}', xlabel='ms from rotation', ylabel='Amplitude', ylim=(-.6, .6));rows.append(result)
            fig.savefig(args.output / 'audio-rotation-waveform.png', dpi=150)
            results['rotation'] = rows
        sf.write(args.rotation / 'output.wav', output, rate, subtype='PCM_16')
    (args.output / 'audio-waveform-analysis.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
