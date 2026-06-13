# Progressive Difficulty + Twin-Boss Finale — Design

Goal: the game is too easy. Make it significantly and PROGRESSIVELY harder
across the run (early rooms stay gentle, late rooms are mean) while keeping
every attack telegraphed — faster/more frequent, never unannounced. Add a new
final room with TWO bosses. Run grows 7 → 8 rooms:
intro, fight, fight, shop, fight, fight, boss, TWIN BOSS.

## A. Difficulty scalar (sim-side, deterministic)

- `World::set_difficulty(int level)` + `int difficulty() const` — plain int on
  World exactly like the scrap mirror (NOT a component). Delegate calls
  `_world.set_difficulty(_currentRoom)` in `_loadRoom` (0-based room index;
  shop room harmlessly gets a level, it has no enemies).
- All scaling formulas live in one new header
  `BrawlerEngine/Simulation/Difficulty.h` as constexpr-style inline helpers so
  tuning is one file:
  - `Difficulty_cooldown_mult(level)`  = max(0.45f, 1.f − 0.07f·level)
  - `Difficulty_speed_mult(level)`     = min(1.25f, 1.f + 0.03f·level)
  - `Difficulty_projectile_mult(level)`= min(1.30f, 1.f + 0.035f·level)
  - `Difficulty_leaper_telegraph(level)` = max(0.55f, 0.9f − 0.045f·level)
  - `Difficulty_leap_duration(level)`  = max(0.30f, 0.40f − 0.015f·level)
  - `Difficulty_reinforce_mult(level)` = max(0.60f, 1.f − 0.05f·level)
- Apply at the existing read sites:
  - EnemyAISystem: `cooldown = def.attackCooldown * Difficulty_cooldown_mult`
    (Spitters throw more often; Grunt/Rusher/Heavy punch more often) and
    `moveSpeed = def.moveSpeed * Difficulty_speed_mult`. Wind-up stays 0.35s —
    the telegraph is sacred.
  - CombatSystem projectile spawn: speed = 420 * Difficulty_projectile_mult.
    (Aim-line length cap should use the same scaled speed × 2.5 lifetime.)
  - LeaperSystem: telegraph duration = Difficulty_leaper_telegraph; leap
    duration = Difficulty_leap_duration (faster jump); Walk cooldown =
    def.attackCooldown (4.0) * Difficulty_cooldown_mult. Minimums above keep
    every leap clearly telegraphed (≥0.55s line).
  - WaveSystem boss reinforcements: interval = kBossReinforceInterval *
    Difficulty_reinforce_mult.
- HP is deliberately NOT scaled — pressure comes from tempo and numbers, not
  sponginess (kid readability).

## B. Bigger wave rosters (fixed data, BrawlerGameDelegate.mm)

Modest bumps so early rooms still read easy and late rooms feel crowded:
- kIntroSpawns: 3 grunts → 4 grunts split over 2 waves (waves 0,0 / 1,1).
  Still the easiest room.
- kMidGruntsRusher: +1 Spitter wave 2.
- kMidRusherPack: +1 Rusher wave 1, +1 Leaper wave 2.
- kMidHeavyEscort: +1 Spitter wave 2.
- kMidMixed: +1 Leaper wave 2.
- kMidTwinHeavies: +1 Spitter wave 2.
- Boss room: kBossMinionCap 3 → 4.
Update each RoomDef count. Keep spawn positions clear of obstacles (check the
rooms with pillars) and away from box positions.

## C. Twin-boss finale (new room 8, the new final room)

- `kFinalSpawns`: two Boss-archetype spawns, wave 0, at (−220, 350) and
  (220, 350). EnemyFactory already attaches BossTag + BossCharge for the Boss
  archetype, so both charge and enrage independently (existing per-entity
  enrage at half HP just works).
- `kFinalRoom` RoomDef: the two bosses, no obstacles, 2 boxes, reinforcements
  same as the existing boss room (cap 3 here).
- Room mapping (`_currentRoomDef`): 0 intro, 3 shop, kNumRooms−1 final (twin),
  kNumRooms−2 boss, everything else middles. kNumRooms 7 → 8. The single-boss
  room is no longer final: after clearing it the normal RoomClear → upgrade →
  exit-arrow flow must happen (verify nothing special-cases "boss room ==
  last"; Win must fire only after the twin room).
- **CRITICAL — boss death sweep** (CombatHelpers.mm ~line 160): currently ANY
  BossTag death sweeps all living enemies + forces wave done. With two bosses
  the first kill would delete the second boss. Change: on a boss death, sweep
  ONLY if no OTHER living BossTag entity remains (alive = present, not dying —
  reuse is_living_enemy_for_sweep plus a BossTag check). First boss death =
  nothing special; last boss death = sweep + slow-mo final kill as today.
- Renderer/HUD: ROOM n/8 follows automatically; final room gets the last
  palette via the existing paletteIndex logic (and room 7 falls back to the
  cycle — fine).

## D. Beatability gate

AutoPilot full-run ScenarioTests and scripts/smoke.sh remain the arbiter. If
the 1P or 2P full-run win test fails (timeout or lives out), do NOT modify
AutoPilot; instead soften in this order and re-run: (1) twin boss
reinforcement cap 3 → 2, (2) Difficulty_cooldown_mult floor 0.45 → 0.55,
(3) drop one added spawn from the two hardest middle rooms. Full-run test
timeouts: +90s (extra room with two 12-HP bosses).

## Tests

- Difficulty helpers: exact values at level 0 (all 1.0 / base), level 4, and
  the clamp floor/ceiling at high level.
- EnemyAI cooldown + Leaper telegraph/leap durations respond to
  world.set_difficulty; telegraph never below 0.55s at any level.
- Projectile speed scales with difficulty.
- Twin boss: first boss death does NOT kill the other boss or force wave
  done; second boss death sweeps remaining minions + emits FinalKill + slow-mo.
- Room flow: single-boss room (index 6) now gets upgrade + exit; Win fires
  only after the twin room (index 7); full runs are 8 rooms.
- EXISTING TESTS: everything updated for 7 rooms last batch moves to 8
  (ScenarioTests room asserts, clears/upgrades counts, timeouts +90s).
