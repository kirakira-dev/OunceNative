#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p,unsigned stage,uint8_t key[8]){memset(key,0,8);key[0]=0x10;key[7]=(uint8_t)p->sd[stage].data;return 0;}
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
uint64_t nvn_new_serial(void){static uint64_t serial=90000;return ++serial;}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL line %d: %s (%s)\n",__LINE__,#x,error.description.UTF8String);return 1;}}while(0)
static tex_t target(int format){tex_t t={.magic=MAGIC('T','E','X',0),.serial=nvn_new_serial()};t.d.width=t.d.height=64;t.d.depth=t.d.samples=1;t.d.levels=2;t.d.target=NVN_TEXTURE_TARGET_2D;t.d.format=format;return t;}
int main(int argc,char **argv){@autoreleasepool{
    NSError *error=nil;CHECK(argc==2);mtl_init();g_msl_dir=@(argv[1]);
    // Exercise the same key-to-variant lookup used by a game's SetShaders call.
    g_shmap=[@{@"1000000000000000":@"vertex",@"1000000000000001":@"pixel",@"1000000000000003":@"hull",@"1000000000000004":@"domain"} mutableCopy];
    prog_t prog={.nstage=4,.serial=nvn_new_serial()};prog.sd[0].data=0;prog.sd[1].data=1;prog.sd[2].data=3;prog.sd[3].data=4;
    NvProg *pr=prog_get(&prog);CHECK(pr);
    NvShader *reference=shader_load(@"2000000000000000_b",0);CHECK(pr->sh[0]&&pr->sh[1]&&pr->sh[3]&&pr->sh[4]&&reference);
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),65536));memset(memory,0,65536);mtl_pool_add(memory,65536);
    unsigned cases=0;uint64_t components=0,visible=0;
    for(unsigned input=3;input<=5;input+=2)for(unsigned mode=0;mode<6;mode++)for(unsigned many=0;many<2;many++)for(unsigned style=0;style<3;style++){@autoreleasepool{
        state_reset();memset(&R,0,sizeof R);vis_clear();S.prog=&prog;S.patch_size=input;S.nattr=3;S.attr[0]=(va_st){.fmt=NVN_FORMAT_RGBA32F,.stream=0};S.attr[2]=(va_st){.fmt=NVN_FORMAT_RGBA32F,.stream=2};S.stream[0].stride=S.stream[2].stride=16;S.stream[2].divisor=2;
        unsigned instances=many?3:1,bi=4,patches=9,count=patches*input+2,level=style==1?1:0,size=64>>level;
        int array=mode==0||mode==4,indirect=mode>=4,base=array?2:mode==1?-2:2;unsigned width=array?0:mode==1?1:mode==2?2:4,first_index=indirect&&!array?2:0;
        float *position=memory,*inst=(float *)((uint8_t *)memory+4096);
        for(unsigned i=0;i<64;i++){int logical=MAX((int)i-2,0),p=logical/(int)input,j=logical%(int)input;position[i*4]=-.9f+.6f*(p%3)+(j==1?.36f:0);position[i*4+1]=-.85f+.55f*(p/3)+(j==2?.36f:0);position[i*4+2]=.02f*p;position[i*4+3]=1;}
        for(unsigned i=0;i<32;i++){inst[i*4]=((int)(i%3)-1)*.025f;inst[i*4+1]=(i%2)*.02f;inst[i*4+2]=inst[i*4+3]=0;}
        S.vbuf[0]=(NVNbufferRange){(uint64_t)position,64*16};S.vbuf[2]=(NVNbufferRange){(uint64_t)inst,32*16};
        uint8_t raw[256]={0};for(unsigned i=0;i<count;i++){uint32_t value=2+i-base;for(unsigned j=0;j<width;j++)raw[(first_index+i)*width+j]=(uint8_t)(value>>(j*8));}
        uint64_t ib=(uint64_t)memory+8199,ia=(uint64_t)memory+12288;memset((void *)ib,0xcc,sizeof raw);memset((void *)ia,0xcc,32);
        uint32_t args[]={count,instances,array?2:first_index,array?bi:(uint32_t)base,bi};
        uint32_t reference_indices[27];unsigned ni=0;for(unsigned p=0;p<patches;p++)if(p%5)for(unsigned j=0;j<3;j++)reference_indices[ni++]=2+p*input+j-base;
        id<MTLBuffer> ri=[g_dev newBufferWithBytes:reference_indices length:ni*4 options:MTLResourceStorageModeShared];
        tex_t color=target(NVN_FORMAT_RGBA8),depth=target(NVN_FORMAT_DEPTH32F);R.has_rt=1;R.rt.n=1;R.rt.color[0]=&color;R.rt.depth=&depth;R.rt.has_cview[0]=R.rt.has_dview=1;R.rt.cview[0].set_levels=R.rt.dview.set_levels=1;R.rt.cview[0].base_level=R.rt.dview.base_level=level;
        R.clear_c[0]=R.clear_d=1;R.cc[0]=MTLClearColorMake(0,0,0,1);R.cd=1;S.ds.dt=1;S.ds.dw=style!=2;S.has_vp=1;S.vp[0][2]=S.vp[0][3]=size;S.dr[1]=1;
        if(style==1){R.has_sc=1;R.sc=(p_scissor){3,5,(int)size-8,(int)size-10};}
        atomic_store(&g_origin_ll,style==2);g_vis_on=g_vis_counting=1;
        id<MTLTexture> got=tex_mtl(&color),dz=tex_mtl(&depth);CHECK(got&&dz);
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:size height:size mipmapped:NO];td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;id<MTLTexture> want=[g_dev newTextureWithDescriptor:td];td.pixelFormat=MTLPixelFormatDepth32Float;id<MTLTexture> want_depth=[g_dev newTextureWithDescriptor:td];
        id<MTLBuffer> read_got=[g_dev newBufferWithLength:size*size*4 options:MTLResourceStorageModeShared],read_want=[g_dev newBufferWithLength:size*size*4 options:MTLResourceStorageModeShared];res_add(read_got);
        mtl_sub_begin();if(width)mtl_sub_update(raw,ib,(first_index+count)*width);if(indirect)mtl_sub_update(args,ia,array?16:20);
        p_draw draw_array={.prim=0xE,.first=2,.count=count,.instances=instances,.base_instance=bi,.ind=indirect?ia:0};p_draw_idx draw_index={.prim=0xE,.itype=mode==1?0:mode==2?1:2,.count=count,.base_vertex=base,.base_instance=bi,.instances=instances,.ibuf=ib,.ind=indirect?ia:0};
        draw(array?&draw_array:NULL,array?NULL:&draw_index);CHECK(pr->tess_vertex);
        id<MTL4ComputeCommandEncoder> copy=blit();[copy copyFromTexture:got sourceSlice:0 sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(size,size,1) toBuffer:read_got destinationOffset:0 destinationBytesPerRow:size*4 destinationBytesPerImage:size*size*4];
        CHECK(mtl_wait(mtl_sub_commit(),10000000000ull));CHECK(!mtl_last_commit_error());
        uint64_t samples=0;for(int i=0;i<g_nvs;i++)samples+=((const uint64_t *)((__bridge id<MTLBuffer>)g_vs[i].buf).contents)[g_vs[i].slot];CHECK(samples>0);visible+=samples;
        uint32_t formats[8]={MTLPixelFormatRGBA8Unorm};pso_key key;pso_key_fill(&key,reference,pr->sh[1],formats,MTLPixelFormatDepth32Float,0,1,0);MTLRenderPipelineDescriptor *pd=pso_desc(&key,reference,pr->sh[1],nil,0);id<MTLRenderPipelineState> ps=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];CHECK(ps);
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=want;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);rp.depthAttachment.texture=want_depth;rp.depthAttachment.loadAction=MTLLoadActionClear;rp.depthAttachment.storeAction=MTLStoreActionStore;rp.depthAttachment.clearDepth=1;
        id<MTLCommandBuffer> cb=[g_q commandBuffer];id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];[en setRenderPipelineState:ps];[en setDepthStencilState:dss_get(1,0)];[en setViewport:(MTLViewport){0,style==2?size:0,size,style==2?-(double)size:(double)size,0,1}];if(style==1)[en setScissorRect:(MTLScissorRect){3,5,size-8,size-10}];
        void *vbuf;uint64_t vo;CHECK(mtl_addr((uint64_t)position,1,&vbuf,&vo));[en setVertexBuffer:(__bridge id<MTLBuffer>)vbuf offset:vo atIndex:VB_SLOT(0)];CHECK(mtl_addr((uint64_t)inst,1,&vbuf,&vo));[en setVertexBuffer:(__bridge id<MTLBuffer>)vbuf offset:vo atIndex:VB_SLOT(2)];[en drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:ni indexType:MTLIndexTypeUInt32 indexBuffer:ri indexBufferOffset:0 instanceCount:instances baseVertex:base baseInstance:bi];[en endEncoding];
        id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];[blit copyFromTexture:want sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(size,size,1) toBuffer:read_want destinationOffset:0 destinationBytesPerRow:size*4 destinationBytesPerImage:size*size*4];[blit endEncoding];[cb commit];[cb waitUntilCompleted];CHECK(!cb.error);
        unsigned differences=0,maxdiff=0;const uint8_t *a=read_got.contents,*b=read_want.contents;for(unsigned i=0;i<size*size*4;i++){unsigned delta=(unsigned)abs((int)a[i]-(int)b[i]);if(delta>1)differences++;maxdiff=MAX(maxdiff,delta);components++;}
        if(differences){fprintf(stderr,"input %u mode %u instances %u style %u: %u differences max %u samples %llu\n",input,mode,instances,style,differences,maxdiff,(unsigned long long)samples);
            for(unsigned n=0;n<2;n++){NSString *path=[g_msl_dir stringByAppendingPathComponent:n?@"want.rgba":@"got.rgba"];[[NSData dataWithBytes:n?b:a length:size*size*4] writeToFile:path atomically:YES];}}
        CHECK(!differences);cases++;res_remove(read_got);
    }}
    vis_clear();mtl_pool_del(memory);free(memory);printf("PASS %u complete tessellation draws versus native triangles, %llu components within 1 UNORM8 step, %llu visible samples; array/u8/u16/u32, GPU indirect records, CP3/5, instancing/divisors, mip/scissor/depth/lower-left and culled patches\n",cases,(unsigned long long)components,(unsigned long long)visible);return 0;
}}
