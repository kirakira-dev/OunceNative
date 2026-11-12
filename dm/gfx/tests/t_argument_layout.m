#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p,unsigned stage,uint8_t key[8]){(void)p;(void)stage;memset(key,0,8);return 0;}
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
uint64_t nvn_new_serial(void){static uint64_t serial=95000;return ++serial;}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL line %d: %s (%s)\n",__LINE__,#x,error.description.UTF8String);return 1;}}while(0)
int main(int argc,char **argv){@autoreleasepool{
    NSError *error=nil;CHECK(argc==2);mtl_init();state_reset();g_msl_dir=@(argv[1]);
    NvShader *shader=shader_load(@"1000000000000000_b",5);CHECK(shader&&shader->ae&&shader->arg_len==24);
    CHECK(shader->rf.nb==3&&shader->rf.b[2].kind==NVN_RB_UNUSED_SAMP);
    id<MTLComputePipelineState> ps=[g_dev newComputePipelineStateWithFunction:shader->fn error:&error];CHECK(ps);
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),getpagesize()));mtl_pool_add(memory,getpagesize());
    unsigned cases=0,words=0;
    for(unsigned legacy=0;legacy<2;legacy++)for(unsigned level=0;level<3;level++){
        memset(memory,0xcd,getpagesize());S.ssbo[5][0]=(p_bind_buf){5,0,(uint64_t)memory+32,32};S.img[5][0]=300;
        tex_t texture={.magic=MAGIC('T','E','X',0),.serial=nvn_new_serial()};
        texture.d.width=20;texture.d.height=12;texture.d.depth=5;texture.d.levels=3;texture.d.samples=1;
        texture.d.target=NVN_TEXTURE_TARGET_2D_ARRAY;texture.d.format=NVN_FORMAT_RGBA32F;
        view_t view={.set_levels=1,.base_level=level,.nlevels=3-level,.set_layers=1,.min_layer=1,.nlayers=3};
        CHECK(tex_mtl(&texture));mtl_reg_tex(300,&texture,&view);args_dirty_all();
        mtl_sub_begin();
        if(legacy){
            id<MTLCommandBuffer> cb=legacy_begin();id<MTLComputeCommandEncoder> ce=[cb computeCommandEncoder];
            [ce setComputePipelineState:ps];CHECK(encode_args_to(ce,shader,5,ARGS_LEGACY_COMPUTE));
            [ce dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
            [ce endEncoding];legacy_commit(cb);
        }else{
            id<MTLComputeCommandEncoder> ce=pg_compute();enc_c_pso(ce,ps);
            CHECK(encode_args_to(ce,shader,5,ARGS_M4_COMPUTE));
            enc_c_dispatch(ce,MTLSizeMake(1,1,1),MTLSizeMake(1,1,1));enc_c_end(ce);
        }
        CHECK(mtl_wait(mtl_sub_commit(),10000000000ull));CHECK(!mtl_last_commit_error());
        uint32_t expected[]={20u>>level,12u>>level,3,3-level,0x12345678};
        uint32_t *actual=(uint32_t *)((uint8_t *)memory+32);
        for(unsigned i=0;i<5;i++){CHECK(actual[i]==expected[i]);words++;}
        for(unsigned i=0;i<32;i++)CHECK(((uint8_t *)memory)[i]==0xcd);
        for(unsigned i=52;i<96;i++)CHECK(((uint8_t *)memory)[i]==0xcd);
        mtl_reg_tex(300,NULL,NULL);cases++;
    }
    NSMutableDictionary *json=[@{@"route":@"B",@"stage":@"compute",@"bindings":@[@{@"kind":@"unused_sampler",@"arg_id":@0,@"msl_type":@"sampler"}]} mutableCopy];
    nvn_refl reflection;char why[256];CHECK(!nvn_refl_from_json(json,&reflection,why,sizeof why));
    for(id aid in @[@(-1),@(NVN_REFL_MAXB),@0.5,@"0"]){json[@"bindings"]=@[@{@"kind":@"unused_sampler",@"arg_id":aid,@"msl_type":@"sampler"}];CHECK(nvn_refl_from_json(json,&reflection,why,sizeof why));}
    NSDictionary *binding=@{@"kind":@"unused_sampler",@"arg_id":@0,@"msl_type":@"sampler"};json[@"bindings"]=@[binding,binding];CHECK(nvn_refl_from_json(json,&reflection,why,sizeof why));
    json[@"bindings"]=@[binding];json[@"stage"]=@"vertex";CHECK(nvn_refl_from_json(json,&reflection,why,sizeof why));
    mtl_pool_del(memory);free(memory);
    printf("PASS %u image-query dispatches, %u exact words and guards; Metal 4/legacy compute, mip/layer views, trailing unused sampler, six invalid reflection cases\n",cases,words);return 0;
}}
