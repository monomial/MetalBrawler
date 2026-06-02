#import "GameViewController.h"
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>
#include "Simulation/World.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include "Platform/InputState.h"

// ---------------------------------------------------------------------------
// Per-draw uniforms — pushed via setVertexBytes: (< 4 KB, no buffer needed).
// Must match Uniforms struct in Brawler.metal.
// ---------------------------------------------------------------------------
typedef struct {
    simd_float4x4 mvp;
    simd_float4   color;
} DrawUniforms;

// Ground-plane quad: 6 verts (2 triangles), XY plane, unit size, centered at origin.
static const simd_float3 kQuadVerts[6] = {
    {-0.5f, -0.5f, 0.f}, { 0.5f, -0.5f, 0.f}, {-0.5f,  0.5f, 0.f},
    { 0.5f, -0.5f, 0.f}, { 0.5f,  0.5f, 0.f}, {-0.5f,  0.5f, 0.f},
};

static const float kEntitySize = 40.0f;   // world-unit footprint per entity
static const float kCamDist    = 800.0f;  // camera distance from target
static const float kCamPitch   = 55.0f * ((float)M_PI / 180.0f);
static const float kFOVY       = 70.0f * ((float)M_PI / 180.0f);
static const float kNearPlane  = 1.0f;
static const float kFarPlane   = 3000.0f;

// ---------------------------------------------------------------------------
// Matrix helpers (right-handed, Metal NDC Z in [0,1])
// ---------------------------------------------------------------------------
static simd_float4x4 make_perspective(float fovY, float aspect, float nearZ, float farZ) {
    float f = 1.0f / tanf(fovY * 0.5f);
    simd_float4x4 m = {};
    m.columns[0].x = f / aspect;
    m.columns[1].y = f;
    m.columns[2].z = farZ / (nearZ - farZ);
    m.columns[2].w = -1.0f;
    m.columns[3].z = (nearZ * farZ) / (nearZ - farZ);
    return m;
}

static simd_float4x4 make_look_at(simd_float3 eye, simd_float3 target, simd_float3 worldUp) {
    simd_float3 f = simd_normalize(target - eye);
    simd_float3 r = simd_normalize(simd_cross(f, worldUp));
    simd_float3 u = simd_cross(r, f);
    simd_float4x4 m;
    m.columns[0] = (simd_float4){ r.x, u.x, -f.x, 0.f };
    m.columns[1] = (simd_float4){ r.y, u.y, -f.y, 0.f };
    m.columns[2] = (simd_float4){ r.z, u.z, -f.z, 0.f };
    m.columns[3] = (simd_float4){ -simd_dot(r,eye), -simd_dot(u,eye), simd_dot(f,eye), 1.f };
    return m;
}

// Translate + uniform scale, no rotation — sufficient for axis-aligned quads.
static simd_float4x4 make_model(float x, float y, float size) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = size;
    m.columns[1].y = size;
    m.columns[2].z = size;
    m.columns[3]   = (simd_float4){ x, y, 0.f, 1.f };
    return m;
}

// ---------------------------------------------------------------------------
// BrawlerDelegate — owns World + Metal rendering
// ---------------------------------------------------------------------------
@interface BrawlerDelegate : NSObject <MTKViewDelegate>
- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pfmt;
- (void)setInputState:(InputState)state;
@end

