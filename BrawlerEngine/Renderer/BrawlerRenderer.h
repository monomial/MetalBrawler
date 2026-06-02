#import <MetalKit/MetalKit.h>
class World;

// Shared Metal renderer — used by macOS, iOS, and tvOS GameViewControllers.
// Reads PositionComponent + FactionComponent from World each frame;
// draws colored ground-plane quads with a perspective camera that follows the player.
@interface BrawlerRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)pixelFormat;

- (void)updateDrawableSize:(CGSize)size;

// Call once per frame after World::update(). Encodes draw calls into cmd.
- (void)drawWorld:(World*)world
            inView:(MTKView*)view
     commandBuffer:(id<MTLCommandBuffer>)cmd;

@end
