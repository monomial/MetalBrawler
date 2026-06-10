#!/usr/bin/env python3
"""
Generate an original looping background track for MetalBrawler.

Adventure flavor: string-ish pads (additive saw, chorused), a horn-ish lead
playing a heroic dotted-rhythm melody, a root–fifth galloping bass, and a
driving but light drum pulse. Constraints that earlier passes taught us:
  - little low-end energy (heavy kick/bass fatigues and masks SFX),
  - no short high plucked notes (sparse decaying "pings" over a bed read as
    stray sound effects — sustained voices only),
  - pure sine timbres sound "outer-spacy" — use harmonic-rich voices instead.
"""

from __future__ import annotations

import math
import wave
from pathlib import Path

import numpy as np


SR = 44_100
BPM = 112
BEAT = 60.0 / BPM
BARS = 16
BEATS_PER_BAR = 4
DURATION = BARS * BEATS_PER_BAR * BEAT

OUT = Path(__file__).resolve().parents[1] / "assets" / "audio" / "music_battle.wav"


def add(dst: np.ndarray, start_sec: float, clip: np.ndarray, gain: float = 1.0) -> None:
    start = int(round(start_sec * SR))
    end = min(start + len(clip), len(dst))
    if start >= len(dst) or end <= start:
        return
    dst[start:end] += clip[: end - start] * gain


def saw_voice(freq: float, dur: float, harmonics: int = 6, detune: float = 0.002) -> np.ndarray:
    """Band-limited saw via additive synthesis, two detuned layers (chorus).
    Reads as 'strings' in a pad, 'brass' in a lead — warm, not spacey."""
    n = int(round(dur * SR))
    t = np.arange(n) / SR
    out = np.zeros(n)
    for d in (1.0 - detune, 1.0 + detune):
        for h in range(1, harmonics + 1):
            out += np.sin(2.0 * math.pi * freq * d * h * t) / h
    return out / (2.0 * 1.8)


def pad_chord(freqs: list[float], dur: float) -> np.ndarray:
    """String-section pad: chorused saws per note, slow swell."""
    n = int(round(dur * SR))
    t = np.arange(n) / SR
    out = np.zeros(n)
    for f in freqs:
        out += saw_voice(f, dur, harmonics=5)
    attack = np.minimum(t / 0.35, 1.0)
    release = np.minimum((dur - t) / 0.5, 1.0)
    return out * attack * release / len(freqs)


def lead_note(freq: float, dur: float) -> np.ndarray:
    """Horn-ish lead: saw + reinforced fundamental, quick-but-soft attack,
    held body with vibrato blooming late. Sustained — never a ping."""
    n = int(round(dur * SR))
    t = np.arange(n) / SR
    vib = 1.0 + 0.005 * np.sin(2.0 * math.pi * 5.5 * t) * np.minimum(t / 0.35, 1.0)
    body = saw_voice(freq, dur, harmonics=7) * 0.7
    body += np.sin(2.0 * math.pi * freq * vib * t) * 0.5
    attack = np.minimum(t / 0.045, 1.0)
    release = np.minimum((dur - t) / 0.12, 1.0)
    return np.tanh(body * 1.2) * attack * release


def soft_kick() -> np.ndarray:
    dur = 0.15
    n = int(round(dur * SR))
    t = np.arange(n) / SR
    freq = 160.0 * np.exp(-t * 24.0) + 58.0
    phase = np.cumsum(2.0 * math.pi * freq / SR)
    return np.sin(phase) * np.minimum(t / 0.003, 1.0) * np.exp(-t / 0.045)


def snare(seed: int) -> np.ndarray:
    dur = 0.16
    n = int(round(dur * SR))
    rng = np.random.default_rng(seed)
    noise = rng.uniform(-1, 1, n)
    noise = noise - np.concatenate([[0.0], noise[:-1]]) * 0.55
    t = np.arange(n) / SR
    tone = np.sin(2.0 * math.pi * 200.0 * t) * np.exp(-t / 0.035) * 0.45
    return (noise * np.exp(-t / 0.04) * 0.55 + tone) * np.minimum(t / 0.002, 1.0)


def soft_hat(seed: int) -> np.ndarray:
    dur = 0.05
    n = int(round(dur * SR))
    rng = np.random.default_rng(seed)
    noise = rng.uniform(-1, 1, n)
    noise = noise - np.concatenate([[0.0], noise[:-1]]) * 0.85
    t = np.arange(n) / SR
    return noise * np.exp(-t / 0.014) * 0.5


