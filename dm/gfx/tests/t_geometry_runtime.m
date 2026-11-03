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
static unsigned triangles(const uint32_t *segment,unsigned n,unsigned topology,uint32_t *out){
    unsigned count=0;
    if(topology==0)for(unsigned i=0;i<n;i++)out[count++]=segment[i];
    if(topology==4)for(unsigned i=0;i+2<n;i+=3){memcpy(out+count,segment+i,12);count+=3;}
    if(topology==5)for(unsigned i=0;i+2<n;i++){out[count++]=segment[i+(i&1)];out[count++]=segment[i+!(i&1)];out[count++]=segment[i+2];}
    if(topology==6)for(unsigned i=1;i+1<n;i++){out[count++]=segment[0];out[count++]=segment[i];out[count++]=segment[i+1];}
    return count;
}
int main(int argc,char **argv){@autoreleasepool{
    NSError *error=nil;CHECK(argc==2);mtl_init();if(getenv("DM_TEST_DEPTH_ZERO"))mtl_set_depth_zero(1);g_msl_dir=@(argv[1]);
    g_shmap=[@{@"1000000000000000":@"vertex",@"1000000000000001":@"pixel",@"1000000000000002":@"geometry",@"1000000000000003":@"geometry"} mutableCopy];
    prog_t prog={.nstage=3,.serial=nvn_new_serial()};for(int i=0;i<3;i++)prog.sd[i].data=i;
    NvProg *pr=prog_get(&prog);CHECK(pr&&pr->geometry_present&&pr->sh[0]&&pr->sh[1]&&pr->sh[2]);
    NvShader *triangle_reference=shader_load(@"2000000000000000_b",0);CHECK(triangle_reference&&triangle_reference->ae);
    prog_t point_prog=prog;point_prog.serial=nvn_new_serial();point_prog.sd[2].data=3;NvProg *point_program=prog_get(&point_prog);CHECK(point_program&&point_program->sh[2]);
    NvShader *point_reference=shader_load(@"2000000000000003_b",0);CHECK(point_reference&&point_reference->ae);
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),131072));memset(memory,0,131072);mtl_pool_add(memory,131072);
    float constants[8]={.125f,.05f,.075f,0};uint32_t layer=2;memcpy(constants+4,&layer,4);
    id<MTLBuffer> ru=[g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];memcpy(ru.contents,constants,sizeof constants);
    id<MTLBuffer> ra=[g_dev newBufferWithLength:triangle_reference->arg_len options:MTLResourceStorageModeShared];
    [triangle_reference->ae setArgumentBuffer:ra offset:0];[triangle_reference->ae setBuffer:ru offset:0 atIndex:0];
    unsigned cases=0;uint64_t components=0,visible=0;
    for(unsigned points=0;points<2;points++)for(unsigned topology=points?0:4;topology<=(points?0:6);topology++)for(unsigned mode=0;mode<6;mode++)for(unsigned many=0;many<2;many++)for(unsigned style=0;style<3;style++)for(unsigned restart=0;restart<2;restart++){@autoreleasepool{
        NvProg *active=points?point_program:pr;NvShader *reference=points?point_reference:triangle_reference;
        state_reset();memset(&R,0,sizeof R);vis_clear();S.prog=points?&point_prog:&prog;S.nattr=3;S.attr[0]=(va_st){.fmt=NVN_FORMAT_RGBA32F,.stream=0};S.attr[2]=(va_st){.fmt=NVN_FORMAT_RGBA32F,.stream=2};S.stream[0].stride=S.stream[2].stride=16;S.stream[2].divisor=2;
        unsigned instances=many?3:1,bi=4,count=29,level=style==1?1:0,size=64>>level;
        int array=mode==0||mode==4,indirect=mode>=4,base=array?2:mode==1?-2:2;unsigned width=array?0:mode==1?1:mode==2?2:4,first_index=indirect&&!array?2:0;
        S.primitive_restart=(p_primitive_restart){restart,199};
        float *position=memory,*inst=(float *)((uint8_t *)memory+4096);
        for(unsigned i=0;i<64;i++){unsigned v=i>=2?i-2:0,p=v/3,j=v%3;position[i*4]=-.85f+.52f*(p%3)+(j==1?.39f:0);position[i*4+1]=-.8f+.5f*(p/3)+(j==2?.37f:0);position[i*4+2]=.02f*p;position[i*4+3]=1;}
        for(unsigned i=0;i<32;i++){inst[i*4]=((int)(i%3)-1)*.025f;inst[i*4+1]=(i%2)*.02f;inst[i*4+2]=inst[i*4+3]=0;}
        S.vbuf[0]=(NVNbufferRange){(uint64_t)position,64*16};S.vbuf[2]=(NVNbufferRange){(uint64_t)inst,32*16};
        uint8_t raw[256]={0};uint32_t segment[32],reference_indices[96];unsigned ns=0,ni=0;
        for(unsigned i=0;i<count;i++){
            int cut=width&&restart&&(i==7||i==16||i==17);uint32_t value=cut?199:2+i-base;
            for(unsigned j=0;j<width;j++)raw[(first_index+i)*width+j]=(uint8_t)(value>>(j*8));
            if(cut){ni+=triangles(segment,ns,topology,reference_indices+ni);ns=0;}else segment[ns++]=value;
        }
        ni+=triangles(segment,ns,topology,reference_indices+ni);CHECK(ni>0);
        uint64_t ib=(uint64_t)memory+8199,ia=(uint64_t)memory+12288,ua=(uint64_t)memory+65536;
        memset((void *)ib,0xcc,sizeof raw);memset((void *)ia,0xcc,32);memset((void *)ua,0,65536);
        S.ubo[2][0]=(p_bind_buf){.stage=2,.index=0,.addr=ua,.size=65536};
        uint32_t args[]={count,instances,array?2:first_index,array?bi:(uint32_t)base,bi};
        id<MTLBuffer> ri=[g_dev newBufferWithBytes:reference_indices length:ni*4 options:MTLResourceStorageModeShared];
        tex_t color=target(NVN_FORMAT_RGBA8),depth=target(NVN_FORMAT_DEPTH32F);if(points){color.d.target=depth.d.target=NVN_TEXTURE_TARGET_2D_ARRAY;color.d.depth=depth.d.depth=5;}R.has_rt=1;R.rt.n=1;R.rt.color[0]=&color;R.rt.depth=&depth;R.rt.has_cview[0]=R.rt.has_dview=1;R.rt.cview[0].set_levels=R.rt.dview.set_levels=1;R.rt.cview[0].base_level=R.rt.dview.base_level=level;unsigned layers=points?5:1,slice=points&&style==1?1:0,draw_layers=points?5-slice:1;if(points){R.rt.cview[0].set_layers=R.rt.dview.set_layers=1;R.rt.cview[0].min_layer=R.rt.dview.min_layer=slice;R.rt.cview[0].nlayers=R.rt.dview.nlayers=draw_layers;}
        R.clear_c[0]=R.clear_d=1;R.cc[0]=MTLClearColorMake(0,0,0,1);R.cd=1;S.ds.dt=1;S.ds.dw=style!=2;S.has_vp=1;S.vp[0][2]=S.vp[0][3]=size;S.dr[1]=1;
        if(style==1){R.has_sc=1;R.sc=(p_scissor){3,5,(int)size-8,(int)size-10};S.color.blend_en=1;S.blend[0].src_rgb=NVN_BLEND_FUNC_SRC_ALPHA;S.blend[0].dst_rgb=NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA;S.chmask.mask=0xfffffff7u;}
        if(style==2)S.poly.cull=points?NVN_FACE_FRONT_AND_BACK:NVN_FACE_BACK;
        atomic_store(&g_origin_ll,style==2);g_vis_on=g_vis_counting=1;
        id<MTLTexture> got=tex_mtl(&color),dz=tex_mtl(&depth);CHECK(got&&dz);
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:size height:size mipmapped:NO];td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;if(points){td.textureType=MTLTextureType2DArray;td.arrayLength=layers;}id<MTLTexture> want=[g_dev newTextureWithDescriptor:td];td.pixelFormat=MTLPixelFormatDepth32Float;id<MTLTexture> want_depth=[g_dev newTextureWithDescriptor:td];
        id<MTLBuffer> read_got=[g_dev newBufferWithLength:size*size*4*layers options:MTLResourceStorageModeShared],read_want=[g_dev newBufferWithLength:size*size*4*layers options:MTLResourceStorageModeShared];res_add(read_got);
        mtl_sub_begin();if(width)mtl_sub_update(raw,ib,(first_index+count)*width);if(indirect)mtl_sub_update(args,ia,array?16:20);mtl_sub_update(constants,ua,sizeof constants);
        p_draw da={.prim=topology,.first=2,.count=count,.instances=instances,.base_instance=bi,.ind=indirect?ia:0};p_draw_idx di={.prim=topology,.itype=mode==1?0:mode==2?1:2,.count=count,.base_vertex=base,.base_instance=bi,.instances=instances,.ibuf=ib,.ind=indirect?ia:0};
        draw(array?&da:NULL,array?NULL:&di);CHECK(active->tess_vertex);
        id<MTL4ComputeCommandEncoder> copy=blit();for(unsigned l=0;l<layers;l++)[copy copyFromTexture:got sourceSlice:l sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(size,size,1) toBuffer:read_got destinationOffset:l*size*size*4 destinationBytesPerRow:size*4 destinationBytesPerImage:size*size*4];
        CHECK(mtl_wait(mtl_sub_commit(),10000000000ull));CHECK(!mtl_last_commit_error());
        uint64_t samples=0;for(int i=0;i<g_nvs;i++)samples+=((const uint64_t *)((__bridge id<MTLBuffer>)g_vs[i].buf).contents)[g_vs[i].slot];CHECK(samples>0);visible+=samples;
        uint32_t formats[8]={MTLPixelFormatRGBA8Unorm};pso_key key;pso_key_fill(&key,reference,pr->sh[1],formats,MTLPixelFormatDepth32Float,0,1,0);MTLRenderPipelineDescriptor *pd=pso_desc(&key,reference,pr->sh[1],nil,0);if(points)pd.inputPrimitiveTopology=MTLPrimitiveTopologyClassPoint;id<MTLRenderPipelineState> ps=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];CHECK(ps);
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=want;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);rp.depthAttachment.texture=want_depth;rp.depthAttachment.loadAction=MTLLoadActionClear;rp.depthAttachment.storeAction=MTLStoreActionStore;rp.depthAttachment.clearDepth=1;if(points){rp.renderTargetArrayLength=draw_layers;rp.colorAttachments[0].slice=rp.depthAttachment.slice=slice;}
        id<MTLCommandBuffer> cb=[g_q commandBuffer];if(points&&slice){MTLRenderPassDescriptor *zero=[MTLRenderPassDescriptor renderPassDescriptor];zero.colorAttachments[0].texture=want;zero.colorAttachments[0].loadAction=MTLLoadActionClear;zero.colorAttachments[0].storeAction=MTLStoreActionStore;zero.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);id<MTLRenderCommandEncoder> ze=[cb renderCommandEncoderWithDescriptor:zero];[ze endEncoding];}id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];[en setRenderPipelineState:ps];[en setDepthStencilState:dss_get(1,0)];[en setViewport:(MTLViewport){0,style==2?size:0,size,style==2?-(double)size:(double)size,0,1}];if(style==1)[en setScissorRect:(MTLScissorRect){3,5,size-8,size-10}];[en setCullMode:style==2?MTLCullModeBack:MTLCullModeNone];[en setFrontFacingWinding:style==2?MTLWindingClockwise:MTLWindingCounterClockwise];
        void *vb;uint64_t vo;CHECK(mtl_addr((uint64_t)position,1,&vb,&vo));[en setVertexBuffer:(__bridge id<MTLBuffer>)vb offset:vo atIndex:VB_SLOT(0)];CHECK(mtl_addr((uint64_t)inst,1,&vb,&vo));[en setVertexBuffer:(__bridge id<MTLBuffer>)vb offset:vo atIndex:VB_SLOT(2)];[en setVertexBuffer:ra offset:0 atIndex:0];[en useResource:ru usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
        [en drawIndexedPrimitives:points?MTLPrimitiveTypePoint:MTLPrimitiveTypeTriangle indexCount:ni indexType:MTLIndexTypeUInt32 indexBuffer:ri indexBufferOffset:0 instanceCount:instances baseVertex:base baseInstance:bi];[en endEncoding];
        id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];for(unsigned l=0;l<layers;l++)[blit copyFromTexture:want sourceSlice:l sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(size,size,1) toBuffer:read_want destinationOffset:l*size*size*4 destinationBytesPerRow:size*4 destinationBytesPerImage:size*size*4];[blit endEncoding];[cb commit];[cb waitUntilCompleted];CHECK(!cb.error);
        unsigned differences=0,maxdiff=0;const uint8_t *a=read_got.contents,*b=read_want.contents;for(unsigned i=0;i<size*size*4*layers;i++){unsigned delta=(unsigned)abs((int)a[i]-(int)b[i]);if(delta>1)differences++;maxdiff=MAX(maxdiff,delta);components++;}
        if(differences){fprintf(stderr,"topology %u mode %u instances %u style %u restart %u: %u differences max %u samples %llu\n",topology,mode,instances,style,restart,differences,maxdiff,(unsigned long long)samples);for(unsigned n=0;n<2;n++){NSString *path=[g_msl_dir stringByAppendingPathComponent:n?@"want.rgba":@"got.rgba"];[[NSData dataWithBytes:n?b:a length:size*size*4*layers] writeToFile:path atomically:YES];}}
        CHECK(!differences);cases++;res_remove(read_got);
    }}
    vis_clear();mtl_pool_del(memory);free(memory);printf("PASS %u native geometry draws versus native triangles, %llu components within 1 UNORM8 step, %llu visible samples; list/strip/fan/points, layered arrays/slices, array/u8/u16/u32, GPU indirect, custom restart, instancing/divisors, UBO, mip/scissor/depth/blend/mask/lower-left/cull\n",cases,(unsigned long long)components,(unsigned long long)visible);return 0;
}}
