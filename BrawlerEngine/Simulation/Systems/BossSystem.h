#pragma once
class World;

// Boss charge attack: Idle (cooldown) → Telegraph (stop + warn) → Charge
// (rush the stored player direction, contact damage) → Recover → Idle.
// Runs AFTER EnemyAISystem and overrides its velocity/clip while active
// (same last-writer-wins trick as Dodge/Knockback). Also owns the decrement
// of DamageCooldownComponent — it is currently the only contact-damage user.
void BossSystem_update(World& world, float gameDt);
