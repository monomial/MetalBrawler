#include "PhysicsSystem.h"
#include "Simulation/World.h"

void PhysicsSystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return; // HitStop — physics frozen this tick

    uint32_t count = world.entity_count();
    auto& positions  = world.positions();
    auto& velocities = world.velocities();

    for (EntityID id = 0; id < count; ++id) {
        if (!positions.present(id) || !velocities.present(id)) continue;

        PositionComponent& pos      = positions.get(id);
        const VelocityComponent& vel = velocities.get(id);

        pos.x += vel.vx * gameDt;
        pos.y += vel.vy * gameDt;
        pos.z += vel.vz * gameDt;
    }
}
