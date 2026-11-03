#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p,unsigned stage,uint8_t key[8]){(void)p;(void)stage;memset(key,0,8);return 0;}
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
uint64_t nvn_new_serial(void){static uint64_t serial=90000;return ++serial;}
#define CHECK(x) do { if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1;} } while(0)
static unsigned reference(const uint32_t *segment,unsigned n,unsigned mode,uint32_t *out) {
    unsigned count=0;
    if(mode==0)for(unsigned i=0;i<n;i++){out[count*4]=segment[i];count++;}
    if(mode==4)for(unsigned i=0;i+2<n;i+=3){memcpy(out+count*4,segment+i,12);count++;}
    if(mode==5)for(unsigned i=0;i+2<n;i++){out[count*4]=segment[i+(i&1)];out[count*4+1]=segment[i+!(i&1)];out[count*4+2]=segment[i+2];count++;}
    if(mode==6)for(unsigned i=1;i+1<n;i++){out[count*4]=segment[0];out[count*4+1]=segment[i];out[count*4+2]=segment[i+1];count++;}
    return count;
}
int main(void){@autoreleasepool{
    mtl_init();unsigned cases=0;uint64_t words=0;
    unsigned widths[]={0,1,2,4},topologies[]={0,4,5,6},counts[]={0,1,2,3,4,5,31,32,33,63,64,65,127,128,129,257};
    for(unsigned wi=0;wi<4;wi++)for(unsigned ti=0;ti<4;ti++)for(unsigned ci=0;ci<16;ci++)for(unsigned style=0;style<6;style++){@autoreleasepool{
        unsigned width=widths[wi],topology=topologies[ti],count=counts[ci],offset=3+(style*3)%16;
        int32_t base=style&1?-3:7;uint32_t marker=style==2?17:width==1?255:width==2?65535:UINT32_MAX;
        p_primitive_restart restart={style!=0,marker};state_op(OP_PRIMITIVE_RESTART,&restart);CHECK(S.primitive_restart.enabled==restart.enabled&&S.primitive_restart.index==marker);
        uint8_t raw[1100]={0};uint32_t expected[257]={0},primitives[257*4]={0},segment[257],n=0,np=0,ns=0;
        for(unsigned i=0;i<count;i++){
            int cut=style==1?i%7==3:style==2?i%11<2:style==3?i==0||i==count-1:style==4?1:0;
            uint32_t value=width?(cut?marker:(i*37+3)%200):i;
            for(unsigned b=0;b<width;b++)raw[offset+i*width+b]=(uint8_t)(value>>(8*b));
            if(width&&restart.enabled&&value==marker){np+=reference(segment,ns,topology,primitives+np*4);ns=0;continue;}
            expected[n]=value+(uint32_t)base;segment[ns++]=n++;
        }
        np+=reference(segment,ns,topology,primitives+np*4);
        id<MTLBuffer> upload=[g_dev newBufferWithBytes:raw length:sizeof raw options:MTLResourceStorageModeShared];
        id<MTLBuffer> input=[g_dev newBufferWithLength:sizeof raw options:MTLResourceStorageModePrivate];
        id<MTLBuffer> output=[g_dev newBufferWithLength:257*4+64 options:MTLResourceStorageModeShared];
        id<MTLBuffer> assembled=[g_dev newBufferWithLength:257*16+64 options:MTLResourceStorageModeShared];
        id<MTLBuffer> args=[g_dev newBufferWithLength:128 options:MTLResourceStorageModeShared];
        memset(output.contents,0xa5,output.length);memset(assembled.contents,0xa5,assembled.length);memset(args.contents,0xa5,args.length);
        id<MTLCommandBuffer> cb=[g_q commandBuffer];id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
        [blit copyFromBuffer:upload sourceOffset:0 toBuffer:input destinationOffset:0 size:sizeof raw];[blit endEncoding];
        CHECK(geometry_indices_encode(cb,input,offset,output,assembled,args,count,width,base,topology,restart));
        [cb commit];[cb waitUntilCompleted];CHECK(!cb.error);
        CHECK(!memcmp(output.contents,expected,n*4));CHECK(!memcmp(assembled.contents,primitives,np*16));
        uint32_t want_args[]={np,1,1,0,n,1,1,0,0,0,0,n,1,1};CHECK(!memcmp(args.contents,want_args,sizeof want_args));
        for(NSUInteger i=n*4;i<output.length;i++)CHECK(((uint8_t *)output.contents)[i]==0xa5);
        for(NSUInteger i=np*16;i<assembled.length;i++)CHECK(((uint8_t *)assembled.contents)[i]==0xa5);
        for(NSUInteger i=sizeof want_args;i<args.length;i++)CHECK(((uint8_t *)args.contents)[i]==0xa5);
        words+=n+np*4+14;cases++;
    }}
    id<MTLBuffer> source=[g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared],middle=[g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared],result=[g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    memset(source.contents,0x7b,64);res_add(source);res_add(middle);res_add(result);mtl_sub_begin();
    [blit() copyFromBuffer:source sourceOffset:0 toBuffer:middle destinationOffset:0 size:64];
    [blit() copyFromBuffer:middle sourceOffset:0 toBuffer:result destinationOffset:0 size:64];
    CHECK(mtl_wait(mtl_sub_commit(),10000000000ull));CHECK(!mtl_last_commit_error());CHECK(!memcmp(source.contents,result.contents,64));
    printf("PASS %u geometry assembly cases, %llu exact words; arrays/u8/u16/u32, list/strip/fan/points, restart on/off/custom/empty, signed base, GPU-written indices, guards and chained Metal 4 copies\n",cases,(unsigned long long)words);return 0;
}}
