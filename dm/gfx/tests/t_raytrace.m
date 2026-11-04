#import "../nvn/nvn_raytrace.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); return 1; } } while (0)
static const float identity[16]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
_Static_assert(sizeof(nvn_ray_capture)==96,"capture ABI");
_Static_assert(sizeof(nvn_ray_camera)==96,"camera ABI");
static int submit(id<MTL4CommandQueue> queue, id<MTL4CommandBuffer> cb) {
    [cb endCommandBuffer]; dispatch_semaphore_t done=dispatch_semaphore_create(0); __block NSError *error;
    MTL4CommitOptions *options=[MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> f) { error=f.error; dispatch_semaphore_signal(done); }];
    id<MTL4CommandBuffer> buffers[]={cb}; [queue commit:buffers count:1 options:options];
    CHECK(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC)));
    if (error) fprintf(stderr,"%s\n",error.description.UTF8String); CHECK(!error); return 0;
}

static int lighting(id<MTLDevice> dev, id<MTL4CommandQueue> queue, int blocker, int mismatch, int zero_near, int flip) {
    NvRayScene *scene=[[NvRayScene alloc] initWithDevice:dev]; CHECK(scene);
    uint32_t ix[]={0,1,2,2,1,3,4,5,6,6,5,7}; nvn_ray_capture cap;
    // A plane at z=-4, viewed from the origin. A vertical wall at x=0 casts
    // contact occlusion without obscuring the plane's center from the camera.
    float xyz[][3]={{-8,-8,-4},{8,-8,-4},{-8,8,-4},{8,8,-4},{0,-8,-4},{0,-8,-2},{0,8,-4},{0,8,-2}};
    float projection[16]={1,0,0,0,0,1,0,0,0,0,zero_near ? -10.f/9 : -11.f/9,zero_near ? -10.f/9 : -20.f/9,0,0,-1,0};
    nvn_ray_camera camera={.radius=2,.strength=.8f,.bias=.005f,.depth_tolerance=.02f,.width=64,.height=64,.flip=flip,.zero_near=zero_near};
    CHECK(nvn_ray_inverse(identity,projection,camera.inverse));
    CHECK([scene appendIndices:ix count:blocker ? 12 : 6 primitive:4 baseVertex:0 baseInstance:0 instances:1 inverse:camera.inverse capture:&cap]);
    uint32_t *v=scene->vertices.contents;
    for (int i=0;i<(blocker ? 8 : 4);i++) { memcpy(v+4*i,xyz[i],12); v[4*i+3]=1; }
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> color=[dev newTextureWithDescriptor:d]; CHECK(color);
    uint8_t white[64*64*4]; memset(white,255,sizeof white);
    for (int i=0;i<64*64;i++) white[4*i+3]=137;
    [color replaceRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0 withBytes:white bytesPerRow:256];
    d.pixelFormat=MTLPixelFormatDepth32Float; d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    id<MTLTexture> depth=[dev newTextureWithDescriptor:d]; CHECK(depth);
    float z=mismatch ? -3 : -4, clip=(projection[10]*z+projection[11])/-z; if (!zero_near) clip=clip*.5f+.5f;
    float depths[64*64]; for(int i=0;i<64*64;i++) depths[i]=clip;
    [depth replaceRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0 withBytes:depths bytesPerRow:256];
    id<MTLResidencySet> rs=[dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:nil];
    [rs addAllocation:color]; [rs addAllocation:depth]; [rs commit];
    id<MTL4CommandAllocator> allocator=[dev newCommandAllocatorWithDescriptor:[MTL4CommandAllocatorDescriptor new] error:nil];
    id<MTL4CommandBuffer> cb=[dev newCommandBuffer]; [cb beginCommandBufferWithAllocator:allocator]; [cb useResidencySet:rs];
    NSError *error=nil; BOOL encoded=[scene encode:cb color:color depth:depth camera:&camera error:&error];
    if(error) fprintf(stderr,"%s\n",error.description.UTF8String); CHECK(encoded);
    CHECK(!submit(queue,cb));
    uint8_t output[sizeof white]; [color getBytes:output bytesPerRow:256 fromRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0];
    int dark=0, changed=0; unsigned near_sum=0, far_sum=0, n=0;
    for (int y=8;y<56;y++) for(int x=0;x<64;x++) {
        uint8_t *p=output+4*(y*64+x); CHECK(p[3]==137); CHECK(p[0]==p[1] && p[1]==p[2]);
        dark+=p[0]<250; changed+=p[0]!=255;
        if(x>=26 && x<31) { near_sum+=p[0]; far_sum+=output[4*(y*64+x-24)]; n++; }
    }
    printf("blocker=%d mismatch=%d zero=%d flip=%d dark=%d near=%.2f far=%.2f\n",blocker,mismatch,zero_near,flip,dark,(double)near_sum/n,(double)far_sum/n);
    if(!blocker || mismatch) CHECK(!changed);
    else { CHECK(dark>100); CHECK(near_sum+20*n<far_sum); }
    [scene reset]; CHECK(!scene->vertex_count && !scene->triangle_count && !scene->applied);
    return 0;
}

