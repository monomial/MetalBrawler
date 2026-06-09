#pragma once
class World;

// Ground hazards (lava snakes): advances each Hazard+PathFollow entity along
// its looping waypoint path, applies area damage to players inside the hazard
// radius (gated by the player's DamageCooldownComponent, blocked by dodge
// i-frames), and despawns hazards whose lifetime expires.
void HazardSystem_update(World& world, float gameDt);

// Spawn one lava snake at (x, y) that loops out to (outX, outY) and back via
// a perpendicular offset. Returns its entity ID. Used by BossSystem and tests.
unsigned int HazardSystem_spawn_snake(World& world, float x, float y,
                                      float outX, float outY);
