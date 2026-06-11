#include "ReviveSystem.h"
#include "Simulation/World.h"
#include "Simulation/Systems/AnimationSystem.h"
#include <math.h>

static constexpr float kReviveRadius = 90.f;
static constexpr float kReviveTime   = 2.5f;

void ReviveSystem_update(World& world, float gameDt) {
    if (gameDt == 0.f) return;

    uint32_t count = world.entity_count();
    for (EntityID downedID = 0; downedID < count; ++downedID) {
        if (!world.downed().present(downedID)) continue;
        if (!world.player_tags().present(downedID)) continue;
        if (!world.has_component<PositionComponent>(downedID)) continue;
        if (!world.has_component<HealthComponent>(downedID)) continue;

        const PositionComponent& dpos = world.get_component<PositionComponent>(downedID);
        bool hasNearbyTeammate = false;
        for (EntityID pid = 0; pid < count; ++pid) {
            if (pid == downedID) continue;
            if (!world.player_tags().present(pid)) continue;
            if (world.has_component<DownedComponent>(pid)) continue;
            if (!world.has_component<PositionComponent>(pid)) continue;
            if (!world.has_component<HealthComponent>(pid)) continue;
            if (world.get_component<HealthComponent>(pid).current <= 0) continue;
            if (world.has_component<AnimationComponent>(pid) &&
                world.get_component<AnimationComponent>(pid).dying) continue;

            const PositionComponent& ppos = world.get_component<PositionComponent>(pid);
            float dx = ppos.x - dpos.x;
            float dy = ppos.y - dpos.y;
            if (dx * dx + dy * dy <= kReviveRadius * kReviveRadius) {
                hasNearbyTeammate = true;
                break;
            }
        }

        DownedComponent& downed = world.get_component<DownedComponent>(downedID);
        if (hasNearbyTeammate) {
            downed.reviveProgress += gameDt;
        } else {
            downed.reviveProgress -= gameDt * 0.5f;
            if (downed.reviveProgress < 0.f) downed.reviveProgress = 0.f;
        }

        if (downed.reviveProgress >= kReviveTime) {
            world.remove_component<DownedComponent>(downedID);
            HealthComponent& hp = world.get_component<HealthComponent>(downedID);
            hp.current = (hp.max + 1) / 2;
            if (world.has_component<VelocityComponent>(downedID)) {
                VelocityComponent& vel = world.get_component<VelocityComponent>(downedID);
                vel.vx = vel.vy = vel.vz = 0.f;
            }
            if (world.has_component<AnimationComponent>(downedID)) {
                AnimationComponent& anim = world.get_component<AnimationComponent>(downedID);
                anim.dying = false;
                AnimationSystem_request_clip(world, downedID, AnimClipID::Idle);
            }
            world.events().emit_player_revived(downedID);
        }
    }
}
