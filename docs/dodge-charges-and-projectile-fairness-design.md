# Dodge Charge System + Projectile Fairness — Design

Player feedback: homing projectiles are too punishing — they home for too long,
don't expire fast enough, hit too hard (died in ~2 hits), and are too fast to
escape; meanwhile the dodge is weak/one-at-a-time so dodging doesn't feel like a
real answer. Fix both together: make ranged attacks fair-but-threatening, and
turn dodge into a satisfying chargeable tool. All deterministic; the existing
beatability gates (1P/2P full-run win + no-dodge-run-fails-to-win) must stay
green.

================================================================================
## PART A — Projectile fairness (mostly constants + a short homing window)
================================================================================

Today (CombatSystem `spawn_projectile_at_target`): straight Spitter shots deal
`curse_damage(damage + 2)` (= 3 base), home at ~3.2 rad/s for the FULL 2.5s
lifetime, at speed 420×difficulty. That's why they feel inescapable.

Changes:
- **Damage**: `curse_damage(damage + 2)` → `curse_damage(damage)` (= 1 base, same
  as a melee jab; still curse-scaled). Tunable up to +1 later if too weak after
  the dodge buff lands.
- **Lifetime**: shorter so they disappear. `ProjectileComponent.lifetime` default
  2.5 → **1.3s** (set explicitly at spawn). They self-destruct quickly.
- **Homing window, not lifelong homing** (the key fix): add
  `float homingTime` to `ProjectileComponent`. Set at spawn to
  `kProjectileHomingWindow = 0.45f`. In `ProjectileSystem`, only apply the
  homing steer while `homingTime > 0` (decrement by gameDt each tick); after it
  expires the shot flies STRAIGHT. So it curves toward you briefly, then commits
  — a deliberate sidestep/dodge after the window cleanly escapes.
- **Speed**: `kProjectileSpeed` 420 → **340** so you can out-position it.
- Keep the difficulty/curse scaling hooks; just smaller base numbers.
- Update the telegraph aim-line length cap (EnemyAISystem uses
  `speed*lifetime`) to the new numbers so the line stays honest.

Net: a Spitter shot now leans toward you for ~0.45s, then locks in; it's slower,
lighter, and gone in 1.3s. Threatening, clearly dodgeable.

================================================================================
## PART B — Dodge charge system (the redesign)
================================================================================

Replace the single clip-length dodge with a stamina pool: short dodges, chain
while held, limited charges that regenerate, variable length, upgradeable.

### Components
- New `DodgeChargesComponent { int charges; int maxCharges; float regenTimer; }`
  on every player (full registration). At spawn: `maxCharges = kBaseDodgeCharges
  (2) + perk/meta bonuses`; `charges = maxCharges`; `regenTimer = 0`.
- Extend `DodgeComponent` with `float elapsed = 0.f` (drives variable length).
  Keep `active/velX/velY`.

### Constants (all named for easy tuning)
- `kBaseDodgeCharges = 2`
- `kDodgeMinDuration = 0.15f` (a tap still gives a real i-frame hop)
- `kDodgeMaxDuration = 0.40f`
- `kDodgeRegenPerCharge = 1.5f` (seconds to recover one charge)
- `kDodgeSpeed` = keep 650 (tune later)

### Starting a dodge (InputSystem)
Replace the current `canDodge` request. A dodge STARTS when:
`input.dodge` is pressed AND not currently dodging AND state is Idle/Walk AND
`charges > 0`. On start: decrement `charges`, request the Dodge clip (DodgeSystem
arms the rest). If `charges == 0`, dodge does nothing (optionally emit a
`DodgeFizzle` event later for a UI cue — skip for v1).

### Active dodge + chaining + variable length (DodgeSystem)
DodgeSystem now reads `current_input` (to detect hold/release) and owns:
1. **Regen** (every player with DodgeChargesComponent): if `charges < maxCharges`,
   `regenTimer -= gameDt`; when `≤ 0`, `charges++`,
   `regenTimer = kDodgeRegenPerCharge * stats.dodgeCooldownMult` (perk makes
   regen faster). Don't regen while a dodge is active (optional; simpler to
   always regen — pick one and note it).
