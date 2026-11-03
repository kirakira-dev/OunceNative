#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial = 90000; return ++serial; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(1); } } while (0)

static id<MTLCommandQueue> tq;
static id<MTLLibrary> tl;
enum { N = 128, WORDS = N * 4 };
static void read_texture(id<MTLTexture> t, uint32_t result[WORDS]) {
    NSString *name = t.pixelFormat == MTLPixelFormatR32Uint ? @"read_uint" : t.textureType == MTLTextureType2DArray ? @"read_array" : @"read_2d";
    NSError *error = nil;
    id<MTLComputePipelineState> ps = [g_dev newComputePipelineStateWithFunction:[tl newFunctionWithName:name] error:&error]; CHECK(ps);
    id<MTLBuffer> out = [g_dev newBufferWithLength:(WORDS + 16) * 4 options:MTLResourceStorageModeShared]; memset(out.contents, 0x59, out.length);
    id<MTLCommandBuffer> cb = [tq commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:ps]; [e setTexture:t atIndex:0]; [e setBuffer:out offset:32 atIndex:0];
    [e dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; CHECK(!cb.error);
    uint32_t *words = out.contents; for (int i = 0; i < 8; i++) CHECK(words[i] == 0x59595959 && words[8 + WORDS + i] == 0x59595959);
    memcpy(result, words + 8, WORDS * 4);
}
static id<MTLTexture> new_base(int array, unsigned seed) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:8 mipmapped:YES];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    if (array) { d.textureType = MTLTextureType2DArray; d.arrayLength = 4; }
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; CHECK(t);
    for (NSUInteger s = 0; s < d.arrayLength; s++) for (NSUInteger l = 0; l < d.mipmapLevelCount; l++) {
        NSUInteger w = MAX(1, d.width >> l), h = MAX(1, d.height >> l); uint8_t data[16 * 8 * 4];
        for (NSUInteger i = 0; i < w * h * 4; i++) data[i] = (uint8_t)(seed + i * 13 + s * 43 + l * 71);
        [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:l slice:s withBytes:data bytesPerRow:w * 4 bytesPerImage:w * h * 4];
    }
    res_add(t); return t;
}
int main(void) { @autoreleasepool {
    mtl_init(); tq = [g_dev newCommandQueue]; NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void read_2d(texture2d<float, access::read> t [[texture(0)]], device uint4 *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { uint l=i%t.get_num_mip_levels(); uint2 p=uint2(i%t.get_width(l),(i/3)%t.get_height(l)); o[i]=as_type<uint4>(t.read(p,l)); }\n"
        "kernel void read_array(texture2d_array<float, access::read> t [[texture(0)]], device uint4 *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { uint l=i%t.get_num_mip_levels(); uint2 p=uint2(i%t.get_width(l),(i/3)%t.get_height(l)); o[i]=as_type<uint4>(t.read(p,i%t.get_array_size(),l)); }\n"
        "kernel void read_uint(texture2d<uint, access::read> t [[texture(0)]], device uint4 *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { uint l=i%t.get_num_mip_levels(); uint2 p=uint2(i%t.get_width(l),(i/3)%t.get_height(l)); o[i]=t.read(p,l); }\n";
    tl = [g_dev newLibraryWithSource:source options:nil error:&error]; if (!tl) fprintf(stderr, "%s\n", error.description.UTF8String); CHECK(tl);
    g_sampling_view_enabled = 1;
    unsigned cases = 0, exact = 0;
    for (int array = 0; array < 2; array++) {
        id<MTLTexture> base = new_base(array, 17);
        tex_t t = {.magic=MAGIC('T','E','X',0), .serial=80001 + array};
        t.d.width=16; t.d.height=8; t.d.depth=array ? 4 : 1; t.d.levels=5; t.d.target=array ? NVN_TEXTURE_TARGET_2D_ARRAY : NVN_TEXTURE_TARGET_2D; t.d.format=NVN_FORMAT_RGBA8;
        serial_put(t.serial, base);
        for (int c = 0; c < 8; c++) {
            if (array && c == 6) continue;
            view_t v = {0};
            if (c != 0) { v.set_levels=v.set_layers=v.set_format=v.set_target=1; v.nlevels=5; v.nlayers=array ? 4 : 1; v.format=NVN_FORMAT_RGBA8; v.target=t.d.target; }
            if (c == 2) { v.base_level=1; v.nlevels=2; }
            if (c == 3 && array) { v.min_layer=1; v.nlayers=2; }
            if (c == 4) { v.set_swizzle=1; v.swz[0]=MTLTextureSwizzleBlue; v.swz[1]=MTLTextureSwizzleGreen; v.swz[2]=MTLTextureSwizzleRed; v.swz[3]=MTLTextureSwizzleOne; }
            if (c == 5) v.format=NVN_FORMAT_RGBA8_SRGB;
            if (c == 6) v.format=NVN_FORMAT_R32UI;
            if (c == 7 && array) { v.target=NVN_TEXTURE_TARGET_2D; v.min_layer=2; v.nlayers=1; }
            uint32_t reference[WORDS], optimized[WORDS];
            for (int mode = 0; mode < 2; mode++) {
                g_descriptor_reuse_env=mode; mtl_reg_tex(7,NULL,NULL); mtl_reg_tex(7,&t,c ? &v : NULL);
                id<MTLTexture> actual=tex_by_id(7); CHECK(actual); read_texture(actual,mode ? optimized : reference);
                if (mode) {
                    if (c <= 1 || (c == 3 && !array) || (c == 7 && !array)) CHECK(actual == base);
                    uint64_t gen=g_reg_gen, rid=actual.gpuResourceID._impl;
                    for (int i=0;i<1000;i++) mtl_reg_tex(7,&t,c ? &v : NULL);
                    CHECK(g_reg_gen == gen+1000 && tex_by_id(7) == actual && g_treg[7].view_rid == rid);
                }
            }
            CHECK(!memcmp(reference,optimized,sizeof reference)); cases++; exact+=WORDS;
        }
        // Reusing a registration must still follow a replaced backing texture.
        view_t sub={.set_levels=1,.base_level=1,.nlevels=2};
        mtl_reg_tex(7,&t,&sub); id<MTLTexture> old=tex_by_id(7); uint32_t before[WORDS],after[WORDS],expected[WORDS];read_texture(old,before);
        id<MTLTexture> replacement=new_base(array,137);serial_put(t.serial,replacement);mtl_reg_tex(7,&t,&sub);id<MTLTexture> current=tex_by_id(7);
        CHECK(current != old && current.parentTexture == replacement);read_texture(current,after);
        id<MTLTexture> gold=[replacement newTextureViewWithPixelFormat:replacement.pixelFormat textureType:replacement.textureType levels:NSMakeRange(1,2) slices:NSMakeRange(0,array ? 4 : 1)];read_texture(gold,expected);
        CHECK(memcmp(before,after,sizeof before) && !memcmp(after,expected,sizeof after));cases++;exact+=WORDS;
        mtl_reg_tex(7,NULL,NULL);CHECK(!g_treg[7].ok && !g_treg[7].view);
    }
    samp_par sp={0};sp.lod_max=1000;sp.aniso=1;mtl_reg_samp(9,&sp);id<MTLSamplerState> original=samp_by_id(9);CHECK(original);
    for(int i=0;i<1000;i++)mtl_reg_samp(9,&sp);CHECK(samp_by_id(9)==original);
    sp.ws=1;mtl_reg_samp(9,&sp);CHECK(samp_by_id(9)!=original);
    // Reconstructed NVN objects and descriptor churn must reuse immutable views.
    id<MTLTexture> base = new_base(1, 57);
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=98000};
    t.pool=(void *)(uintptr_t)0x1000; t.d.width=16; t.d.height=8; t.d.depth=4;
    t.d.levels=5; t.d.target=NVN_TEXTURE_TARGET_2D_ARRAY; t.d.format=NVN_FORMAT_RGBA8;
    view_t sub={.set_levels=1,.base_level=1,.nlevels=2,.set_layers=1,.min_layer=1,.nlayers=2};
    serial_put(t.serial,base);mtl_reg_tex(12,&t,&sub);
    id<MTLTexture> reused=tex_by_id(12);CHECK(reused && reused.parentTexture == base);
    uint64_t hits=g_sampling_view_hits;
    uint32_t before[WORDS],after[WORDS],expected[WORDS];read_texture(reused,before);
    for(int i=0;i<1000;i++) {
        mtl_reg_tex(12,NULL,NULL);serial_del(t.serial);t.serial++;serial_put(t.serial,base);
        mtl_reg_tex(12,&t,&sub);CHECK(tex_by_id(12)==reused);
    }
    CHECK(g_sampling_view_hits==hits+1000);
    id<MTLTexture> gold=[base newTextureViewWithPixelFormat:base.pixelFormat textureType:base.textureType levels:NSMakeRange(1,2) slices:NSMakeRange(1,2)];
    read_texture(gold,expected);read_texture(tex_by_id(12),after);CHECK(!memcmp(after,expected,sizeof after));cases++;exact+=WORDS;
    uint8_t updated[8*4*4];memset(updated,193,sizeof updated);
    [base replaceRegion:MTLRegionMake2D(0,0,8,4) mipmapLevel:1 slice:1 withBytes:updated bytesPerRow:32 bytesPerImage:128];
    read_texture(tex_by_id(12),after);read_texture(gold,expected);
    CHECK(memcmp(before,after,sizeof before) && !memcmp(after,expected,sizeof after));cases++;exact+=WORDS;
    treg_drop_pool_views(t.pool);CHECK(!g_treg[12].view);
    for(unsigned i=0;i<SAMPLING_VIEW_CACHE_SIZE;i++) CHECK(!g_sampling_views[i].view || g_sampling_views[i].key.pool!=(uintptr_t)t.pool);
    CHECK(tex_by_id(12)!=reused);read_texture(tex_by_id(12),after);CHECK(!memcmp(after,expected,sizeof after));cases++;exact+=WORDS;
    uint8_t sw[4]={MTLTextureSwizzleRed,MTLTextureSwizzleGreen,MTLTextureSwizzleBlue,MTLTextureSwizzleAlpha};
    id<MTLTexture> first=nil;
    for(unsigned i=0;i<SAMPLING_VIEW_CACHE_SIZE+3;i++) {
        id<MTLTexture> view=sampling_view(base,(void *)(uintptr_t)(0x2000+16*i),base.pixelFormat,base.textureType,NSMakeRange(1,2),NSMakeRange(1,2),0,sw);
        CHECK(view);if(!i)first=view;CHECK(g_sampling_view_map.n<=SAMPLING_VIEW_CACHE_SIZE);
    }
    CHECK(sampling_view(base,(void *)(uintptr_t)0x2000,base.pixelFormat,base.textureType,NSMakeRange(1,2),NSMakeRange(1,2),0,sw)!=first);
    read_texture(first,after);CHECK(!memcmp(after,expected,sizeof after));cases++;exact+=WORDS;
    for(unsigned i=0;i<SAMPLING_VIEW_CACHE_SIZE;i++)sampling_view_drop(&g_sampling_views[i]);
    CHECK(g_sampling_view_map.n==0);
    CHECK(g_sampling_view_bytes==0);
    MTLTextureDescriptor *largeDescription=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1024 height:1024 mipmapped:NO];
    largeDescription.usage=MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
    id<MTLTexture> large=[g_dev newTextureWithDescriptor:largeDescription];CHECK(large && large.allocatedSize>0);
    for(unsigned i=0;i<40;i++) {
        CHECK(sampling_view(large,(void *)(uintptr_t)(0x4000+16*i),large.pixelFormat,large.textureType,NSMakeRange(0,1),NSMakeRange(0,1),0,sw));
        CHECK(g_sampling_view_bytes<=SAMPLING_VIEW_CACHE_BYTES);
    }
    CHECK(g_sampling_view_map.n<40);
    for(unsigned i=0;i<SAMPLING_VIEW_CACHE_SIZE;i++)sampling_view_drop(&g_sampling_views[i]);
    CHECK(!g_sampling_view_bytes && !g_sampling_view_map.n);

    fprintf(stderr,"Sampling view cache: %llu hits, %llu misses; pool eviction and bounded replacement passed\n",(unsigned long long)g_sampling_view_hits,(unsigned long long)g_sampling_view_misses);
    printf("PASS %u paired GPU cases, %u exact components; texture registrations reused=%llu sampler registrations reused=%llu identity views elided=%llu\n",cases,exact,(unsigned long long)g_tex_reg_reused,(unsigned long long)g_samp_reg_reused,(unsigned long long)g_identity_view_elided);
    return 0;
} }
