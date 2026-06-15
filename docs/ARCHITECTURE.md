# MetalBrawler — Architecture Overview

A high-level map of how the code is organized and how a frame flows, written so
you can reason about "how hard is feature X?" without reading every file.

---

## 1. The one-paragraph mental model

MetalBrawler is a **deterministic simulation** with a **renderer bolted on top**.
All gameplay lives in a hand-written C++ **Entity-Component-System (ECS)** that
knows nothing about Metal, audio, or which platform it's on. Each frame, the
platform layer feeds player input into the sim, the sim advances in fixed
120 Hz steps, the sim emits **events** ("a hit landed", "a box broke"), and a
thin **delegate** turns those events into rendering, sound, and haptics. Because
the sim is pure and deterministic (same input + same seed = same result), we can
run it **headless** in tests and let a bot play full games to prove the game is
still winnable.

```
input → [ Simulation (pure C++, deterministic) ] → events → [ Renderer / Audio / Haptics ]
                     ▲                                              │
              fixed 120Hz ticks                              drawn to screen
```

---

## 2. The layers (where everything lives)

```
BrawlerEngine/
  Simulation/            ← the game. Pure C++/ECS. No Metal, no UIKit. Testable headless.
    World.{h,mm}         ← owns all entities/components; runs the systems each tick
    Components.h         ← every component struct (pure data, no logic)
    Systems/*.{h,mm}     ← all gameplay logic, one concern per file (23 systems)
    EventBus.h           ← per-frame message queue (sim → outside world)
    EnemyArchetypes.h    ← enemy stat table (Grunt/Rusher/Heavy/Boss/Spitter/Leaper)
    Difficulty.h         ← difficulty scaling formulas
    RoomBounds.h         ← arena dimensions
    AutoPilot.{h,mm}     ← the test/​demo bot that plays the game itself

  BrawlerGameDelegate.{h,mm}  ← the ORCHESTRATOR (shared by all 3 platforms)
                                rooms, phases (title/play/upgrade/win…), run state
                                (scrap, coins, perks, curse), routes events out

  Renderer/BrawlerRenderer.mm ← Metal rendering + the in-engine text overlay + HUD
  Renderer/ParticleSim.h      ← pure-C++ particle pool (NOT ECS entities)
  Audio/AudioEngine.mm        ← sound effects + music
  Haptics/HapticsEngine.mm    ← controller rumble
  Assets/CharacterLoader.mm   ← loads USDZ skinned meshes + animation clips
  MetaProgressStore.{h,mm}    ← persistent coins/upgrades (NSUserDefaults)
  Platform/InputState.h       ← the tiny struct of per-player input

Brawler-macOS/ , Brawler-iOS/ , Brawler-tvOS/   ← thin per-platform shells
  GameViewController.mm   ← translates keyboard/touch/controller → InputState
  BrawlerAutoTest.mm      ← --autotest mode: drives AutoPilot, screenshots, exit code
  AppDelegate, main, Info.plist, Assets.xcassets

BrawlerLogicTests/        ← XCTest suites that run the headless sim (274 tests)
Shaders/*.metal           ← GPU shaders (skinned mesh, flat quads, post-FX)
tools/*.py                ← asset pipeline (USDZ conversion, icons, music synth)
scripts/{run.sh,smoke.sh} ← run locally / run the visual bot test
project.yml               ← xcodegen project definition (generates the .xcodeproj)
docs/                     ← design docs (one per feature) + this file
```

The golden rule: **`Simulation/` never imports Metal/UIKit/Foundation-UI.** That
purity is what makes the whole thing testable and deterministic.

---

## 3. The ECS (this is the core — understand this and you understand the game)

Three concepts:

- **Entity** — just an integer ID (`EntityID`). A player, an enemy, a heart, a
  lava pool, an exit portal: all just IDs.
- **Component** — a plain data struct attached to an entity. No logic. Examples:
  `PositionComponent {x,y,z}`, `HealthComponent {current,max}`,
  `VelocityComponent`, `BossChargeComponent`. There are ~34 of them in
  `Components.h`. An entity "is" whatever components it has — a Grunt is an ID
  with Position + Velocity + Health + Faction + Animation + EnemyArchetype…
- **System** — a free function that runs each tick, loops over entities that have
  the components it cares about, and does one job. `CombatSystem` resolves hits,
  `EnemyAISystem` steers enemies, `WaveSystem` spawns waves, etc. (23 in
  `Systems/`).

