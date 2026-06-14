#include "EnemyFactory.h"

EntityID Enemy_spawn(World& world, uint8_t archetype, float x, float y) {
    const EnemyArchetypeDef& def = enemy_archetype_def(archetype);
    int maxHP = (int)lroundf((float)def.maxHP * world.curse_mult());
    if (maxHP < 1) maxHP = 1;

    EntityID e = world.defer_create();
    world.add_component<PositionComponent>(e) = {x, y, 0.f};
    world.add_component<VelocityComponent>(e) = {0.f, 0.f, 0.f};
    world.add_component<FactionComponent>(e).type = FactionComponent::Enemy;
    world.add_component<HealthComponent>(e) = {maxHP, maxHP};
    world.add_component<AnimationComponent>(e);
    world.add_component<FacingComponent>(e);
    world.add_component<EnemyAttackCooldownComponent>(e);
    world.add_component<EnemyArchetypeComponent>(e).type = archetype;
    if (archetype == (uint8_t)EnemyArchetype::Boss) {
        world.add_component<BossTagComponent>(e);
        world.add_component<BossChargeComponent>(e);
    }
    if (archetype == (uint8_t)EnemyArchetype::Leaper) {
        world.add_component<LeaperComponent>(e).cooldown = 0.f;
    }
    return e;
}
