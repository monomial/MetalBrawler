#pragma once
#include "Simulation/World.h"
class World;
void PickupSystem_update(World& world, float gameDt);
void PickupSystem_break_box(World& world, EntityID boxID);
