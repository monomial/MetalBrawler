#pragma once
#include "Simulation/World.h"

static constexpr float kInitialWaveDelay      = 1.5f;
static constexpr float kMarkerTelegraph       = 1.0f;
static constexpr float kInterWaveDelay        = 1.5f;
static constexpr float kSpawnAnimDuration     = 0.6f;
static constexpr float kBossReinforceInterval = 9.0f;
static constexpr int   kBossMinionCap         = 4;
static constexpr int   kFinalBossMinionCap    = 3;

enum WavePhase : uint8_t {
    WavePhaseInitialDelay = 0,
    WavePhaseTelegraph    = 1,
    WavePhaseFighting     = 2,
    WavePhaseDone         = 3,
};

enum SpawnStyle : uint8_t {
    SpawnStyleGroundRise = 0,
    SpawnStyleSkyDrop    = 1,
};

uint8_t WaveSystem_spawn_style(uint8_t archetype);
void WaveSystem_update(World& world, float gameDt);
bool WaveSystem_room_finished(World& world);
void WaveSystem_force_done(World& world);
