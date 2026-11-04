#import "nvn_raytrace.h"
#include <math.h>
#include <string.h>

#define RAY_VERTICES (4u * 1024u * 1024u)
#define RAY_TRIANGLES (2u * 1024u * 1024u)
#define RAY_MSL(...) @#__VA_ARGS__
static NSString *ray_source(void) {
    return @"#include <metal_stdlib>\n#include <metal_raytracing>\n"
    RAY_MSL(
    using namespace metal;
    using namespace raytracing;
    struct RayCamera { float4 inverse[4]; float radius, strength, bias, tolerance; uint width, height, flip, zero_near; };
    float4 ray_mul(constant RayCamera& c, float4 p) {
        return float4(dot(c.inverse[0],p),dot(c.inverse[1],p),dot(c.inverse[2],p),dot(c.inverse[3],p));
    }
    kernel void ray_gather(device const uint4* captured [[buffer(0)]], device const uint* indices [[buffer(1)]],
                           device packed_float3* triangles [[buffer(2)]], constant uint& count [[buffer(3)]], uint t [[thread_position_in_grid]]) {
        if (t >= count) return;
        uint4 a=captured[indices[3*t]], b=captured[indices[3*t+1]], c=captured[indices[3*t+2]];
        bool good=a.w && b.w && c.w;
        triangles[3*t]=good ? as_type<float3>(a.xyz) : float3(0);
        triangles[3*t+1]=good ? as_type<float3>(b.xyz) : float3(0);
        triangles[3*t+2]=good ? as_type<float3>(c.xyz) : float3(0);
    }
    kernel void ray_ao(primitive_acceleration_structure scene [[buffer(0)]], device const packed_float3* triangles [[buffer(1)]],
                       constant RayCamera& c [[buffer(2)]], depth2d<float, access::read> depth [[texture(0)]],
                       texture2d<float, access::write> output [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= output.get_width() || p.y >= output.get_height()) return;
        uint2 q=min(p*2+1,uint2(c.width-1,c.height-1)); float d=depth.read(q);
        output.write(float4(1,0,0,0),p);
        if (!isfinite(d) || d <= 0.000001f || d >= 0.999999f) return;
        float2 xy=(float2(q)+0.5f)/float2(c.width,c.height)*2.0f-1.0f;
        if (!c.flip) xy.y=-xy.y;
        float4 h=ray_mul(c,float4(xy,c.zero_near ? d : d*2-1,1));
        float4 eye=ray_mul(c,float4(0,0,1,0));
        if (abs(h.w)<1e-8f || abs(eye.w)<1e-8f) return;
        float3 world=h.xyz/h.w, origin=eye.xyz/eye.w, delta=world-origin;
        float dist=length(delta); if (!isfinite(dist) || dist<1e-6f) return;
        float3 direction=delta/dist;
        intersector<triangle_data> tracer; tracer.assume_geometry_type(geometry_type::triangle);
        tracer.force_opacity(forced_opacity::opaque);
        ray r; r.origin=origin; r.direction=direction; r.min_distance=0; r.max_distance=dist+max(c.tolerance,c.radius*0.1f);
        auto hit=tracer.intersect(r,scene);
        if (hit.type==intersection_type::none || abs(hit.distance-dist)>max(c.tolerance,dist*0.002f)) return;
        uint t=hit.primitive_id*3; float3 a=triangles[t], b=triangles[t+1], v=triangles[t+2];
        float3 n=cross(b-a,v-a); float len=length(n); if (!isfinite(len) || len<1e-10f) return;
        n/=len; if (dot(n,direction)>0) n=-n;
        float3 tangent=normalize(cross(abs(n.y)<0.9f ? float3(0,1,0) : float3(1,0,0),n));
        float3 bitangent=cross(n,tangent); uint hash=(p.x*1664525u+p.y*1013904223u); hash^=hash>>16;
        float rotation=float(hash&65535u)*(6.28318530718f/65536.0f); float occlusion=0;
        tracer.accept_any_intersection(true);
        for (uint i=0;i<8;i++) {
            float u=(float(i)+0.5f)/8.0f, phi=float(i)*2.39996323f+rotation;
            float rr=sqrt(u); float3 local=float3(rr*cos(phi),rr*sin(phi),sqrt(1-u));
            r.origin=origin+direction*hit.distance+n*c.bias;
            r.direction=tangent*local.x+bitangent*local.y+n*local.z;
            r.min_distance=c.bias; r.max_distance=c.radius;
            auto blocker=tracer.intersect(r,scene); occlusion+=blocker.type!=intersection_type::none ? 1.0f : 0.0f;
        }
        output.write(float4(1.0f-c.strength*occlusion/8.0f,dist,1,0),p);
    }
    struct RayBlit { float4 position [[position]]; float2 uv; };
    vertex RayBlit ray_fullscreen(uint i [[vertex_id]]) {
        float2 p=float2((i<<1)&2,i&2); RayBlit o; o.position=float4(p*2-1,0,1); o.uv=float2(p.x,1-p.y); return o;
    }
    fragment float4 ray_composite(RayBlit in [[stage_in]], texture2d<float> ao [[texture(0)]],
                                  depth2d<float, access::read> depth [[texture(1)]], constant RayCamera& c [[buffer(0)]]) {
        uint2 q=min(uint2(in.position.xy),uint2(c.width-1,c.height-1)); float d=depth.read(q);
        float2 xy=(float2(q)+0.5f)/float2(c.width,c.height)*2-1; if (!c.flip) xy.y=-xy.y;
        float4 h=ray_mul(c,float4(xy,c.zero_near ? d : d*2-1,1)), eye=ray_mul(c,float4(0,0,1,0));
        if (d<=0.000001f || d>=0.999999f || abs(h.w)<1e-8f || abs(eye.w)<1e-8f) return float4(1);
        float dist=length(h.xyz/h.w-eye.xyz/eye.w), sum=0, weight=0;
        int2 center=int2(q/2), extent=int2(ao.get_width(),ao.get_height());
        for (int y=-1;y<=1;y++) for (int x=-1;x<=1;x++) {
            int2 p=clamp(center+int2(x,y),int2(0),extent-1); float4 a=ao.read(uint2(p));
            float w=exp(-abs(a.y-dist)/max(c.tolerance,dist*0.002f))*a.z/(1+float(x*x+y*y));
            sum+=a.x*w; weight+=w;
        }
        return float4(weight>1e-5f ? sum/weight : 1.0f);
    }
    );
}
#undef RAY_MSL

