# Lobbed Lava Projectiles + Expanded Boss Move-Set — Design

Goal: make bosses much more dangerous and add a new readable hazard. Two
threads, one batch.

Existing primitives to reuse (do NOT reinvent):
- `HazardComponent { radius, damage, lifetime }` + `HazardSystem` already do
  area damage + lifetime despawn + per-victim rehit (0.8s) + dodge i-frames +
  damage-cooldown respect + second wind. A hazard WITHOUT a
  `PathFollowComponent` stays stationary (HazardSystem only moves it if a path
  is present). A lava pool == a stationary HazardComponent. Renderer already
  draws hazards as a molten floor quad; delegate already emits an ember trail
  per hazard per frame.
- `BossChargeComponent` + `BossSystem` drive the charge state machine and
  already spawn lava snakes on slam. We EXTEND this into a multi-ability picker.
- Difficulty.h scalar (= room index) is mirrored on World; reuse it.

TELEGRAPHS ARE SACRED (user reaffirmed): every new attack must show a clear
ground indicator before it can hurt. Lobs telegraph via a landing-target ring
that is visible for the whole flight; boss leaps telegraph via a wide ground
line like the Leaper; charge keeps its 0.7s wind-up.

---

## A. Lobbed lava projectile + lava pool (the headline mechanic)

A mortar-style shot that arcs to a fixed ground point and bursts into a lava
pool. The arc + landing ring are the telegraph; the pool is the threat. No
mid-air contact damage (keeps it fair and clearly dodgeable).

- **Component** (full registration per docs/codex-rules.md rule 3):
  `LavaLobComponent { float startX, startY, destX, destY; float elapsed;
   float duration = 1.1f; int poolDamage = 1; float poolRadius = 80.f;
   float poolLifetime = 3.5f; }`. Cosmetic-flat entity: Position only, NO
  AnimationComponent (rule 8). Renderer special-cases it (rule 10).
- **Spawn helper** (put in HazardSystem.h/.mm next to spawn_snake):
  `EntityID HazardSystem_spawn_lava_lob(World&, float sx, float sy, float dx,
   float dy, int poolDamage, float poolRadius, float poolLifetime)`. Clamp
  dest into RoomBounds inset 40. Creates the entity with Position={sx,sy,0} and
  a LavaLobComponent.
- **New `LavaLobSystem`** (.h/.mm; new files → xcodegen + pbxproj), ticked in
  World::tick() immediately AFTER ProjectileSystem_update:
  - `elapsed += gameDt`; `t = clamp(elapsed/duration, 0, 1)`.
  - position = lerp(start, dest, t) (x,y only; the visual z-arc is renderer-
    side from t, sim stays 2D).
  - On `t >= 1` (landing): spawn a STATIONARY hazard — create entity, add
    Position={destX,destY,0}, add HazardComponent{poolRadius, poolDamage,
    poolLifetime} (NO PathFollowComponent → it stays put). Emit a new event
    `LavaPoolSpawned { float x, y }`. `defer_destroy` the lob.
  - No damage while airborne. (Determinism: pure arithmetic, no RNG.)
- **Renderer**:
  - The lob itself: glowing orb quad at arc height. Compute
    `t = clamp(lob.elapsed/lob.duration,0,1)`; `z = 20.f + sinf(t*M_PI)*220.f`;
    draw ~18-unit quad color {1.0, 0.55, 0.12} at (pos.x,pos.y,z), pulsing.
    Early-continue.
  - Landing telegraph ring at dest the whole flight: a pulsing hollow-looking
    ring — simplest is two concentric flat quads at z≈2 at (destX,destY): outer
    ~poolRadius*2 in warning orange-red {1.0,0.3,0.1, ~0.4 pulsing}, inner
    darker, so it reads as a target. (No need for a true ring mesh; concentric
    quads match the spawn-marker pattern already in the renderer.)
  - The resulting pool reuses the existing hazard draw automatically.
- **Delegate routing**: `LavaPoolSpawned` → a chunky lava burst via
  spawnBurstAt (count ~24, warm orange) + playFinisherSound-or-swing (reuse an
  existing SFX; no new asset) + a small screen shake is already triggered
  sim-side? No — add `ScreenShakeSystem_trigger(world, 14.f)` at the landing
  site in LavaLobSystem so it's deterministic. Also keep the existing per-frame
  ember trail loop over hazards (the pool gets embers for free).

## B. Spitters occasionally lob (difficulty-gated)

Early Spitters stay simple straight-shooters (the dodge-sideways lesson). Late
Spitters mix in a lob so positioning matters.

- In CombatSystem `spawn_projectile_at_target` ranged branch: keep a
  deterministic per-attacker shot counter. Add `uint8_t shotCounter` to
  EnemyArchetypeComponent? No — simpler: add `uint8_t rangedShotCounter` to a
  small existing per-enemy component. The cleanest deterministic source: add
  `uint8_t shotCount` to `TelegraphLineComponent`? No. Use the existing
  `EnemyAttackCooldownComponent` — add `uint8_t shotCount = 0` field to it
  (it's already per-enemy and present on every attacker). Increment on each
  ranged fire.
- Decision: lob instead of straight-fire when
  `world.difficulty() >= 3 && (shotCount % 3 == 2)` (every 3rd shot, only from
  room index 3+). When lobbing, call HazardSystem_spawn_lava_lob aimed at the
  nearest living player's CURRENT position (pool smaller for spitters:
  radius 64, lifetime 2.5, damage 1), and DO consume the telegraph line as
  usual. Otherwise the existing straight shot. The aim-line telegraph still
  shows for straight shots; for lobs the landing ring is the telegraph (the
  straight aim line is misleading for a lob, so when lobbing, remove the
  TelegraphLineComponent without drawing the straight line — i.e. skip adding
  the straight aim line in EnemyAISystem when the upcoming shot will be a lob;
  if that coupling is awkward, acceptable fallback: still add the line but the
  landing ring dominates — pick the cleaner one and note it).

