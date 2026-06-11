#pragma once
#include "Simulation/World.h"

static constexpr float kProjectileHitRadius = 35.f;

void ProjectileSystem_update(World& world, float gameDt);