`World` owns it all: it stores every component in typed pools
(`ComponentStorage<T>`) and exposes accessors like `world.get_component<T>(id)`,
`world.has_component<T>(id)`, `world.add_component<T>(id)`.

### Adding a component = a 4-step registration (memorize this)
This is the single most common gotcha. To add a new component type you touch
**four** places (mirror any existing one, e.g. `DodgeComponent`):
1. Define the `struct` in `Components.h`.
2. Add a storage member + accessor in `World.h`.
3. Add a `_pool<T>()` specialization in `World.mm`.
4. Add a removal line in `World::flush()` in `World.mm`.

Miss #4 and components silently "leak" onto recycled entity IDs. (This rule
lives in `docs/codex-rules.md` because it bites every time.)

---

## 4. The update loop & determinism (the other core idea)

`World::update(physicalDt)` is called once per rendered frame. It does **not**
simulate using the raw frame time. Instead it accumulates wall-clock time and
drains it in **fixed 120 Hz ticks** (`kFixedDt = 1/120 s`):

```
update(physicalDt):
   clear events
   accumulator += physicalDt
   while accumulator >= 1/120:
        tick(gameDt)      ← one fixed step
```

Why fixed steps: deterministic physics, no hitbox "tunneling", identical results
on any hardware. This is what lets the bot reproduce runs exactly.

**Two clocks.** `tick(gameDt)` takes a *game* dt that can differ from real time:
- **Hit-stop** (the satisfying freeze on a big hit): a few ticks run with
  `gameDt = 0` — animation/feel systems still tick on real time, but gameplay
  freezes.
- **Slow-motion** (the final-kill moment): ticks run with `gameDt = kFixedDt *
  scale`. `World::time_scale()` reports the current factor for visuals.

### System order matters
`World::tick()` calls the 23 systems in a deliberate sequence. The key
invariant: anything that **writes velocity** (Input, EnemyAI, Boss, Knockback,
Leaper, Projectile) runs **before** `PhysicsSystem` (which integrates velocity
into position), which runs before `WallCollisionSystem` (which clamps). Combat
resolves after movement; pickups/waves/animation after that. The full ordered
list with comments is at the top of `World::tick()` in `World.mm` — read it once,
it's the best 50-line summary of the game.

---

## 5. The EventBus (how the silent sim talks to the loud world)

The sim can't play a sound — it's pure. Instead, systems **emit events** into a
ring buffer: `DamageDealt`, `HitContact`, `BossTelegraph`, `ScrapCollected`,
`BoxBroken`, `FinalKill`, `LavaPoolSpawned`, `ChargedSlam`, … (~22 types in
`EventBus.h`). 

