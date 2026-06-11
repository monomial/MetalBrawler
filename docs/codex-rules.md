# Standing rules for AI coding tasks in MetalBrawler

Read this fully before touching code. Violating these breaks the game silently.

1. **Never commit.** Leave changes in the working tree for supervisor review.
2. **Progress journal**: append one line to `CODEX_PROGRESS.md` (repo root) after
   each meaningful step — what's done, what's next. It's the resume point if the
   session dies.
3. **Component registration** (mirror DodgeComponent): struct in
   `BrawlerEngine/Simulation/Components.h`; storage member + accessor in
   `World.h`; `_pool<T>()` specialization AND a removal line in `flush()` in
   `World.mm`. A missed flush line leaks components onto recycled entity IDs.
4. **Determinism**: simulation randomness only via `world.rand_range(n)` /
   `world.rand_float01()` — never arc4random/rand. Same seed = identical run.
5. **Event semantics**: the EventBus clears once per `World::update()` (frame);
   a frame runs ~2 fixed 120 Hz ticks and events accumulate across them.
   Simulation systems must NOT consume events via `for_each` per tick (they'd
   double-process earlier ticks); act at emission sites instead. The ObjC
   delegate routes events to audio/particles/haptics once per frame.
6. **System ordering** is explicit in `World::tick()` (World.mm). Velocity-
   override systems run after velocity writers, before PhysicsSystem.
7. **Clip-table trap**: `AnimClipID` (Components.h) sizes FOUR parallel tables
   that must all change together when adding a clip: `kClipDurationFallback`
   and `clip_speed_multiplier` (AnimationSystem.mm), `kAttackWindows`
   (CombatSystem.mm), and the clips filename array in
   `BrawlerGameDelegate._loadCharacterIn:mesh:device:`. A missed table silently
   zero-fills (0-length clip, no hitbox).
8. **kMaxAnimEntities = 64**: the renderer bone buffer is indexed by raw
   EntityID. Never give cosmetic/static entities an AnimationComponent.
9. **New .h/.mm files** require running `xcodegen` before xcodebuild.
10. **Renderer special-case pattern**: flat-quad entities (hazards, hearts,
    markers) are special-cased with an early `continue` in BrawlerRenderer.mm's
    entity loop — mirror that for new cosmetic entity types.
11. **Tests**: BrawlerLogicTests/ (XCTest .mm; match the style of
    KnockbackTests.mm / ScenarioTests.mm; no `__block` in C++ lambdas).
    All existing tests must stay green:
    `xcodebuild -project MetalBrawler.xcodeproj -scheme BrawlerLogicTests -destination 'platform=macOS' test`
12. **Your shell cannot run `scripts/smoke.sh`** (no Metal toolchain) — the
    supervisor runs it. You MUST run: xcodegen (if files added), the full test
    suite, and both
    `xcodebuild -scheme Brawler-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build -quiet`
    and the same for `Brawler-tvOS` if you touched platform code.
13. **Report** at the end: changes per feature, test count before/after,
    deviations from the brief and why, anything noticed but not fixed.
