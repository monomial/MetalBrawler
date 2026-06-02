#include "ScreenShakeSystem.h"
#include "Simulation/World.h"
#include <math.h>
#include <stdlib.h>

// Shake state is global — one camera, one shake.
static float       s_magnitude = 0.f;
static simd_float2 s_offset    = {0, 0};

static constexpr float kDecayRate = 12.0f; // magnitude halves in ~0.06s at this rate

void ScreenShakeSystem_trigger(World& /*world*/, float magnitude) {
    if (magnitude > s_magnitude) s_magnitude = magnitude;
}

void ScreenShakeSystem_update(World& /*world*/, float physicalDt) {
    if (s_magnitude < 0.5f) {
        s_magnitude = 0.f;
        s_offset    = {0, 0};
        return;
    }

    // Exponential decay.
    s_magnitude *= expf(-kDecayRate * physicalDt);

    // Random direction each tick → jitter effect.
    float angle = ((float)rand() / (float)RAND_MAX) * 2.f * (float)M_PI;
    s_offset = { cosf(angle) * s_magnitude, sinf(angle) * s_magnitude };
}

simd_float2 ScreenShakeSystem_offset(const World& /*world*/) {
    return s_offset;
}