@interface NvRayPipelines : NSObject {
@public id<MTLLibrary> library; id<MTLComputePipelineState> gather, ao;
    NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *composite;
}
@end
@implementation NvRayPipelines @end

static NvRayPipelines *ray_pipelines(id<MTLDevice> dev, NSError **error) {
    static NvRayPipelines *p;
    if (p) return p;
    NvRayPipelines *next=[NvRayPipelines new];
    MTLCompileOptions *options=[MTLCompileOptions new]; options.mathMode=MTLMathModeSafe; options.languageVersion=MTLLanguageVersion4_0;
    next->library=[dev newLibraryWithSource:ray_source() options:options error:error]; if (!next->library) return nil;
    next->gather=[dev newComputePipelineStateWithFunction:[next->library newFunctionWithName:@"ray_gather"] error:error];
    next->ao=[dev newComputePipelineStateWithFunction:[next->library newFunctionWithName:@"ray_ao"] error:error];
    if (!next->gather || !next->ao) return nil;
    next->composite=[NSMutableDictionary dictionary]; p=next; return p;
}

static id<MTL4ArgumentTable> ray_table(id<MTLDevice> dev) {
    MTL4ArgumentTableDescriptor *d=[MTL4ArgumentTableDescriptor new]; d.maxBufferBindCount=4; d.maxTextureBindCount=2;
    return [dev newArgumentTableWithDescriptor:d error:nil];
}
static void ray_begin(id<MTL4CommandEncoder> e) {
    [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
}
static void ray_end(id<MTL4CommandEncoder> e) {
    [e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [e endEncoding];
}

@implementation NvRayScene
- (instancetype)initWithDevice:(id<MTLDevice>)dev {
    if (!(self=[super init]) || !dev.supportsRaytracing || ![dev supportsFamily:MTLGPUFamilyApple9]) return nil;
    device=dev;
    vertices=[dev newBufferWithLength:RAY_VERTICES*16 options:MTLResourceStorageModeShared];
    indices=[dev newBufferWithLength:RAY_TRIANGLES*12 options:MTLResourceStorageModeShared];
    triangles=[dev newBufferWithLength:RAY_TRIANGLES*36 options:MTLResourceStorageModePrivate];
    params=[dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    residency=[dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:nil];
    if (!vertices || !indices || !triangles || !params || !residency) return nil;
    memset(vertices.contents,0,vertices.length);
    for (id<MTLAllocation> a in @[vertices,indices,triangles,params]) [residency addAllocation:a];
    [residency commit]; return self;
}
- (void)reset {
    memset(vertices.contents,0,(size_t)vertex_count*16);
    vertex_count=triangle_count=rejected=draws=0; overflow=applied=NO;
}
- (BOOL)appendIndices:(const uint32_t *)ix count:(uint32_t)count primitive:(int)primitive
          baseVertex:(int32_t)baseVertex baseInstance:(uint32_t)baseInstance
           instances:(uint32_t)instances inverse:(const float *)inverse capture:(nvn_ray_capture *)capture {
    memset(capture,0,sizeof *capture);
    if (!ix || count<3 || !instances || instances>4096 || (primitive!=4 && primitive!=5)) { rejected++; return NO; }
    uint32_t lo=UINT32_MAX, hi=0;
    for (uint32_t i=0;i<count;i++) { if (ix[i]<lo) lo=ix[i]; if (ix[i]>hi) hi=ix[i]; }
    int64_t first=(int64_t)lo+baseVertex, last=(int64_t)hi+baseVertex;
    if (first<0 || last>UINT32_MAX || hi-lo>=RAY_VERTICES || (uint64_t)baseInstance+instances>UINT32_MAX) { rejected++; return NO; }
    uint64_t per=(uint64_t)hi-lo+1, nv=per*instances;
    uint32_t nt=primitive==4 ? count/3 : count-2;
    if (nv>RAY_VERTICES-vertex_count || (uint64_t)nt*instances>RAY_TRIANGLES-triangle_count) { overflow=YES; rejected++; return NO; }
    uint32_t *dst=(uint32_t *)indices.contents+3*triangle_count;
    for (uint32_t instance=0;instance<instances;instance++) for (uint32_t t=0;t<nt;t++) {
        uint32_t a=primitive==4 ? 3*t : t, b=a+1, c=a+2;
        if (primitive==5 && (t&1)) { uint32_t swap=a; a=b; b=swap; }
        uint32_t base=vertex_count+(uint32_t)per*instance;
        *dst++=base+ix[a]-lo; *dst++=base+ix[b]-lo; *dst++=base+ix[c]-lo;
    }
    capture->vertices=vertices.gpuAddress+(uint64_t)vertex_count*16;
    capture->first=(uint32_t)first; capture->count=(uint32_t)per; capture->base_instance=baseInstance; capture->instances=instances;
    memcpy(capture->inverse,inverse,sizeof capture->inverse);
    vertex_count+=(uint32_t)nv; triangle_count+=nt*instances; draws++; return YES;
}
- (BOOL)encode:(id<MTL4CommandBuffer>)cb color:(id<MTLTexture>)color depth:(id<MTLTexture>)depth
         camera:(const nvn_ray_camera *)camera error:(NSError **)error {
    if (applied || overflow || !triangle_count || !color || !depth || color.width!=depth.width || color.height!=depth.height ||
        color.sampleCount!=1 || depth.sampleCount!=1 || color.textureType!=MTLTextureType2D || depth.textureType!=MTLTextureType2D ||
        !camera || camera->width!=color.width || camera->height!=color.height || !isfinite(camera->radius) || camera->radius<=0) return NO;
    NvRayPipelines *p=ray_pipelines(device,error); if (!p) return NO;
    id<MTLRenderPipelineState> composite=p->composite[@(color.pixelFormat)];
    if (!composite) {
        MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
        d.vertexFunction=[p->library newFunctionWithName:@"ray_fullscreen"]; d.fragmentFunction=[p->library newFunctionWithName:@"ray_composite"];
        d.colorAttachments[0].pixelFormat=color.pixelFormat; d.colorAttachments[0].blendingEnabled=YES;
        d.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorZero; d.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorSourceColor;
        d.colorAttachments[0].sourceAlphaBlendFactor=MTLBlendFactorZero; d.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorOne;
        composite=[device newRenderPipelineStateWithDescriptor:d error:error]; if (!composite) return NO;
        p->composite[@(color.pixelFormat)]=composite;
    }
    NSUInteger aw=(color.width+1)/2, ah=(color.height+1)/2;
    if (!visibility || visibility.width!=aw || visibility.height!=ah) {
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:aw height:ah mipmapped:NO];
        d.storageMode=MTLStorageModePrivate; d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        id<MTLTexture> next=[device newTextureWithDescriptor:d]; if (!next) return NO;
        if (visibility) [residency removeAllocation:visibility]; visibility=next; [residency addAllocation:visibility];
    }
    MTL4AccelerationStructureTriangleGeometryDescriptor *geometry=[MTL4AccelerationStructureTriangleGeometryDescriptor new];
    geometry.vertexBuffer=(MTL4BufferRange){triangles.gpuAddress,triangle_count*36ull}; geometry.vertexStride=12;
    geometry.triangleCount=triangle_count; geometry.opaque=YES;
    MTL4PrimitiveAccelerationStructureDescriptor *desc=[MTL4PrimitiveAccelerationStructureDescriptor new];
    desc.geometryDescriptors=@[geometry]; desc.usage=MTLAccelerationStructureUsagePreferFastBuild;
    MTLAccelerationStructureSizes sizes=[device accelerationStructureSizesWithDescriptor:desc];
    if (!acceleration || acceleration.size<sizes.accelerationStructureSize) {
        id<MTLAccelerationStructure> next=[device newAccelerationStructureWithSize:sizes.accelerationStructureSize]; if (!next) return NO;
        if (acceleration) [residency removeAllocation:acceleration]; acceleration=next; [residency addAllocation:acceleration];
    }
    if (!scratch || scratch.length<sizes.buildScratchBufferSize) {
        id<MTLBuffer> next=[device newBufferWithLength:sizes.buildScratchBufferSize options:MTLResourceStorageModePrivate]; if (!next) return NO;
        if (scratch) [residency removeAllocation:scratch]; scratch=next; [residency addAllocation:scratch];
    }
    memcpy(params.contents,camera,sizeof *camera); memcpy((uint8_t *)params.contents+128,&triangle_count,sizeof triangle_count);
    [residency commit]; [cb useResidencySet:residency];
    id<MTL4ArgumentTable> table=ray_table(device); if (!table) return NO;
    id<MTL4ComputeCommandEncoder> ce=[cb computeCommandEncoder]; ray_begin(ce); [ce setArgumentTable:table];
    [table setAddress:vertices.gpuAddress atIndex:0]; [table setAddress:indices.gpuAddress atIndex:1];
    [table setAddress:triangles.gpuAddress atIndex:2]; [table setAddress:params.gpuAddress+128 atIndex:3];
    [ce setComputePipelineState:p->gather]; [ce dispatchThreads:MTLSizeMake(triangle_count,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)]; ray_end(ce);
    ce=[cb computeCommandEncoder]; ray_begin(ce);
    [ce buildAccelerationStructure:acceleration descriptor:desc scratchBuffer:(MTL4BufferRange){scratch.gpuAddress,scratch.length}]; ray_end(ce);
    ce=[cb computeCommandEncoder]; ray_begin(ce); [ce setArgumentTable:table];
    [table setResource:acceleration.gpuResourceID atBufferIndex:0]; [table setAddress:triangles.gpuAddress atIndex:1]; [table setAddress:params.gpuAddress atIndex:2];
    [table setTexture:depth.gpuResourceID atIndex:0]; [table setTexture:visibility.gpuResourceID atIndex:1];
    [ce setComputePipelineState:p->ao]; [ce dispatchThreads:MTLSizeMake(aw,ah,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; ray_end(ce);
    MTL4RenderPassDescriptor *rp=[MTL4RenderPassDescriptor new]; rp.colorAttachments[0].texture=color;
    rp.colorAttachments[0].loadAction=MTLLoadActionLoad; rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> re=[cb renderCommandEncoderWithDescriptor:rp]; ray_begin(re);
    [table setAddress:params.gpuAddress atIndex:0]; [table setTexture:visibility.gpuResourceID atIndex:0]; [table setTexture:depth.gpuResourceID atIndex:1];
    [re setArgumentTable:table atStages:MTLRenderStageFragment]; [re setRenderPipelineState:composite];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; ray_end(re);
    applied=YES; return YES;
}
@end
