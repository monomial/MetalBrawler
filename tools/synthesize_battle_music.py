#!/usr/bin/env python3
"""
Generate an original looping background track for MetalBrawler.

Mellow by design: warm sustained pads, a soft plucked arpeggio, a quiet round
bass an octave up from where the old track sat, and a feather-light hat pulse.
No kick, no gritty saws — it should sit far under the combat SFX and never
fatigue the player (or their parents).
"""

from __future__ import annotations

import math
import wave
from pathlib import Path

import numpy as np


SR = 44_100
BPM = 88
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
    """Warm sustained chord: sine fundamentals + quiet detuned partials,
    slow attack/release so chord changes melt into each other."""
    n = int(round(dur * SR))
    t = np.arange(n) / SR
    out = np.zeros(n)
    for f in freqs:
        vib = 1.0 + 0.0015 * np.sin(2.0 * math.pi * 0.7 * t)   # gentle drift
        out += np.sin(2.0 * math.pi * f * t * vib)
        out += 0.35 * np.sin(2.0 * math.pi * f * 2.003 * t)    # soft octave shimmer
    attack = np.minimum(t / 0.9, 1.0)
    release = np.minimum((dur - t) / 1.2, 1.0)
    return out * attack * release / (len(freqs) * 1.35)


def pluck(freq: float, dur: float = 0.5) -> np.ndarray:
    """Soft triangle pluck with a rounded top — kalimba-ish, no edge."""
    n = int(round(dur * SR))
    t = np.arange(n) / SR
    body = triangle(freq, dur) * 0.6 + sine(freq, dur) * 0.4
    env = np.minimum(t / 0.006, 1.0) * np.exp(-t / 0.16)
    return np.tanh(body * env * 1.2) * 0.8


def soft_hat(seed: int) -> np.ndarray:
    """Feather-light tick: short filtered noise, mixed very low."""
    dur = 0.05
    n = int(round(dur * SR))
    rng = np.random.default_rng(seed)
    noise = rng.uniform(-1, 1, n)
    noise = noise - np.concatenate([[0.0], noise[:-1]]) * 0.85   # crude highpass
    t = np.arange(n) / SR
    return noise * np.exp(-t / 0.014) * 0.5


def main() -> None:
    n = int(round(DURATION * SR))
    mono = np.zeros(n, dtype=np.float64)

    # Gentle progression, two bars per chord: Am7 — Fmaj7 — Cmaj7 — G6.
    # Voicings stay in the midrange so there's little low-end energy.
    chords = [
        [220.00, 261.63, 329.63, 392.00],   # A C E G
        [174.61, 220.00, 261.63, 329.63],   # F A C E
        [261.63, 329.63, 392.00, 493.88],   # C E G B
        [196.00, 246.94, 293.66, 329.63],   # G B D E
    ]
    bass_roots = [110.00, 87.31, 130.81, 98.00]  # A2 F2 C3 G2 — quiet, round

    chord_dur = 2 * BEATS_PER_BAR * BEAT
    for i in range(BARS // 2):
        base = i * chord_dur
        ch = chords[i % len(chords)]
        add(mono, base, pad_chord(ch, chord_dur + 0.8), 0.30)

        # One soft bass note per chord, sine only — present, not boomy.
        root = bass_roots[i % len(bass_roots)]
        t = np.arange(int(round(chord_dur * SR))) / SR
        bass = np.sin(2.0 * math.pi * root * t)
        bass_env = np.minimum(t / 0.05, 1.0) * np.exp(-t / 2.4)
        add(mono, base, bass * bass_env, 0.16)

    # Plucked arpeggio over the chord tones — the melodic surface of the track.
    # Sparse pattern, skips beats so it breathes; rests entirely in bars 7–8
    # of each half so the loop has shape.
    arp_pattern = [0, 2, 1, 3, 2, 0, 3, 1]
    for bar in range(BARS):
        if bar % 8 in (6, 7):
            continue
        base = bar * BEATS_PER_BAR * BEAT
        ch = chords[(bar // 2) % len(chords)]
        for step in range(8):
            if step % 2 == 1 and step != 3:
                continue
            tone = ch[arp_pattern[(bar * 8 + step) % len(arp_pattern)]]
            add(mono, base + step * BEAT * 0.5, pluck(tone * 2.0), 0.14)

    # Whisper-quiet hat on the off-beats keeps a pulse without drums.
    hat = soft_hat(11)
    for bar in range(BARS):
        base = bar * BEATS_PER_BAR * BEAT
        for beat in range(BEATS_PER_BAR):
            add(mono, base + (beat + 0.5) * BEAT, hat, 0.10)

    # Gentle fade edges so the loop point is silent-safe.
    edge = int(0.04 * SR)
    fade = np.ones(n)
    fade[:edge] = np.linspace(0, 1, edge)
    fade[-edge:] = np.linspace(1, 0, edge)
    mono *= fade

    # Soft limit and a conservative master level — the game mixes this at low
    # volume under SFX; headroom here beats loudness.
    mono = np.tanh(mono * 1.05)
    peak = np.max(np.abs(mono)) or 1.0
    mono = mono / peak * 0.55

    # Stereo: tiny delay on the right gives width; lows stay centered enough.
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
