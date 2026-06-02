#pragma once
class World;

// Watches for EntityDied events. When all enemies are dead, spawns a new wave
// after a short delay. Keeps the game loop alive for feel-milestone testing.
// V1: one enemy, respawns at a random room position after kRespawnDelay seconds.
void RespawnSystem_update(World& world, float physicalDt);

// Resets internal timer state — call in tests setUp to prevent cross-test leakage.
void RespawnSystem_reset();
