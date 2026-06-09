#pragma once
class World;

// Shoves entities that just took a hit: linear decay from the impulse stored
// in KnockbackComponent to zero over its duration, then removes the component.
// Runs after the velocity writers (InputSystem, EnemyAISystem) and before
// PhysicsSystem so the shove overrides AI/input movement for its duration.
void KnockbackSystem_update(World& world, float gameDt);