@implementation BrawlerDelegate {
    World                      _world;
    CFTimeInterval             _lastTime;
    id<MTLCommandQueue>        _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState>   _depthState;
    id<MTLBuffer>              _quadVB;
    dispatch_semaphore_t       _frameSemaphore;
    simd_float4x4              _projMatrix;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pfmt {
    self = [super init];
    if (!self) return nil;

    _commandQueue   = [device newCommandQueue];
    _lastTime       = CACurrentMediaTime();
    _frameSemaphore = dispatch_semaphore_create(3);
    _projMatrix     = matrix_identity_float4x4;

    // Quad vertex buffer (72 bytes — unit square in XY plane)
    _quadVB = [device newBufferWithBytes:kQuadVerts
                                  length:sizeof(kQuadVerts)
                                 options:MTLResourceStorageModeShared];

    // Shader library + pipeline
    id<MTLLibrary> lib = [device newDefaultLibrary];
    if (!lib) { NSLog(@"Metal default library not found"); return nil; }

    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction   = [lib newFunctionWithName:@"vertex_main"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fragment_main"];
    pd.colorAttachments[0].pixelFormat = pfmt;
    pd.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;

    MTLVertexDescriptor *vd   = [MTLVertexDescriptor new];
    vd.attributes[0].format      = MTLVertexFormatFloat3;
    vd.attributes[0].offset      = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.layouts[0].stride         = sizeof(simd_float3);
    pd.vertexDescriptor = vd;

    NSError *err = nil;
    _pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!_pipeline) { NSLog(@"Pipeline error: %@", err); return nil; }

    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLess;
    dd.depthWriteEnabled    = YES;
    _depthState = [device newDepthStencilStateWithDescriptor:dd];

    [self _spawnEntities];
    return self;
}

- (void)_spawnEntities {
    EntityID player = _world.defer_create();
    _world.add_component<PlayerTagComponent>(player).active = true;
    _world.add_component<PositionComponent>(player)         = {0, 0, 0};
    _world.add_component<VelocityComponent>(player)         = {0, 0, 0};
    _world.add_component<FactionComponent>(player).type     = FactionComponent::Player;
    _world.add_component<HealthComponent>(player)           = {10, 10};

    EntityID enemy = _world.defer_create();
    _world.add_component<PositionComponent>(enemy)          = {400, 0, 0};
    _world.add_component<VelocityComponent>(enemy)          = {0, 0, 0};
    _world.add_component<FactionComponent>(enemy).type      = FactionComponent::Enemy;
    _world.add_component<HealthComponent>(enemy)            = {3, 3};
}

- (void)setInputState:(InputState)state {
    _world.set_input(state);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    if (size.width > 0 && size.height > 0)
        _projMatrix = make_perspective(kFOVY, (float)size.width / (float)size.height,
                                       kNearPlane, kFarPlane);
}

- (void)drawInMTKView:(MTKView *)view {
    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);

    CFTimeInterval now = CACurrentMediaTime();
    float physicalDt = (float)(now - _lastTime);
    _lastTime = now;
    if (physicalDt > 0.1f) physicalDt = 0.1f;

    _world.update(physicalDt, physicalDt);

    // Camera follows player; if none, look at origin.
    simd_float3 target = {0, 0, 0};
    for (EntityID id = 0; id < _world.entity_count(); ++id) {
        if (_world.player_tags().present(id) &&
            _world.has_component<PositionComponent>(id)) {
            auto& p = _world.get_component<PositionComponent>(id);
            target  = {p.x, p.y, 0};
            break;
        }
    }

    // Apply screen shake offset to camera target.
    simd_float2 shake = ScreenShakeSystem_offset(_world);
    target.x += shake.x;
    target.y += shake.y;

    // Z-up world: camera sits above-and-behind the target at kCamPitch degrees.
    simd_float3 eye = {
        target.x,
        target.y - kCamDist * cosf(kCamPitch),
        kCamDist * sinf(kCamPitch)
    };
    simd_float4x4 viewMtx = make_look_at(eye, target, (simd_float3){0, 0, 1});
    simd_float4x4 vp      = simd_mul(_projMatrix, viewMtx);

    // Command buffer — semaphore signalled in completedHandler.
    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    __block dispatch_semaphore_t sem = _frameSemaphore;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull b) {
        dispatch_semaphore_signal(sem);
    }];

    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (rpd && view.currentDrawable) {
        rpd.colorAttachments[0].clearColor  = MTLClearColorMake(0.08, 0.08, 0.12, 1.0);
        rpd.colorAttachments[0].loadAction  = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
        [enc setRenderPipelineState:_pipeline];
        [enc setDepthStencilState:_depthState];
        [enc setVertexBuffer:_quadVB offset:0 atIndex:0];

        uint32_t count = _world.entity_count();
        for (EntityID eid = 0; eid < count; ++eid) {
            if (!_world.has_component<PositionComponent>(eid)) continue;

            auto& pos = _world.get_component<PositionComponent>(eid);

            simd_float4 color = {1, 1, 1, 1};
            if (_world.has_component<FactionComponent>(eid)) {
                switch (_world.get_component<FactionComponent>(eid).type) {
                    case FactionComponent::Player:
                        color = {0.2f, 0.9f, 0.3f, 1.f}; break; // green
                    case FactionComponent::Enemy:
                        color = {0.9f, 0.2f, 0.15f, 1.f}; break; // red
                }
            }

            DrawUniforms u;
            u.mvp   = simd_mul(vp, make_model(pos.x, pos.y, kEntitySize));
            u.color = color;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }

        [enc endEncoding];
        [cmd presentDrawable:view.currentDrawable];
    }
    [cmd commit];
}

