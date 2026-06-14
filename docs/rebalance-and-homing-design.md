# Rebalance for Difficulty + Homing Projectiles — Design

Player feedback: beat the game without dodging once; never saw lava lobs;
enemies die too fast; upgrades are overpowered (should be incremental, not
drastic). Goal: make dodging NECESSARY to win, let enemies live long enough to
telegraph + attack (so lobs/leaps actually happen), make perks incremental, and
add homing projectiles. Everything deterministic + gated by the headless tests.

Root cause: base punch = 1 dmg (Attack window), enemies have 2–3 HP, so any
+damage perk one-shots them; Epic perks (360° Whirlwind, lifesteal sustain)
trivialize positioning; and AutoPilot only dodges boss threats, so a
no-dodge run can win. Fix all four.

---

## A. Make upgrades incremental (rein in player power)

In `_applyPerk` (BrawlerGameDelegate.mm) reduce magnitudes:
- Speed: `+0.2` → `+0.1` (20%/stack was huge).
- SpecialCharge: `*... +0.5` → `+0.25`.
- Knockback: `*1.3` → `*1.2`.
- Toughness (Rare): `+6` → `+4` maxHP.
- HeavyHitter (Rare): `+2` → `+1` damage (so even the damage rare is
  incremental; rarity value comes from frequency, not power spikes).
- Lifesteal (Rare): heal every `6` → every `10` hits.
- Vampire (Epic): lifesteal every `3` → every `6` hits; drop the `+1` damage
  (sustain only).
- Adrenaline (Epic): passive special `0.06/s` → `0.03/s` (SpecialSystem const).
- **Whirlwind (Epic): remove the full-360°.** Keep the enum/label but change the
  effect from "360° + range" to a MODEST arc widen + small range: in
  CombatSystem, when `stats.whirlwind`, relax the arc cosine from kPunchArcCosine
  (~cos70°) to ~cos110° (still must roughly face the foe — not omnidirectional)
  and `+15` range (was +25). Positioning still matters.
- Damage (Common +1), MaxHP (+3), Life, QuickDodge (*0.7), SecondWind, Thorns:
  unchanged (already incremental).

Charged heavy attack (CombatSystem): it currently clears groups for 3+bonus.
Tone down: `kHeavyBaseDamage 3 → 2`, `kHeavyRadius 150 → 130`. Still a worthwhile
wind-up payoff, no longer a room-wipe.

## B. Enemies survive long enough to threaten (modest HP, not sponges)

In kEnemyArchetypes (EnemyArchetypes.h) raise HP so enemies reach their
telegraph→attack before dying (this is what surfaces lobs/leaps/projectiles —
it is NOT spongey bullet-soaking; pair it with the toned-down player damage):
- Grunt 3 → 4, Rusher 2 → 3, Heavy 8 → 10, Boss 12 → 16, Spitter 2 → 4
  (must survive to lob), Leaper 3 → 4.

Surface the lava lob earlier: in CombatSystem the Spitter lob gate is
`difficulty >= 3 && shotCount % 3 == 2`. Change to `difficulty >= 2` and
`shotCount % 2 == 1` (every other shot from room 2 on) so players actually see
+ must dodge lobs. Keep boss LobVolley/Leap as-is (the HP bump lets bosses live
to cycle abilities).

## C. Homing projectiles

Straight Spitter shots gently curve toward the player — dodgeable with a
deliberate sidestep/dodge, punishing if ignored.

- Add `float homing = 0.f;` to ProjectileComponent (turn rate, rad/s; 0 = none).
- In ProjectileSystem, before integrating position: if `proj.homing > 0`, find
  the nearest living non-downed player; compute the desired heading
  (atan2 toward them) vs current velocity heading; rotate the velocity toward
  desired by at most `proj.homing * gameDt` radians (clamp the per-tick delta;
  keep speed magnitude constant). Cap so it's escapable: `kProjectileHoming`
  base ~2.2 rad/s (~125°/s). NOT applied to lobbed lava (those are arc + a
  telegraphed landing ring; leave them).
- Set homing when spawning straight Spitter shots (the non-lob branch of
  spawn_projectile_at_target): `proj.homing = kProjectileHoming *
  fminf(1.f, 0.4f + 0.15f * world.difficulty())` so early rooms barely curve and
  late rooms curve hard but never instantly. Deterministic.
- The aim-line telegraph still shows the initial direction (honest at launch;
  the curve is the "careless gets punished" part — document it).

## D. AutoPilot must dodge — and the game must require it

Extend AutoPilot defense (it currently dodges ONLY boss threats) to also dodge:
- an incoming enemy **projectile** within ~160 units whose velocity points
  roughly at the bot (dot of (bot−proj) vs proj velocity > 0 and closing);
- a **Leaper** in Telegraph/Leap state whose dest is near the bot (within ~140);
- a boss **LobVolley/Leap** telegraph already partially covered — keep.
Use the existing dodge-from-Idle/Walk gate + i-frames. Keep dodges purposeful
(only real incoming threats) so the bot doesn't flail.

Beatability/verification:
- 1P + 2P full-run AutoPilot wins MUST still pass (the dodging bot proves a
  careful player wins). Iterate the constants above against this gate; if the
  bot now loses, the FIRST lever is improving the bot's dodge timing/coverage
  (it should dodge what a human would), only then easing enemy numbers — do NOT
  re-inflate player perks.
- **NEW regression encoding "dodging is required"**: add a scenario test that
  runs a full 1P run with the bot's dodge SUPPRESSED (add a test-only
  `AutoPilot_set_dodge_enabled(bool)` flag, default true) and asserts the
  no-dodge run does NOT reach Win (it loses, or at minimum finishes with fewer
  lives than the dodging run). This is the machine proof that the game now
  demands dodging. If a hard loss proves flaky across seeds, assert
  no-dodge lives_lost > dodging lives_lost by a clear margin.

## Tests
- Perk magnitudes: each reduced perk applies the new value; Whirlwind relaxes
  but does NOT make attacks omnidirectional (an enemy directly behind is NOT
  hit; one at ~100° off-facing IS).
- Homing: a projectile with homing curves toward a moving player over time but a
  player dodging perpendicular escapes its hit radius; homing=0 flies straight;
  lobs are unaffected.
- Enemy HP bumps reflected; Spitter lob gate fires from difficulty 2.
- Charged heavy new damage/radius.
- AutoPilot dodges an incoming homing projectile and a Leaper telegraph.
- The no-dodge full run fails to win (or loses more lives) vs the dodging run.
- All existing tests stay green (247 now); update any that encoded old perk
  magnitudes / enemy HP / the 360° whirlwind / charged-heavy numbers.
