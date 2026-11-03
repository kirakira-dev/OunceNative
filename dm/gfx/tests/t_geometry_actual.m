#include "../nvn/nvn_mtl.m"
#include <stdbool.h>
int prog_key(const prog_t *p,unsigned stage,uint8_t key[8]){if(stage==2)memcpy(key,p->sd[stage].control,8);else{memset(key,0,8);key[0]=0x10;key[7]=(uint8_t)p->sd[stage].data;}return 0;}
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
uint64_t nvn_new_serial(void){static uint64_t serial=90000;return ++serial;}
typedef struct {uint32_t count,vertices[12][16];bool cut[12];} reference_result;
extern int geometry_reference(const char *,const char *,const uint32_t *,const void *,void *);
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL line %d: %s (%s)\n",__LINE__,#x,error.description.UTF8String);return 1;}}while(0)
static uint32_t rng=0x90143921;
static float random_float(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return (rng&65535)/65535.f;}
static tex_t target(int format){tex_t t={.magic=MAGIC('T','E','X',0),.serial=nvn_new_serial()};t.d.width=t.d.height=96;t.d.depth=t.d.samples=t.d.levels=1;t.d.target=NVN_TEXTURE_TARGET_2D;t.d.format=format;return t;}
int main(int argc,char **argv){@autoreleasepool{
    NSError *error=nil;CHECK(argc==2);mtl_init();if(getenv("DM_TEST_DEPTH_ZERO"))mtl_set_depth_zero(1);g_msl_dir=@(argv[1]);
    NSArray *jobs=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[g_msl_dir stringByAppendingPathComponent:@"cases.json"]] options:0 error:&error];CHECK(jobs.count==9);
    g_shmap=[@{@"1000000000000000":@"vertex",@"1000000000000001":@"pixel"} mutableCopy];for(NSDictionary *job in jobs)g_shmap[job[@"key"]]=@"geometry";
    NvShader *reference=shader_load(@"2000000000000000_b",0);CHECK(reference);
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),131072));memset(memory,0,131072);mtl_pool_add(memory,131072);
    unsigned cases=0,shaders=0,unsupported=0;uint64_t components=0,visible=0;unsigned maximum_difference=0;
    for(NSDictionary *job in jobs){@autoreleasepool{
        NSString *key=job[@"key"];NSDictionary *geometry=job[@"geometry"];unsigned input=[geometry[@"input_vertices"] unsignedIntValue];
        uint8_t key_bytes[8];for(unsigned i=0;i<8;i++){unsigned value=0;sscanf(key.UTF8String+2*i,"%2x",&value);key_bytes[i]=value;}
        prog_t prog={.nstage=3,.serial=nvn_new_serial()};prog.sd[0].data=0;prog.sd[1].data=1;prog.sd[2].control=key_bytes;
        NvProg *pr=prog_get(&prog);CHECK(pr&&pr->sh[0]&&pr->sh[1]&&pr->sh[2]&&pr->geometry_present);
        if([geometry[@"unresolved_position_default"] boolValue]){CHECK(pr->sh[2]->rf.geometry.unresolved_position);unsupported++;continue;}
        uint64_t shader_samples=0;
        for(unsigned mode=0;mode<3;mode++)for(unsigned many=0;many<2;many++)for(unsigned style=0;style<3;style++){@autoreleasepool{
            state_reset();memset(&R,0,sizeof R);vis_clear();S.prog=&prog;S.nattr=8;S.stream[0].stride=128;
            for(unsigned i=0;i<8;i++)S.attr[i]=(va_st){.fmt=NVN_FORMAT_RGBA32F,.offset=i*16,.stream=0};
            unsigned n=12,count=n*input,instances=many?2:1,width=mode==0?0:mode==1?2:4;int32_t base=mode==1?-2:2;
            float *raw=memory;uint8_t canonical[64*608]={0};
            for(unsigned i=0;i<64;i++){
                float *p=raw+i*32;for(unsigned j=0;j<32;j++)p[j]=.1f+random_float()*.8f;
                p[0]=.05f+random_float()*.9f;p[1]=.05f+random_float()*.9f;p[2]=.3f+random_float()*.3f;p[3]=1;
                unsigned v=i>=2?i-2:0;
                p[4]=-.75f+.43f*(v%4);p[5]=-.65f+.44f*(v/4);p[6]=.4f;p[7]=1;p[11]=1;p[28]=.04f;
                if(input==3){static const float x[]={-.47f,.53f,.03f},y[]={-.51f,-.51f,.49f};p[4]=x[v%3];p[5]=y[v%3];p[6]=.6f+.05f*(v%3);}
                if([key isEqual:@"a3c093c2a6c2d89b"]){p[0]=p[4];p[1]=p[5];p[2]=p[6];}
                memcpy(canonical+i*608,p,112);memcpy(canonical+i*608+512,p+4,16);memcpy(canonical+i*608+528,p+28,4);
            }
            S.vbuf[0]=(NVNbufferRange){(uint64_t)memory,64*128};
            float constants[8]={1.3f,.15f,.3f,.5f,1.2f,0,0,0};uint64_t ua=(uint64_t)memory+65536;memset((void *)ua,0,65536);S.ubo[2][0]=(p_bind_buf){.stage=2,.index=0,.addr=ua,.size=65536};
            float reference_vertices[12*36*8];unsigned reference_count=0;
            for(unsigned primitive=0;primitive<n;primitive++){
                uint32_t indices[]={2+primitive*input,3+primitive*input,4+primitive*input};reference_result result;
                CHECK(geometry_reference(key.UTF8String,(const char *)canonical,indices,constants,&result));CHECK(result.count<=12);
                unsigned start=0;
                for(unsigned i=0;i<result.count;i++){
                    if(i-start>=2){unsigned tri[]={i-2,i-1,i};if((i-start)&1){tri[0]=i-1;tri[1]=i-2;}
                        for(unsigned j=0;j<3;j++){
                            const float *v=(const float *)result.vertices[tri[j]];float *out=reference_vertices+reference_count++*8;
                            for(unsigned k=0;k<6;k++)CHECK(isfinite(v[k]));memcpy(out,v,24);out[6]=0;out[7]=1;
                        }
                    }
                    if(result.cut[i])start=i+1;
                }
            }
            CHECK(reference_count>0);id<MTLBuffer> rv=[g_dev newBufferWithBytes:reference_vertices length:reference_count*32 options:MTLResourceStorageModeShared];
            uint8_t raw_indices[160]={0};for(unsigned i=0;i<count;i++){uint32_t value=2+i-base;for(unsigned j=0;j<width;j++)raw_indices[i*width+j]=(uint8_t)(value>>(8*j));}
            uint64_t ib=(uint64_t)memory+8197,ia=(uint64_t)memory+12288;memset((void *)ib,0xcd,sizeof raw_indices);memset((void *)ia,0xcd,20);
            uint32_t args[]={count,instances,0,(uint32_t)base,3};
            tex_t color=target(NVN_FORMAT_RGBA8),depth=target(NVN_FORMAT_DEPTH32F);R.has_rt=1;R.rt.n=1;R.rt.color[0]=&color;R.rt.depth=&depth;R.clear_c[0]=R.clear_d=1;R.cc[0]=MTLClearColorMake(0,0,0,1);R.cd=1;
            S.ds.dt=1;S.ds.dw=style!=2;S.has_vp=1;S.vp[0][2]=S.vp[0][3]=96;S.dr[1]=1;if(style==1){R.has_sc=1;R.sc=(p_scissor){7,9,78,76};}atomic_store(&g_origin_ll,style==2);g_vis_on=g_vis_counting=1;
            id<MTLTexture> got=tex_mtl(&color);CHECK(got&&tex_mtl(&depth));MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:96 height:96 mipmapped:NO];td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;id<MTLTexture> want=[g_dev newTextureWithDescriptor:td];td.pixelFormat=MTLPixelFormatDepth32Float;id<MTLTexture> zd=[g_dev newTextureWithDescriptor:td];
            id<MTLBuffer> ga=[g_dev newBufferWithLength:96*96*4 options:MTLResourceStorageModeShared],wa=[g_dev newBufferWithLength:96*96*4 options:MTLResourceStorageModeShared];res_add(ga);
            mtl_sub_begin();mtl_sub_update(constants,ua,sizeof constants);if(width)mtl_sub_update(raw_indices,ib,count*width);if(mode==2)mtl_sub_update(args,ia,sizeof args);
            p_draw da={.prim=input==1?0:4,.first=2,.count=count,.instances=instances,.base_instance=3};p_draw_idx di={.prim=input==1?0:4,.count=count,.instances=instances,.base_instance=3,.base_vertex=base,.itype=width==2?1:2,.ibuf=ib,.ind=mode==2?ia:0};draw(width?NULL:&da,width?&di:NULL);
            id<MTL4ComputeCommandEncoder> copy=blit();[copy copyFromTexture:got sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(96,96,1) toBuffer:ga destinationOffset:0 destinationBytesPerRow:384 destinationBytesPerImage:96*384];CHECK(mtl_wait(mtl_sub_commit(),10000000000ull));CHECK(!mtl_last_commit_error());
            uint64_t samples=0;for(int i=0;i<g_nvs;i++)samples+=((const uint64_t *)((__bridge id<MTLBuffer>)g_vs[i].buf).contents)[g_vs[i].slot];shader_samples+=samples;
            S.nattr=2;S.attr[0]=(va_st){.fmt=NVN_FORMAT_RGBA32F,.stream=0};S.attr[1]=(va_st){.fmt=NVN_FORMAT_RGBA32F,.offset=16,.stream=0};S.stream[0].stride=32;
            uint32_t formats[8]={MTLPixelFormatRGBA8Unorm};pso_key pkey;pso_key_fill(&pkey,reference,pr->sh[1],formats,MTLPixelFormatDepth32Float,0,1,0);MTLRenderPipelineDescriptor *pd=pso_desc(&pkey,reference,pr->sh[1],nil,0);id<MTLRenderPipelineState> ps=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];CHECK(ps);
            MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=want;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);rp.depthAttachment.texture=zd;rp.depthAttachment.loadAction=MTLLoadActionClear;rp.depthAttachment.storeAction=MTLStoreActionStore;rp.depthAttachment.clearDepth=1;
            id<MTLCommandBuffer> cb=[g_q commandBuffer];id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];[en setRenderPipelineState:ps];[en setVertexBuffer:rv offset:0 atIndex:VB_SLOT(0)];[en setDepthStencilState:dss_get(1,0)];[en setViewport:(MTLViewport){0,style==2?96:0,96,style==2?-96:96,0,1}];if(style==1)[en setScissorRect:(MTLScissorRect){7,9,78,76}];[en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:reference_count instanceCount:instances];[en endEncoding];
            id<MTLBlitCommandEncoder> be=[cb blitCommandEncoder];[be copyFromTexture:want sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(96,96,1) toBuffer:wa destinationOffset:0 destinationBytesPerRow:384 destinationBytesPerImage:96*384];[be endEncoding];[cb commit];[cb waitUntilCompleted];CHECK(!cb.error);
            const uint8_t *a=ga.contents,*b=wa.contents;unsigned differences=0,maxdiff=0;for(unsigned i=0;i<96*96*4;i++){unsigned delta=abs((int)a[i]-b[i]);differences+=delta>1;maxdiff=MAX(maxdiff,delta);components++;}
            if(differences)fprintf(stderr,"%s mode%u instances%u style%u: %u differences max%u, visible %llu\n",key.UTF8String,mode,instances,style,differences,maxdiff,(unsigned long long)samples);
            CHECK(!differences);maximum_difference=MAX(maximum_difference,maxdiff);cases++;res_remove(ga);
        }}
        CHECK(shader_samples>0);visible+=shader_samples;shaders++;printf("PASS actual geometry %s visible samples %llu\n",key.UTF8String,(unsigned long long)shader_samples);
    }}
    CHECK(shaders==8&&unsupported==1);vis_clear();mtl_pool_del(memory);free(memory);
    printf("PASS %u actual geometry shaders, %u full runtime raster cases, %llu components, max UNORM8 difference %u, %llu visible samples; one undefined-position shader excluded\n",shaders,cases,(unsigned long long)components,maximum_difference,(unsigned long long)visible);return 0;
}}
