#!/usr/bin/env python3
"""
Generate an original looping battle track for MetalBrawler.

The output is intentionally simple and code-owned: heavy kick/snare, gritty bass,
short synth stabs, and a sparse lead. It is designed to sit under combat SFX
without masking hit impacts.
"""

from __future__ import annotations

import math
import wave
from pathlib import Path

import numpy as np


SR = 44_100
BPM = 128
BEAT = 60.0 / BPM
BARS = 16
BEATS_PER_BAR = 4
DURATION = BARS * BEATS_PER_BAR * BEAT

ROOT = 55.0  # A1
OUT = Path(__file__).resolve().parents[1] / "assets" / "audio" / "music_battle.wav"


def env_percussive(n: int, attack: float, decay: float) -> np.ndarray:
    t = np.arange(n) / SR
    return np.minimum(t / attack, 1.0) * np.exp(-t / decay)


def add(dst: np.ndarray, start_sec: float, clip: np.ndarray, gain: float = 1.0) -> None:
    start = int(round(start_sec * SR))
    end = min(start + len(clip), len(dst))
    if start >= len(dst) or end <= start:
        return
    dst[start:end] += clip[: end - start] * gain


def sine(freq: np.ndarray | float, dur: float, phase: float = 0.0) -> np.ndarray:
    n = int(round(dur * SR))
    if np.isscalar(freq):
        t = np.arange(n) / SR
        return np.sin(2.0 * math.pi * float(freq) * t + phase)
    phase_inc = 2.0 * math.pi * np.asarray(freq) / SR
    return np.sin(np.cumsum(phase_inc) + phase)


def lowpass(x: np.ndarray, alpha: float) -> np.ndarray:
    y = np.zeros_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += alpha * (v - acc)
        y[i] = acc
    return y


def highpass(x: np.ndarray, alpha: float) -> np.ndarray:
    low = lowpass(x, alpha)
    return x - low


def kick() -> np.ndarray:
    dur = 0.42
    n = int(round(dur * SR))
    t = np.arange(n) / SR
    freq = 138.0 * np.exp(-t * 16.0) + 38.0
    body = sine(freq, dur)
    click = highpass(np.random.default_rng(1).uniform(-1, 1, n), 0.08)
    return (body * env_percussive(n, 0.002, 0.12) * 1.35
            + click * env_percussive(n, 0.001, 0.012) * 0.12)


def snare(seed: int) -> np.ndarray:
    dur = 0.28
    n = int(round(dur * SR))
    rng = np.random.default_rng(seed)
    noise = highpass(rng.uniform(-1, 1, n), 0.04)
    tone = sine(185.0, dur) * env_percussive(n, 0.003, 0.08)
    return noise * env_percussive(n, 0.002, 0.055) * 0.46 + tone * 0.35


def hat(seed: int, open_hat: bool = False) -> np.ndarray:
    dur = 0.13 if not open_hat else 0.34
    n = int(round(dur * SR))
    rng = np.random.default_rng(seed)
    noise = highpass(rng.uniform(-1, 1, n), 0.025)
    decay = 0.025 if not open_hat else 0.11
    return noise * env_percussive(n, 0.001, decay) * (0.18 if not open_hat else 0.23)


def synth_note(freq: float, dur: float, gain: float = 1.0, grit: float = 0.25) -> np.ndarray:
    n = int(round(dur * SR))
    t = np.arange(n) / SR
    saw = 2.0 * ((freq * t) % 1.0) - 1.0
    square = np.sign(sine(freq * 0.5, dur))
    sub = sine(freq * 0.5, dur)
    raw = saw * (1.0 - grit) + square * grit + sub * 0.45
    shaped = np.tanh(raw * 1.8)
    env = np.minimum(t / 0.015, 1.0) * np.minimum((dur - t) / 0.05, 1.0)
    return lowpass(shaped * env, 0.08) * gain


