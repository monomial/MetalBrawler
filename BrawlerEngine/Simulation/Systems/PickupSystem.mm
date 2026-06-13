#include "PickupSystem.h"
#include "Simulation/World.h"
#include <math.h>

static constexpr float kPickupRadius = 55.0f;
static constexpr float kScrapMagnetRadius = 140.0f;
static constexpr float kScrapCollectRadius = 40.0f;
static constexpr float kScrapMagnetSpeed = 600.0f;
static constexpr float kBoxContactRadius = 45.0f;

static bool is_living_player(World& world, EntityID playerID) {
    if (!world.player_tags().present(playerID)) return false;
    if (!world.has_component<PositionComponent>(playerID)) return false;
    if (!world.has_component<HealthComponent>(playerID)) return false;
    if (world.get_component<HealthComponent>(playerID).current <= 0) return false;
    if (world.has_component<DownedComponent>(playerID)) return false;
    if (world.has_component<AnimationComponent>(playerID) &&
        world.get_component<AnimationComponent>(playerID).dying) return false;
    return true;
}

void PickupSystem_break_box(World& world, EntityID boxID) {
    if (!world.boxes().present(boxID)) return;
    if (!world.has_component<PositionComponent>(boxID)) return;

    const PositionComponent p = world.get_component<PositionComponent>(boxID);
    const BoxComponent box = world.get_component<BoxComponent>(boxID);
    world.remove_component<BoxComponent>(boxID);
    world.events().emit_box_broken(p.x, p.y, box.hasScrap ? 1 : 0);
    if (box.hasScrap) {
        for (int i = 0; i < 3; ++i) {
            float ox = (world.rand_float01() * 2.f - 1.f) * 30.f;
            float oy = (world.rand_float01() * 2.f - 1.f) * 30.f;
            EntityID scrap = world.defer_create();
            world.add_component<PositionComponent>(scrap) = {p.x + ox, p.y + oy, 0.f};
            world.add_component<ScrapPickupComponent>(scrap).value = 2;
        }
    }
    world.defer_destroy(boxID);
}

void PickupSystem_update(World& world, float gameDt) {
    if (gameDt == 0.0f) return;

    uint32_t count = world.entity_count();
    for (EntityID heartID = 0; heartID < count; ++heartID) {
        if (!world.heart_pickups().present(heartID)) continue;
        if (!world.has_component<PositionComponent>(heartID)) continue;

        HeartPickupComponent& heart = world.get_component<HeartPickupComponent>(heartID);
        heart.lifetime -= gameDt;
        if (heart.lifetime <= 0.f) {
            world.defer_destroy(heartID);
            continue;
        }

        const PositionComponent& hpos = world.get_component<PositionComponent>(heartID);
        bool collected = false;
        for (EntityID playerID = 0; playerID < count; ++playerID) {
            if (!is_living_player(world, playerID)) continue;

            HealthComponent& hp = world.get_component<HealthComponent>(playerID);
            if (hp.current >= hp.max) continue;

            const PositionComponent& ppos = world.get_component<PositionComponent>(playerID);
            float dx = ppos.x - hpos.x;
            float dy = ppos.y - hpos.y;
            if (dx * dx + dy * dy > kPickupRadius * kPickupRadius) continue;

            hp.current += 3;
            if (hp.current > hp.max) hp.current = hp.max;
            world.defer_destroy(heartID);
            world.events().emit_pickup_collected(playerID);
            collected = true;
            break;
        }
        if (collected) continue;
    }

    for (EntityID scrapID = 0; scrapID < count; ++scrapID) {
        if (!world.scrap_pickups().present(scrapID)) continue;
        if (!world.has_component<PositionComponent>(scrapID)) continue;

        ScrapPickupComponent& scrap = world.get_component<ScrapPickupComponent>(scrapID);
        scrap.lifetime -= gameDt;
        if (scrap.lifetime <= 0.f) {
            world.defer_destroy(scrapID);
            continue;
        }

        PositionComponent& spos = world.get_component<PositionComponent>(scrapID);
        EntityID nearest = kInvalidEntity;
        float nearestD2 = 0.f;
        for (EntityID playerID = 0; playerID < count; ++playerID) {
            if (!is_living_player(world, playerID)) continue;
            const PositionComponent& ppos = world.get_component<PositionComponent>(playerID);
            float dx = ppos.x - spos.x;
            float dy = ppos.y - spos.y;
            float d2 = dx * dx + dy * dy;
            if (nearest == kInvalidEntity || d2 < nearestD2) {
                nearest = playerID;
                nearestD2 = d2;
            }
        }
        if (nearest == kInvalidEntity) continue;

        const PositionComponent& ppos = world.get_component<PositionComponent>(nearest);
        float dx = ppos.x - spos.x;
        float dy = ppos.y - spos.y;
        float dist = sqrtf(dx * dx + dy * dy);
        if (dist <= kScrapCollectRadius) {
            world.events().emit_scrap_collected(scrap.value);
            world.defer_destroy(scrapID);
            continue;
        }
        if (dist <= kScrapMagnetRadius && dist > 0.001f) {
            float step = kScrapMagnetSpeed * gameDt;
            if (step > dist) step = dist;
            spos.x += (dx / dist) * step;
            spos.y += (dy / dist) * step;
        }
    }

    for (EntityID boxID = 0; boxID < count; ++boxID) {
        if (!world.boxes().present(boxID)) continue;
        if (!world.has_component<PositionComponent>(boxID)) continue;
        const PositionComponent& bpos = world.get_component<PositionComponent>(boxID);
        for (EntityID playerID = 0; playerID < count; ++playerID) {
            if (!is_living_player(world, playerID)) continue;
            const PositionComponent& ppos = world.get_component<PositionComponent>(playerID);
            float dx = ppos.x - bpos.x;
            float dy = ppos.y - bpos.y;
            if (dx * dx + dy * dy <= kBoxContactRadius * kBoxContactRadius) {
                PickupSystem_break_box(world, boxID);
                break;
            }
        }
    }
}
