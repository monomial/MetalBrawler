# MetalBrawler — Improvement & Polish Plan of Attack

## Context

MetalBrawler (TMNT: Splintered Fate-inspired roguelike brawler, raw Metal + ObjC/ObjC++, macOS/iOS/tvOS) has hit the design doc's "first ship" bar: solid hand-rolled ECS, 4-room run with boss, 1–2 players, hit-stop, audio, haptics, 1,628 LOC of passing logic tests. The goal now is to move beyond the basics: finish the combat-feel vision, add visual polish, enemy/boss variety, and begin the roguelike layer. Per user: roguelike layer IS in scope; enemy art = strong tint now, real second Mixamo model wired in later when the user exports one; **verification must be heavily automated** — no manual playtest required per change.

First action after approval: save this plan as `docs/improvement-plan.md` in the repo.

**Verified bugs/findings that shape this plan:**
- `ScreenShakeSystem_offset()` is **never called by the renderer** — all screen shake is currently invisible. Also `World.mm:100` ticks it with `gameDt` (freezes during hit-stop) despite the comment saying physicalDt.
- Enemy-character plumbing already exists end-to-end (`AnimationSystem_set_characters(player, enemy)`, `[renderer setPlayerCharacter:enemyCharacter:]`); `BrawlerGameDelegate.mm:105-106` just passes the player twice.
- `assets/characters/player/attack2.fbx` and `hurt2.fbx` exist but were never converted to USDZ — combo system has an asset-pipeline prerequisite (`tools/convert_to_usdz.py` via Blender).
- Trap: `kClipDurationFallback` (AnimationSystem.mm), `kAttackWindows` (CombatSystem.mm), and the ordered clips array in `BrawlerGameDelegate._loadCharacters` are all sized/ordered by `AnimClipID::Count`. Adding `Attack2` silently zero-fills missed tables (0-second clip, no hitbox). All must be updated together.
- Renderer bone buffer is indexed by raw EntityID, capped at `kMaxAnimEntities = 64` → **particles must NOT be ECS entities**.
- `_world = World()` is rebuilt every room → run-level perk state must live in `BrawlerGameDelegate` and be re-applied at spawn.
- Floor/walls already render as flat quads (`BrawlerRenderer.mm` ~272–297) — environment work is an upgrade, not greenfield.
- `drawInMTKView:` (BrawlerGameDelegate.mm:259) already sequences pulses → sim update → event routing → phase machine → render; sim nondeterminism is a single `arc4random_uniform` (CombatSystem.mm:119) plus `rand()` in ScreenShakeSystem — headless deterministic full-game runs are cheap to enable.

**Key files:** `BrawlerEngine/Simulation/{World.h,World.mm,Components.h,EventBus.h}`, `BrawlerEngine/Simulation/Systems/*`, `BrawlerEngine/BrawlerGameDelegate.mm`, `BrawlerEngine/Renderer/BrawlerRenderer.mm`, `Shaders/{Brawler,SkinnedMesh}.metal`, `BrawlerEngine/Audio/AudioEngine.mm`, `BrawlerEngine/Haptics/HapticsEngine.mm`, `BrawlerLogicTests/*`.

**Pattern for every new component:** declare struct in `Components.h`, register storage + accessor in `World.h`, `_pool` specialization + `flush()` removal in `World.mm` (mirror `DodgeComponent`).

---

## Phase 0 — Free wins (S)

1. **Wire screen shake into the camera** — `BrawlerRenderer.mm`: include `ScreenShakeSystem.h`, add `ScreenShakeSystem_offset()` x/y to `eye` and `target` before `make_look_at`. Every existing hit instantly gains visible feedback.
2. **Fix shake dt** — `World.mm:100`: pass `kFixedDt` instead of `gameDt`; adjust `ScreenShakeTests.mm` if needed.
3. **Strong enemy tint** — add `float tintStrength` to `SkinnedUniforms` (renderer struct + `SkinnedMesh.metal`); ~0.08 players, ~0.45 enemies. Enemies become visually distinct in one session.

## Phase 1 — Automated verification harness (so nothing after this needs manual testing)