@end

// ---------------------------------------------------------------------------
// GameViewController — key tracking → InputState → BrawlerDelegate
// ---------------------------------------------------------------------------
@implementation GameViewController {
    MTKView         *_mtkView;
    BrawlerDelegate *_delegate;
    BOOL _left, _right, _up, _down, _attack, _dodge;
}

- (void)loadView {
    _mtkView = [[MTKView alloc] initWithFrame:NSMakeRect(0, 0, 960, 720)
                                       device:MTLCreateSystemDefaultDevice()];
    _mtkView.colorPixelFormat        = MTLPixelFormatBGRA8Unorm;
    _mtkView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    self.view = _mtkView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _delegate = [[BrawlerDelegate alloc] initWithDevice:_mtkView.device
                                            pixelFormat:_mtkView.colorPixelFormat];
    [_delegate mtkView:_mtkView drawableSizeWillChange:_mtkView.drawableSize];
    _mtkView.delegate = _delegate;

    [NSTimer scheduledTimerWithTimeInterval:1.0 / 120.0
                                     target:self
                                   selector:@selector(_feedInput)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self.view.window makeFirstResponder:self];
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)_feedInput {
    float mx = (_right ? 1.f : 0.f) - (_left ? 1.f : 0.f);
    float my = (_up    ? 1.f : 0.f) - (_down ? 1.f : 0.f);
    InputState s = { mx, my, (bool)_attack, (bool)_dodge, false };
    [_delegate setInputState:s];
    _attack = NO;
    _dodge  = NO;
}

- (void)keyDown:(NSEvent *)event {
    if (event.isARepeat) return;
    switch (event.keyCode) {
        case 0:   _left   = YES; break; // A
        case 2:   _right  = YES; break; // D
        case 13:  _up     = YES; break; // W
        case 1:   _down   = YES; break; // S
        case 123: _left   = YES; break; // ←
        case 124: _right  = YES; break; // →
        case 126: _up     = YES; break; // ↑
        case 125: _down   = YES; break; // ↓
        case 49:  _attack = YES; break; // space
        case 56:  _dodge  = YES; break; // shift
        default: [super keyDown:event];
    }
}

- (void)keyUp:(NSEvent *)event {
    switch (event.keyCode) {
        case 0:   _left  = NO; break;
        case 2:   _right = NO; break;
        case 13:  _up    = NO; break;
        case 1:   _down  = NO; break;
        case 123: _left  = NO; break;
        case 124: _right = NO; break;
        case 126: _up    = NO; break;
        case 125: _down  = NO; break;
        default: [super keyUp:event];
    }
}

@end
