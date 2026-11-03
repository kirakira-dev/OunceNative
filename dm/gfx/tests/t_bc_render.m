#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key,0,8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial=90000; return ++serial; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); return 1; } } while (0)

int main(void) { @autoreleasepool {
    mtl_init(); state_reset(); NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 vs(uint i [[vertex_id]]) { return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1); }\n"
        "fragment uint4 fs() { return uint4(0x1234,0x5678,0x9abc,0xdef0); }\n";
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error]; CHECK(lib);
    unsigned cases=0; size_t exact=0;
    for (unsigned wide=0;wide<2;wide++) for(unsigned level=0;level<2;level++) for(unsigned slice=0;slice<3;slice++) {
        tex_t t={.magic=MAGIC('T','E','X',0),.serial=nvn_new_serial()};
        t.d.width=101;t.d.height=61;t.d.depth=3;t.d.levels=2;t.d.samples=1;t.d.target=NVN_TEXTURE_TARGET_2D_ARRAY;
        t.d.format=wide?NVN_FORMAT_RGTC2_UNORM:NVN_FORMAT_RGTC1_UNORM;
        id<MTLTexture> base=tex_mtl(&t);CHECK(base);
        unsigned bpb=wide?16:8;
        mtl_sub_begin();
        for(unsigned sl=0;sl<3;sl++) for(unsigned lv=0;lv<2;lv++) {
            NSUInteger w=mip_extent(t.d.width,lv),h=mip_extent(t.d.height,lv),row=(((w+3)/4)*bpb+255)&~255u,img=row*((h+3)/4);
            id<MTLBuffer> seed=[g_dev newBufferWithLength:img options:MTLResourceStorageModeShared];CHECK(seed);memset(seed.contents,0x20+sl*4+lv,img);res_add(seed);
            enc_b_copy_buffer_texture(blit(),seed,0,row,img,MTLSizeMake(w,h,1),base,sl,lv,MTLOriginMake(0,0,0));defer_obj_release(seed);
        }
        memset(&R,0,sizeof R);R.has_rt=1;R.rt.n=1;R.rt.color[0]=&t;R.rt.has_cview[0]=1;
        R.rt.cview[0]=(view_t){.set_format=1,.set_levels=1,.set_layers=1,.format=wide?NVN_FORMAT_RGBA32UI:NVN_FORMAT_RGBA16UI,.base_level=level,.nlevels=1,.min_layer=slice,.nlayers=1};
        id<MTL4RenderCommandEncoder> en=rp_begin();CHECK(en);CHECK(g_bc_rt_count==1);
        NSUInteger pw=(mip_extent(t.d.width,level)+3)/4,ph=(mip_extent(t.d.height,level)+3)/4;CHECK(g_pass.tw==pw&&g_pass.th==ph);
        MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"vs"];pd.fragmentFunction=[lib newFunctionWithName:@"fs"];pd.colorAttachments[0].pixelFormat=wide?MTLPixelFormatRGBA32Uint:MTLPixelFormatRGBA16Uint;
        id<MTLRenderPipelineState> ps=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];CHECK(ps);
        enc_r_pso(en,ps);enc_r_viewport(en,(MTLViewport){0,0,pw,ph,0,1});enc_r_scissor(en,(MTLScissorRect){1,1,pw-2,ph-2});enc_r_cull(en,MTLCullModeNone);enc_r_draw(en,MTLPrimitiveTypeTriangle,0,3);
        rp_end();CHECK(!g_bc_rt_count);
        NSMutableArray *reads=[NSMutableArray array];
        for(unsigned sl=0;sl<3;sl++) for(unsigned lv=0;lv<2;lv++) {
            NSUInteger w=mip_extent(t.d.width,lv),h=mip_extent(t.d.height,lv),row=(((w+3)/4)*bpb+255)&~255u,img=row*((h+3)/4);
            id<MTLBuffer> out=[g_dev newBufferWithLength:img options:MTLResourceStorageModeShared];CHECK(out);res_add(out);[reads addObject:out];
            enc_b_copy_texture_buffer(blit(),base,sl,lv,MTLOriginMake(0,0,0),MTLSizeMake(w,h,1),out,0,row,img);
        }
        CHECK(mtl_wait(mtl_sub_commit(),10000000000ull));CHECK(!mtl_last_commit_error());
        for(unsigned sl=0;sl<3;sl++) for(unsigned lv=0;lv<2;lv++) {
            NSUInteger bx=(mip_extent(t.d.width,lv)+3)/4,by=(mip_extent(t.d.height,lv)+3)/4,row=(bx*bpb+255)&~255u;
            id<MTLBuffer> out=reads[sl*2+lv];const uint8_t *data=out.contents;
            uint32_t words32[]={0x1234,0x5678,0x9abc,0xdef0};uint16_t words16[]={0x1234,0x5678,0x9abc,0xdef0};const uint8_t *drawn=wide?(const uint8_t *)words32:(const uint8_t *)words16;
            for(NSUInteger y=0;y<by;y++)for(NSUInteger x=0;x<bx;x++)for(unsigned k=0;k<bpb;k++) {
                uint8_t expected=sl==slice&&lv==level&&x>0&&y>0&&x+1<bx&&y+1<by?drawn[k]:0x20+sl*4+lv;
                if(data[y*row+x*bpb+k]!=expected)fprintf(stderr,"case %u sl%u lv%u block%lu,%lu byte%u got %02x expected %02x\n",cases,sl,lv,x,y,k,data[y*row+x*bpb+k],expected);
                CHECK(data[y*row+x*bpb+k]==expected);exact++;
            }
            res_remove(out);
        }
        cases++;
    }
    printf("PASS %u compressed attachment cases, %zu exact bytes; 8/16-byte blocks, partial writes, odd mip sizes, preserved borders and array layers\n",cases,exact);
    return 0;
}}
