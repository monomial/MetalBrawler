#pragma once
#include <stdint.h>
#include <vector>
#include <cassert>
#include "Components.h"

using EntityID = uint32_t;
static constexpr EntityID kInvalidEntity = UINT32_MAX;

// One storage slot per component type.
// data[id] holds the component value; has[id] says whether this entity has it.
// Indexed directly by EntityID — no hash map, no indirection.
template<typename T>
struct ComponentStorage {
    std::vector<T>    data;
    std::vector<bool> has;

    T& add(EntityID id) {
        if (id >= (EntityID)data.size()) {
            data.resize(id + 1);
            has.resize(id + 1, false);
        }
        has[id] = true;
        return data[id];
    }

    T& get(EntityID id) {
        assert(id < (EntityID)data.size() && has[id] && "get_component: entity missing component");
        return data[id];
    }

    bool present(EntityID id) const {
        return id < (EntityID)has.size() && has[id];
    }

    void remove(EntityID id) {
        if (id < (EntityID)has.size()) has[id] = false;
    }
};

// Hand-rolled ECS World.
// Owns entity IDs, component storage vectors, and the system execution order.
//
// Frame contract:
//   World.update(physicalDt, gameDt) drives one frame.
//   physicalDt = wall-clock time (audio, haptics, screen shake, render — never freezes).
//   gameDt     = scaled game time (logic, physics, combat — HitStopSystem sets to 0).
//   Deferred creates/destroys buffer until flush() at end of frame.
class World {
public:
    World();
    ~World();

    void update(float physicalDt, float gameDt);

    // Deferred lifecycle — buffered and applied at end of frame, after all systems run.
    EntityID defer_create();
    void     defer_destroy(EntityID id);

    // Component API — template methods dispatch to the matching storage member.
    template<typename T> T&   add_component(EntityID id);
    template<typename T> T&   get_component(EntityID id);
    template<typename T> bool has_component(EntityID id);
    template<typename T> void remove_component(EntityID id);

    uint32_t entity_count() const { return _nextID; }

    // Direct pool access for systems that iterate all entities with a component.
    ComponentStorage<PositionComponent>& positions() { return _positions; }
    ComponentStorage<VelocityComponent>& velocities() { return _velocities; }
    ComponentStorage<HealthComponent>&   healths()    { return _healths; }
    ComponentStorage<FactionComponent>&  factions()   { return _factions; }

private:
    void flush();

    // Each _pool<T>() specialization returns the matching storage member.
    // Specializations are defined in World.mm.
    template<typename T> ComponentStorage<T>& _pool();

    uint32_t _nextID;
    uint32_t _deferredDestroyCount;
    EntityID _deferredDestroy[256];

    ComponentStorage<PositionComponent> _positions;
    ComponentStorage<VelocityComponent> _velocities;
    ComponentStorage<HealthComponent>   _healths;
    ComponentStorage<FactionComponent>  _factions;
};

// Template method bodies — inline here so all translation units can instantiate them.

template<typename T>
T& World::add_component(EntityID id)    { return _pool<T>().add(id); }

template<typename T>
T& World::get_component(EntityID id)    { return _pool<T>().get(id); }

template<typename T>
bool World::has_component(EntityID id)  { return _pool<T>().present(id); }

template<typename T>
void World::remove_component(EntityID id) { _pool<T>().remove(id); }

// Explicit specialization declarations — bodies are in World.mm.
template<> ComponentStorage<PositionComponent>& World::_pool<PositionComponent>();
template<> ComponentStorage<VelocityComponent>& World::_pool<VelocityComponent>();
template<> ComponentStorage<HealthComponent>&   World::_pool<HealthComponent>();
template<> ComponentStorage<FactionComponent>&  World::_pool<FactionComponent>();
