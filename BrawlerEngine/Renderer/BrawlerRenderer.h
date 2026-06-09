#import <MetalKit/MetalKit.h>
class World;
struct LoadedCharacter;

// Shared Metal renderer — used by macOS, iOS, and tvOS GameViewControllers.
// Draws colored ground-plane quads for entities without loaded characters;
// draws lit skinned meshes for entities whose faction has a LoadedCharacter.
@interface BrawlerRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)pixelFormat;

- (void)updateDrawableSize:(CGSize)size;

// Supply loaded character meshes for skinned rendering. Either may be nil (falls back to quads).
- (void)setPlayerCharacter:(LoadedCharacter*)player
               enemyCharacter:(LoadedCharacter*)enemy;

// Lives shown in HUD. Set each frame before drawWorld:.
@property (nonatomic) int livesRemaining;

// 0-based room number — selects the room color palette. Set at room load.
@property (nonatomic) int roomIndex;

// Call once per frame after World::update(). Encodes draw calls into cmd.
- (void)drawWorld:(World*)world
            inView:(MTKView*)view
     commandBuffer:(id<MTLCommandBuffer>)cmd;

// Write the next rendered frame to a PNG at path (async, off-main). Used by
// the --autotest smoke mode. Requires view.framebufferOnly == NO.
- (void)captureNextFrameToPath:(NSString*)path;

// Spawn a radial particle burst (hit sparks, telegraphs, clears) at a world
// position. Rendered as additive camera-facing billboards next frame.
- (void)spawnBurstAt:(simd_float3)pos
               count:(int)count
               speed:(float)speed
                size:(float)size
               color:(simd_float4)color;

@end
