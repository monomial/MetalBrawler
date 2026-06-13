#pragma once
#include <algorithm>

inline float Difficulty_cooldown_mult(int level) {
    return std::max(0.45f, 1.f - 0.07f * (float)level);
}

inline float Difficulty_speed_mult(int level) {
    return std::min(1.25f, 1.f + 0.03f * (float)level);
}

inline float Difficulty_projectile_mult(int level) {
    return std::min(1.30f, 1.f + 0.035f * (float)level);
}

inline float Difficulty_leaper_telegraph(int level) {
    return std::max(0.55f, 0.9f - 0.045f * (float)level);
}

inline float Difficulty_leap_duration(int level) {
    return std::max(0.30f, 0.40f - 0.015f * (float)level);
}

inline float Difficulty_reinforce_mult(int level) {
    return std::max(0.60f, 1.f - 0.05f * (float)level);
}
