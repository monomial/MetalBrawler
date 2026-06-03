#include "PhysicsSystem.h"
#include "Simulation/World.h"
#include <math.h>

static constexpr float kSeparationRadius = 60.0f; // minimum distance between entity centers

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

    // Push overlapping mobile entities apart so characters never visually stack.
    // Only applies to entities with VelocityComponent — static/test entities are exempt.
    for (EntityID a = 0; a < count; ++a) {
        if (!positions.present(a) || !velocities.present(a)) continue;
        for (EntityID b = a + 1; b < count; ++b) {
            if (!positions.present(b) || !velocities.present(b)) continue;
            PositionComponent& pa = positions.get(a);
            PositionComponent& pb = positions.get(b);
            float dx = pb.x - pa.x;
            float dy = pb.y - pa.y;
            float dist = sqrtf(dx * dx + dy * dy);
            if (dist < kSeparationRadius && dist > 0.001f) {
                float overlap = (kSeparationRadius - dist) * 0.5f;
                float nx = dx / dist, ny = dy / dist;
                pa.x -= nx * overlap;
                pa.y -= ny * overlap;
                pb.x += nx * overlap;
                pb.y += ny * overlap;
            }
        }
    }
}
