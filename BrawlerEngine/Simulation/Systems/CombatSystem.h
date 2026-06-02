#pragma once
class World;

// Resolves player attacks: checks attack input, damages enemies within range,
// destroys enemies at 0 HP via defer_destroy, triggers hit-stop on contact.
// Uses gameDt — no new hits fire during a hit-stop freeze.
void CombatSystem_update(World& world, float gameDt);