2. **Roll motion**: as today, velocity = stored dir × kDodgeSpeed, decelerating
   over `kDodgeMaxDuration` (use `dodge.elapsed`, not clip time). i-frames =
   `DodgeComponent` present (unchanged — other systems already skip damage on
   dodging players).
3. **End conditions** (`dodge.elapsed += gameDt`):
   - `elapsed >= kDodgeMaxDuration` → end, OR
   - `elapsed >= kDodgeMinDuration && !input.dodge` → end early (released).
4. **On end**: if `input.dodge` STILL held AND `charges > 0` → **chain**:
   decrement a charge, reset `elapsed = 0`, re-capture direction from current
   facing/move input, continue dodging (no Idle in between). Else: remove
   `DodgeComponent`, zero velocity, return to Idle/Walk.

i-frames are therefore per-charge: each chained dodge costs one charge and grants
its own window, so holding the button burns through your 2 charges then stops.

### Upgrades
- **Perk "Evasion" (+1 max dodge charge)**: append to the BrawlerPerk enum
  (Common or Rare) with `_applyPerk` doing `perks.bonusDodgeCharges += 1`; seed
  into `DodgeChargesComponent.maxCharges` at spawn (via StatsComponent or a new
  PlayerPerks field). 
- **Repurpose existing "Quick Dodge"** (`dodgeCooldownMult`): now multiplies
  `kDodgeRegenPerCharge` (lower = faster regen). Already plumbed through
  StatsComponent; just change where it's read.
- (Meta-shop "Reflexes" +1 starting charge is a natural future add; OUT OF SCOPE
  for this batch unless trivial.)

### HUD
Draw the dodge charges as small pips near the player HUD (mirror the
special-meter / hearts pip pattern). Renderer property for current/max dodge
charges, set each frame by the delegate. Dim spent pips; show regen.

### AutoPilot
The bot dodges threats (boss attacks, incoming projectiles, leaper telegraphs).
Update it to only dodge when `DodgeChargesComponent.charges > 0` (models a player
who's out of stamina). Keep dodges purposeful so it doesn't burn charges
needlessly.

================================================================================
## Gate + tests
================================================================================

- **Beatability gates MUST stay green.** The no-dodge regression DISABLES dodge
  entirely, so charges don't affect it — but the projectile nerf slightly eases a
  no-dodge run. If `no-dodge` starts WINNING, the lever is boss
  survivability/damage (bosses are the dodge-or-die differentiator), NOT
  re-buffing projectiles. The dodging bot now has limited charges; if it starts
  LOSING, tune regen/charges or make its dodging more selective — don't weaken
  enemies.
- Tests:
  - Projectile: homing applies only during `homingTime` then flies straight;
    `homingTime`/lifetime decrement; shorter lifetime expires; damage = base
    (curse-scaled); slower speed.
  - Dodge charges: start at `kBaseDodgeCharges`; a dodge consumes one; can't
    dodge at 0; regen restores one after `kDodgeRegenPerCharge`; Quick Dodge
    speeds regen; Evasion perk raises max by 1.
  - Variable length: release after min ends the dodge early; holding to max ends
    at max.
  - Chaining: holding dodge with 2 charges performs exactly 2 consecutive dodges
    then stops (charges exhausted).
  - i-frames: a dodging player takes no damage from a projectile/enemy hit.
  - All existing tests stay green (274 now); update any dodge test that assumed
    clip-length duration / no charge system.
- Supervisor runs the full gate on a CLEAN build (tests + smoke + iOS/tvOS).

These are all FEEL constants — expect to tune `kDodgeMinDuration`/`MaxDuration`,
`kDodgeRegenPerCharge`, charge count, and the projectile lifetime/homing
window/speed/damage after hands-on play.
