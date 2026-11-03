#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial = 90000; return ++serial; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)

int main(void) { @autoreleasepool {
    mtl_init(); state_reset(); NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct A { constant uint *root [[id(0)]]; };\n"
        "kernel void read_root(constant A &a [[buffer(0)]], device uint *out [[buffer(1)]], uint i [[thread_position_in_grid]]) { out[i] = a.root[i]; }\n";
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&error]; CHECK(lib);
    NvShader *sh = [NvShader new]; sh->fn = [lib newFunctionWithName:@"read_root"];
    sh->ae = [sh->fn newArgumentEncoderWithBufferIndex:0]; sh->arg_len = sh->ae.encodedLength;
    sh->rf.nb = 1; sh->rf.b[0] = (nvn_rbind){.kind=NVN_RB_ROOT_CONSTANTS, .aid=0};
    id<MTLComputePipelineState> ps = [g_dev newComputePipelineStateWithFunction:sh->fn error:&error]; CHECK(ps);
    enum { DRAWS = 6 * 8 * 2, WORDS = DRAWS * 64 };
    uint32_t expected[WORDS], cpu[2][8][64] = {0};
    id<MTLBuffer> output = [g_dev newBufferWithLength:(WORDS + 16) * 4 options:MTLResourceStorageModeShared];
    memset(output.contents, 0x59, output.length); res_add(output);
    mtl_sub_begin(); id<MTLCommandBuffer> cb = legacy_begin();
    id<MTLComputeCommandEncoder> encoder = [cb computeCommandEncoder]; [encoder setComputePipelineState:ps];
    unsigned draw = 0;
    for (unsigned stage = 0; stage < 6; stage++) for (unsigned table = 0; table < 8; table++) for (unsigned update = 0; update < 2; update++) {
        unsigned compute = stage == 5;
        p_push_constants p = {.compute=compute, .index=table, .offset=update ? 12 : 0, .size=update ? 228 : 256};
        for (unsigned i = 0; i < p.size / 4; i++) {
            uint32_t value = 0x98760000u ^ stage * 991u ^ table * 137u ^ update * 313u ^ i * 17u;
            memcpy(p.data + 4 * i, &value, 4); cpu[compute][table][p.offset / 4 + i] = value;
        }
        memset(g_args_dirty, 0, sizeof g_args_dirty); state_op(OP_PUSH_CONSTANTS, &p);
        for (unsigned i = 0; i < 6; i++) CHECK(g_args_dirty[i] == (compute ? i == 5 : i != 5));
        CHECK(!memcmp(S.root_constants[compute][table], cpu[compute][table], 256));
        CHECK(S.root_valid[compute][table] == UINT64_MAX);
        sh->rf.b[0].reg = table;
        CHECK(encode_args_to(encoder, sh, stage, ARGS_LEGACY_COMPUTE));
        [encoder setBuffer:output offset:(8 + draw * 64) * 4 atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
        memcpy(expected + draw++ * 64, cpu[compute][table], 256);
    }
    // All dispatches are still pending when the mutable state is overwritten.
    memset(S.root_constants, 0xc7, sizeof S.root_constants);
    [encoder endEncoding]; legacy_commit(cb);
    CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull)); CHECK(!mtl_last_commit_error());
    CHECK(draw == DRAWS); uint32_t *actual = output.contents;
    for (unsigned i = 0; i < WORDS; i++) CHECK(actual[8 + i] == expected[i]);
    for (unsigned i = 0; i < 8; i++) CHECK(actual[i] == 0x59595959 && actual[8 + WORDS + i] == 0x59595959);
    res_remove(output);
    sh->rf.b[0] = (nvn_rbind){.kind=NVN_RB_DRV0, .aid=0}; sh->rf.drv_read[0]=1;
    sh->rf.nx2_c0_size=176; sh->rf.nx2_root_words[0]=18; sh->rf.nx2_root_words[1]=7;
    sh->rf.nx2_ubo=1; sh->rf.nx2_ssbo=1; sh->rf.nx2_tex=1; sh->rf.nx2_img=1;
    S.ubo[5][0]=(p_bind_buf){.addr=0x1234567890ull,.size=0x4321};
    S.ssbo[5][0]=(p_bind_buf){.addr=0x9876543210ull,.size=0x1122};
    S.tex[5][0]=0x12345; S.img[5][0]=0x67890;
    g_dispatch_dim[0]=19;g_dispatch_dim[1]=7;g_dispatch_dim[2]=3;
    id<MTLBuffer> compact=[g_dev newBufferWithLength:4*256 options:MTLResourceStorageModeShared];res_add(compact);
    uint32_t compact_expected[4][64]={0};
    mtl_sub_begin();cb=legacy_begin();encoder=[cb computeCommandEncoder];[encoder setComputePipelineState:ps];
    for(unsigned snapshot=0;snapshot<4;snapshot++) {
        uint8_t *d=(uint8_t *)compact_expected[snapshot];uint32_t size=176;
        memcpy(d,&size,4);memcpy(d+4,g_dispatch_dim,12);
        for(unsigned root=0;root<2;root++)for(unsigned i=0;i<64;i++) {
            uint32_t word=0x32100000u+snapshot*1024+root*256+i;
            memcpy(S.root_constants[1][root]+4*i,&word,4);
        }
        memcpy(d+16,S.root_constants[1][0],72);memcpy(d+96,S.root_constants[1][1],28);
        uint64_t a=S.ubo[5][0].addr;uint32_t n=S.ubo[5][0].size;memcpy(d+128,&a,8);memcpy(d+136,&n,4);
        a=S.ssbo[5][0].addr;n=S.ssbo[5][0].size;memcpy(d+144,&a,8);memcpy(d+152,&n,4);
        uint32_t h=S.tex[5][0];memcpy(d+160,&h,4);h=S.img[5][0];memcpy(d+168,&h,4);
        CHECK(encode_args_to(encoder,sh,5,ARGS_LEGACY_COMPUTE));
        [encoder setBuffer:compact offset:snapshot*256 atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
    }
    memset(S.root_constants,0xee,sizeof S.root_constants);[encoder endEncoding];legacy_commit(cb);
    CHECK(mtl_wait(mtl_sub_commit(),10000000000ull));CHECK(!mtl_last_commit_error());
    CHECK(!memcmp(compact.contents,compact_expected,sizeof compact_expected));res_remove(compact);
    printf("PASS 4 compact compute tables, 256 exact words; roots, padding, descriptors and queued lifetime\n");
    printf("PASS %u root constant snapshots, %u exact words; six stages, eight tables, partial updates and queued GPU lifetime\n", draw, WORDS);
    return 0;
}}
