# Passive Dodge Chance (TMNT-style "Dodge") — Design

Adds a passive % chance to auto-negate an incoming hit, upgradeable like other
player stats. This is DISTINCT from the existing directional roll, which is
really a **dash**.

## Naming (important — avoid churn + confusion)
- The existing `DodgeComponent` / `DodgeSystem` / `AnimClipID::Dodge` /
  `DodgeChargesComponent` are the **DASH** (active roll + i-frames). DO NOT
  rename them — too much churn/risk. Keep all internal names as-is.
- This feature adds a new PASSIVE stat called **dodge chance** (`dodgeChance`).
- Relabel the user-facing perk strings for clarity (kPerkLabels only, no enum
  changes): "Quick Dodge" → "Quick Dash"; "Evasion" → "Extra Dash". Then the
  new perk below is the only thing called "Dodge".

## The stat
- Add `float dodgeChance = 0.f` to `StatsComponent` and a matching
  `float dodgeChance = 0.f` to `PlayerPerks`. Base 0 (no passive dodge without
  investing). Seed StatsComponent.dodgeChance from PlayerPerks at `_spawnPlayer`.
- Clamp to a sane cap (e.g. 0.6) wherever applied.

## The roll (one shared helper — keep RNG in one place)
Add to CombatHelpers: `bool Combat_player_dodges_hit(World& world, EntityID
playerID)`:
```
if (!world.has_component<StatsComponent>(playerID)) return false;
float chance = min(world.get_component<StatsComponent>(playerID).dodgeChance, 0.6f);
if (chance <= 0.f) return false;            // no RNG consumed at base — keeps
                                            // existing seeded tests unchanged
if (world.rand_float01() >= chance) return false;
world.events().emit_evaded(playerID);       // new event for feedback
return true;
```
DETERMINISM NOTE: only call rand when chance > 0, so runs with no Dodge perk
consume zero extra RNG and existing seeded scenario outcomes are unchanged.

## Apply at every player-damage site
At each site, AFTER the existing skip checks (players_invincible, DownedComponent,
dash i-frames via DodgeComponent, DamageCooldownComponent) and BEFORE applying
damage, call `Combat_player_dodges_hit`; if true, skip the hit entirely (no
damage, no hurt clip; optionally set a short DamageCooldown so one roll covers a
moment). Sites:
- HazardSystem (lava), ProjectileSystem, LeaperSystem (leap),
  BossSystem (`damage_players_in_radius`: charge + leap), CombatSystem
  (enemy→player melee). These are the same 5 sites the victory-invincibility
  guard touches — add the dodge roll right after that guard.

## New event + feedback
- `EvadedPayload { uint32_t playerID; }` + `EventType::Evaded` +
  `emit_evaded` in EventBus.h (full event registration like the others).
- Delegate routes `Evaded` → a quick "swoosh" SFX (reuse playSwingSound or
  dodge sound) + a small "DODGE!" particle/text pop at the player (reuse
  spawnBurstAt; a HUD text pop is optional). Light + readable.

## The upgrade
- New perk `BrawlerPerkDodgeChance` appended to the BrawlerPerk enum (Rare),
  label "Dodge" (or "Dodge +15%"), `_applyPerk`: `perks.dodgeChance += 0.15f`.
  Add to `kPerkRarity` (Rare) and the rarity-weighted pool. (Optional future:
  a meta-shop "Reflexes" for a small starting dodgeChance — OUT OF SCOPE here.)

## Gate + tests
- Beatability gates MUST stay green. Base dodgeChance is 0, so the dodging-
  disabled (no-dash) regression and the 1P/2P win runs are unaffected UNLESS the
  bot picks the Dodge perk. If picking it lets the no-dash run start winning,
  lower the cap / per-stack value — do NOT touch enemy damage. Keep per-stack
  modest (0.15) and capped (0.6).
- Tests:
  - `Combat_player_dodges_hit`: false at chance 0 (and consumes no RNG —
    assert rng state unchanged across the call at chance 0); deterministic
    true/false for a fixed seed at a given chance; never exceeds the cap.
  - A player with dodgeChance 1.0 takes NO damage from a projectile/hazard/enemy
    melee (rolls always succeed) and emits Evaded; at 0.0 takes normal damage.
  - `_applyPerk` raises dodgeChance by 0.15 and the relabels are intact
    (counts[] still sized by BrawlerPerkCount).
  - All existing tests stay green (286 now); supervisor clean-builds.
