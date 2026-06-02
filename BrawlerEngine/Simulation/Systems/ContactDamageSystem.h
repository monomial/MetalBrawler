#pragma once
class World;

// Deals damage to the player when an enemy is within contact range.
// Uses DamageCooldownComponent to limit to one hit per kContactCooldown seconds.
// Uses gameDt — no contact damage during HitStop.
void ContactDamageSystem_update(World& world, float gameDt);
