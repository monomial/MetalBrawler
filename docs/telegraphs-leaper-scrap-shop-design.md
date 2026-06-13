# Ground Telegraphs, Leaper Enemy, Scrap Economy, Shop Room — Design

Two implementation parts. Part 1 = sections A+B. Part 2 = sections C+D+E.

## A. Ground telegraph lines (shared infrastructure)

A flat line on the ground showing where an attack is about to go.

- **Component**: `TelegraphLineComponent { float x2, y2; float width; }` (full
  registration per docs/codex-rules.md rule 3). Lives ON the attacker entity;
  the line runs from the entity's current PositionComponent to (x2, y2).
  Removed by whoever fires the attack.
- **Render** (BrawlerRenderer.mm, early-continue flat-quad pattern): a flat
  quad stretched between the entity position and (x2,y2) at z≈2 (above floor,
  below the exit arrow's 2.5). Needs a small helper `make_model_line(x1,y1,
  x2,y2,width,z)` — translate to midpoint, rotate by atan2(y2-y1,x2-x1),
  scale (length, width). Color warm warning orange-red {1.0, 0.35, 0.15},
  alpha pulsing ~0.35–0.6 (CACurrentMediaTime, like the exit arrow pulse).
  NOTE: an entity with a TelegraphLineComponent is usually ALSO a skinned
  enemy — do NOT `continue` past the mesh draw; draw the line as an extra
  pass. Simplest: a separate small loop over `world->telegraph_lines()`
  before the entity loop, drawing one line per holder with a Position.

## B. Spitter aim line + Leaper enemy

### B1. Spitter projectile telegraph

- **Aim lock**: in EnemyAISystem, when a **ranged** enemy commits to an attack
  (the windup start — where EnemyAttackCooldownComponent.windup is set),
  compute the aim: direction from enemy to nearest living non-downed player,
  normalized. Add TelegraphLineComponent with width 18 and endpoint =
  enemy pos + dir * L, where L = march along dir in 20-unit steps until
  hitting an ObstacleComponent AABB or leaving RoomBounds, capped at 1050
  (= projectile speed 420 × lifetime 2.5). Store the locked dir — add
  `float aimX, aimY` to TelegraphLineComponent (derivable from endpoint −
  current pos, but the enemy may get knocked back during windup; using
  endpoint−pos at fire time is acceptable and simpler — pick one and test it).
- **Fire**: in CombatSystem's ranged branch (`spawn_projectile_at_target`),
  if the attacker has a TelegraphLineComponent, fire along the telegraph
  direction instead of re-aiming at the nearest player (the line must be
  honest), then remove the component. If knockback moved the spitter, the
  projectile still starts at the spitter's current position along the locked
  direction. Remove the telegraph too if the attack is interrupted (death —
  remove in Combat_apply_death; Hurt cancels the attack clip? check: if the
  attack clip is replaced before hitApplied, the telegraph would orphan —
  remove TelegraphLineComponent wherever the enemy's attack is cancelled).
- Telegraph duration ends up ≈ windup (0.35s) + attack-clip pre-hit frames —
  no timer needed; lifecycle is add-on-commit / remove-on-fire-or-cancel.

### B2. Leaper archetype

Slow walker that telegraphs a long jump along a wide ground line, then leaps,
damaging players it passes over.

- **Archetype**: `Leaper = 5` in EnemyArchetypes.h:
  `{moveSpeed 70, stopRadius 140, attackCooldown 4.0,
  maxHP 3, scale 1.05, knockbackScale 0.8, ranged false}`. Leapers never do
  the normal melee attack — EnemyAISystem skips attack initiation for them
  (check archetype); a new LeaperSystem owns their attack.
- **LeaperComponent** (full registration):
  `{ uint8_t state; float timer; float startX, startY, destX, destY; float cooldown; }`
  states: Walk=0, Telegraph=1, Leap=2, Recover=3. Added at spawn for Leaper-
  archetype enemies (where the delegate/WaveSystem builds enemies — same place
  archetype components are attached).
- **LeaperSystem** (new, ticked just BEFORE EnemyAISystem; enemies with a
  LeaperComponent in state != Walk are skipped by EnemyAI — gate the same way
  BossSystem-controlled entities are gated, or check the component directly):
  - **Walk**: normal EnemyAI chase handles movement (slow). LeaperSystem ticks
    `cooldown` down; when cooldown ≤ 0 and distance to nearest living
    non-downed player is within [120, 600], try to pick a leap destination:
    - dir = normalize(player − leaper); leapLen = min(dist + 80, kLeapMax 460)
      (slightly past the player so the leap crosses them).
    - Clamp dest into RoomBounds inset by 60 on all sides.
    - If dest (inflated by character radius 40) is inside any ObstacleComponent
      AABB, shorten leapLen in 40-unit steps until clear. **Leaping OVER an
      obstacle mid-path is allowed and encouraged** (it's a jump); only the
      LANDING spot must be clear.
    - If no valid leapLen ≥ kLeapMin 180, skip — retry in 0.5s.
    - On success: state=Telegraph, timer=0.9, store start/dest, zero velocity,
      add TelegraphLineComponent {dest, width 80}.
  - **Telegraph** (0.9s): stand still (velocity zero each tick — runs before
    EnemyAI but EnemyAI must not move it; gate EnemyAI on state != Walk).
    Request Attack clip near the end so the swing lands mid-flight.
  - **Leap** (0.40s): remove the TelegraphLineComponent; each tick set
    position by interpolating start→dest with smoothstep on t (write velocity
    so PhysicsSystem integrates, or set position directly + zero velocity —
    match how KnockbackSystem overrides; pick the existing pattern). Any
    living non-downed player within 55 units of the leaper takes 1 damage
    through the same path HazardSystem uses (DamageCooldownComponent respected,
    dodge i-frames respected, `Combat_try_second_wind`, DamageDealt event).
  - **Recover** (0.6s): stand still, then state=Walk, cooldown=attackCooldown.
  - Death during any state: Combat_apply_death already removes the entity;
    ensure the TelegraphLineComponent is removed there (same line as B1).
- **Render hop** (cosmetic, BrawlerRenderer.mm): entities in Leap state get a
  z offset of `sinf(t * π) * 130` (t = leap progress; read LeaperComponent —
  add a tiny accessor or compute t from timer). Mirrors the spawn-anim z-offset
  pattern.
- **Rooms**: add one Leaper to kMidGruntsRusher wave 2 and one to
  kMidTwinHeavies wave 1 (replace nothing; bump counts). Keep totals modest.
- **Spawn style**: ground-rise (same as Heavy).

### Part 1 tests (BrawlerLogicTests)

- Telegraph added on ranged windup commit with endpoint shortened by an
  obstacle in the path; removed after the projectile fires; projectile
  direction equals telegraph direction even if the player moved during windup.
- Telegraph removed when the spitter dies mid-windup.
- Leaper: full state cycle; destination clamped inside room bounds; landing
  spot shortened off an obstacle; leap crossing a player deals exactly 1
  damage (cooldown prevents double-hit); dodge i-frames avoid it; no leap
  attempted when cooldown is up but player is outside [200,600].
- Existing 208 tests stay green. Smoke/scenario runs must still win (Leapers
  added to two rooms — AutoPilot needs no changes; it already fights anything).

## C. Scrap currency + pickups (Part 2)

- Run-level `int _scrap` in BrawlerGameDelegate (like PlayerPerks), shared
  pool for all players, reset to 0 on new run (where perks reset). Persists
  across rooms and life-loss reloads.
- `ScrapPickupComponent { int value; float lifetime = 12.f; }` (full
  registration) + Position. Magnet behavior in PickupSystem (alongside
  hearts): if a living non-downed player is within 140 units, move the pickup
  toward the nearest such player at 600 u/s; within 40 units → emit new event
  `ScrapCollected { int value; }`, destroy. Lifetime expiry destroys silently.
- Delegate routes ScrapCollected → `_scrap += value`, plays heart-pickup
  sound (reuse), small golden particle burst.
- **Sources**: every broken scrap box (section D); enemies drop one pickup
  worth 2 with 35% chance via `world.rand_float01()` (in Combat_apply_death
  next to the heart drop; hearts and scrap can both drop).
- **HUD**: new renderer property `@property (nonatomic) int scrapCount;` drawn
  with the same text mechanism as the ROOM n/N label — "SCRAP 23" in warm
  gold, positioned near the room label. Delegate sets it each frame.
- Render pickup: small gold flat quad (~14 units, {1.0, 0.85, 0.25}), gentle
  bob (sin offset), early-continue pattern.

## D. Breakable boxes

- `BoxComponent { bool hasScrap; }` (full registration) + Position. No
  collision — boxes don't block movement.
- **Placement**: extend RoomDef with `const BoxSpawn* boxes; int boxCount;`
  where `BoxSpawn {float x, y; bool hasScrap;}`. Scatter 2–4 boxes per room
  near edges/corners (clear of spawn points and obstacles); roughly 60%
  hasScrap. Fixed per-room data like spawns. Boss room: 2 boxes. Spawned in
  _loadRoom.
- **Breaking**, either way works:
  - Player melee: in CombatSystem's player attack sweep, boxes within the
    same arc/range as enemies break (no damage numbers, just break).
  - Contact: any living non-downed player within 45 units (check in
    PickupSystem or a small BoxSystem) breaks it.
- **On break**: emit `BoxBroken { float x, y; uint8_t hadScrap; }`; if
  hasScrap spawn 3 ScrapPickups (value 2) at the box position with small
  deterministic offsets (world.rand_float01 spread ±30). Delegate routes
  BoxBroken → woody-brown particle burst + swing sound (reuse).
- Render: brown flat quad 50×50 {0.55, 0.38, 0.2} with a darker inner quad
  (two draws) so it reads as a crate, early-continue pattern. No
  AnimationComponent (rule 8).
- Enemy projectiles ignore boxes. Knockback-flying enemies ignore boxes.

## E. Shop room

One non-combat room mid-run where players spend scrap with a shopkeeper.

- **Room sequence**: currently intro + 4 shuffled middles + boss (6). Insert
  the shop as a fixed room AFTER the second middle room: intro, mid, mid,
  SHOP, mid, mid, boss = 7 rooms. Update kNumRooms, `_currentRoomDef`
  mapping, `totalRooms`, and the ROOM n/N HUD automatically follows.
- **RoomDef**: add `bool isShop` (default false). Shop def: no spawns, no
  obstacles, 3 boxes (one hasScrap) so the room isn't empty.
- **Flow**: on loading a shop room, spawn the exit entity immediately (reuse
  ExitComponent + arrow). The delegate's room-clear detection must NOT fire
  in a shop room (gate on isShop — no enemies ever spawn; without the gate it
  would instantly go RoomClear → upgrade overlay). ExitReached advances as
  usual. Life-loss reload of a shop room just reloads it.
- **Shopkeeper**: cosmetic entity at (0, 380): the ENEMY character mesh,
  Idle clip, with a friendly warm-gold tint. Renderer mesh selection is
  PlayerTag vs everything else, so it gets the enemy mesh for free; add a
  `ShopkeeperComponent {}` (full registration) checked in the renderer to
  override the tint color to {1.0, 0.8, 0.3} and skip enemy red-tint. It has
  an AnimationComponent (it's a real skinned character — allowed, it's not
  cosmetic-flat). No faction, no AI — nothing ticks it; verify EnemyAI/Combat
  iterate faction/archetype holders and skip it naturally.
- **Items**: 3 pedestals at (-250, 150), (0, 150), (250, 150):
  `ShopItemComponent { uint8_t perkID; int price; }` + Position. Perks =
  3 distinct picks from the existing 8-perk pool via world rand (seeded run
  → deterministic). Prices: 25, 25, 40 (the 40 on a randomly chosen slot).
  Pedestal render: small stone-gray quad + the perk-colored glow quad above.
- **Buying**: new ShopSystem (after PickupSystem): for each living non-downed
  player whose attack input is pressed this tick (edge — track prevAttack per
  item or reuse however InputSystem edges attacks) within 70 units of a
  pedestal: if delegate-owned scrap ≥ price… but scrap lives in the delegate,
  not the World. Solution: delegate mirrors scrap into the sim each frame via
  a setter `World::set_scrap(int)` + `World::scrap()` (plain int on World, not
  a component; deterministic input like player InputState). ShopSystem checks
  `world.scrap() >= price`, emits `ShopPurchase { uint8_t perkID; int price;
  uint32_t itemEID; }`, deducts via world.set_scrap (so two pedestals can't
  both fire the same frame), destroys the pedestal entity. Delegate routes
  ShopPurchase → `_scrap -= price`, applies the perk through the SAME path as
  the upgrade choice (all players, v1), celebratory burst + UI click sound.
  Insufficient scrap: emit nothing; optional: a `ShopDenied` event for a
  buzz— skip, keep it simple.
- **HUD prompt**: new renderer property `@property (nonatomic, copy)
  NSString* shopPrompt;` drawn at bottom-center with the room-label text
  mechanism. Delegate sets it each frame in shop rooms: nearest pedestal
  within 110 units → "PERK NAME — 25 SCRAP (PUNCH TO BUY)" using kPerkLabels;
  else "" (hidden). Empty elsewhere.
- **AutoPilot**: already steers to the exit when no enemies + exit exists —
  shop room works unchanged. It may punch pedestals while passing; purchases
  are harmless to scenario assertions (they assert phase/room/lives).

### Part 2 tests

- Scrap pickup magnetism + collection event value; lifetime expiry.
- Box breaks by melee arc and by contact; hasScrap spawns exactly 3 pickups;
  scrapless box spawns none; BoxBroken payload.
- Enemy death scrap drop respects 35% via seeded rand (assert deterministic
  for a fixed seed).
- ShopSystem: purchase deducts world scrap, destroys pedestal, emits payload;
  insufficient scrap is a no-op; two purchases same frame can't overspend.
- Shop room: loads with exit + shopkeeper + 3 pedestals, never enters
  RoomClear, ExitReached advances to room 4.
- **EXISTING TESTS**: anything asserting 6 rooms / room indices (ScenarioTests
  full-run wins, ROOM label, boss-room index) must be updated for 7 rooms;
  full-run timeouts +60s for the extra room.