def main() -> None:
    n = int(round(DURATION * SR))
    mono = np.zeros(n, dtype=np.float64)

    # One bar per chord: Am — F — C — G, the adventure staple. Midrange voicings.
    chords = [
        [220.00, 261.63, 329.63],   # A C E
        [174.61, 220.00, 261.63],   # F A C
        [196.00, 261.63, 329.63],   # C/G voicing: G C E
        [196.00, 246.94, 293.66],   # G B D
    ]
    roots = [110.00, 87.31, 130.81, 98.00]    # A2 F2 C3 G2
    fifths = [164.81, 130.81, 196.00, 146.83]  # E3 C3 G3 D3

    bar_dur = BEATS_PER_BAR * BEAT
    for bar in range(BARS):
        base = bar * bar_dur
        add(mono, base, pad_chord(chords[bar % 4], bar_dur + 0.3), 0.22)

    # Galloping root–fifth bass: eighth notes R R 5 R R 5 R 5 — adventure drive.
    pattern = [0, 0, 1, 0, 0, 1, 0, 1]
    for bar in range(BARS):
        base = bar * bar_dur
        r, f5 = roots[bar % 4], fifths[bar % 4]
        for step, which in enumerate(pattern):
            freq = f5 if which else r
            note_dur = BEAT * 0.42
            t = np.arange(int(round(note_dur * SR))) / SR
            note = np.sin(2.0 * math.pi * freq * t) + 0.3 * np.sin(2.0 * math.pi * freq * 2 * t)
            env = np.minimum(t / 0.012, 1.0) * np.minimum((note_dur - t) / 0.06, 1.0)
            add(mono, base + step * BEAT * 0.5, note * env, 0.125)

    # Drums: kick 1 & 3, snare 2 & 4 with an eighth pickup before 1, hats.
    k, s, h = soft_kick(), snare(9), soft_hat(11)
    for bar in range(BARS):
        base = bar * bar_dur
        add(mono, base + 0 * BEAT, k, 0.34)
        add(mono, base + 2 * BEAT, k, 0.30)
        add(mono, base + 1 * BEAT, s, 0.26)
        add(mono, base + 3 * BEAT, s, 0.30)
        add(mono, base + 3.5 * BEAT, s, 0.12)          # pickup into the next bar
        for eighth in range(8):
            add(mono, base + eighth * BEAT * 0.5, h, 0.13 if eighth % 2 else 0.09)

    # Heroic lead melody over two 8-bar halves; rests in bars 7–8 of each half.
    # (offset in beats from half start, semitones above A3, length in beats)
    phrase = [
        (0.0, 0, 0.75), (0.75, 3, 0.25), (1.0, 5, 1.0), (2.0, 7, 1.5), (3.5, 5, 0.5),
        (4.0, 8, 2.0), (6.0, 7, 1.0), (7.0, 5, 1.0),
        (8.0, 3, 0.75), (8.75, 5, 0.25), (9.0, 7, 1.0), (10.0, 10, 1.5), (11.5, 8, 0.5),
        (12.0, 7, 1.5), (13.5, 5, 0.5), (14.0, 3, 2.0),
        (16.0, 0, 0.75), (16.75, 3, 0.25), (17.0, 5, 1.0), (18.0, 7, 1.5), (19.5, 8, 0.5),
        (20.0, 12, 2.5), (22.5, 10, 0.75), (23.25, 8, 0.75),
    ]
    semitone = 2.0 ** (1.0 / 12.0)
    for half in range(2):
        half_base = half * 8 * bar_dur
        for beat_off, semi, length in phrase:
            add(mono, half_base + beat_off * BEAT,
                lead_note(220.0 * (semitone ** semi), length * BEAT),
                0.135 if half == 0 else 0.115)

    # Gentle fade edges so the loop point is silent-safe.
    edge = int(0.04 * SR)
    fade = np.ones(n)
    fade[:edge] = np.linspace(0, 1, edge)
    fade[-edge:] = np.linspace(1, 0, edge)
    mono *= fade

    mono = np.tanh(mono * 1.05)
    peak = np.max(np.abs(mono)) or 1.0
    mono = mono / peak * 0.60

    delay = int(0.011 * SR)
    right = np.roll(mono, delay) * 0.94
    right[:delay] *= np.linspace(0, 1, delay)
    stereo = np.column_stack([mono, right])

    OUT.parent.mkdir(parents=True, exist_ok=True)
    pcm = np.clip(stereo * 32767, -32768, 32767).astype("<i2")
    with wave.open(str(OUT), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())

    print(f"wrote {OUT} ({DURATION:.2f}s, {BPM} BPM)")


if __name__ == "__main__":
    main()
