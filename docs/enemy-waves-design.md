# Enemy Waves — Design

## Goals

1. Rooms open with a calm beat: a short delay before any enemy appears, giving the
   player time to read the room (pillars, space) and plan.
2. Every combat room plays out in **at least two waves** of enemies.
3. Telegraphed spawns: a ground **marker** appears where each enemy will arrive,
   about a second before it does — spawns are never a surprise hit.
4. Arrival is physical: enemies either **rise out of the ground** (heavy things) or
   **drop from the sky** (fast things), and are inert/invulnerable until they land.
5. The **boss room** sends reinforcement waves for as long as the boss lives; when
   the boss dies, every remaining enemy dies with it and pending waves cancel.

## Tuning constants

| Constant | Value | Meaning |
|---|---|---|
| kInitialWaveDelay | 1.5 s | room start → first markers |
| kMarkerTelegraph | 1.0 s | marker visible → enemy arrives |
| kInterWaveDelay | 0.8 s | last enemy of a wave dies → next markers |
| kSpawnAnimDuration | 0.6 s | rise/drop animation; inert + invulnerable |
| kBossReinforceInterval | 9.0 s | boss room: pause between reinforcement waves |
| kBossMinionCap | 3 | no reinforcements while ≥ this many minions live |

Wave sizes run 2–4 enemies (intro room ramps 1 → 2).

## Simulation model (all deterministic, sim-side — headless-testable)

### Components (full registration pattern)

- `WaveControllerComponent` — one singleton entity per room, created at room load.
  Embeds the entire room plan so no delegate callback is needed mid-room:
  `{ PendingSpawn spawns[16]; int spawnCount; int waveCount; int currentWave;
     float timer; uint8_t phase (InitialDelay / Telegraph / Fighting / Done);
     bool bossMode; PendingSpawn reinforcements[8]; int reinforceCount; }`
  where `PendingSpawn = { uint8_t archetype; uint8_t wave; float x, y; }`.
- `SpawnMarkerComponent { uint8_t archetype; float countdown; uint8_t style; }` —
  marker entity (Position + this; no faction, no animation).
- `SpawnAnimComponent { float progress; uint8_t style; }` — on a just-spawned enemy
  for its first 0.6 s. style: 0 = ground-rise, 1 = sky-drop.

### Style rule

Heavy and Boss rise from the ground; Grunt and Rusher drop from the sky.
(Deterministic by archetype — no RNG needed.)

### New system: WaveSystem (ticks after PickupSystem, before AnimationSystem)

State machine on the controller:
- **InitialDelay**: timer counts down kInitialWaveDelay → emit markers for wave 0.
- **Telegraph**: markers count down; at zero each marker is replaced by its enemy
  (spawned via the shared `Enemy_spawn` helper) wearing a `SpawnAnimComponent`;
  controller → Fighting. Emits `WaveStarted { waveIndex }` when markers appear.
- **Fighting**: when no living (non-dying) enemies remain and waves remain →
  kInterWaveDelay, then Telegraph for the next wave. When no waves remain →
  Done (non-boss) or reinforcement loop (boss mode).
- **Boss mode**: after the boss wave is out, every kBossReinforceInterval seconds,
  if the boss is alive and fewer than kBossMinionCap minions live, telegraph the
  next reinforcement wave (cycling the reinforcement list, 2 per wave).

`SpawnAnimComponent` ticks here too: progress → 1 over 0.6 s, then removed.
While present the enemy is skipped by EnemyAISystem (no moving/attacking), by
CombatSystem/SpecialSystem as a target, and deals no contact damage.

### Enemy construction helper

`_spawnEnemiesForCurrentRoom`'s per-archetype component assembly moves to a shared
sim helper `Enemy_spawn(World&, uint8_t archetype, float x, float y)` so WaveSystem
and the delegate build identical enemies.

### Boss death sweep

At the emission site (`Combat_apply_death`): if the victim has `BossTagComponent`,
apply death to every other living enemy-faction entity (no heart drops from the
sweep) and force the wave controller to Done. (Emission-site logic, not event
consumption — events accumulate per frame and must not be consumed per tick.)

### Room-clear condition

Delegate's `_allEnemiesDefeated` gains "… and the wave controller is Done and no
markers remain", via a small sim query `WaveSystem_room_finished(World&)`.

## Room definitions

`EnemySpawn` gains a `wave` field. Existing rooms split/extend:

| Room | Wave 0 | Wave 1 |
|---|---|---|
| Intro | 1 Grunt | 2 Grunts |
| GruntsRusher | 2 Grunts | Grunt + Rusher |
| RusherPack | 2 Rushers | 2 Rushers |
| HeavyEscort | 2 Grunts | Heavy + Grunt |
| Mixed | 2 Rushers | Heavy + Grunt |
| TwinHeavies | Heavy | Heavy + Rusher |
| Boss | Boss | reinforcements: Grunt+Rusher cycle, every 9 s |

(Totals rise slightly; hearts and Second Wind absorb the difficulty bump.)

## Presentation

- **Marker**: flat pulsing quad on the floor (like hazard rendering): warm orange
  ring-ish square, ±20% sine pulse, plus a thin vertical light pillar for sky drops.
  Ember particles each frame (1–2, like hazard trails).
- **Ground rise**: model matrix offset from −character-height up to 0 over 0.6 s
  (eased), small dust burst (existing spawnBurstAt, palette-gray) on emergence.
- **Sky drop**: offset from +600 units down to 0 with accelerating fall; on landing,
  dust burst + tiny screen shake (4) + soft thud (existing hit haptic only —
  no new sounds; reuse playDodgeSound at landing for a soft whoosh).
- **Audio**: markers appear → playUIClickSound (quiet tick); wave fully landed →
  nothing (combat speaks for itself).

## Testing

New `WaveTests.mm`:
- no enemies exist before kInitialWaveDelay elapses; markers appear after it
- markers precede enemies by kMarkerTelegraph; enemy archetype matches its marker
- wave 1 does not telegraph until wave 0 is fully dead; kInterWaveDelay respected
- spawn-animating enemies are invulnerable, deal no damage, and don't move
- room_finished only after all waves dead (and false between waves)
- boss mode: reinforcements arrive while boss alive, respect the minion cap,
  stop when boss dies; boss death kills all minions and cancels markers
- determinism: same seed → identical wave timeline

ScenarioTests: full-run timeouts extended if needed (waves add ~5 s per room).
AutoPilot already stands still with no enemies (verified) — no bot change expected.

## Risks

- 64-slot bone buffer: concurrent entities stay well under 64 (≤4 enemies + markers
  without AnimationComponents).
- Smoke timing: the win-timeout in BrawlerAutoTest may need a bump (waves lengthen
  runs by ~30–40 s total).
- Existing tests that spawn enemies directly (most do) bypass waves entirely —
  unaffected. ScenarioTests go through rooms and WILL feel the new pacing.
