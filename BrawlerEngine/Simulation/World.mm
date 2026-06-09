#include "World.h"
#include "Systems/InputSystem.h"
#include "Systems/EnemyAISystem.h"
#include "Systems/PhysicsSystem.h"
#include "Systems/CombatSystem.h"
#include "Systems/WallCollisionSystem.h"
#include "Systems/AnimationSystem.h"
#include "Systems/ScreenShakeSystem.h"
#include "Systems/DodgeSystem.h"
#include "Systems/KnockbackSystem.h"
#include "Systems/BossSystem.h"
#include "Systems/HazardSystem.h"
#include <cassert>

static constexpr float kFixedDt = 1.0f / 120.0f; // 8.33ms physics tick

// _pool<T>() specializations — each returns the matching storage member.
// To add a new component type: add the member to World.h, then add a line here.
template<> ComponentStorage<PositionComponent>&  World::_pool() { return _positions; }
template<> ComponentStorage<VelocityComponent>&  World::_pool() { return _velocities; }
template<> ComponentStorage<HealthComponent>&    World::_pool() { return _healths; }
template<> ComponentStorage<FactionComponent>&   World::_pool() { return _factions; }
template<> ComponentStorage<PlayerTagComponent>&      World::_pool() { return _playerTags; }
template<> ComponentStorage<DamageCooldownComponent>& World::_pool() { return _damageCooldowns; }
template<> ComponentStorage<AnimationComponent>&      World::_pool() { return _animations; }
template<> ComponentStorage<FacingComponent>&              World::_pool() { return _facings; }
template<> ComponentStorage<EnemyAttackCooldownComponent>& World::_pool() { return _attackCooldowns; }
template<> ComponentStorage<DodgeComponent>&              World::_pool() { return _dodges; }
template<> ComponentStorage<BossTagComponent>&            World::_pool() { return _bossTags; }
template<> ComponentStorage<KnockbackComponent>&          World::_pool() { return _knockbacks; }
template<> ComponentStorage<EnemyArchetypeComponent>&     World::_pool() { return _archetypes; }
template<> ComponentStorage<BossChargeComponent>&         World::_pool() { return _bossCharges; }
template<> ComponentStorage<StatsComponent>&              World::_pool() { return _stats; }
template<> ComponentStorage<HazardComponent>&             World::_pool() { return _hazards; }
template<> ComponentStorage<PathFollowComponent>&         World::_pool() { return _paths; }

// ----

World::World()
    : _nextID(0)
    , _rngState(0x9E3779B9u)
    , _deferredDestroyCount(0)
    , _accumulator(0.0f)
    , _hitStopTicks(0)
    , _inputs{}
{}

World::~World() {}

EntityID World::defer_create() {
    return _nextID++;
}

void World::defer_destroy(EntityID id) {
    assert(_deferredDestroyCount < 256 && "deferred destroy buffer overflow");
    _deferredDestroy[_deferredDestroyCount++] = id;
}

void World::trigger_hit_stop(int ticks) {
    if (ticks > _hitStopTicks) _hitStopTicks = ticks;
}

void World::flush() {
    for (uint32_t i = 0; i < _deferredDestroyCount; ++i) {
        EntityID id = _deferredDestroy[i];
        _positions.remove(id);
        _velocities.remove(id);
        _healths.remove(id);
        _factions.remove(id);
        _playerTags.remove(id);
        _damageCooldowns.remove(id);
        _animations.remove(id);
        _facings.remove(id);
        _attackCooldowns.remove(id);
        _dodges.remove(id);
        _bossTags.remove(id);
        _knockbacks.remove(id);
        _archetypes.remove(id);
        _bossCharges.remove(id);
        _stats.remove(id);
        _hazards.remove(id);
        _paths.remove(id);
    }
    _deferredDestroyCount = 0;
}

void World::tick(float gameDt) {
    _events.clear(); // fresh slate each tick

    // Systems run in declared order (see docs/ecs-vocabulary.md).
    // gameDt is 0 during HitStop — systems that use it freeze automatically.

    // 1. InputSystem — reads current_input(), writes player velocity
    InputSystem_update(*this);
    // 1.5. EnemyAISystem — steers enemies toward player
    EnemyAISystem_update(*this, gameDt);
    // 1.6. BossSystem — charge state machine, overrides AI velocity/clip while
    //      telegraphing/charging/recovering; owns DamageCooldown decrement
    BossSystem_update(*this, gameDt);
    // 1.7. HazardSystem — moves lava snakes along their loops, applies area
    //      damage to players inside (gated by DamageCooldown), expires them
    HazardSystem_update(*this, gameDt);
    // 1.75. KnockbackSystem — overrides AI/input velocity while an entity is
    //       being shoved (runs after the velocity writers, before integration)
    KnockbackSystem_update(*this, gameDt);
    // 2. PhysicsSystem
    PhysicsSystem_update(*this, gameDt);
    // 2.5. WallCollisionSystem — clamp entities to room bounds
    WallCollisionSystem_update(*this, gameDt);
    // 3. CombatSystem — handles both player→enemy and enemy→player attack hitboxes.
    //    ContactDamageSystem removed: enemies now deal damage through Attack animations,
    //    not passive proximity. Code kept in ContactDamageSystem.mm for hazard reuse later.
    CombatSystem_update(*this, gameDt);
    // 4. HitStopSystem — managed by _hitStopTicks / trigger_hit_stop()
    // 5. AnimationSystem — advances clip time, samples bone matrices when assets loaded
    AnimationSystem_update(*this, gameDt);
    // 6. DodgeSystem — arms invincibility + applies impulse when Dodge clip starts;
    //    removes DodgeComponent when clip finishes. Runs after AnimationSystem so
    //    clipDone is up-to-date.
    DodgeSystem_update(*this, gameDt);
    // 7. AudioSystem (physicalDt — run even during HitStop)
    // RespawnSystem removed: room progression in BrawlerGameDelegate owns enemy spawning.
    // 8. HapticsSystem   — TODO
    // 9. ScreenShakeSystem (fixed physical dt — must keep decaying during HitStop,
    //    when gameDt is 0, otherwise the shake freezes exactly when it matters most)
    ScreenShakeSystem_update(*this, kFixedDt);
    // 9. flush
    flush();
    // 10. RenderSystem — called by the render loop after update() returns
}

void World::update(float physicalDt, float /*gameDt*/) {
    // Accumulate wall-clock time and drain in fixed 120Hz steps.
    // Prevents hitbox tunneling and makes physics deterministic.
    _accumulator += physicalDt;
    while (_accumulator >= kFixedDt) {
        _accumulator -= kFixedDt;

        // HitStop: consume one frozen tick, then resume.
        float tickGameDt = kFixedDt;
        if (_hitStopTicks > 0) {
            tickGameDt = 0.0f;
            --_hitStopTicks;
        }

        tick(tickGameDt);
    }
}
