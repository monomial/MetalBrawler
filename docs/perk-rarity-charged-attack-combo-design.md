# Perk Rarity + Charged Heavy Attack + Combo/Score — Design

Three art-free, sim/HUD-side features that deepen the roguelike + combat loop.
All deterministic, all covered by the headless test + AutoPilot beatability
gate. No new meshes/textures/audio assets (reuse existing particles + SFX).

Conventions: component registration per docs/codex-rules.md rule 3;
determinism via world RNG only; renderer flat-quad/early-continue + HUD-label
texture patterns already in BrawlerRenderer.mm; event routing once per frame in
the delegate.

---

## A. Perk rarity tiers + build-defining perks

Today: 8 flat perks (BrawlerPerk enum), offered 2-at-a-time in the upgrade
phase and 3 on shop pedestals, applied via `_applyPerk` → `PlayerPerks`
(delegate run state) → `StatsComponent` (sim, set at spawn).

- **Rarity enum** (delegate): `typedef NS_ENUM(int, BrawlerPerkRarity)
  { BrawlerRarityCommon=0, BrawlerRarityRare=1, BrawlerRarityEpic=2 };`
- **New perks** — APPEND to the BrawlerPerk enum (never reorder; `kPerkLabels`,
  `counts[]`, and offer indices are positional). Keep the existing 8 as Common.
  Add:
  - Rare: `BrawlerPerkHeavyHitter` (+2 damage), `BrawlerPerkToughness`
    (+6 maxHP), `BrawlerPerkLifesteal` (heal 1 HP every 6 landed hits),
    `BrawlerPerkThorns` (melee attacker takes 1 damage).
  - Epic: `BrawlerPerkWhirlwind` (attacks hit a full 360° + +25 range),
    `BrawlerPerkAdrenaline` (special meter charges passively over time),
    `BrawlerPerkVampire` (heal 1 every 3 hits AND +1 damage).
  Update `kPerkLabels` (human names) and any `BrawlerPerkCount`-sized array.
- **Rarity table**: `static const BrawlerPerkRarity kPerkRarity[BrawlerPerkCount]`
  (Common for the original 8, Rare/Epic for the new ones).
- **Weighted roll** (replaces the current uniform `rand_range(BrawlerPerkCount)`
  in the upgrade-offer + shop-pedestal pickers): roll a rarity by weight
  Common 60 / Rare 30 / Epic 10 via `world.rand_range(100)`, then pick a
  uniformly-random perk OF that rarity (build a small index list of that
  rarity's perks, pick via rand_range). Ensure the 2 upgrade offers (and 3 shop
  items) are distinct perks; if a roll collides, re-roll the perk (bounded
  loop, deterministic). The shop's "expensive slot" can bias toward higher
  rarity but keep it simple: price by rarity instead of the old 25/25/40 —
  Common 25, Rare 40, Epic 60.
- **Display**: prefix shown labels with a rarity marker — Common "" , Rare
  "★ ", Epic "★★ " (in `upgradeChoiceLabel:` and the shop prompt). Renderer:
  tint the shop pedestal glow + the upgrade overlay choice by rarity (Common
  gray-blue, Rare blue, Epic gold) — add a rarity→color helper; reuse existing
  perk-color draw slots.
- **StatsComponent new fields** (sim): `int lifestealPerHits = 0;` (0=off),
  `bool thorns = false; bool whirlwind = false; bool passiveSpecial = false;`
  plus runtime `int hitsSinceHeal = 0;`. `PlayerPerks` gets matching fields;
  `_applyPerk` sets them; `_spawnPlayer` copies them into StatsComponent (Heavy
  Hitter/Toughness/Vampire stack onto bonusDamage/bonusMaxHP like the existing
  stat perks).
- **Sim hooks**:
  - Lifesteal/Vampire: at the player-lands-a-hit site in CombatSystem (where
    `emit_damage(targetID, …)` fires for an enemy target), if
    `stats.lifestealPerHits > 0` increment `stats.hitsSinceHeal`; when it
    reaches lifestealPerHits, heal 1 (clamp to HealthComponent.max) and reset.
  - Thorns: at the enemy-melee-hits-player site (CombatSystem enemy attack
    branch that damages a player — NOT projectiles/hazards), if the player has
    `stats.thorns`, deal 1 damage to the attacker through Combat_apply_death on
    lethal (reuse the existing damage→death pattern).
  - Whirlwind: in the player attack arc test, if `stats.whirlwind` skip the
    forward-arc dot check (hit all directions) and add +25 to kAttackRange for
    that swing.
  - Adrenaline/passiveSpecial: in SpecialSystem, if the player has
    `stats.passiveSpecial`, add a small passive charge per second
    (e.g. +0.06/s) on top of hit-based charge, clamped to 1.
