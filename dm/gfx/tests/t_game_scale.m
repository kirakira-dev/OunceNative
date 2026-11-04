#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key,0,8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t n = 90000; return ++n; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); return 1; } } while (0)
static int run(NSUInteger iw, NSUInteger ih, NSUInteger ow, NSUInteger oh, int zero_alpha) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:iw height:ih mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> src=[g_dev newTextureWithDescriptor:d]; CHECK(src);
    uint32_t color=128 | 512<<10 | 800<<20 | (zero_alpha?0u:3u)<<30;
    uint32_t *pixels=malloc(iw*ih*4);CHECK(pixels);
    for(NSUInteger i=0;i<iw*ih;i++)pixels[i]=color;
    [src replaceRegion:MTLRegionMake2D(0,0,iw,ih) mipmapLevel:0 withBytes:pixels bytesPerRow:iw*4];free(pixels);
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsageRenderTarget;
    d.width=ow;d.height=oh;id<MTLTexture> dst=[g_dev newTextureWithDescriptor:d];CHECK(dst);
    NSUInteger row=(ow*4+255)&~255ull;id<MTLBuffer> read=[g_dev newBufferWithLength:row*oh options:MTLResourceStorageModeShared];CHECK(read);
    uint32_t root[18]={0,0,(uint32_t)iw-1,(uint32_t)ih-1,0,0,(uint32_t)ow-1,(uint32_t)oh-1};NSUInteger shape[4];
    CHECK(game_scale_shape(src,dst,root,0x3ffff,shape));
    CHECK(!game_scale_shape(src,dst,root,0x1ffff,shape));
    root[4]=1;CHECK(!game_scale_shape(src,dst,root,0x3ffff,shape));root[4]=0;
    p_dispatch dispatch={.x=(iw+63)/64,.y=(ih+31)/32,.z=1};
    CHECK(game_scale_full_dispatch(&dispatch,root));
    dispatch.x--;CHECK(!game_scale_full_dispatch(&dispatch,root));dispatch.x++;
    dispatch.z=2;CHECK(!game_scale_full_dispatch(&dispatch,root));dispatch.z=1;
    dispatch.ind=1;CHECK(!game_scale_full_dispatch(&dispatch,root));
    uint32_t input_max=root[2];root[2]=(uint32_t)iw/2-1;
    CHECK(!game_scale_shape(src,dst,root,0x3ffff,shape));root[2]=input_max;
    id<MTL4CommandAllocator> allocator=[g_dev newCommandAllocatorWithDescriptor:[MTL4CommandAllocatorDescriptor new] error:nil];CHECK(allocator);
    id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];[cb beginCommandBufferWithAllocator:allocator];
    res_add(src);res_add(dst);res_add(read);res_commit();
    CHECK(game_scale_encode(cb,src,dst,root,0x3ffff));
    id<MTL4ComputeCommandEncoder> copy=[cb computeCommandEncoder];
    [copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [copy copyFromTexture:dst sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(ow,oh,1) toBuffer:read destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*oh];m4_end(copy);[cb endCommandBuffer];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSError *error=nil;__block double ms;
    MTL4CommitOptions *options=[MTL4CommitOptions new];[options addFeedbackHandler:^(id<MTL4CommitFeedback> f){error=f.error;ms=(f.GPUEndTime-f.GPUStartTime)*1000;dispatch_semaphore_signal(done);}];
    id<MTL4CommandBuffer> buffers[]={cb};[g_q4 commit:buffers count:1 options:options];
    CHECK(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC)));if(error)fprintf(stderr,"%s\n",error.description.UTF8String);CHECK(!error);
    int bad=0,worst=0,alpha_bad=0;
    for(NSUInteger y=0;y<oh;y++)for(NSUInteger x=0;x<ow;x++) {
        uint32_t v=((uint32_t *)((uint8_t *)read.contents+y*row))[x];
        for(int c=0;c<3;c++){int delta=abs((int)((v>>(c*10))&1023)-(int)((color>>(c*10))&1023));if(delta>worst)worst=delta;bad+=delta>3;}
        alpha_bad+=(v>>30)!=3;
    }
    printf("game MetalFX %lux%lu -> %lux%lu %.3f ms: RGB error<=%d, bad%d, alpha bad%d (input alpha%d)\n",iw,ih,ow,oh,ms,worst,bad,alpha_bad,zero_alpha?0:3);
    CHECK(!bad);CHECK(!alpha_bad);res_remove(src);res_remove(dst);res_remove(read);res_commit();return 0;
}
int main(void) { @autoreleasepool {mtl_init();CHECK(!run(96,64,144,96,0));CHECK(!run(96,64,144,96,1));CHECK(!run(1280,720,1920,1080,0));puts("game MetalFX checks passed");return 0;} }