static int capture_raster(id<MTLDevice> dev, int zero_near) {
    const float world[3][3]={{-.8f,-.6f,-4},{2,-.4f,-5},{.8f,1.1f,-3.5f}};
    const float view[16]={1,0,0,-1,0,1,0,.3f,0,0,1,-.5f,0,0,0,1};
    const float projection[16]={1.4f,0,0,0,0,1.6f,0,0,0,0,zero_near ? -10.f/9 : -11.f/9,zero_near ? -10.f/9 : -20.f/9,0,0,-1,0};
    float inverse[16]; CHECK(nvn_ray_inverse(view,projection,inverse));
    NSString *body=[NSString stringWithFormat:@"main0_out out; constexpr float3 p[3]={float3(-.8,-.6,-4),float3(2,-.4,-5),float3(.8,1.1,-3.5)}; float3 v=p[i]+float3(-1,.3,-.5); out.gl_Position=float4(1.4*v.x,1.6*v.y,(%.9ff)*v.z+(%.9ff),-v.z);",projection[10],projection[11]];
    NSString *source=[NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\nstruct main0_out { float4 gl_Position [[position]]; };\nvertex main0_out main0(uint i [[vertex_id]]) { %@ out.gl_Position.z=out.gl_Position.z*.5f+out.gl_Position.w*.5f; return out; }\nvertex main0_out main0_z(uint i [[vertex_id]]) { %@ return out; }\nfragment float4 color() { return float4(.25,.5,.75,1); }\n",body,body];
    NvRayScene *scene=[[NvRayScene alloc] initWithDevice:dev]; CHECK(scene);
    uint32_t ix[]={0,1,2}; nvn_ray_capture capture;
    CHECK([scene appendIndices:ix count:3 primitive:4 baseVertex:0 baseInstance:0 instances:1 inverse:inverse capture:&capture]);
    id<MTLBuffer> params=[dev newBufferWithBytes:&capture length:sizeof capture options:MTLResourceStorageModeShared]; CHECK(params);
    uint8_t pixels[2][32*32*4];
    for(int mode=0;mode<2;mode++) {
        NSError *error=nil; MTLCompileOptions *options=[MTLCompileOptions new];
        options.mathMode=MTLMathModeSafe; options.preserveInvariance=YES;
        id<MTLLibrary> library=[dev newLibraryWithSource:mode ? nvn_ray_vertex_source(source) : source options:options error:&error];
        if(error) fprintf(stderr,"%s\n",error.description.UTF8String); CHECK(library);
        MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
        d.vertexFunction=[library newFunctionWithName:zero_near ? @"main0_z" : @"main0"];
        d.fragmentFunction=[library newFunctionWithName:@"color"]; d.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> ps=[dev newRenderPipelineStateWithDescriptor:d error:&error]; CHECK(ps);
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:32 mipmapped:NO];
        td.storageMode=MTLStorageModeShared; td.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> color=[dev newTextureWithDescriptor:td]; CHECK(color);
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor new]; rp.colorAttachments[0].texture=color;
        rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
        rp.colorAttachments[0].loadAction=MTLLoadActionClear; rp.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLCommandQueue> queue=[dev newCommandQueue]; id<MTLCommandBuffer> cb=[queue commandBuffer];
        id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp]; [en setRenderPipelineState:ps];
        [en setViewport:(MTLViewport){0,0,32,32,0,1}];
        if(mode) { [en setVertexBuffer:params offset:0 atIndex:13]; [en useResource:scene->vertices usage:MTLResourceUsageWrite]; }
        [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
        [cb commit]; [cb waitUntilCompleted]; CHECK(cb.status==MTLCommandBufferStatusCompleted);
        [color getBytes:pixels[mode] bytesPerRow:128 fromRegion:MTLRegionMake2D(0,0,32,32) mipmapLevel:0];
    }
    CHECK(!memcmp(pixels[0],pixels[1],sizeof pixels[0]));
    int lit=0; for(int i=0;i<32*32;i++) lit+=pixels[0][4*i+3]!=0;
    printf("perspective raster coverage: %d pixels\n",lit); CHECK(lit>25 && lit<512);
    for(int i=0;i<3;i++) {
        const uint32_t *p=(uint32_t *)scene->vertices.contents+4*i; float actual[3]; memcpy(actual,p,12); CHECK(p[3]);
        for(int k=0;k<3;k++) CHECK(fabsf(actual[k]-world[i][k])<1e-4f);
    }
    printf("capture zero=%d: perspective world positions and %d raster pixels match the original\n",zero_near,lit);
    return 0;
}

