#pragma once
class World;

// Clamps every entity with a PositionComponent to the room boundary after
// PhysicsSystem has integrated velocity. Zeroes the corresponding velocity
// axis on contact so entities don't accumulate into the wall.
// Uses gameDt — no-op during HitStop.
void WallCollisionSystem_update(World& world, float gameDt);