Critical semantics: **events are cleared once per `update()` (per frame), not
per tick.** A frame runs ~2 ticks, and events accumulate across them; the
delegate reads them once after the frame. (Systems must act at the *emission
site*, not by re-scanning events each tick, or they'd double-process.)

The `BrawlerGameDelegate` drains the events each frame and translates them:
`HitContact → play hit sound + particles`, `BoxBroken → woody burst`,
`FinalKill → slow-mo + camera zoom`, etc.

---

## 6. The delegate (the conductor)

`BrawlerGameDelegate` is the one big stateful object shared by all three
platforms. It is *not* the sim — it wraps it. It owns:
- The current `World` (rebuilt each room).
- **Run state that must survive a room rebuild**: lives, scrap, coins, per-player
  perks, the curse multiplier, combo/score. These get *mirrored into* the World
  each room (`set_scrap`, `set_difficulty`, `set_curse`).
- The **phase state machine**: Title → PlayerSelect → Playing → RoomClear →
  Upgrade → (walk to exit) → next room … → Win/Lose, plus Paused and MetaShop.
- **Room definitions**: which enemies spawn where, obstacles, boxes, shop layout.
- Routing events → Renderer/Audio/Haptics.

`drawInMTKView:` (the per-frame entry) is split so tests can call `advanceFrame:`
without any rendering — that's the headless hook.

---

## 7. Rendering (kept deliberately simple)

`BrawlerRenderer` draws in Metal: skinned character meshes (players, enemies,
boss, shopkeeper) plus a lot of **flat quads on the floor** for everything
cosmetic — hazards, markers, hearts, scrap, exit arrows, telegraph lines, curse
portals. New cosmetic entity types follow an "early-continue flat-quad" pattern
in the entity loop. Text (HUD labels, the overlay) is rendered in-engine so all
three platforms look identical and the screenshot tests can read it.

Two hard limits to remember: the bone buffer is indexed by raw entity ID and
capped at **64** (so cosmetic/flat entities must NOT get an `AnimationComponent`),
and particles are a separate pure-C++ pool (`ParticleSim`), **not** ECS entities.

---

## 8. How it's built, tested, and verified

- **Build**: `project.yml` → `xcodegen` generates `MetalBrawler.xcodeproj`. New
  `.h/.mm` files require re-running `xcodegen`. Three app targets + a test bundle.
- **Logic tests** (`BrawlerLogicTests/`, 274): run the headless sim. Includes
  **scenario tests** where `AutoPilot` plays full games and asserts the outcome —
  e.g. "1P bot wins all 8 rooms", "a bot with dodging disabled loses" (proves the
  game *requires* dodging). These are the **beatability gate**.
- **Smoke test** (`scripts/smoke.sh`): builds the macOS app, runs `--autotest`
  where the bot plays a full run, captures screenshots at each beat, and exits 0
  only if it reaches Win. (Gotcha: needs the display awake — `caffeinate`.)
- **CI**: GitHub Actions runs xcodegen + builds all 3 targets + the logic tests
  on every push.
- **Determinism caveat for testing**: always trust a **clean build** after adding
  test methods — incremental builds have silently run a stale test bundle.

The verification loop is the project's superpower: most changes are proven
correct by the headless bot, not by you replaying the game by hand.

---

## 9. The asset pipeline

3D characters are Mixamo exports converted to USDZ by `tools/convert_to_usdz.py`
(via Blender), stored in `assets/` with Git LFS. Animation clips map to an
`AnimClipID` enum — and there's a **clip-table trap**: adding a clip means
updating FOUR parallel tables together (durations, speed multipliers, attack
windows, and the filename array), or it silently zero-fills. Music is synthesized
by `tools/synthesize_battle_music.py`; icons by `generate_icons.py`.

---

## 10. "How hard is feature X?" — a practical cookbook

The honest answer for most gameplay features: **medium, and it follows a
recipe.** Here's how to estimate, by mapping the feature to what it touches.

### Pattern A — a new enemy behavior / attack (e.g. Leaper, Spitter lobs)
Touch: maybe a new `Component` (the 4-step registration), a new or extended
`System` in `Systems/`, an entry in `EnemyArchetypes.h`, the wave/room data,
optionally a renderer branch for a new visual, and tests. **Medium.** The sim is
deterministic so it's fully testable; the renderer bit is the only part you
eyeball.

### Pattern B — a new pickup / interactable (e.g. scrap, breakable boxes)
Touch: a `Component`, logic in an existing system (often `PickupSystem`), an
event in `EventBus.h`, a delegate handler for sound/particles, a flat-quad
renderer branch, tests. **Small–medium.** Lots of reuse.

### Pattern C — a new run-level mechanic (e.g. perks, curse portals, coins)
Touch: run state in the **delegate**, often mirrored into `World` (the
`set_scrap`/`set_curse` pattern), application at spawn or at damage sites, maybe
a new phase, HUD text, and tests. **Medium.** The cross-platform UI (a new
overlay/screen) is usually the heaviest part.

### Pattern D — a tuning / balance change (e.g. difficulty, damage numbers)
Touch: named constants in one or two files (`Difficulty.h`, archetype table,
system constants). **Small** — but balance *tuning* is iterative against the
beatability gate, so it's the one kind of work that's a loop, not a one-shot.

### Pattern E — pure visual polish (e.g. shadows, post-FX, biomes)
Touch: `BrawlerRenderer` + shaders only; no sim changes. **Small–medium.** Can't
be verified by the bot — needs your eyes (the smoke screenshots help).

### What makes something *hard*
- It needs to **break determinism** (e.g. adopting a non-deterministic framework
  like GameplayKit) — avoid; it breaks the test gate.
- It needs **cross-platform UI** (a new interactive screen on macOS keys / iOS
  touch / tvOS remote) — that's real work in three `GameViewController`s.
- It needs **new animation clips or art** — gated on the asset pipeline / a
  Mixamo export, and the clip-table trap.
- It changes **system ordering** or **event timing** — possible but requires
  understanding the tick sequence (§4) and event semantics (§5).

### The repeatable workflow we use
For non-trivial features: write a short **design doc in `docs/`** (one per
feature — there are many to read as examples), implement it (often via Codex)
following the registration/event/clip rules in `docs/codex-rules.md`, then run
the gate (tests + smoke + 3 builds) and commit. The design docs + this file are
the map; `World::tick()` and `Components.h` are the territory.