4. **Headless frame advance (M)** — extract everything in `drawInMTKView:` except the semaphore/render call into `- (void)advanceFrame:(float)dt`; add `-initHeadless` that creates World + phase machine but leaves `_renderer/_audio/_haptics` nil (ObjC nil-messaging makes all their calls no-ops — zero branching needed). `drawInMTKView:` becomes advanceFrame + render.
5. **Deterministic sim (S)** — World-owned seedable PRNG (xorshift32, `World::set_seed`); replace `arc4random_uniform` in `CombatSystem.mm:119` and `rand()` in `ScreenShakeSystem.mm`. Identical seed + identical input script = identical run, forever.
6. **AutoPilot bot (S)** — `Simulation/AutoPilot.h`: free function producing an `InputState` for a player (steer toward nearest living enemy, attack in range, occasional dodge — mirrors EnemyAISystem math). Shared by scenario tests and the visual smoke mode.
7. **Scenario tests (M)** — new `BrawlerLogicTests/ScenarioTests.mm` driving a headless delegate at fixed dt through full games: bot completes 1P run to Win; idle player loses lives → Lose; 2P run; pause freezes sim; life-loss reloads same room; phase/room/lives asserted at each transition. **This is the regression gate every later feature must keep green** — knockback, combos, archetypes, perks all get scenario cases here, not manual playtests.
8. **Visual smoke mode + screenshots (M)** — `--autotest` launch flag on Brawler-macOS: AutoPilot plays, in-app capture (set `framebufferOnly=NO`, blit drawable → PNG via ImageIO) writes screenshots at key beats (title, first hit, mid-combat, room clear, boss, win) to `/tmp/brawler-autotest/`, exits 0 iff Win reached within timeout. `scripts/smoke.sh` = build + run it. Claude reads the PNGs to verify visual changes (shadows, particles, tint, environment) instead of the user playing.
9. **CI (S)** — `.github/workflows/ci.yml`: macOS runner, `xcodegen`, build all 3 targets, run `BrawlerLogicTests` (incl. scenarios; already GPU-free) on every push.

Honest limits of automation: hit-stop strength, haptic feel, and audio mix still need occasional human hands/ears — but those become rare tuning checks, not per-change gates. Correctness, game flow, and visuals are covered.

## Phase 2 — Combat depth & feel completion (the product)