static int capture_vertices(id<MTLDevice> dev, int zero_near, int existing_ids) {
    NSString *args=existing_ids ? @"uint v [[vertex_id]], uint inst [[instance_id]]" : @"";
    NSString *position=existing_ids ? @"float4(float(v-7)*.2f-.8f,float(inst-3)*.2f-.5f,.25f,1)" : @"float4(.2f,.3f,.25f,1)";
    NSString *source=[NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\nstruct main0_out { float4 gl_Position [[position]]; };\nvertex main0_out main0(%@) { main0_out out; out.gl_Position=%@; out.gl_Position.z=out.gl_Position.z*.5f+.5f; return out; }\nvertex main0_out main0_z(%@) { main0_out out; out.gl_Position=%@; return out; }\n",args,position,args,position];
    NSString *patched=nvn_ray_vertex_source(source); CHECK(patched);
    NSError *error=nil; id<MTLLibrary> lib=[dev newLibraryWithSource:patched options:nil error:&error];
    if(error) fprintf(stderr,"%s\n",error.description.UTF8String); CHECK(lib);
    MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new]; d.vertexFunction=[lib newFunctionWithName:zero_near ? @"main0_z" : @"main0"];
    d.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
    id<MTLRenderPipelineState> ps=[dev newRenderPipelineStateWithDescriptor:d error:&error];
    if(error) fprintf(stderr,"%s\n",error.description.UTF8String); CHECK(ps);
    NvRayScene *scene=[[NvRayScene alloc] initWithDevice:dev]; CHECK(scene);
    uint32_t ix[]={9,10,11,11,10,12}; nvn_ray_capture cap;
    CHECK([scene appendIndices:ix count:6 primitive:4 baseVertex:-2 baseInstance:3 instances:2 inverse:identity capture:&cap]);
    CHECK(cap.first==7 && cap.count==4 && cap.instances==2 && scene->triangle_count==4);
    id<MTLBuffer> ib=[dev newBufferWithBytes:ix length:sizeof ix options:MTLResourceStorageModeShared];
    id<MTLBuffer> cb=[dev newBufferWithBytes:&cap length:sizeof cap options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue=[dev newCommandQueue]; id<MTLCommandBuffer> commands=[queue commandBuffer];
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor new]; rp.renderTargetWidth=16; rp.renderTargetHeight=16; rp.defaultRasterSampleCount=1;
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:16 height:16 mipmapped:NO];
    td.storageMode=MTLStorageModePrivate; td.usage=MTLTextureUsageRenderTarget;
    rp.depthAttachment.texture=[dev newTextureWithDescriptor:td]; rp.depthAttachment.loadAction=MTLLoadActionClear;
    id<MTLRenderCommandEncoder> en=[commands renderCommandEncoderWithDescriptor:rp]; [en setRenderPipelineState:ps];
    [en setVertexBuffer:cb offset:0 atIndex:13]; [en useResource:scene->vertices usage:MTLResourceUsageWrite];
    [en drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferOffset:0 instanceCount:2 baseVertex:-2 baseInstance:3];
    [en endEncoding]; [commands commit]; [commands waitUntilCompleted]; CHECK(commands.status==MTLCommandBufferStatusCompleted);
    for(int i=0;i<2;i++) for(int v=0;v<4;v++) {
        const uint32_t *raw=(uint32_t *)scene->vertices.contents+4*(i*4+v); float xyz[3]; memcpy(xyz,raw,12); CHECK(raw[3]==1);
        CHECK(fabsf(xyz[0]-(existing_ids ? v*.2f-.8f : .2f))<1e-5f);
        CHECK(fabsf(xyz[1]-(existing_ids ? i*.2f-.5f : .3f))<1e-5f); CHECK(fabsf(xyz[2]-.25f)<1e-5f);
    }
    CHECK(![scene appendIndices:ix count:6 primitive:4 baseVertex:-100 baseInstance:0 instances:1 inverse:identity capture:&cap]);
    CHECK(![scene appendIndices:ix count:6 primitive:4 baseVertex:0 baseInstance:UINT32_MAX instances:2 inverse:identity capture:&cap]);
    float singular[16]={0}, inverse[16]; CHECK(!nvn_ray_inverse(singular,identity,inverse));
    CHECK(!nvn_ray_vertex_source([source stringByReplacingOccurrencesOfString:@"return out;" withString:@"return {};" ]));
    printf("capture zero=%d existing IDs=%d: indexed duplicates, signed base vertex and instances passed\n",zero_near,existing_ids);
    return 0;
}

int main(void) { @autoreleasepool {
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice(); CHECK(dev.supportsRaytracing && [dev supportsFamily:MTLGPUFamilyApple9]);
    id<MTL4CommandQueue> queue=[dev newMTL4CommandQueue]; CHECK(queue);
    for(int zero=0;zero<2;zero++) CHECK(!capture_raster(dev,zero));
    for(int zero=0;zero<2;zero++) for(int ids=0;ids<2;ids++) CHECK(!capture_vertices(dev,zero,ids));
    for(int zero=0;zero<2;zero++) for(int flip=0;flip<2;flip++) {
        CHECK(!lighting(dev,queue,0,0,zero,flip)); CHECK(!lighting(dev,queue,1,0,zero,flip)); CHECK(!lighting(dev,queue,1,1,zero,flip));
    }
    puts("hardware ray tracing, contact occlusion, depth rejection and alpha preservation passed"); return 0;
} }
