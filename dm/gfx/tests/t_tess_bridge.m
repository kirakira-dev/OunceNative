#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key,0,8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial=90000;return ++serial; }
#define CHECK(x) do { if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1;} } while(0)
typedef struct { uint32_t patch, coord[3], values[12]; } Capture;
int main(int argc,char **argv) { @autoreleasepool {
    CHECK(argc==2);mtl_init();state_reset();NSError *error=nil;
    id<MTLLibrary> hull=[g_dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&error];CHECK(hull);
    id<MTLFunction> hf=[hull newFunctionWithName:@"main0"];CHECK(hf);
    id<MTLComputePipelineState> hp=[g_dev newComputePipelineStateWithFunction:hf error:&error];CHECK(hp);
    id<MTLLibrary> domain=[g_dev newLibraryWithURL:[NSURL fileURLWithPath:@"t_tess_bridge.metallib"] error:&error];CHECK(domain);
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[domain newFunctionWithName:@"capture_patch"];pd.rasterizationEnabled=NO;
    pd.tessellationPartitionMode=MTLTessellationPartitionModeFractionalOdd;pd.maxTessellationFactor=64;pd.tessellationFactorFormat=MTLTessellationFactorFormatHalf;pd.tessellationFactorStepFunction=MTLTessellationFactorStepFunctionPerPatch;pd.tessellationOutputWindingOrder=MTLWindingClockwise;
    id<MTLRenderPipelineState> dp=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];CHECK(dp);
    enum { PATCHES=33, STRIDE=608, REPEATS=4 };NSUInteger size=PATCHES*3*STRIDE;
    id<MTLBuffer> constants=[g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];res_add(constants);
    uint32_t params[]={3,PATCHES};id<MTLBuffer> indirect=[g_dev newBufferWithBytes:params length:sizeof params options:MTLResourceStorageModeShared];res_add(indirect);
    id<MTLArgumentEncoder> ae=[hf newArgumentEncoderWithBufferIndex:0];id<MTLBuffer> args=[g_dev newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];[ae setArgumentBuffer:args offset:0];[ae setBuffer:constants offset:0 atIndex:0];res_add(args);
    unsigned long components=0,patches=0;
    for(unsigned sub=0;sub<8;sub++){@autoreleasepool{
        id<MTLBuffer> readback[REPEATS],readcount[REPEATS];NSMutableArray *keep=[NSMutableArray array];
        mtl_sub_begin();
        for(unsigned repeat=0;repeat<REPEATS;repeat++){
            p_patch_size patch={3+(int)repeat};CHECK(state_op(OP_PATCH_SIZE,&patch));CHECK(S.patch_size==patch.count);
            id<MTLBuffer> input=[g_dev newBufferWithLength:size options:MTLResourceStorageModeShared];float *in=input.contents;
            for(unsigned p=0;p<PATCHES;p++)for(unsigned v=0;v<3;v++){float *a=in+(p*3+v)*152;a[0]=(float)v*.2f-.3f;a[1]=(float)v*.1f-.1f;a[2]=.5f;a[3]=1;for(unsigned k=4;k<8;k++)a[k]=(float)(sub*10000+repeat*1000+p*71+v*13+k);}
            id<MTLBuffer> vertices=[g_dev newBufferWithLength:size options:MTLResourceStorageModePrivate],factors=[g_dev newBufferWithLength:PATCHES*8 options:MTLResourceStorageModePrivate],count=[g_dev newBufferWithLength:32 options:MTLResourceStorageModePrivate],capture=[g_dev newBufferWithLength:4096*sizeof(Capture)+64 options:MTLResourceStorageModePrivate];
            readback[repeat]=[g_dev newBufferWithLength:capture.length options:MTLResourceStorageModeShared];readcount[repeat]=[g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
            for(id<MTLBuffer> b in @[input,vertices,factors,count,capture,readback[repeat],readcount[repeat]]){CHECK(b);res_add(b);[keep addObject:b];}
            id<MTL4ComputeCommandEncoder> ce=enc_c_begin(NULL);[ce fillBuffer:count range:NSMakeRange(0,count.length) value:0];[ce fillBuffer:capture range:NSMakeRange(0,capture.length) value:0xcd];[ce setComputePipelineState:hp];
            [g_ct setAddress:args.gpuAddress atIndex:0];[g_ct setAddress:input.gpuAddress atIndex:22];[g_ct setAddress:vertices.gpuAddress atIndex:28];[g_ct setAddress:factors.gpuAddress atIndex:26];[g_ct setAddress:indirect.gpuAddress atIndex:29];
            [ce dispatchThreads:MTLSizeMake(PATCHES*3,1,1) threadsPerThreadgroup:MTLSizeMake(96,1,1)];enc_c_end(ce);
            id<MTLCommandBuffer> cb=legacy_begin();
            float replacement=(float)(200000+sub*10+repeat);
            id<MTLBuffer> late=[g_dev newBufferWithBytes:&replacement length:sizeof replacement options:MTLResourceStorageModeShared];res_add(late);[keep addObject:late];
            up_begin();[g_up_ce copyFromBuffer:late sourceOffset:0 toBuffer:vertices destinationOffset:16 size:4];
            MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.renderTargetWidth=rp.renderTargetHeight=16;rp.defaultRasterSampleCount=1;
            id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];[en setRenderPipelineState:dp];[en setVertexBuffer:vertices offset:0 atIndex:22];[en setVertexBuffer:count offset:0 atIndex:23];[en setVertexBuffer:capture offset:32 atIndex:24];[en setTessellationFactorBuffer:factors offset:0 instanceStride:0];
            [en drawPatches:3 patchStart:0 patchCount:PATCHES patchIndexBuffer:nil patchIndexBufferOffset:0 instanceCount:1 baseInstance:0];[en endEncoding];legacy_commit(cb);
            ce=enc_c_begin(NULL);[ce copyFromBuffer:count sourceOffset:0 toBuffer:readcount[repeat] destinationOffset:0 size:32];[ce copyFromBuffer:capture sourceOffset:0 toBuffer:readback[repeat] destinationOffset:0 size:capture.length];enc_c_end(ce);
        }
        uint64_t fence=mtl_sub_commit();CHECK(mtl_wait(fence,10000000000ull));CHECK(!mtl_last_commit_error());CHECK(S.patch_size==6);
        for(unsigned repeat=0;repeat<REPEATS;repeat++){
            unsigned n=*(uint32_t *)readcount[repeat].contents;CHECK(n>=PATCHES*3&&n<4096);unsigned seen[PATCHES]={0};const Capture *records=(const Capture *)((const char *)readback[repeat].contents+32);
            for(unsigned i=0;i<n;i++){unsigned p=records[i].patch;CHECK(p<PATCHES);seen[p]++;for(unsigned v=0;v<3;v++)for(unsigned k=0;k<4;k++){float value=p==0&&v==0&&k==0?(float)(200000+sub*10+repeat):(float)(sub*10000+repeat*1000+p*71+v*13+k+4);uint32_t bits;memcpy(&bits,&value,4);CHECK(records[i].values[v*4+k]==bits);components++;}}
            for(unsigned p=0;p<PATCHES;p++){CHECK(seen[p]>=3);patches++;}
            const uint8_t *bytes=readback[repeat].contents;for(unsigned k=0;k<32;k++){CHECK(bytes[k]==0xcd);CHECK(bytes[readback[repeat].length-1-k]==0xcd);}
        }
        for(id<MTLBuffer> b in keep)res_remove(b);
    }}
    printf("PASS 32 Metal4 hull -> Metal3 hardware patch -> Metal4 readback handoffs; %lu patches, %lu exact components; late uploads, final fences, persistent patch state and buffer guards verified\n",patches,components);return 0;
} }