def stab(freqs: list[float], dur: float) -> np.ndarray:
    n = int(round(dur * SR))
    t = np.arange(n) / SR
    out = np.zeros(n)
    for f in freqs:
        out += synth_note(f, dur, gain=0.26, grit=0.1)
    env = np.minimum(t / 0.01, 1.0) * np.exp(-t / 0.20)
    return highpass(out * env, 0.008)


def main() -> None:
    np.random.seed(7)
    n = int(round(DURATION * SR))
    mono = np.zeros(n, dtype=np.float64)

    k = kick()
    s1 = snare(2)
    s2 = snare(3)
    hc = hat(4)
    ho = hat(5, True)

    # Drums: steady brawler pulse, with a small turnaround in every fourth bar.
    for bar in range(BARS):
        base = bar * BEATS_PER_BAR * BEAT
        for beat in (0, 2):
            add(mono, base + beat * BEAT, k, 0.82)
        add(mono, base + 1 * BEAT, s1, 0.70)
        add(mono, base + 3 * BEAT, s2, 0.78)
        for eighth in range(8):
            add(mono, base + eighth * BEAT * 0.5, hc, 0.70 if eighth % 2 == 0 else 0.48)
        if bar % 4 == 3:
            add(mono, base + 3.5 * BEAT, ho, 0.55)
            add(mono, base + 3.75 * BEAT, s2, 0.35)

    # Bass riff in A minor. Short notes leave room for hits and haptics.
    semis = [0, 0, 3, 0, 5, 0, 7, 3, 0, 0, 3, 5, 7, 5, 3, -2]
    for bar in range(BARS):
        base = bar * BEATS_PER_BAR * BEAT
        for step, semi in enumerate(semis):
            start = base + step * BEAT * 0.25
            note = ROOT * (2.0 ** (semi / 12.0))
            dur = BEAT * (0.22 if step % 4 else 0.34)
            add(mono, start, synth_note(note, dur, gain=0.44, grit=0.38), 1.0)

    # Dark chord stabs, changing every two bars.
    chords = [
        [220.0, 261.63, 329.63],  # A minor-ish
        [196.0, 246.94, 293.66],  # G/D color
        [174.61, 220.0, 261.63],  # F/A color
        [196.0, 246.94, 329.63],
    ]
    for bar in range(BARS):
        base = bar * BEATS_PER_BAR * BEAT
        ch = chords[(bar // 2) % len(chords)]
        add(mono, base + 0.00 * BEAT, stab(ch, 0.42), 0.42)
        add(mono, base + 2.50 * BEAT, stab(ch, 0.32), 0.28)

    # Sparse lead appears in the back half so the loop has a small lift.
    lead_steps = [(0, 12), (1.5, 10), (2.0, 7), (2.75, 10), (3.25, 12)]
    for bar in range(8, BARS):
        base = bar * BEATS_PER_BAR * BEAT
        for beat_offset, semi in lead_steps:
            freq = 220.0 * (2.0 ** (semi / 12.0))
            clip = synth_note(freq, 0.22, gain=0.22, grit=0.05)
            add(mono, base + beat_offset * BEAT, clip, 1.0)

    # Tiny ambience bed to hide loop boundaries without being washy.
    t = np.arange(n) / SR
    bed = (sine(55.0, DURATION) + sine(82.41, DURATION) * 0.6) * 0.03
    mono += bed * (0.85 + 0.15 * np.sin(2 * math.pi * t / DURATION))

    # Gentle fade edges and limiter. No reverb tail crossing the loop boundary.
    edge = int(0.03 * SR)
    fade = np.ones(n)
    fade[:edge] = np.linspace(0, 1, edge)
    fade[-edge:] = np.linspace(1, 0, edge)
    mono *= fade
    mono = np.tanh(mono * 1.15)
    peak = np.max(np.abs(mono)) or 1.0
    mono = mono / peak * 0.82

    # Stereo: keep low end centered, spread mids/highs subtly.
    delay = int(0.009 * SR)
    right = np.roll(mono, delay) * 0.92
    right[:delay] *= np.linspace(0, 1, delay)
    left = mono
    stereo = np.column_stack([left, right])

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
