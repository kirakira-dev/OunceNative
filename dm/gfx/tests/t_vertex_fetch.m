#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key,0,8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial=90000;return ++serial; }
#define CHECK(x) do { if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1;} } while(0)
int main(void) { @autoreleasepool {
    mtl_init(); NSError *error=nil;
    id<MTLLibrary> lib=[g_dev newLibraryWithURL:[NSURL fileURLWithPath:@"t_vertex_fetch.metallib"] error:&error]; CHECK(lib);
    enum { N=512, STRIDE=16 }; uint8_t bytes[N*STRIDE]; uint32_t random=7;
    for(size_t i=0;i<sizeof bytes;i++){random=random*1664525u+1013904223u;bytes[i]=(uint8_t)(random>>24);}
    id<MTLCommandQueue> queue=[g_dev newCommandQueue]; CHECK(queue);
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];td.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> target=[g_dev newTextureWithDescriptor:td];CHECK(target);
    unsigned formats=0,exact=0,rounded=0,max_ulp=0;
    for(int f=0;f<256;f++) {
        int bits,sign,integer=vconv_int(f,&bits,&sign);if(!integer&&!vconv_ncomp(f))continue;
        uint8_t input[sizeof bytes];memcpy(input,bytes,sizeof input);
        // Exercise finite half / packed-float values so NaN payload choices do not mask a bit mismatch.
        for(int n=0;n<N;n++) {
            uint8_t *row=input+n*STRIDE;
            if(f==0x05||f==0x11||f==0x1d||f==0x29)for(int c=0;c<vconv_ncomp(f);c++){uint16_t h;memcpy(&h,row+c*2,2);if((h&0x7c00)==0x7c00)h^=0x400;memcpy(row+c*2,&h,2);}
            if(f==0x3f){uint32_t x;memcpy(&x,row,4);if((x&0x7c0)==0x7c0)x^=0x40;if((x&0x3e0000)==0x3e0000)x^=0x20000;if((x&0xf8000000)==0xf8000000)x^=0x8000000;memcpy(row,&x,4);}
        }
        memset(input,0,STRIDE);memset(input+STRIDE,255,STRIDE); // minimum / maximum integer and normalized inputs
        if(f==0x05||f==0x11||f==0x1d||f==0x29||f==0x3f)memset(input+STRIDE,0,STRIDE);
        NvShader *vs=[NvShader new];vs->vfetch_lib=lib;vs->vfetch_entry=@"test";vs->vfetch_mask=1;vs->rf.nv=1;
        vs->rf.v[0].loc=0;vs->rf.v[0].nvn=0;vs->rf.v[0].ct=integer&&!sign?NVN_CT_INT:NVN_CT_UINT;
        strlcpy(vs->key,"vertex-fetch-test",sizeof vs->key);
        vs->fn=vfetch_specialize(vs,vs->rf.v[0].ct==NVN_CT_INT?2:0);CHECK(vs->fn);
        pso_key key={0};key.attr[0].fmt=f;key.attr[0].stream=0;key.stream[0].stride=STRIDE;key.cfmt[0]=MTLPixelFormatRGBA8Unorm;key.samples=1;
        CHECK(vconv_wanted(&vs->rf,0,&key));
        MTLRenderPipelineDescriptor *pd=pso_desc(&key,vs,nil,nil,0);
        CHECK(pd.vertexDescriptor.attributes[0].bufferIndex==VB_SLOT(0));
        CHECK(pd.vertexDescriptor.attributes[0].format==vfmt(f));
        id<MTLRenderPipelineState> pipeline=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if(!pipeline){fprintf(stderr,"format %#x: %s\n",f,error.description.UTF8String);return 2;}
        id<MTLBuffer> src=[g_dev newBufferWithBytes:input length:sizeof input options:MTLResourceStorageModeShared];
        id<MTLBuffer> result=[g_dev newBufferWithLength:N*16 options:MTLResourceStorageModeShared];CHECK(src&&result);
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor new];rp.colorAttachments[0].texture=target;
        id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
        [en setRenderPipelineState:pipeline];[en setVertexBuffer:src offset:0 atIndex:VB_SLOT(0)];[en setVertexBuffer:result offset:0 atIndex:1];
        [en drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:N];[en endEncoding];[cb commit];[cb waitUntilCompleted];CHECK(!cb.error);
        const uint32_t *gpu=result.contents;
        for(int n=0;n<N;n++){
            float expect[4];vconv_elem(f,input+n*STRIDE,expect);uint32_t words[4];memcpy(words,expect,16);
            for(int c=0;c<4;c++){
                uint32_t actual=gpu[n*4+c],wanted=words[c];if(actual==wanted){exact++;continue;}
                if(integer){fprintf(stderr,"integer format %#x vertex %d component %d: %08x != %08x\n",f,n,c,actual,wanted);return 3;}
                float a;memcpy(&a,&actual,4);uint32_t ulp=actual>wanted?actual-wanted:wanted-actual;
                if(!isfinite(a)||!isfinite(expect[c])||ulp>1){fprintf(stderr,"float format %#x vertex %d component %d: %08x != %08x (%u ULP)\n",f,n,c,actual,wanted,ulp);return 4;}
                rounded++;if(ulp>max_ulp)max_ulp=ulp;
            }
        }
        formats++;
    }
    printf("PASS %u formats, %u component bit matches; %u normalized components within %u ULP; native vertex bindings and signed extension verified\n",formats,exact,rounded,max_ulp);
    return 0;
} }
