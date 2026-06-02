#import "BrawlerRenderer.h"
#import <simd/simd.h>
#include "Simulation/World.h"
#include "Simulation/RoomBounds.h"

typedef struct { simd_float4x4 mvp; simd_float4 color; } DrawUniforms;

static const simd_float3 kQuadVerts[6] = {
    {-0.5f,-0.5f,0.f},{ 0.5f,-0.5f,0.f},{-0.5f, 0.5f,0.f},
    { 0.5f,-0.5f,0.f},{ 0.5f, 0.5f,0.f},{-0.5f, 0.5f,0.f},
};

static const float kEntitySize = 40.0f;
static const float kCamDist    = 800.0f;
static const float kCamPitch   = 55.0f * ((float)M_PI / 180.0f);
static const float kFOVY       = 70.0f * ((float)M_PI / 180.0f);
static const float kNear       = 1.0f;
static const float kFar        = 3000.0f;

static simd_float4x4 make_perspective(float fovY, float aspect, float n, float f) {
    float t = 1.f / tanf(fovY * .5f);
    simd_float4x4 m = {};
    m.columns[0].x = t / aspect;  m.columns[1].y = t;
    m.columns[2].z = f/(n-f);     m.columns[2].w = -1.f;
    m.columns[3].z = n*f/(n-f);
    return m;
}

static simd_float4x4 make_look_at(simd_float3 eye, simd_float3 tgt, simd_float3 up) {
    simd_float3 f = simd_normalize(tgt-eye);
    simd_float3 r = simd_normalize(simd_cross(f,up));
    simd_float3 u = simd_cross(r,f);
    simd_float4x4 m;
    m.columns[0]=(simd_float4){r.x,u.x,-f.x,0};
    m.columns[1]=(simd_float4){r.y,u.y,-f.y,0};
    m.columns[2]=(simd_float4){r.z,u.z,-f.z,0};
    m.columns[3]=(simd_float4){-simd_dot(r,eye),-simd_dot(u,eye),simd_dot(f,eye),1};
    return m;
}

static simd_float4x4 make_model(float x, float y, float s) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = s; m.columns[1].y = s; m.columns[2].z = s;
    m.columns[3] = (simd_float4){x,y,0.f,1.f};
    return m;
}

// Non-uniform scale — used for floor quad and wall strips.
static simd_float4x4 make_model_rect(float x, float y, float z, float w, float h) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = w; m.columns[1].y = h; m.columns[2].z = 1.f;
    m.columns[3] = (simd_float4){x, y, z, 1.f};
    return m;
}

static float clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

@implementation BrawlerRenderer {
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState>   _depthState;
    id<MTLBuffer>              _quadVB;
    simd_float4x4              _proj;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pfmt {
    self = [super init];
    if (!self) return nil;

    _quadVB = [device newBufferWithBytes:kQuadVerts length:sizeof(kQuadVerts)
                                 options:MTLResourceStorageModeShared];
    _proj   = matrix_identity_float4x4;

    id<MTLLibrary> lib = [device newDefaultLibrary];
    if (!lib) { NSLog(@"BrawlerRenderer: no default Metal library"); return nil; }

    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction   = [lib newFunctionWithName:@"vertex_main"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fragment_main"];
    pd.colorAttachments[0].pixelFormat = pfmt;
    pd.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;

    MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
    vd.attributes[0].format = MTLVertexFormatFloat3;
    vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
    vd.layouts[0].stride    = sizeof(simd_float3);
    pd.vertexDescriptor = vd;

    NSError *err = nil;
    _pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!_pipeline) { NSLog(@"Pipeline: %@", err); return nil; }

    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLess;
    dd.depthWriteEnabled    = YES;
    _depthState = [device newDepthStencilStateWithDescriptor:dd];
    return self;
}

- (void)updateDrawableSize:(CGSize)size {
    if (size.width > 0 && size.height > 0)
        _proj = make_perspective(kFOVY, (float)size.width/(float)size.height, kNear, kFar);
}

- (void)drawWorld:(World*)world inView:(MTKView*)view commandBuffer:(id<MTLCommandBuffer>)cmd {
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd || !view.currentDrawable) return;

    // Camera follows player, clamped to room so void is never visible.
    simd_float3 target = {kCameraDefaultTargetX, kCameraDefaultTargetY, 0};
    for (EntityID id = 0; id < world->entity_count(); ++id) {
        if (world->player_tags().present(id) && world->has_component<PositionComponent>(id)) {
            auto& p = world->get_component<PositionComponent>(id);
            target = {p.x, p.y, 0};
            break;
        }
    }
    // Clamp camera target so the view frustum stays within room bounds.
    // Padding ≈ half visible ground width at the camera's pitch & FOV.
    static const float kCamPadX = 320.f;
    static const float kCamPadY = 220.f;
    target.x = clampf(target.x, kRoomMinX + kCamPadX, kRoomMaxX - kCamPadX);
    target.y = clampf(target.y, kRoomMinY + kCamPadY, kRoomMaxY - kCamPadY);

    simd_float3 eye = { target.x,
                        target.y - kCamDist * cosf(kCamPitch),
                        kCamDist  * sinf(kCamPitch) };
    simd_float4x4 vp = simd_mul(_proj, make_look_at(eye, target, (simd_float3){0,0,1}));

    rpd.colorAttachments[0].clearColor  = MTLClearColorMake(0.08,0.08,0.12,1);
    rpd.colorAttachments[0].loadAction  = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
    [enc setRenderPipelineState:_pipeline];
    [enc setDepthStencilState:_depthState];
    [enc setVertexBuffer:_quadVB offset:0 atIndex:0];

    // Floor quad — drawn first at Z=-1 so entities render on top.
    {
        DrawUniforms u;
        u.mvp   = simd_mul(vp, make_model_rect(kRoomCenterX, kRoomCenterY, -1.f,
                                               kRoomWidth, kRoomHeight));
        u.color = (simd_float4){0.13f, 0.13f, 0.18f, 1.f}; // slightly lighter than clear
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }

    // Wall outlines — thin quads along each boundary edge, at Z=0.
    static const simd_float4 kWallColor = {0.30f, 0.30f, 0.40f, 1.f};
    static const float kWallThick = 20.f;
    struct { float cx,cy,w,h; } walls[4] = {
        {kRoomCenterX, kRoomMinY + kWallThick*0.5f, kRoomWidth, kWallThick}, // bottom
        {kRoomCenterX, kRoomMaxY - kWallThick*0.5f, kRoomWidth, kWallThick}, // top
        {kRoomMinX + kWallThick*0.5f, kRoomCenterY, kWallThick, kRoomHeight}, // left
        {kRoomMaxX - kWallThick*0.5f, kRoomCenterY, kWallThick, kRoomHeight}, // right
    };
    for (auto& w : walls) {
        DrawUniforms u;
        u.mvp   = simd_mul(vp, make_model_rect(w.cx, w.cy, 0.f, w.w, w.h));
        u.color = kWallColor;
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }

    for (EntityID eid = 0; eid < world->entity_count(); ++eid) {
        if (!world->has_component<PositionComponent>(eid)) continue;
        auto& pos = world->get_component<PositionComponent>(eid);

        simd_float4 color = {1,1,1,1};
        if (world->has_component<FactionComponent>(eid)) {
            switch (world->get_component<FactionComponent>(eid).type) {
                case FactionComponent::Player: color = {0.2f,0.9f,0.3f,1.f}; break;
                case FactionComponent::Enemy:  color = {0.9f,0.2f,0.15f,1.f}; break;
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

@end
