# Curse Portals + Meta-Progression (Coins) — Design

Two linked features. Part 1 = branching cursed exits (in-run difficulty/reward).
Part 2 = persistent coins + a pre-run meta-shop (cross-run progression). The
link: cursed portals are the main coin source, so design the economy together
but SHIP IN TWO CODEX BATCHES (Part 1 first — it's the coin sink/source; Part 2
second — it has the cross-platform UI lift).

Reuse map (most of this exists): exit flow (`ExitComponent`, `ExitSystem`,
`ExitReached`, walk-to-arrow, AutoPilot steering); run-state-mirrored-into-sim
pattern (`set_scrap`/`set_difficulty` → add `set_curse`); HUD label textures;
the perk/`StatsComponent` pipe for starting bonuses; seeded `world.rand_range`.
NOTE: enemy HP is a fixed archetype constant and enemy damage is applied at ~6
sites — the curse multiplier needs new application points there (enumerated
below), same lesson as the rebalance.

================================================================================
## PART 1 — Curse Portals (branching exits)
================================================================================

After clearing a room, the player walks to one of TWO exits instead of one:
a calm exit (normal) and a cursed portal (harder, better reward). Offered
whenever the NEXT room is not a shop (shops can't be cursed) and a next room
exists. The single-boss room → twin-boss is offered; the final room has no exit
(Win). The pre-shop room offers a single plain exit (next room is the shop).

### Curse multiplier (the escalator)
- Delegate run state `float _curseMult = 1.f`. Each cursed pick multiplies it
  by the portal's factor (1.1 typical). Stacks multiplicatively across rooms
  (1.1 → 1.21 → …), persists for the rest of the run, resets each run.
- Mirror into the sim like scrap: `World::set_curse(float)` + `float curse_mult()
  const` (plain float member, set in `_loadRoom` from `_curseMult`). Default 1.0.
- Apply (helper `int World::curse_damage(int base) const { return max(1,
  (int)lroundf(base * _curseMult)); }`):
  - **Enemy HP at spawn** (EnemyFactory / wherever maxHP is set):
    `maxHP = max(1, lroundf(def.maxHP * world.curse_mult()))`.
  - **Enemy damage** at every enemy→player site, wrap the dealt amount in
    `world.curse_damage(...)`: CombatSystem enemy melee; Spitter projectile
    (`pc.damage` at spawn); Leaper leap; Boss charge; Boss leap AoE; lava pool
    (HazardComponent.damage at spawn). Player-dealt damage is NOT cursed.
- Determinism preserved (pure arithmetic; mult is mirrored input like scrap).

### Portal generation (variety, seeded)
- Add to `ExitComponent`: `bool cursed = false; uint8_t curseType = 0;`. Put the
  resolved effect in the `ExitReached` payload so the handler doesn't depend on
  the (destroyed) entity: extend `ExitReachedPayload` with
  `bool cursed; uint8_t curseType;` (ExitSystem reads the ExitComponent when it
  emits). 
- New helper `_spawnExitsForNextRoom`: replaces the two current `_spawnExit`
  call sites (post-upgrade in `chooseUpgrade`, and the shop branch of
  `_loadRoom`). Logic: if room `_currentRoom+1` is a shop OR is the last room →
  one plain exit at (0, kRoomMaxY-60) (unchanged behavior). Else → TWO exits:
  calm at (-220, kRoomMaxY-60), cursed at (+220, kRoomMaxY-60); roll the cursed
  portal's type via `world.rand_range`.
- **Curse pool** (4 flavors; all stack enemy HP & damage, vary the reward —
  this is the "variety, randomly chosen"). Coins (Part 2 currency) are the
  guaranteed reward on every cursed portal, scaled up by how cursed the run
  already is (risk compounds reward):
  - 0 "Iron Horde": ×1.1 HP&dmg. Reward: coins.
  - 1 "War Chest":  ×1.1 HP&dmg. Reward: coins + 40 scrap now.
  - 2 "Bloodpact":  ×1.1 HP&dmg. Reward: coins + heal all players +3 now.
  - 3 "Greater Curse": ×1.2 HP&dmg. Reward: 2× coins.
  - Base coin reward = `8 + 4 * curseStacksTakenSoFar` (so later curses pay more;
    Greater Curse doubles it). Track `_curseStacks` int alongside `_curseMult`.
- Each portal renders its label above it via the HUD-label texture
  (e.g. "GREATER CURSE  ▲▲ enemies  +coins"); calm exit renders "ONWARD". Reuse
  the exit-arrow draw; tint the cursed portal red/purple, calm one cyan.

### Routing
- `ExitReached` handler (currently `_currentRoom += 1; _loadRoom; Playing`):
  if `payload.cursed`, before advancing: `_curseMult *= curseFactor[curseType]`,
  `_curseStacks += 1`, grant the reward (coins to `_runCoins` [Part 2; for Part 1
  alone, stash in an int that Part 2 will bank], scrap/heal per flavor), play a
  heavier portal SFX + screen shake. Then advance as today.
- HUD: show the active curse with a small indicator (e.g. "CURSE ×1.21") near
  the room label when `_curseMult > 1`, via the label-texture pattern.

### AutoPilot + gate (Part 1)
- Two exits: the bot steers to the CALM exit (so the full-run beatability gate
  runs at base difficulty and stays meaningful). Bounded change: prefer the
  non-cursed ExitComponent when choosing a target.
- Tests: curse mult stacks multiplicatively; cursed enemy HP & damage scale and
  round (≥1); a calm run leaves `_curseMult == 1`; portal pool selection is
  deterministic for a seed; the existing dodge/no-dodge + 1P/2P full-run gates
  still pass (calm path). A forced-curse scenario test asserts enemies in the
  next room have boosted HP.

================================================================================
## PART 2 — Meta-Progression (persistent coins + pre-run shop)
================================================================================

Coins earned during a run are banked permanently and spent before runs on small
permanent upgrades. Local persistence only (no login/iCloud).

### Persistence: NSUserDefaults via an injectable store
- `MetaProgressStore` (new ObjC class): holds `int coins` + upgrade levels
  `hpLevel, livesLevel, scrapLevel, secondWindLevel`; a `version` int.
  `-load` / `-save` to `NSUserDefaults` under ONE key `@"brawler.meta.v1"`
  (a single dictionary, version-stamped for future migration).
- **Test isolation** (mirror `rngSeedOverride`): the delegate owns a
  `MetaProgressStore`. `initHeadless` (and a `metaStoreOverride` setter) uses an
  IN-MEMORY store so scenario tests never read/write real defaults. Normal
  platform init uses the NSUserDefaults-backed store.
- tvOS note: NSUserDefaults is the only simple local store on tvOS and may be
  evicted under storage pressure — acceptable per product decision (no iCloud).

### Earning (reward even failed runs)
- Delegate `_runCoins` accumulates during a run: +3 per room cleared, +cursed
  portal rewards (Part 1), +25 win bonus. On entering Win OR Lose: 
  `store.coins += _runCoins; [store save];`. `_runCoins` resets in `_startNewRun`.
- Show `_runCoins` on the run-summary statLines ("Coins earned: N").

### Spending: pre-run meta-shop
- New phase `BrawlerGamePhaseMetaShop` reachable from Title (Title → press a
  dedicated control / a "shop" choice → MetaShop → back to Title → start run).
  Simplest cross-platform: Title shows "PLAY" and "UPGRADES"; selecting
  UPGRADES enters MetaShop.
- Upgrades (incremental + capped — do NOT let these re-trivialize the rebalance):
  - "Vitality" hpLevel 0–4: +1 starting max HP per level. Cost 20,35,55,80.
  - "Extra Life" livesLevel 0–2: +1 starting life. Cost 60,120.
  - "Prospector" scrapLevel 0–3: +15 starting scrap per level. Cost 15,25,40.
  - "Resolve" secondWindLevel 0–1: start with +1 second wind. Cost 100.
- MetaShop UI: reuse the overlay text mechanism — render a list of upgrades with
  level/cost and current coins; navigate with move up/down, buy with attack,
  exit with dodge/pause. Same in-engine overlay across all 3 platforms (like the
  perk-choice overlay). Buying: if `coins >= cost` and below cap → deduct,
  level++, `[store save]`.
- Apply at `_startNewRun` BEFORE spawning players:
  `_lives = kStartingLives + livesLevel`; `_scrap = scrapLevel*15`; seed each
  player's `PlayerPerks.bonusMaxHP += hpLevel`, `secondWinds += secondWindLevel`
  (these already flow into StatsComponent at spawn).

### Tests (Part 2)
- In-memory store: coins bank on Win and on Lose; `_runCoins` accrues per room +
  win bonus; resets each run.
- Meta upgrades apply at run start (lives/scrap/maxHP/secondWind reflect levels);
  buying respects cost + cap; persistence round-trips through the in-memory store.
- Existing gates green; the meta layer is OFF by default in headless gate tests
  (in-memory store at level 0) so the dodge/no-dodge + full-run gates are
  unchanged.

### Balance guardrail
Meta upgrades are intentionally small/capped; curse portals are the counter-
pressure. The base game's "must dodge" difficulty must remain true at meta
level 0 (the gate enforces this).
