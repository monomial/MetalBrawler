# ECS Vocabulary for MetalBrawler

Four concepts. One page.

---

## World

The single container that owns everything: entity IDs, component storage, and the system list.

```cpp
class World {
public:
    void update(float physicalDt, float gameDt);
    EntityID defer_create();
    void     defer_destroy(EntityID id);
    void     flush(); // called once per frame after all systems run
};
```

`World.update(physicalDt, gameDt)` drives one frame. `physicalDt` is wall-clock time — audio, haptics, screen shake, and rendering always use it and never freeze. `gameDt` is scaled game time — logic, physics, combat, and animation use it; HitStopSystem sets it to 0 to freeze gameplay without pausing the render loop.

There is one `World`. It is not a singleton. It is owned by the game loop and passed to systems explicitly.

---

## Entity

An integer ID. Nothing more.

```cpp
using EntityID = uint32_t;
```

An entity has no data and no behavior. It is a key into component arrays. When you say "the player" you mean "EntityID 1" (or whatever ID was assigned). The entity itself is just a number; its meaning comes from which components are attached to it.

Entities are created via `defer_create()` and destroyed via `defer_destroy()`. Both are buffered — the World's deferred command buffer flushes after all systems complete each frame. You cannot create or destroy mid-frame.

---

## Component

A plain C struct. No methods. No logic. Only data.

```cpp
struct PositionComponent {
    float x, y, z;
};

struct HealthComponent {
    int current;
    int max;
};
```

Components are stored in `std::vector<ComponentType>`, one vector per component type, indexed by EntityID. Access is cache-friendly because all positions are next to each other in memory, all healths are next to each other, etc.

A component that holds no data (e.g., `struct PlayerTag {}`) is a tag — it marks an entity as belonging to a category without adding data.

Rule: if you find yourself writing a method on a component, move that logic to a system.

---

## System

A function (or callable struct) that reads and writes specific components each frame. Systems contain all the logic.

```cpp
// PhysicsSystem reads PositionComponent and VelocityComponent,
// writes PositionComponent.
void PhysicsSystem_update(World& world, float gameDt);
```

Systems run in a fixed, declared order every frame. Order matters — CombatSystem must run before HitStopSystem so that the gameDt scale is set *after* damage is resolved. The frame execution order is the architecture.

Frame execution order (see design.md for full table):
1. InputSystem (physicalDt)
2. PhysicsSystem (gameDt)
3. CombatSystem (gameDt)
4. HitStopSystem — scales gameDt
5. AnimationSystem (gameDt — already scaled)
6. AudioSystem (physicalDt)
7. HapticsSystem (physicalDt)
8. ScreenShakeSystem (physicalDt)
9. World flush — deferred create/destroy
10. RenderSystem (physicalDt)

A system should do one thing. If you find a system doing two unrelated things, split it.

---

## The one rule

**Components own data. Systems own logic. World owns lifetime. Entities own nothing.**

If you violate this — putting logic in a component, or data in a system — you will regret it by month two.
