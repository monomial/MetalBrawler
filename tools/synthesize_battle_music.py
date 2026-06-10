#!/usr/bin/env python3
"""
Generate an original looping background track for MetalBrawler.

Mid-energy by design: warm pads and a legato synth melody over a light
drum pulse and a round, quiet bass. Two deliberate constraints:
  - little low-end energy (the old track was all kick and gritty bass), and
  - NO short high plucked notes — sparse decaying "pings" on an ambient bed
    read as stray sound effects, not music. Melody notes are sustained.
"""

from __future__ import annotations

import math
import wave
from pathlib import Path

import numpy as np


SR = 44_100
BPM = 104
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


def sine(freq: float, dur: float, phase: float = 0.0) -> np.ndarray:
    t = np.arange(int(round(dur * SR))) / SR
    return np.sin(2.0 * math.pi * freq * t + phase)


def triangle(freq: float, dur: float) -> np.ndarray:
    t = np.arange(int(round(dur * SR))) / SR
    return 2.0 * np.abs(2.0 * ((freq * t) % 1.0) - 1.0) - 1.0


def pad_chord(freqs: list[float], dur: float) -> np.ndarray:
    """Warm sustained chord — sine fundamentals plus a soft octave shimmer."""
    n = int(round(dur * SR))
    t = np.arange(n) / SR
    out = np.zeros(n)
    for f in freqs:
        vib = 1.0 + 0.0015 * np.sin(2.0 * math.pi * 0.7 * t)
        out += np.sin(2.0 * math.pi * f * t * vib)
        out += 0.30 * np.sin(2.0 * math.pi * f * 2.003 * t)
    attack = np.minimum(t / 0.5, 1.0)
    release = np.minimum((dur - t) / 0.8, 1.0)
    return out * attack * release / (len(freqs) * 1.35)


def lead_note(freq: float, dur: float) -> np.ndarray:
    """Legato melody voice: triangle+sine blend with slow attack and a held
    body — deliberately NOT a pluck, so it can't read as a stray 'ping'."""
    n = int(round(dur * SR))
    t = np.arange(n) / SR
    vib = 1.0 + 0.004 * np.sin(2.0 * math.pi * 5.0 * t) * np.minimum(t / 0.4, 1.0)
    body = (triangle(freq, dur) * 0.45 + np.sin(2.0 * math.pi * freq * t * vib) * 0.55)
    attack = np.minimum(t / 0.10, 1.0)
    release = np.minimum((dur - t) / 0.18, 1.0)
    return np.tanh(body * 1.1) * attack * release


def soft_kick() -> np.ndarray:
    """Round, tight thump — felt as pulse, mixed low so it never booms."""
    dur = 0.16
    n = int(round(dur * SR))
    t = np.arange(n) / SR
    freq = 150.0 * np.exp(-t * 22.0) + 55.0
    phase = np.cumsum(2.0 * math.pi * freq / SR)
    return np.sin(phase) * np.minimum(t / 0.003, 1.0) * np.exp(-t / 0.05)


def soft_snare(seed: int) -> np.ndarray:
    """Brushy tap, mostly midrange noise — no crack."""
    dur = 0.14
    n = int(round(dur * SR))
    rng = np.random.default_rng(seed)
    noise = rng.uniform(-1, 1, n)
    noise = noise - np.concatenate([[0.0], noise[:-1]]) * 0.6
    t = np.arange(n) / SR
    tone = np.sin(2.0 * math.pi * 190.0 * t) * np.exp(-t / 0.03) * 0.4
    return (noise * np.exp(-t / 0.035) * 0.5 + tone) * np.minimum(t / 0.002, 1.0)


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

    # Two bars per chord: Am7 — Fmaj7 — Cmaj7 — G6, midrange voicings.
    chords = [
        [220.00, 261.63, 329.63, 392.00],   # A C E G
        [174.61, 220.00, 261.63, 329.63],   # F A C E
        [261.63, 329.63, 392.00, 493.88],   # C E G B
        [196.00, 246.94, 293.66, 329.63],   # G B D E
    ]
    bass_roots = [110.00, 87.31, 130.81, 98.00]  # A2 F2 C3 G2

    chord_dur = 2 * BEATS_PER_BAR * BEAT
    for i in range(BARS // 2):
        base = i * chord_dur
        add(mono, base, pad_chord(chords[i % len(chords)], chord_dur + 0.5), 0.26)

    # Bass: quiet sine, but rhythmic now — root on each beat, octave lift on
    # beat 3. Movement without boom.
    for bar in range(BARS):
        base = bar * BEATS_PER_BAR * BEAT
        root = bass_roots[(bar // 2) % len(bass_roots)]
        for beat in range(BEATS_PER_BAR):
            f = root * (2.0 if beat == 2 else 1.0)
            note_dur = BEAT * 0.85
            t = np.arange(int(round(note_dur * SR))) / SR
            note = np.sin(2.0 * math.pi * f * t)
            env = np.minimum(t / 0.02, 1.0) * np.minimum((note_dur - t) / 0.10, 1.0)
            add(mono, base + beat * BEAT, note * env, 0.13)

    # Drums: gentle pulse. Kick 1 & 3, brush snare 2 & 4, off-beat hats.
    k, s, h = soft_kick(), soft_snare(9), soft_hat(11)
    for bar in range(BARS):
        base = bar * BEATS_PER_BAR * BEAT
        add(mono, base + 0 * BEAT, k, 0.34)
        add(mono, base + 2 * BEAT, k, 0.28)
        add(mono, base + 1 * BEAT, s, 0.22)
        add(mono, base + 3 * BEAT, s, 0.26)
        for beat in range(BEATS_PER_BAR):
            add(mono, base + (beat + 0.5) * BEAT, h, 0.12)

    # Legato melody: phrases of held notes over the chord tones, resting in
    # bars 7–8 of each half. Sustained voice — energy without ping.
    # (offset in beats, scale degree above A3, length in beats)
    phrase = [(0.0, 0, 1.5), (1.5, 3, 1.0), (2.5, 5, 1.5), (4.0, 7, 2.0),
              (6.0, 5, 1.0), (7.0, 3, 2.5), (10.0, 7, 1.5), (11.5, 8, 1.0),
              (12.5, 7, 1.5), (14.0, 5, 3.0), (17.5, 3, 1.5), (19.0, 0, 3.0)]
    semitone = 2.0 ** (1.0 / 12.0)
    for half in range(2):
        half_base = half * 8 * BEATS_PER_BAR * BEAT
        for beat_off, semi, length in phrase:
            if beat_off >= 6 * BEATS_PER_BAR:   # rest bars 7–8
                continue
            freq = 220.0 * (semitone ** semi) * (2.0 if half == 1 else 1.0) / 2.0 * 2.0
            add(mono, half_base + beat_off * BEAT,
                lead_note(freq, length * BEAT), 0.16 if half == 0 else 0.13)

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
