# Character Assets

Drop Mixamo FBX files here. The game uses ModelIO to load them.

## Expected files

```
assets/characters/
  player/
    Ch24_nonPBR.usdz  ← base mesh (T-pose, With Skin FBX → converted to USDZ)
    idle.usdz
    walk.usdz
    attack.usdz
    hurt.usdz
    death.usdz
  enemy/
    (same set)
```

## How to get them

ModelIO on macOS 14+ does NOT support FBX. Use USDZ instead.

### Step 1 — Download from Mixamo (FBX 7.4 format)
1. Go to https://www.mixamo.com
2. Download base character: FBX 7.4, **With Skin**, 30fps → save as `Ch24_nonPBR.fbx`
3. For each clip: FBX 7.4, **Without Skin**, 30fps → save as `idle.fbx`, `walk.fbx`, etc.
   - idle → "Idle", walk → "Walking", attack → "Punching", hurt → "Hit Reaction", death → "Dying"

### Step 2 — Convert FBX → USDZ via Blender
Requires Blender 4.x (free at blender.org).

```bash
blender --background --python tools/convert_to_usdz.py
```

This reads the `.fbx` files and writes `.usdz` files to this folder.

## Clip mapping to AnimClipID

| File       | AnimClipID     | Loops |
|------------|----------------|-------|
| idle.fbx   | Idle (0)       | yes   |
| walk.fbx   | Walk (1)       | yes   |
| attack.fbx | Attack (2)     | no    |
| hurt.fbx   | Hurt (3)       | no    |
| death.fbx  | Death (4)      | no    |

## What happens without these files

The game runs normally with colored quads instead of 3D meshes.
AnimationSystem advances clip timers but skips bone matrix sampling.
Drop the files in and rebuild — ModelIO loading is wired and ready.
