#pragma once
#import <Metal/Metal.h>

typedef struct {
    uint64_t vertices;
    uint32_t first, count, base_instance, instances;
    uint32_t pad[2];
    float inverse[16];
} nvn_ray_capture;

typedef struct {
    float inverse[16];
    float radius, strength, bias, depth_tolerance;
    uint32_t width, height, flip, zero_near;
} nvn_ray_camera;

int nvn_ray_inverse(const float view[16], const float projection[16], float out[16]);
NSString *nvn_ray_vertex_source(NSString *source);

// A scene owns every resource until its final submission completes. Reset only
// after that fence, including frames where the composite pass was not reached.
@interface NvRayScene : NSObject {
@public
    id<MTLDevice> device;
    id<MTLBuffer> vertices, indices, triangles, scratch, params;
    id<MTLAccelerationStructure> acceleration;
    id<MTLResidencySet> residency;
    id<MTLTexture> visibility;
    uint32_t vertex_count, triangle_count, rejected, draws;
    uint64_t frame, fence;
    BOOL overflow, applied;
}
- (instancetype)initWithDevice:(id<MTLDevice>)dev;
- (void)reset;
- (BOOL)appendIndices:(const uint32_t *)ix count:(uint32_t)count primitive:(int)primitive
          baseVertex:(int32_t)baseVertex baseInstance:(uint32_t)baseInstance
           instances:(uint32_t)instances inverse:(const float *)inverse capture:(nvn_ray_capture *)capture;
- (BOOL)encode:(id<MTL4CommandBuffer>)cb color:(id<MTLTexture>)color
         depth:(id<MTLTexture>)depth camera:(const nvn_ray_camera *)camera error:(NSError **)error;
@end
