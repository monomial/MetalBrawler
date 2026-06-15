# Smarter Enemy Steering + Bigger Staggered Waves — Design

Player feedback: enemies beeline and get stuck grinding into pillars; waves are
too small (~2) and land all at once. Fix with in-engine, DETERMINISTIC steering
(no GameplayKit — it would break our seeded headless determinism) and bigger,
staggered-drop waves. All changes must keep the existing gates green
(1P/2P AutoPilot full-run wins + the no-dodge-run-fails-to-win regression).

Current state (verified):
- `EnemyAISystem` chase is a pure beeline: `vel = (dir) * moveSpeed`. No
  obstacle avoidance, no separation. `WallCollisionSystem` then stops them at
  pillars → the "stuck on obstacle" bug. `point_blocked_by_obstacle(world,x,y)`
  already exists (used for Spitter aim lines) and can be reused.
- Waves: `emit_plan_markers` spawns every marker in a wave with the SAME
  `countdown = kMarkerTelegraph` → simultaneous landing. `tick_markers`
  converts each marker to an enemy when its countdown hits 0; the wave advances
  to Fighting when `marker_count == 0`. So per-marker staggered countdowns
  "just work" with the existing machinery.

================================================================================
## A. Obstacle-avoidance steering (EnemyAISystem)
================================================================================

Only changes the CHASE branch (the `else` that sets `vel = dir*moveSpeed`);
windup/stop branches unchanged. Deterministic (no RNG).

Compute the move direction as a blend of three steering vectors, then
`vel = normalize(blend) * moveSpeed`:

1. **Seek** = unit vector toward the player (the existing `dx/dist, dy/dist`).
   weight `kSeekWeight = 1.0`.
2. **Obstacle avoidance** `kAvoidWeight = 1.4`: for the nearest Obstacle
   component whose AABB (expanded by `kCharacterRadius=40 + kAvoidMargin=20`)
   the enemy would enter within a short lookahead (`kLookahead = 70` units along
   the seek dir), compute an avoidance push:
   - vector from obstacle center → enemy = `aw`; if the enemy is essentially
     on the line through the box, pick a deterministic side.
   - the two perpendiculars to the seek dir are `(-seekY, seekX)` and
     `(seekY, -seekX)`; choose the one whose dot with `aw` is larger (steer
     around the side the enemy is already on / toward open space), i.e. tangent
     around the box. That's the avoid vector (unit).
   - Only contributes when a box is actually in the lookahead path; otherwise 0
     (so open-field movement is unchanged → existing EnemyAI tests unaffected).
3. **Separation** `kSepWeight = 0.6`: sum of `(self - other)/dist` over other
   living enemies within `kSepRadius = 64`, normalized. Prevents stacking into
   one blob. Zero when no neighbors in range (open-field unchanged). Apply to
   all chasing enemies; skip bosses as the `other` source AND skip applying to
   bosses (they're huge and have their own BossSystem movement).

Blend: `dir = seek*kSeekWeight + avoid*kAvoidWeight + sep*kSepWeight`; if
`|dir| > 0` normalize and `vel = dir * moveSpeed` (preserve current speed); else
fall back to seek. Leave `stopRadius`, windup, Rusher/Run-clip logic as-is.

Note: Rushers/Heavies/Spitters/Leapers all run through EnemyAISystem chase, so
they all benefit. Leaper's own telegraph/leap states (LeaperSystem) are
untouched. Bosses (BossSystem) untouched.

================================================================================
## B. Bigger, staggered-drop waves
================================================================================

### Bigger rosters (BrawlerGameDelegate room data)
Bump combat-room waves to 3–6 enemies per wave (was ~2). Keep the intro gentle
(it ramps difficulty). Spread spawn positions across the top/middle, clear of
obstacle pillars and box positions, mostly **sky-drop** style so they "drop in."
`WaveControllerComponent.spawns[16]` caps total; keep ≤ ~6/wave × 2 waves.
Suggested per-room wave sizes (tune against the gate): intro 4 (2+2), early
middles 4–5, later middles 5–6, boss reinforcements unchanged. Don't exceed the
spawns[16] cap or the 64-entity skinning cap with concurrent enemies.

### Staggered landing (WaveSystem `emit_plan_markers` + reinforcements)
Markers still all appear at telegraph time (so the player SEES where everyone
will drop), but each gets a staggered countdown so they LAND at different times.

- For the wave's markers, assign `countdown = kMarkerTelegraph + group*kDropGap
  + jitter`, where:
  - `group = (indexInWave / kDropGroupSize)` with `kDropGroupSize = 2`
    (≈ 2 land, then 2 more, then 2 more).
  - `kDropGap = 0.55f` seconds between groups.
  - `jitter = world.rand_range(...)` mapped to ±0.08s (seeded → deterministic;
    keeps it from feeling mechanical). OK to omit jitter if it complicates the
    test — pick one and note it.
- The existing `tick_markers` already lands each marker on its own countdown and
  flips to Fighting when the last one is consumed — no state-machine change
  needed. Verify the inter-wave/Fighting transition still keys off
  `marker_count == 0` so a wave isn't considered "spawned" until the last
  staggered drop lands.
- Apply the same staggering to `emit_reinforcement_markers` (boss adds) so boss
  minions also trickle in.

================================================================================
## Gate + tests
================================================================================

- **Beatability is the arbiter.** 1P/2P AutoPilot full-run wins + the no-dodge
  regression MUST stay green. Bigger waves/smarter enemies raise difficulty; if
  a full run regresses, reduce wave SIZES (not enemy damage, not perks). The
  avoidance also helps the bot navigate, which offsets some of the added
  pressure.
- Tests:
  - Avoidance: enemy with a pillar directly between it and the player gains a
    perpendicular velocity component (doesn't drive straight into the box) and,
    over N ticks, ends up closer to the player than a beeline would leave it
    stuck. Open-field enemy (no obstacle) velocity == pure seek (unchanged).
  - Separation: two near-coincident enemies acquire opposing velocity
    components; a lone enemy is unaffected.
  - Staggered waves: a wave of N≥4 produces markers with ≥2 distinct countdown
    values; enemies land at staggered ticks; phase→Fighting only after the last
    lands; total spawned == roster size.
  - All existing tests stay green (268 now); update any EnemyAI test that
    assumed exact beeline velocity ONLY if obstacles/neighbors are present in
    that test (open-field ones should be unaffected by design).
- Supervisor runs the full gate (tests + smoke + iOS/tvOS) on a CLEAN build
  (incremental builds have masked new tests before).
