#pragma once
#include "Simulation/World.h"

static constexpr float kCombatKnockbackSpeed     = 480.0f;
static constexpr float kCombatKnockbackDuration  = 0.18f;
static constexpr float kCombatBossKnockbackScale = 0.25f;

void Combat_spawn_heart_drop_if_needed(World& world, EntityID victimID);
bool Combat_try_second_wind(World& world, EntityID victimID);
void Combat_apply_death(World& world, EntityID victimID);
