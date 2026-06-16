# Stylized City Theme (v1) — Design

Make the arenas read as a city WITHOUT any external art assets — pure
renderer/shader work in the existing flat-shaded style. Four parts: 3D wooden
crates, a city floor (asphalt + road markings), city-themed per-room palettes,
and the box scrap ratio fixed to exactly 50%. (Lit-window wall shader is a
planned follow-up, NOT this batch — walls just get re-paletted + a top trim.)

This is PURELY VISUAL: no sim changes, no determinism impact, headless tests
unaffected. The supervisor verifies via smoke screenshots and tunes constants.

Context (current renderer):
- Floor: `floor_vertex`/`floor_fragment` in Shaders/Brawler.metal — base color +
  125u grid + edge vignette; fed by `FloorUniforms {mvp, baseColor, lineColor,
  center, size}` (mirrored as FloorUniformsGPU in BrawlerRenderer.mm) from
  `RoomPalette {floorBase, floorLine, wall, clear}`.
- Walls: solid `pal.wall` quads via `make_model_wall` (height 80) on far + side
  edges, flat strip on the near edge.
- Boxes: TWO flat ground quads (50×50 brown + 32×32 dark) in the
  `world->boxes().present(eid)` branch of drawWorld — looks like a flat square.
- Per-room palette index already cycles `kRoomPalettes` (last = boss violet).

---

## A. 3D wooden crates (replace the flat box quads)

In the box render branch, draw a crate built from existing quad helpers (no new
shader). Crate ~50×50 footprint, height `kCrateH = 44`:
- **Top face**: `make_model_rect(pos.x, pos.y, kCrateH, 50, 50)`, light wood
  `{0.60,0.43,0.24,1}`.
- **4 side walls** via `make_model_wall`: front/back (alongX, at pos.y ± 25) and
  left/right (alongY, at pos.x ± 25), each length 50, height kCrateH. Faux-light
  by face: front/back mid wood `{0.50,0.34,0.18,1}`, sides darker
  `{0.40,0.27,0.14,1}`.
- **Plank + X-brace detail on the top** (reads as a crate lid): a few thin dark
  quads `{0.28,0.18,0.09,1}` at z just above kCrateH — two diagonals forming an
  X across the top (use `make_model_line` with width ~5 from corner to corner)
  plus a border frame (4 thin quads or a slightly inset darker rect). Keep it
  cheap (≤ ~6 quads total per crate).
- Boxes have no AnimationComponent (rule 8) — still a flat/cosmetic entity, just
  drawn as a stack of quads. Early-continue as today.
- The existing BoxBroken woody particle burst stays.

## B. City floor (extend the floor shader)

Turn the grid floor into an asphalt street. Add `float4 marking` to
`FloorUniforms`/`FloorUniformsGPU` + `RoomPalette` (the road-paint color) and set
it per palette below. In `floor_fragment`:
- **Asphalt base** = `baseColor` (darker grays in the new palettes).
- **Expansion-joint grid**: keep the existing grid but fainter and larger
  (cell 250u, line mix ~0.25) so it reads as pavement seams, not a game grid.
- **Center lane line**: a DASHED line down the room's center axis — where
  `abs(world.x - center.x) < 5`, and the dash is on for ~70u of every 120u in
  world.y. Color `marking` (yellow for downtown). 
- **Curb/sidewalk bands**: a lighter band just inside each edge — where
  `max(rel.x, rel.y)` (already computed for vignette) is in ~[0.80, 0.92], tint
  toward a light gray `{0.55,0.55,0.58}` (a sidewalk ring). Keeps the existing
  outer vignette beyond it.
- Keep it readable (floor must not distract from gameplay) — markings subtle.

## C. City-themed palettes

Replace `kRoomPalettes` with city locales (keep the array length & the last =
boss; add the new `marking` field to each). Suggested set (floorBase / floorLine
/ wall / clear / marking):
- **Downtown street** — asphalt grays, yellow lane paint, blue-gray buildings.
- **Brick alley** — grimy concrete floor, warm brick walls, faded white paint.
- **Subway platform** — concrete, tiled walls (cooler gray), yellow safety line.
- **Rooftop night** — dark tar floor, dark parapet walls, cyan/neon marking.
- **Industrial yard** — oil-stained concrete, rusty walls, orange hazard paint.
- **Boss (keep violet/neon)** — neon marking.
Pick tasteful values; the supervisor will tune after screenshots. The delegate's
existing palette indexing is unchanged.

## D. Walls (light touch this batch)
Keep solid `pal.wall` quads, but add a thin brighter **trim line** along the top
edge of each standing wall (a thin quad in a lighter shade of pal.wall) so walls
read as building tops/parapets. Full lit-window shader = a documented FOLLOW-UP,
not this batch.

## E. Scrap ratio = exactly 50%
The user wants "half" of boxes to contain scrap (currently ~60%). In the
BrawlerGameDelegate room box data (`BoxSpawn` arrays), set the `hasScrap` flags
so exactly half (rounded) per room are true. Keep positions unchanged.

---

## Gate / verification
- Pure visual: all 291 logic tests must still pass unchanged (no sim/data logic
  changed except the box hasScrap flags — update any test asserting a specific
  per-room scrap count if one exists). 
- Supervisor runs smoke + reads screenshots (title/combat/boss) to verify the
  crates look like crates and the floor/palettes read as a city, then tunes the
  shader/color constants. iOS/tvOS must build (shader + renderer changes are
  cross-platform).
- New FloorUniforms field must match exactly between Brawler.metal and the
  FloorUniformsGPU struct in BrawlerRenderer.mm (size/order) or the floor breaks.