- **Tests**: rarity weighting is deterministic for a fixed seed; each new perk
  effect (lifesteal heals after N hits; thorns damages a melee attacker;
  whirlwind hits an enemy behind the player; passive special rises with no
  hits); `_applyPerk` sets each field; offers/pedestals never duplicate a perk.

## B. Charged heavy attack

Hold attack from a standstill to wind up a radial smash. The attack input is
LEVEL-based (holding auto-repeats Attack), so the rule is designed to keep tap
responsiveness while repurposing a sustained hold:

- **Component**: `ChargeAttackComponent { float held = 0.f; bool charging =
  false; }` on every player (full registration; add in _spawnPlayer).
- **InputSystem rule** (extend the existing player block):
  - Tap / normal attack is unchanged: a press from Idle still fires Attack
    immediately, and the combo-queue logic is untouched.
  - When `input.attack` is held AND the player is Idle (the prior clip finished)
    AND not moving: accumulate `charge.held += dt` and DO NOT auto-request
    another Attack (this is the behavior change — sustained hold charges instead
    of rapid-firing). At `held >= kChargeThreshold (0.5s)` set
    `charging = true` once and emit a new `ChargeReady { playerID }` event
    (telegraph).
  - Moving, dodging, or being Hurt cancels: reset held=0, charging=false.
  - On release (attack true→false): if `charging`, execute the heavy and reset.
- **Heavy execution** (in CombatSystem or a small ChargeAttackSystem invoked
  right after Combat): radial AoE around the player, radius `kHeavyRadius=150`,
  damage `kHeavyBaseDamage(3) + stats.damageBonus`, strong knockback
  (kCombatKnockbackSpeed * 1.6 * stats.knockbackMult) radially outward on each
  enemy hit, `trigger_hit_stop(8)`, `ScreenShakeSystem_trigger(30)`, request
  the Attack2 clip for the swing visual, emit `ChargedSlam { x, y }`. Respects
  enemy hurt-reaction + Combat_apply_death like normal hits.
- **AutoPilot** (bounded): when 2+ living enemies are within kHeavyRadius and no
  hazard/incoming threat is adjacent, occasionally hold attack ~0.6s then
  release to charge-slam; otherwise unchanged. Keep it rare so normal combat
  (and the beatability gate) is unaffected.
- **Renderer/delegate**: ChargeReady → pulsing wind-up particles + brighter
  player tint while charging (reuse spawnBurstAt + a tint boost like the boss
  enrage cue). ChargedSlam → big shockwave burst (reuse the finisher burst) +
  playFinisherSound + finisher haptic.
- **Tests**: held-from-idle reaches charging after threshold; release fires a
  radial hit that damages an enemy directly BEHIND the player (proving it's not
  arc-limited); release before threshold does nothing special; moving mid-charge
  cancels; a charged slam knocks enemies back and applies hit-stop.
- **FEEL FLAG for the human review**: this converts "hold attack = rapid-fire"
  into "hold attack = charge." Tapping still rapid-attacks. Note it in the
  report; it is the one change that needs hands-on judgement.

## C. Combo + score counter

Reward aggressive uninterrupted play; pure delegate state + HUD.

- **Delegate run state**: `int _combo, _maxCombo, _score; float _comboTimer;`.
  Reset all on new run (where _scrap resets). On each `DamageDealt` event whose
  target is an ENEMY (faction check) this frame: `_combo++`,
  `_score += kComboBasePoints(10) * _combo`, `_comboTimer = kComboWindow(2.5f)`,
  `_maxCombo = max(_maxCombo, _combo)`. On any player-damage event
  (DamageDealt to a player / PlayerDowned): `_combo = 0`. Each frame in
  Playing: `_comboTimer -= dt`; at ≤0 set `_combo = 0`. Score persists across
  rooms.
- **Run summary**: add `maxCombo` and `score` to RunStats + the Win/Lose
  summary statLines (the overlay already renders statLines).
- **Renderer HUD**: `@property int comboCount; @property int scoreValue;` set
  each frame from the delegate. Draw "SCORE n" in a top corner (makeHUDLabel
  pattern, like SCRAP). When `comboCount >= 2`, draw "COMBO xN" centered near
  the top with a brief scale-pop each time N increases (track last-drawn combo;
  on increase, animate a short scale bounce via a decaying timer — cosmetic,
  renderer-local). Hidden when combo < 2.
- **Tests** (headless delegate): combo increments on enemy hits, resets on
  player damage, expires after the window; score accumulates with the
  multiplier; maxCombo tracked; all reset on a new run.

## Gate

- Full BrawlerLogicTests suite stays green (233 now) + new tests.
- AutoPilot 1P + 2P full-run wins remain the beatability gate; the charge
  behavior change must not break them. If a full run regresses, prefer making
  the bot's charge usage rarer over weakening enemies (this is a combat-feel
  change, not a difficulty change).
- iOS/tvOS builds + smoke run are the supervisor's gate (Codex sandbox lacks
  the Metal toolchain).