10. **Knockback (M)** — new `KnockbackComponent {velX, velY, elapsed, duration}` + `Systems/KnockbackSystem.mm` running after InputSystem/EnemyAISystem, before PhysicsSystem (DodgeSystem's velocity-ownership trick). Applied in `CombatSystem.mm` on hit: direction attacker→target, speed ~480, ~0.18s linear decay; ×0.25 for `BossTagComponent`; players exempt (existing "players stay mobile" rule). New `KnockbackTests.mm` (push direction, decay, removal, boss scaling, wall clamp) + scenario case.
11. **2-hit combo via attack2 (M)** — convert `attack2.fbx` (+ `hurt2.fbx`) to USDZ via `tools/convert_to_usdz.py`. Add `AnimClipID::Attack2`; update ALL four clip tables (see trap above). `bool comboQueued` on `AnimationComponent`; InputSystem sets it when attack pressed during late Attack window; AnimationSystem chains Attack→Attack2 on completion. Finisher feel: 2 dmg, hit-stop 7 ticks, shake 30. New `ComboTests.mm`.
12. **Animation cross-fade (M)** — `prevClip/prevClipTime/blendRemaining` on `AnimationComponent`; lerp bone matrices from frozen prev pose into current over 0.1s in `AnimationSystem_update`. Kills visible pops on every transition. Extend `AnimationTests.mm`.
13. **Per-attack haptics + missing SFX (S/M)** — new `AttackStarted`/`DodgeStarted` events in `EventBus.h`, emitted from AnimationSystem at transition points. `AudioEngine`: swing whoosh, dodge, finisher, room-clear, UI click (file-then-synth-fallback pattern; Kenney pack already in `assets/audio/`). `HapticsEngine`: light attack (0.4), finisher (1.0 + continuous), dodge, death patterns. Routed in `BrawlerGameDelegate` next to the HitContact handler. Event-emission tests.

## Phase 3 — Visual polish (verified via smoke screenshots)

14. **Blob shadows (S)** — alpha-blended circle quad (smoothstep falloff, new fragment shader) under every animated entity, after the floor draw, depth-write off.
15. **Hit particles (M)** — pure-C++ `ParticleSim` (fixed 256 pool: pos/vel/life/size/color — testable, NOT ECS entities) + instanced billboard pass in `BrawlerRenderer.mm` (additive blending, triple-buffered instance buffer like `_boneBuf`). Driven from the delegate's HitContact handler. Reused later for boss telegraph + room-clear burst. New `ParticleSimTests.mm`.
16. **Death dissolve (S/M)** — `deathFade` countdown (~1s) replaces instant `defer_destroy` after death clip; screen-door dissolve (`discard` by hash vs alpha) in `skinned_fragment_main`. Note: shifts room-clear timing ~1s (scenario tests will catch/encode this). Extend `AnimationTests.mm`.
17. **Room environment upgrade (S/M)** — grid-line floor shader (world-xy in fragment), walls get height (vertical quads at RoomBounds edges), per-room palette via `roomIndex` property on renderer (same pattern as `livesRemaining`).
18. **Post-processing pass (L, LAST overall)** — restructure to scene→offscreen texture→fullscreen post pass→HUD on top. In-shader damage vignette/flash + the design doc's radial blur on hit (decay ~0.15s). Biggest renderer restructure, lowest payoff-per-line — do it after everything else ships.

## Phase 4 — Content & variety

19. **Enemy archetypes (M)** — `EnemyArchetypeComponent {type}` + constexpr table in new `Simulation/EnemyArchetypes.h`: `{moveSpeed, stopRadius, attackCooldown, maxHP, scale, knockbackScale, characterIdx}`. Grunt (current), Rusher (speed 260, HP 2, cooldown 1.2s, 0.85×), Heavy (speed 90, HP 8, cooldown 3s, 1.3×, knockback ×0.3). EnemyAISystem reads params with fallback to current constants (keeps existing tests green); renderer generalizes the hardcoded boss 2× to archetype scale. **Includes the shared RoomDef refactor**: `{enemyCount, enemyHP}` → spawn list `{archetypeID, x, y}[]`. Archetype + AI tests, scenario case.
20. **Boss charge attack (M)** — `BossChargeComponent {state, timer, dirX, dirY}` + `Systems/BossSystem.mm` before EnemyAISystem: Idle→Telegraph 0.7s (stop, particle burst, tint pulse)→Charge (~700 u/s, contact damage reusing `ContactDamageSystem` logic + player's existing `DamageCooldownComponent`)→Recover. Ends on wall contact or timeout. New `BossChargeTests.mm`.
21. **Lava-snake ground hazards (L)** — the design-doc TODO: `HazardComponent {radius, damage}` + `PathFollowComponent` (looping waypoints) + `Systems/HazardSystem.mm` (path interp + ContactDamage cooldown pattern). Boss spawns 2–3 fan-out snakes every ~8s. Rendered as emissive quads + particle trails (no skinned mesh → avoids 64-slot bone cap). New `HazardTests.mm`.
22. **Real enemy model (S, whenever user provides it)** — user exports a second Mixamo character into `assets/characters/enemy/`; wire in `_loadCharacters` + enemy arg (plumbing exists). For per-archetype looks: generalize `AnimationSystem_set_characters` + renderer to `LoadedCharacter*[]` selected via archetype.

## Phase 5 — Roguelike layer

23. **Perk choice between rooms (M/L)** — per-player run-level `PlayerPerks {bonusDamage, speedMult, bonusMaxHP}` in `BrawlerGameDelegate` (world rebuilt per room), applied at spawn via new `StatsComponent` consumed by CombatSystem (damage) and InputSystem (speed). `BrawlerGamePhaseUpgrade` appears between RoomClear and next room; each active player gets a sequential two-choice perk offer using seeded PRNG, while `+1 Team Life` remains shared because run lives are shared. Chosen via the PlayerSelect overlay pattern in all 3 platform GameViewControllers. Stat-math tests through Combat/Input + scenario cases.
24. **More rooms + variation (S after #19)** — 7–8 rooms mixing archetypes, shuffle middle rooms per run (seeded), boss last, per-room palette via #17. Watch spawn-slot capacity (6) and the 64-entity skinning cap.

---

## Execution order & dependencies

`0 → 1 (harness) → 10 → 11 → 12 → 13 → 14 → 15 → 16 → 17 → 19 → 20 → 23 → 24 → 21 → 18` (22 whenever the model arrives).

Highest impact-per-effort, front-loaded: shake wiring (near-zero cost), strong tint, harness (pays for itself immediately), knockback, combo, shadows + particles, swing/dodge SFX + haptics, boss charge. Deliberately last: radial-blur post pass and lava snakes (both L).

## Verification (per change, fully automated)

1. `xcodebuild test -scheme BrawlerLogicTests` — unit + scenario suites green (scenarios = full bot-driven games to Win/Lose with seeded determinism).
2. `scripts/smoke.sh` — build + `--autotest` run: bot plays to Win, exits 0, dumps beat screenshots to `/tmp/brawler-autotest/`; Claude reads the PNGs to verify visual changes.
3. CI runs xcodegen + 3-target build + logic/scenario tests on push.
4. Human-in-the-loop only for feel tuning (hit-stop strength, haptic patterns, audio mix) — flagged explicitly when a change touches those.
5. Commit and push after each working item (standing user preference).
