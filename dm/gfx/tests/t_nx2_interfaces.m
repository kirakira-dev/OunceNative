#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key,0,8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial=90000; return ++serial; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s (%s)\n",__LINE__,#x,error.localizedDescription.UTF8String); return 1; } } while (0)
int main(int argc, char **argv) { @autoreleasepool {
    NSError *error=nil; CHECK(argc==2); mtl_init();
    NSString *source=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error]; CHECK(source);
    MTLCompileOptions *options=[MTLCompileOptions new]; options.fastMathEnabled=NO;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:options error:&error];CHECK(lib);
    NvShader *fs=[NvShader new], *vs=[NvShader new];fs->color_lib=lib;fs->color_entry=@"main0";fs->color_mask=3;fs->varying_inputs=2;
    MTLPixelFormat formats[]={MTLPixelFormatRGBA32Float,MTLPixelFormatRGBA32Uint,MTLPixelFormatRGBA32Sint};
    uint32_t expected0[]={0x3f800000,0x80000000,0xbf000000,0x4aabc123};unsigned checks=0;
    id<MTLCommandQueue> queue=[g_dev newCommandQueue];
    for(unsigned present=0;present<2;present++)for(unsigned kind=0;kind<3;kind++) {
        pso_key key={0};key.cfmt[0]=formats[kind];key.cfmt[1]=MTLPixelFormatRGBA32Float;
        vs->varying_outputs=present?2:0;
        MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:present?@"vspresent":@"vsmissing"];
        pd.fragmentFunction=color_for_pso(fs,vs,&key);CHECK(pd.fragmentFunction);
        id<MTLTexture> targets[2];MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        for(unsigned i=0;i<2;i++) {
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:key.cfmt[i] width:4 height:4 mipmapped:NO];d.usage=MTLTextureUsageRenderTarget;d.storageMode=MTLStorageModeShared;
            targets[i]=[g_dev newTextureWithDescriptor:d];CHECK(targets[i]);pd.colorAttachments[i].pixelFormat=key.cfmt[i];pass.colorAttachments[i].texture=targets[i];
            pass.colorAttachments[i].loadAction=MTLLoadActionClear;pass.colorAttachments[i].storeAction=MTLStoreActionStore;
        }
        id<MTLRenderPipelineState> pipeline=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];CHECK(pipeline);
        id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:pass];
        [en setRenderPipelineState:pipeline];[en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[en endEncoding];[cb commit];[cb waitUntilCompleted];CHECK(!cb.error);
        for(unsigned i=0;i<2;i++) {
            uint32_t pixels[64];[targets[i] getBytes:pixels bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
            float varying[4]={present?0.25f:0,present?0.5f:0,present?0.75f:0,present?0.875f:1};uint32_t expected1[4];memcpy(expected1,varying,16);
            for(unsigned p=0;p<64;p++) { CHECK(pixels[p]==(i?expected1[p%4]:expected0[p%4]));checks++; }
        }
    }
    printf("PASS 6 linked pipelines, %u exact words; float, uint, sint, mixed targets and absent varyings\n",checks);return 0;
}}
