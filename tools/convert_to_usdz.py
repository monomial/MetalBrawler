"""
Converts Mixamo FBX files to USDZ for ModelIO (FBX unsupported on macOS 14+).

Usage (from the MetalBrawler project root):
  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/convert_to_usdz.py
"""

import bpy, os, sys

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
PLAYER_DIR  = os.path.join(PROJECT_DIR, "assets", "characters", "player")

CLIPS = ["idle", "walk", "attack", "attack2", "hurt", "hurt2", "death", "dodge"]

# Incremental: skip outputs that already exist and are newer than their FBX.
# Set BRAWLER_FORCE_CONVERT=1 to re-export everything.
FORCE = os.environ.get("BRAWLER_FORCE_CONVERT") == "1"


def up_to_date(src, dst):
    if FORCE:
        return False
    return os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src)


def clear_scene():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)


def find_armature(exclude=None):
    for obj in bpy.context.scene.objects:
        if obj.type == 'ARMATURE' and obj is not exclude:
            return obj
    return None


def import_fbx(path):
    bpy.ops.import_scene.fbx(
        filepath=path,
        ignore_leaf_bones=True,
        automatic_bone_orientation=True,
    )


def export_usdz(path, animated, with_materials=False):
    bpy.ops.wm.usd_export(
        filepath=path,
        export_animation=animated,
        export_uvmaps=True,
        export_normals=True,
        export_materials=with_materials,
        export_shapekeys=False,
        export_armatures=True,
        use_instancing=False,
    )


# -----------------------------------------------------------------------
# Load base character and export T-pose mesh
# -----------------------------------------------------------------------
clear_scene()

char_fbx = os.path.join(PLAYER_DIR, "Ch24_nonPBR.fbx")
if not os.path.exists(char_fbx):
    print(f"ERROR: {char_fbx} not found")
    sys.exit(1)

import_fbx(char_fbx)
char_arm = find_armature()
if not char_arm:
    print("ERROR: no armature found in character FBX")
    sys.exit(1)

print(f"Loaded: {[o.name for o in bpy.context.scene.objects]}")

char_out = os.path.join(PLAYER_DIR, "Ch24_nonPBR.usdz")
if up_to_date(char_fbx, char_out):
    print(f"Base mesh up to date: {char_out}")
else:
    export_usdz(char_out, animated=False, with_materials=True)
    print(f"Exported base mesh: {char_out}  ({os.path.getsize(char_out)//1024}KB)")

# -----------------------------------------------------------------------
# Export each animation clip
# -----------------------------------------------------------------------
for clip_name in CLIPS:
    anim_fbx = os.path.join(PLAYER_DIR, f"{clip_name}.fbx")
    if not os.path.exists(anim_fbx):
        print(f"Skipping {clip_name} — {clip_name}.fbx not found")
        continue
    clip_out_path = os.path.join(PLAYER_DIR, f"{clip_name}.usdz")
    if up_to_date(anim_fbx, clip_out_path):
        print(f"Up to date: {clip_out_path}")
        continue

    import_fbx(anim_fbx)

    anim_arm = find_armature(exclude=char_arm)
    if anim_arm and anim_arm.animation_data and anim_arm.animation_data.action:
        action = anim_arm.animation_data.action
        if not char_arm.animation_data:
            char_arm.animation_data_create()
        char_arm.animation_data.action = action
        bpy.data.objects.remove(anim_arm, do_unlink=True)
        print(f"  {clip_name}: transferred action '{action.name}'")
    else:
        if anim_arm:
            bpy.data.objects.remove(anim_arm, do_unlink=True)
        print(f"  {clip_name}: no animation action found in {clip_name}.fbx")

    # Trim scene timeline to the actual action frame range
    if char_arm.animation_data and char_arm.animation_data.action:
        fr = char_arm.animation_data.action.frame_range
        bpy.context.scene.frame_start = int(fr[0])
        bpy.context.scene.frame_end   = int(fr[1])
        print(f"  frame range: {int(fr[0])}–{int(fr[1])}")

    clip_out = os.path.join(PLAYER_DIR, f"{clip_name}.usdz")
    bpy.context.view_layer.objects.active = char_arm
    export_usdz(clip_out, animated=True)
    print(f"Exported {clip_name}: {clip_out}  ({os.path.getsize(clip_out)//1024}KB)")

    if char_arm.animation_data:
        char_arm.animation_data.action = None

print("\nAll done.")
