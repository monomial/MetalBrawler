# Room-Finish Drama + Exit Door + Projectile Enemies — Design

## A. Final-kill slow motion + camera zoom (TMNT-style)

When the killing blow lands on the **last enemy of a room's last wave** (including
the boss — whose death sweep already makes it the last), the game drops into slow
motion and the camera pushes in on the killer, then eases back.

- **Sim**: add `World::trigger_slow_motion(int ticks, float scale)` mirroring
  `trigger_hit_stop`: while active, `tick()` receives `gameDt = kFixedDt * scale`
  instead of kFixedDt (hit-stop still wins when both active). Expose
  `World::time_scale()` (1.0 when inactive). Trigger at the emission site in
  `Combat_apply_death`: after the death (and after the boss sweep), if
  `WaveSystem_room_finished(world)` and no other living non-dying enemy remains,
  call `trigger_slow_motion(kSlowMoTicks=216, kSlowMoScale=0.3)` (≈1.8s real
  time) and emit new event `FinalKill { killerID, victimID }`. Killer = the
  attacker; SpecialSystem death path passes the player as killer.
- **Camera**: delegate routes FinalKill → renderer `[beginFinalKillZoomAt:pos]`
  (killer's position). Renderer-side cosmetic animation over the same 1.8s
  (physical dt): ease eye/target 40% toward the killer position and reduce the
  camera distance ~35%, hold briefly, ease back during the final 0.5s. No sim
  impact, deterministic sim untouched.
- **Particles** during slow-mo: delegate passes `world.time_scale()` into the
  renderer each frame; renderer multiplies the ParticleSim update dt by it.
- RoomClear phase timers are wall-clock in the delegate — unchanged; the overlay
  may appear during the tail of the slow-mo, which is fine.

## B. Exit door (walk out to the next room)

After the perk choice, instead of instantly loading the next room, the player(s)
walk to a glowing exit on the top edge.

- `chooseUpgrade:` (last picker) now returns to **Playing in the same cleared
  room** and spawns an exit entity: `ExitComponent {}` + Position at
  (0, kRoomMaxY - 60). New tiny `ExitSystem` (after PickupSystem): any living
  player within 70 units → emit `ExitReached {}` once (then remove the exit so it
  can't double-fire).
- Delegate routes ExitReached → `_currentRoom++`, `_loadRoom`, Playing (the
  existing post-upgrade advance code moves here). Boss room is unaffected (Win
  fires directly; no upgrade/exit after the final room).
- Render: pulsing portal — a bright cyan flat quad (the hazard/heart early-
  continue pattern), ~70 units, plus a taller faint light pillar like the
  sky-drop markers. UI hint not needed; the glow reads.
- Life-loss reload: exits only exist post-upgrade; `_loadRoom` rebuilds the world
  so no stale exit survives. Verify.
- **AutoPilot**: when no living enemies and an ExitComponent entity exists, steer
  to it (priority below reviving a downed teammate, above idle).
- **EXISTING TESTS CHANGE**: ScenarioTests currently assert `chooseUpgrade:`
  advances `currentRoom` immediately (single and multiplayer cases). Update them:
  after the last pick, phase == Playing, same room, exit exists; bot walks out;
  THEN room advances. Full-run win tests just need the bot behavior + possibly
  +60s on timeouts (extra walking).

## C. Projectile enemies (Spitter archetype)

- **Archetype**: add `Spitter` to EnemyArchetypes.h:
  `{moveSpeed 120, stopRadius 350, attackCooldown 2.6, maxHP 2, scale 0.9,
  knockbackScale 1.2}` plus a new `bool ranged` field on the def (true only for
  Spitter; melee for everyone else). Spitters use the normal Attack clip as the
  throw animation, sky-drop spawn style, and the same wind-up telegraph.
- **Projectile**: `ProjectileComponent { float vx, vy; int damage = 1;
  float lifetime = 2.5f; }` (full registration). Spawned at the emission site in
  CombatSystem: when a **ranged** attacker's attack clip enters its active frame
  window (the existing hitApplied gate), instead of the melee arc check, spawn
  one projectile at the attacker aimed at the nearest living non-downed player,
  speed 420. Deterministic.
- **New ProjectileSystem** (after Knockback, before Physics): integrate position
  by vx,vy * gameDt; despawn on lifetime, on leaving RoomBounds, or on entering
  an ObstacleComponent AABB (pillars block shots — tactical cover). On overlap
  with a living non-downed player (radius 35, skip players with DodgeComponent —
  dodge i-frames — and respect DamageCooldownComponent like HazardSystem does):
  deal damage through the same player-damage path as hazards (second wind via
  `Combat_try_second_wind`, DamageDealt event, Hurt clip request), then despawn.
- **Render**: small pulsing orange-hot flat quad (~16 units, particle-like
  glow color {1.0, 0.6, 0.2}) via the early-continue pattern; delegate spawns a
  1-2 ember trail per frame like hazards (cheap, reuses spawnBurstAt).
- **Rooms**: add Spitters to the rotation — RusherPack gains a back-line Spitter
  in wave 2; HeavyEscort's wave 2 Grunt becomes a Spitter; boss reinforcement
  cycle gains one Spitter. Keep totals modest (kid-friendly readability).
- Audio: reuse playSwingSound on throw (already wired via AttackStarted? that's
  player-only — instead route nothing new; the wind-up telegraph carries it).

## Tests

- SlowMo: trigger_slow_motion scales tick gameDt (entity moves ~0.3x distance);
  expires; hit-stop takes precedence; FinalKill emitted only on the true last
  kill (not mid-wave, not when another enemy lives).
- Exit: spawns only after last pick; ExitReached fires once within radius; room
  advances; no exit in boss room.
- Projectiles: ranged attacker emits exactly one projectile per attack window;
  projectile travels deterministically; damages player + respects dodge i-frames
  and damage cooldown; second wind works; despawns on wall/obstacle/lifetime;
  pillars block.
- Update the two upgrade-flow ScenarioTests per section B; full-run wins stay
  green.
