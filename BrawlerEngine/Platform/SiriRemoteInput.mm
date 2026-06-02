#include "SiriRemoteInput.h"
#include <math.h>

static constexpr float kDeadZone = 0.10f; // ignore input below this magnitude
static constexpr float kMaxRaw   = 0.80f; // raw value that maps to full speed

InputState SiriRemote_processSwipeDelta(float rawX, float rawY) {
    float mag = sqrtf(rawX * rawX + rawY * rawY);

    if (mag < kDeadZone) return {0, 0, false, false, false};

    // Remap dead-zone edge → 0, kMaxRaw → 1, clamp beyond.
    float remapped = (mag - kDeadZone) / (kMaxRaw - kDeadZone);
    if (remapped > 1.0f) remapped = 1.0f;

    // Acceleration curve: square gives finer control at low speeds.
    float curved = remapped * remapped;

    // Scale direction by curved magnitude.
    float nx = (rawX / mag) * curved;
    float ny = (rawY / mag) * curved;

    // Clamp to unit circle (diagonal should not be faster than cardinal).
    float len = sqrtf(nx * nx + ny * ny);
    if (len > 1.0f) { nx /= len; ny /= len; }

    return { nx, ny, false, false, false };
}
