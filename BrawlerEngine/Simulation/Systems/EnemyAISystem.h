#pragma once
class World;

// Steers every entity with FactionComponent::Enemy toward the player.
// Writes VelocityComponent; PhysicsSystem integrates the result.
// Uses gameDt — enemies freeze during HitStop along with everything else.
void EnemyAISystem_update(World& world, float gameDt);