## C. Expanded boss move-set (charge + lob volley + leap)

Generalize the boss from charge-only into a 3-ability picker. Keep the
`BossChargeComponent` name to limit churn; add fields:
- `uint8_t ability = 0;       // 0 Charge, 1 LobVolley, 2 Leap`
- `uint8_t abilityCounter = 0;// rotates deterministically`
- `float destX, destY, startX, startY; // for Leap arc`
- `float leapDuration = 0.45f;`
State enum: add `Leap = 4` alongside Idle/Telegraph/Charge/Recover.

Ability selection (deterministic, NO RNG) at Idle→Telegraph:
`ability = kBossPattern[abilityCounter % kBossPatternLen]; abilityCounter++;`
with `kBossPattern = {Charge, LobVolley, Charge, Leap}` (len 4). Enrage does
NOT change the pattern, only speeds timers and beefs each ability (below).

Per-ability behavior:
- **Charge**: exactly today's behavior (telegraph stare + dir lock → charge →
  slam spawns snakes → recover). Unchanged.
- **LobVolley**: Telegraph = boss plants, faces nearest player, plays Idle, for
  `kBossLobTelegraph = 0.6f` (enraged 0.4f). On telegraph end: throw N lobs via
  HazardSystem_spawn_lava_lob at living players — N = 2 (enraged 3). Aim each
  lob at a distinct living player if multiple, else spread around the single
  player by ±90 units. Boss pool: radius 90, lifetime 3.5, damage 1. Then go
  straight to Recover (timer kRecoverTime). The lobs' landing rings telegraph.
- **Leap**: Telegraph = boss plants for `kBossLeapTelegraph = 0.7f` (enraged
  0.5f, floor 0.55f overall via max) and adds a wide `TelegraphLineComponent`
  (width 90) from boss to a chosen dest. Dest = toward nearest player, length
  min(dist+80, 520), clamped to bounds inset 60 (reuse the Leaper's clamp
  approach; landing need NOT avoid obstacles — boss is huge, keep simple but DO
  clamp to bounds). On telegraph end → Leap state: arc boss start→dest over
  leapDuration (smoothstep; set position directly, zero velocity, like
  LeaperSystem); on landing: AoE damage radius 120 (damage 2, hit-stop 6, shake
  26, respect dodge/cooldown/second-wind like the charge body-slam) AND spawn a
  stationary lava pool at dest (radius 100, lifetime 3.0, damage 1) so the
  landing zone stays hot; remove the telegraph line; → Recover.

Boss cadence: scale the Idle cooldown by difficulty so later bosses act more
often: `kChargeCooldown * Difficulty_cooldown_mult(world.difficulty())` (and
keep the existing enrage multiplier). Telegraph times keep their floors.

Renderer: boss leap z-hop — bosses in Leap state get
`zOffset += sinf(t*M_PI)*150.f` (t from leapDuration), mirroring the Leaper hop
block. The wide telegraph line draws via the existing TelegraphLineComponent
pass for free.

## D. Twin-boss balance + beatability gate

Two bosses with the full move-set is the intended hard finale. The headless
AutoPilot full-run ScenarioTests (1P + 2P) + scripts/smoke.sh remain the
arbiter — they MUST stay green.

**Allowed, bounded AutoPilot change** (exception to the usual "never touch
AutoPilot"): a new mechanic the bot can't perceive makes it a bad player-proxy,
which would force us to over-soften for humans. So teach AutoPilot ONLY to
avoid standing hazards: when steering, if the next step would land within
(HazardComponent.radius + 30) of any hazard, OR within a pending lob's landing
ring (LavaLobComponent.destX/destY + poolRadius + 30), steer away from the
nearest such center instead. Keep it minimal — pure avoidance vector added to
the existing chase target, no new combat logic. This models a competent player
dodging lava; it is NOT making the bot stronger at fighting.

If full runs STILL fail after that, soften difficulty in this order, never the
mechanic's readability: (1) boss LobVolley N 3→2 / 2→1; (2) pool lifetimes
−1.0s; (3) Leap AoE radius 120→95 and Leap pool radius 100→80; (4) twin-boss
only: gate so the two bosses can't be in a non-Charge ability simultaneously
(if one is in LobVolley/Leap Telegraph/Active, the other falls back to Charge
this cycle); (5) boss Idle cooldown floor up. Full-run test timeouts: +60s.

## Tests (BrawlerLogicTests)

- LavaLob: arcs start→dest deterministically; no damage airborne; on landing
  creates a stationary HazardComponent at dest (no PathFollowComponent) and
  LavaPoolSpawned fires once; lob despawns; the pool damages a player standing
  in it (respects rehit/dodge/second-wind via existing HazardSystem) and
  despawns after poolLifetime.
- Spitter lob gating: difficulty < 3 → straight shot (ProjectileComponent
  spawned, no lob); difficulty ≥ 3, 3rd shot → a LavaLob spawned, no straight
  projectile that shot.
- Boss move-set: ability rotates deterministically through the pattern;
  LobVolley spawns N lobs; Leap moves the boss to dest and spawns a pool +
  applies AoE; Charge still spawns snakes. Enrage raises lob count and shortens
  telegraphs (but telegraph ≥ floor).
- Twin boss: both bosses pick abilities independently; one boss's death still
  does NOT sweep while the other lives (regression on last batch's fix).
- AutoPilot hazard avoidance: a bot adjacent to a hazard steps away from it.
- EXISTING: full-run 1P/2P win (the gate); update any boss test that assumed
  charge-only cadence; keep all current tests green (suite is 225 now).
