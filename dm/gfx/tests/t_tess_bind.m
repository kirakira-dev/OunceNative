#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p,unsigned stage,uint8_t key[8]){(void)p;(void)stage;memset(key,0,8);return 0;}
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
uint64_t nvn_new_serial(void){static uint64_t serial=90000;return ++serial;}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL line %d: %s (%s)\n",__LINE__,#x,error.description.UTF8String);return 1;}}while(0)
static const char source[]=
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct A { constant uint *u [[id(0)]]; device uint *s [[id(1)]]; constant uint *c1 [[id(2)]]; constant uint *d0 [[id(3)]]; constant uint *d2 [[id(4)]]; texture2d<float> t [[id(5)]]; sampler sm [[id(6)]]; };\n"
"void emit(constant A &a,device uint *o) { o[0]=a.u[0];o[1]=a.c1[0];o[2]=a.s[0];o[3]=a.d0[a.u[1]];o[4]=a.d0[a.u[1]+2];o[5]=a.d2[a.u[2]];o[6]=uint(a.t.sample(a.sm,float2(.5),level(0)).x);o[7]=a.u[3];a.s[1]=a.u[0]^0x12345678u; }\n"
"kernel void cs(constant A &a [[buffer(0)]],device uint *o [[buffer(1)]]) { emit(a,o); }\n"
"vertex void vs(constant A &a [[buffer(0)]],device uint *o [[buffer(1)]]) { emit(a,o); }\n"
"vertex float4 triangle(uint i [[vertex_id]]) { return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1); }\n"
"fragment float4 fs(constant A &a [[buffer(0)]],device uint *o [[buffer(1)]]) { emit(a,o);return float4(1); }\n"
"struct A3 { constant uint *u [[id(0)]]; device uint *s [[id(1)]]; constant uint *c1 [[id(2)]]; constant uint *d0 [[id(3)]]; constant uint *d2 [[id(4)]]; texture3d<float> t [[id(5)]]; sampler sm [[id(6)]]; };\n"
"void emit3(constant A3 &a,device uint *o) { o[0]=a.u[0];o[1]=a.c1[0];o[2]=a.s[0];o[3]=a.d0[a.u[1]];o[4]=a.d0[a.u[1]+2];o[5]=a.d2[a.u[2]];o[6]=uint(a.t.sample(a.sm,float3(.5),level(0)).x);o[7]=a.u[3];a.s[1]=a.u[0]^0x12345678u; }\n"
"kernel void cs3(constant A3 &a [[buffer(0)]],device uint *o [[buffer(1)]]) { emit3(a,o); }\n"
"vertex void vs3(constant A3 &a [[buffer(0)]],device uint *o [[buffer(1)]]) { emit3(a,o); }\n"
"fragment float4 fs3(constant A3 &a [[buffer(0)]],device uint *o [[buffer(1)]]) { emit3(a,o);return float4(1); }\n";
int main(void){@autoreleasepool{
    NSError *error=nil;mtl_init();state_reset();
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@(source) options:nil error:&error];CHECK(lib);
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),getpagesize()));memset(memory,0,getpagesize());mtl_pool_add(memory,getpagesize());
    unsigned cases=0,words=0;
    for(unsigned repeat=0;repeat<3;repeat++)for(unsigned stage=0;stage<6;stage++){
        if(stage==2)continue;uint32_t *u=(uint32_t *)((uint8_t *)memory+stage*128),*s=u+16;
        u[0]=100+stage+repeat*100;u[1]=(DM_GAME_NVN_SSBO_BASE(stage)+16)/4;u[2]=(DM_GAME_NVN_TEX_BASE+16)/4;u[3]=900+stage;s[0]=300+stage;s[1]=0;
        S.ubo[stage][0]=(p_bind_buf){stage,0,(uint64_t)u,16};S.ssbo[stage][1]=(p_bind_buf){stage,1,(uint64_t)s,16};S.tex[stage][2]=300+stage;
        tex_t texture={.magic=MAGIC('T','E','X',0),.serial=nvn_new_serial()};texture.d.width=texture.d.height=texture.d.depth=texture.d.levels=texture.d.samples=1;texture.d.target=repeat==2?NVN_TEXTURE_TARGET_3D:NVN_TEXTURE_TARGET_2D;texture.d.format=NVN_FORMAT_RGBA32F;
        id<MTLTexture> tex=tex_mtl(&texture);CHECK(tex);mtl_reg_tex(300+stage,&texture,NULL);
        // Complete production initialization before the test's independent clear.
        // In particular, a new 3D texture has a queued zero-fill upload.
        mtl_sub_begin();CHECK(mtl_wait(mtl_sub_commit(),10000000000ull));CHECK(!mtl_last_commit_error());
        id<MTLCommandBuffer> seed=[g_q commandBuffer];MTLRenderPassDescriptor *clear=[MTLRenderPassDescriptor renderPassDescriptor];clear.colorAttachments[0].texture=tex;clear.colorAttachments[0].loadAction=MTLLoadActionClear;clear.colorAttachments[0].storeAction=MTLStoreActionStore;clear.colorAttachments[0].clearColor=MTLClearColorMake(42+stage,0,0,1);[[seed renderCommandEncoderWithDescriptor:clear] endEncoding];[seed commit];[seed waitUntilCompleted];CHECK(!seed.error);
        NvShader *sh=[NvShader new];sh->stage=stage;NSString *fn=stage==4?@"vs":stage==1?@"fs":@"cs";if(repeat)fn=[fn stringByAppendingString:@"3"];sh->fn=[lib newFunctionWithName:fn];sh->ae=[sh->fn newArgumentEncoderWithBufferIndex:0];sh->arg_len=sh->ae.encodedLength;CHECK(sh->arg_len==56);
        sh->rf.nb=7;sh->rf.b[0]=(nvn_rbind){.kind=NVN_RB_CBUF,.reg=0,.aid=0};sh->rf.b[1]=(nvn_rbind){.kind=NVN_RB_SBUFP,.reg=1,.aid=1,.rw=1};sh->rf.b[2]=(nvn_rbind){.kind=NVN_RB_C1,.aid=2};sh->rf.b[3]=(nvn_rbind){.kind=NVN_RB_DRV0,.aid=3};sh->rf.b[4]=(nvn_rbind){.kind=NVN_RB_DRV2,.aid=4};sh->rf.b[5]=(nvn_rbind){.kind=NVN_RB_TEX,.reg=2,.aid=5,.dtt=repeat?MTLTextureType3D:MTLTextureType2D};sh->rf.b[6]=(nvn_rbind){.kind=NVN_RB_SAMP,.reg=0,.aid=6};sh->rf.drv_read[0]=sh->rf.drv_read[2]=1;
        uint32_t constant=1000+stage;sh->c1buf=[g_dev newBufferWithBytes:&constant length:4 options:MTLResourceStorageModeShared];sh->c1_gpu=sh->c1buf.gpuAddress;res_add(sh->c1buf);
        id<MTLBuffer> output=[g_dev newBufferWithLength:96 options:MTLResourceStorageModeShared];memset(output.contents,0xcd,output.length);res_add(output);
        mtl_sub_begin();id<MTLCommandBuffer> cb=legacy_begin();
        if(stage==0||stage==3||stage==5){
            id<MTLComputePipelineState> ps=[g_dev newComputePipelineStateWithFunction:sh->fn error:&error];CHECK(ps);id<MTLComputeCommandEncoder> ce=[cb computeCommandEncoder];[ce setComputePipelineState:ps];CHECK(encode_args_to(ce,sh,stage,ARGS_LEGACY_COMPUTE));[ce setBuffer:output offset:32 atIndex:1];[ce dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[ce endEncoding];
        }else{
            MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=stage==4?sh->fn:[lib newFunctionWithName:@"triangle"];pd.fragmentFunction=stage==1?sh->fn:nil;pd.rasterizationEnabled=stage==1;if(stage==1)pd.colorAttachments[0].pixelFormat=tex.pixelFormat;
            id<MTLRenderPipelineState> ps=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];CHECK(ps);MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.renderTargetWidth=rp.renderTargetHeight=1;rp.defaultRasterSampleCount=1;
            if(stage==1){MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:tex.pixelFormat width:1 height:1 mipmapped:NO];td.usage=MTLTextureUsageRenderTarget;rp.colorAttachments[0].texture=[g_dev newTextureWithDescriptor:td];rp.colorAttachments[0].loadAction=MTLLoadActionDontCare;rp.colorAttachments[0].storeAction=MTLStoreActionDontCare;}
            id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];[en setRenderPipelineState:ps];CHECK(encode_args_to(en,sh,stage,stage==4?ARGS_LEGACY_VERTEX:ARGS_LEGACY_FRAGMENT));
            if(stage==4)[en setVertexBuffer:output offset:32 atIndex:1];else [en setFragmentBuffer:output offset:32 atIndex:1];[en drawPrimitives:stage==4?MTLPrimitiveTypePoint:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:stage==4?1:3];[en endEncoding];
        }
        legacy_commit(cb);CHECK(mtl_wait(mtl_sub_commit(),10000000000ull));CHECK(!mtl_last_commit_error());
        uint32_t expected[]={u[0],constant,s[0],(uint32_t)(uintptr_t)s,16,300+stage,repeat==1?0:42+stage,u[3]};uint32_t *actual=(uint32_t *)((uint8_t *)output.contents+32);
        for(unsigned i=0;i<8;i++){if(actual[i]!=expected[i])fprintf(stderr,"stage %u word %u got %x expected %x\n",stage,i,actual[i],expected[i]);CHECK(actual[i]==expected[i]);words++;}CHECK(s[1]==(u[0]^0x12345678u));
        const uint8_t *guard=output.contents;for(unsigned i=0;i<32;i++){CHECK(guard[i]==0xcd);CHECK(guard[output.length-1-i]==0xcd);}cases++;
        res_remove(output);res_remove(sh->c1buf);mtl_reg_tex(300+stage,NULL,NULL);
    }
    mtl_pool_del(memory);free(memory);printf("PASS %u legacy binding cases, %u exact words; NVN stages 0/1/3/4/5, UBO/SSBO/C1/driver tables/texture/sampler, valid 2D/3D and incompatible 2D-to-3D null reads, writes and guards\n",cases,words);return 0;
}}
