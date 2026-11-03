#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key,0,8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial=90000;return ++serial; }
#define CHECK(x) do { if(!(x)){fprintf(stderr,"FAIL line %d: %s: %s\n",__LINE__,#x,error.description.UTF8String);return 1;} } while(0)
static NvShader *shader(id<MTLLibrary> lib) {
    NvShader *s=[NvShader new];s->vfetch_lib=lib;s->vfetch_entry=@"main0";s->vfetch_mask=1;s->rf.nv=2;
    s->rf.v[0].loc=0;s->rf.v[0].nvn=0;s->rf.v[0].ct=NVN_CT_UINT;
    s->rf.v[1].loc=1;s->rf.v[1].nvn=1;s->rf.v[1].ct=NVN_CT_FLOAT;
    s->fn=vfetch_specialize(s,0);return s;
}
static int index_cases(id<MTLCommandQueue> q) {
    NSError *error=nil;unsigned cases=0;
    const unsigned widths[]={0,1,2,4},offsets[]={0,1,7,15,16,31},counts[]={0,1,7,63,64,65,127,513};
    const int32_t bases[]={INT32_MIN,-2,0,3,INT32_MAX};
    for(unsigned w=0;w<4;w++)for(unsigned s=0;s<6;s++)for(unsigned n=0;n<8;n++)for(unsigned b=0;b<5;b++){@autoreleasepool{
        unsigned width=widths[w],off=offsets[s],count=counts[n];
        id<MTLBuffer> upload=[g_dev newBufferWithLength:off+count*width+32 options:MTLResourceStorageModeShared];
        id<MTLBuffer> src=[g_dev newBufferWithLength:upload.length options:MTLResourceStorageModePrivate];
        id<MTLBuffer> dst=[g_dev newBufferWithLength:count*4+64 options:MTLResourceStorageModeShared];
        uint8_t *p=upload.contents;for(unsigned i=0;i<upload.length;i++)p[i]=(uint8_t)(i*71+13);memset(dst.contents,0xcd,dst.length);
        id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
        [blit copyFromBuffer:upload sourceOffset:0 toBuffer:src destinationOffset:0 size:upload.length];[blit endEncoding];
        CHECK(tess_indices_encode(cb,src,off,dst,32,count,width,bases[b]));[cb commit];[cb waitUntilCompleted];CHECK(!cb.error);
        const uint32_t *got=(const uint32_t *)((const uint8_t *)dst.contents+32);
        for(unsigned i=0;i<count;i++){uint32_t value=width?0:i;for(unsigned j=0;j<width;j++)value|=(uint32_t)p[off+i*width+j]<<(8*j);CHECK(got[i]==value+(uint32_t)bases[b]);}
        const uint8_t *guard=dst.contents;for(unsigned i=0;i<32;i++){CHECK(guard[i]==0xcd);CHECK(guard[dst.length-1-i]==0xcd);}cases++;
    }}
    printf("PASS %u GPU index preparation cases, private GPU-written inputs, all widths, byte offsets, signed bases and output guards\n",cases);return 0;
}
int main(int argc,char **argv) { @autoreleasepool {
    NSError *error=nil;CHECK(argc==2);mtl_init();NSString *root=@(argv[1]);
    id<MTLLibrary> cl=[g_dev newLibraryWithURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"capture.metallib"]] error:&error];CHECK(cl);
    id<MTLLibrary> rl=[g_dev newLibraryWithURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"reference.metallib"]] error:&error];CHECK(rl);
    NvShader *vs=shader(cl),*ref=shader(rl);CHECK(vs->fn&&ref->fn);
    id<MTLCommandQueue> q=[g_dev newCommandQueue];id<MTLBuffer> vb=[g_dev newBufferWithLength:64*16 options:MTLResourceStorageModeShared],ib=[g_dev newBufferWithLength:64*16 options:MTLResourceStorageModeShared],zero=[g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    uint8_t *bytes=vb.contents;uint32_t random=7;for(unsigned i=0;i<vb.length;i++){random=random*1664525u+1013904223u;bytes[i]=(uint8_t)(random>>24);}
    float *inst=ib.contents;for(unsigned i=0;i<64*4;i++)inst[i]=.125f+(float)i/16;
    CHECK(!index_cases(q));unsigned draws=0,components=0,formats=0;
    for(int format=1;format<256;format++){
        if(vfmt(format)==MTLVertexFormatInvalid)continue;formats++;
        for(unsigned mode=0;mode<7;mode++){@autoreleasepool{
            enum { N=7 };int base=mode==0?5:mode==1?3:mode==2||mode==4?-2:0;unsigned bi=mode==0?7:mode==1?5:mode==2?7:mode==4?9:0,divisor=mode==0||mode==4?2:mode==1?1:mode==2?3:0,instanceOffset=mode==4?3:0,instances=mode==4?1:3;
            const uint32_t order[N]={1,4,7,9,2,6,3};uint32_t original[N],normalized[N];uint16_t small[N];
            for(unsigned i=0;i<N;i++){original[i]=order[i]+(base<0?4:0);small[i]=(uint16_t)original[i];normalized[i]=mode==0?i+(unsigned)base:original[i]+(uint32_t)base;}
            int short_ref=mode==1||mode==6;unsigned width=mode==0?0:mode==1?2:mode==6?1:4;
            id<MTLBuffer> raw=[g_dev newBufferWithBytes:short_ref?(const void *)small:original length:short_ref?sizeof small:sizeof original options:MTLResourceStorageModeShared],norm=[g_dev newBufferWithLength:sizeof normalized+32 options:MTLResourceStorageModeShared];
            id<MTLBuffer> upload=[g_dev newBufferWithLength:13+N*width options:MTLResourceStorageModeShared],indices=[g_dev newBufferWithLength:upload.length options:MTLResourceStorageModePrivate];
            for(unsigned i=0;i<N;i++)for(unsigned j=0;j<width;j++)((uint8_t *)upload.contents)[13+i*width+j]=(uint8_t)(original[i]>>(j*8));
            uint32_t parameters[]={(uint32_t)base,bi,instanceOffset,0};id<MTLBuffer> params=[g_dev newBufferWithBytes:parameters length:sizeof parameters options:MTLResourceStorageModeShared];
            id<MTLBuffer> output=[g_dev newBufferWithLength:N*instances*608+64 options:MTLResourceStorageModeShared],reference=[g_dev newBufferWithLength:64*(instances+instanceOffset)*80 options:MTLResourceStorageModeShared];memset(output.contents,0xcd,output.length);memset(reference.contents,0xcd,reference.length);
            pso_key key={0};key.samples=1;key.attr[0].fmt=mode==5?0:format;key.attr[0].stream=0;key.stream[0].stride=16;key.attr[1].fmt=0x2e;key.attr[1].stream=1;key.stream[1].stride=mode==5?0:16;key.stream[1].divisor=divisor;
            MTLRenderPipelineDescriptor *rp=pso_desc(&key,ref,nil,nil,0);rp.rasterizationEnabled=NO;id<MTLRenderPipelineState> rps=[g_dev newRenderPipelineStateWithDescriptor:rp error:&error];CHECK(rps);
            MTLComputePipelineDescriptor *cp=tess_vertex_desc(vs,&key);CHECK(cp);id<MTLComputePipelineState> cps=[g_dev newComputePipelineStateWithDescriptor:cp options:MTLPipelineOptionNone reflection:nil error:&error];CHECK(cps);
            id<MTLCommandBuffer> cb=[q commandBuffer];MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.renderTargetWidth=pass.renderTargetHeight=16;pass.defaultRasterSampleCount=1;
            id<MTLRenderCommandEncoder> re=[cb renderCommandEncoderWithDescriptor:pass];[re setRenderPipelineState:rps];[re setVertexBuffer:vb offset:0 atIndex:VB_SLOT(0)];[re setVertexBuffer:ib offset:0 atIndex:VB_SLOT(1)];[re setVertexBuffer:zero offset:0 atIndex:30];[re setVertexBuffer:reference offset:0 atIndex:1];
            if(mode==0)[re drawPrimitives:MTLPrimitiveTypePoint vertexStart:base vertexCount:N instanceCount:instances+instanceOffset baseInstance:bi];else [re drawIndexedPrimitives:MTLPrimitiveTypePoint indexCount:N indexType:short_ref?MTLIndexTypeUInt16:MTLIndexTypeUInt32 indexBuffer:raw indexBufferOffset:0 instanceCount:instances+instanceOffset baseVertex:base baseInstance:bi];[re endEncoding];
            id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];[blit copyFromBuffer:upload sourceOffset:0 toBuffer:indices destinationOffset:0 size:upload.length];[blit endEncoding];CHECK(tess_indices_encode(cb,indices,13,norm,16,N,width,base));
            id<MTLComputeCommandEncoder> ce=[cb computeCommandEncoder];[ce setComputePipelineState:cps];[ce setBuffer:vb offset:0 atIndex:TESS_VB_SLOT(0)];[ce setBuffer:ib offset:divisor?(bi+instanceOffset/divisor)*16:0 atIndex:TESS_VB_SLOT(1)];[ce setBuffer:zero offset:0 atIndex:30];[ce setBuffer:norm offset:16 atIndex:21];[ce setBuffer:params offset:0 atIndex:23];[ce setBuffer:output offset:32 atIndex:28];[ce setStageInRegion:MTLRegionMake3D(0,0,0,N,instances,1)];[ce dispatchThreads:MTLSizeMake(N,instances,1) threadsPerThreadgroup:MTLSizeMake(8,1,1)];[ce endEncoding];[cb commit];[cb waitUntilCompleted];CHECK(!cb.error);
            for(unsigned y=0;y<instances;y++)for(unsigned x=0;x<N;x++){
                const uint32_t *got=(const uint32_t *)((const uint8_t *)output.contents+32+(y*N+x)*608),*want=(const uint32_t *)((const uint8_t *)reference.contents+((y+instanceOffset)*64+normalized[x])*80);
                for(unsigned k=0;k<20;k++){uint32_t actual=got[k<8?k:k<12?128+k-8:133+k-12];if(actual!=want[k]){fprintf(stderr,"format %#x mode %u instance %u vertex %u word %u: %08x != %08x\n",format,mode,y,x,k,actual,want[k]);return 2;}components++;}
            }
            const uint8_t *guard=output.contents;for(unsigned i=0;i<32;i++){CHECK(guard[i]==0xcd);CHECK(guard[output.length-1-i]==0xcd);}draws++;
        }}
    }
    printf("PASS %u vertex formats, %u paired draw/capture cases, %u exact components; GPU array/u8/u16/u32 indices, negative base vertex, base instance, divisors, instance offset and missing attributes\n",formats,draws,components);return 0;
} }
