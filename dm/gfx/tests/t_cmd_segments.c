#include "../nvn/hle_nvn.c"
#include <time.h>
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
int dm_guest_as_contains(uintptr_t address) { return 0; }
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
enum { LISTS = 1024 };
static NVNcommandHandle record_at(NVNcommandBuffer *c, pool_t *pool, unsigned index, unsigned generation, size_t offset) {
    h_nvnCommandBufferInitialize(c, NULL);
    h_nvnCommandBufferAddCommandMemory(c, (NVNmemoryPool *)pool, offset, 512);
    h_nvnCommandBufferBeginRecording(c);
    for (unsigned push = 0; push < 3; push++) {
        uint32_t data[64];
        for (unsigned i = 0; i < 64; i++) data[i] = index * 991 + generation * 10000000 + push * 73 + i;
        h_nvnCommandBufferPushGraphicsConstants(c, 0, 0, sizeof data, data);
        memset(data, 0xa7, sizeof data);
    }
    return h_nvnCommandBufferEndRecording(c);
}
static NVNcommandHandle record(NVNcommandBuffer *c, pool_t *pool, unsigned index, unsigned generation) {
    return record_at(c, pool, index, generation, index * 512);
}
static void verify(NVNcommandHandle handle, unsigned index, unsigned generation) {
    const uint8_t *p = (const uint8_t *)handle; unsigned pushes = 0, steps = 0;
    for (;;) {
        CHECK(++steps < 10); op_hdr h; memcpy(&h, p, sizeof h);
        if (h.op == OP_END) break;
        if (h.op == OP_JUMP) { memcpy(&p, p + 8, sizeof p); continue; }
        if (h.op == OP_PUSH_CONSTANTS) {
            const p_push_constants *q = (const void *)(p + 8);
            CHECK(q->size == 256 && !q->compute && !q->index && !q->offset);
            for (unsigned i = 0; i < 64; i++) { uint32_t value; memcpy(&value, q->data + i * 4, 4); CHECK(value == index * 991 + generation * 10000000 + pushes * 73 + i); }
            pushes++;
        } else CHECK(h.op == OP_BEGIN);
        p += h.size;
    }
    CHECK(pushes == 3);
}
int main(void) {
    pool_t pool = {.mem=calloc(LISTS, 512)}; CHECK(pool.mem);
    NVNcommandBuffer c; NVNcommandHandle handles[LISTS];
    for (unsigned i = 0; i < LISTS; i++) handles[i] = record(&c, &pool, i, 0);
    CHECK(g_nhostseg == LISTS && g_hostseg_bytes == LISTS * 4096);
    for (unsigned i = 0; i < LISTS; i++) verify(handles[i], i, 0);
    for (unsigned i = 0; i < LISTS; i += 2) handles[i] = record(&c, &pool, i, 1);
    CHECK(g_nhostseg == LISTS && g_hostseg_bytes == LISTS * 4096);
    for (unsigned i = 0; i < LISTS; i++) verify(handles[i], i, !(i & 1));
    pool_t callers={.mem=calloc(1,8192)}, destinations={.mem=calloc(1,8192)};
    NVNcommandBuffer call, copied;
    h_nvnCommandBufferInitialize(&call,NULL);h_nvnCommandBufferAddCommandMemory(&call,(NVNmemoryPool *)&callers,0,8192);
    h_nvnCommandBufferBeginRecording(&call);h_nvnCommandBufferCallCommands(&call,1,&handles[1]);
    NVNcommandHandle nested=h_nvnCommandBufferEndRecording(&call);
    h_nvnCommandBufferInitialize(&copied,NULL);h_nvnCommandBufferAddCommandMemory(&copied,(NVNmemoryPool *)&destinations,0,8192);
    h_nvnCommandBufferBeginRecording(&copied);h_nvnCommandBufferCopyCommands(&copied,1,&nested);
    NVNcommandHandle independent=h_nvnCommandBufferEndRecording(&copied);
    verify(independent,1,0);handles[1]=record(&c,&pool,1,3);memset(callers.mem,0xe7,8192);verify(independent,1,0);
    tex_t texture={.magic=MAGIC('T','E','X',0),.serial=4123};texture.d.width=71;
    const NVNtexture *target=(const NVNtexture *)&texture;NVNcopyRegion region={0,0,0,4,4,1};float color[4]={1,2,3,4};
    h_nvnCommandBufferInitialize(&call,NULL);h_nvnCommandBufferAddCommandMemory(&call,(NVNmemoryPool *)&callers,0,8192);
    h_nvnCommandBufferBeginRecording(&call);
    h_nvnCommandBufferSetRenderTargets(&call,1,&target,NULL,target,NULL);
    h_nvnCommandBufferClearTexture(&call,target,NULL,&region,color,15);
    h_nvnCommandBufferCopyBufferToTexture(&call,123,target,NULL,&region,0);
    h_nvnCommandBufferCopyTextureToBuffer(&call,target,NULL,&region,456,0);
    h_nvnCommandBufferCopyTextureToTexture(&call,target,NULL,&region,target,NULL,&region,0);
    NVNcommandHandle textures=h_nvnCommandBufferEndRecording(&call);
    h_nvnCommandBufferBeginRecording(&copied);h_nvnCommandBufferCopyCommands(&copied,1,&textures);
    textures=h_nvnCommandBufferEndRecording(&copied);memset(callers.mem,0x13,8192);memset(&texture,0x51,sizeof texture);
    unsigned snapshots=0;
    for(const uint8_t *p=(const uint8_t *)textures;;) {
        op_hdr h;memcpy(&h,p,8);if(h.op==OP_END)break;CHECK(h.size>=8);const void *payload=p+8;
        const tex_t *check[2]={0};
        switch(h.op) {
            case OP_SET_RT:check[0]=((const p_set_rt *)payload)->color[0];check[1]=((const p_set_rt *)payload)->depth;break;
            case OP_CLEAR_TEX:check[0]=((const p_clear_tex *)payload)->tex;break;
            case OP_COPY_B2T:case OP_COPY_T2B:check[0]=((const p_copy_b2t *)payload)->tex;break;
            case OP_COPY_T2T:check[0]=((const p_copy_t2t *)payload)->src;check[1]=((const p_copy_t2t *)payload)->dst;break;
            default:CHECK(h.op==OP_BEGIN);break;
        }
        for(unsigned i=0;i<2;i++)if(check[i]) {CHECK((const uint8_t *)check[i]>=p+8&&(const uint8_t *)(check[i]+1)<=p+h.size);CHECK(check[i]->serial==4123&&check[i]->d.width==71);snapshots++;}
        p+=h.size;
    }
    CHECK(snapshots==7);printf("PASS copied nested commands survive source reuse; 7 embedded texture snapshots relocated\n");
    // Record in a large slab, then re-record in the measured compact slot.
    // The engine supplies its 512-byte minimum grant even for a 496-byte list.
    pool_t compact = {.mem=calloc(1,2048)};
    h_nvnCommandBufferInitialize(&c,NULL);
    h_nvnCommandBufferAddCommandMemory(&c,(NVNmemoryPool *)&compact,0,2048);
    h_nvnCommandBufferBeginRecording(&c);
    for(unsigned i=0;i<30;i++)h_nvnCommandBufferSetPatchSize(&c,i+1);
    NVNcommandHandle measured=h_nvnCommandBufferEndRecording(&c);
    size_t compact_size=h_nvnCommandBufferGetCommandMemoryUsed(&c);
    CHECK(compact_size==496);
    h_nvnCommandBufferAddCommandMemory(&c,(NVNmemoryPool *)&compact,compact_size,512);
    h_nvnCommandBufferBeginRecording(&c);h_nvnCommandBufferSetPatchSize(&c,31);
    NVNcommandHandle adjacent=h_nvnCommandBufferEndRecording(&c);
    uint8_t saved[32];memcpy(saved,(void *)adjacent,sizeof saved);
    h_nvnCommandBufferAddCommandMemory(&c,(NVNmemoryPool *)&compact,0,512);
    h_nvnCommandBufferBeginRecording(&c);
    for(unsigned i=0;i<30;i++)h_nvnCommandBufferSetPatchSize(&c,i+1);
    CHECK(h_nvnCommandBufferEndRecording(&c)==measured);
    CHECK(h_nvnCommandBufferGetCommandMemoryUsed(&c)==compact_size);
    CHECK(!memcmp(saved,(void *)adjacent,sizeof saved));
    printf("PASS compact re-recording preserves size and adjacent cached list\n");
    // A minimum-size grant overlaps the next packed list, but the recording
    // itself does not. Its overflow must remain alive when another list grows.
    pool_t packed = {.mem=calloc(1,4096)};
    NVNcommandHandle overflow_neighbor = record_at(&c,&packed,7,0,496);
    h_nvnCommandBufferInitialize(&c,NULL);
    h_nvnCommandBufferAddCommandMemory(&c,(NVNmemoryPool *)&packed,0,512);
    h_nvnCommandBufferBeginRecording(&c);
    for(unsigned i=0;i<30;i++)h_nvnCommandBufferSetPatchSize(&c,i+1);
    h_nvnCommandBufferEndRecording(&c);
    CHECK(h_nvnCommandBufferGetCommandMemoryUsed(&c)==496);
    record(&c,&packed,3,1);
    verify(overflow_neighbor,7,0);
    printf("PASS overlapping unused grant preserves a neighbor's overflow commands\n");
    h_nvnCommandBufferInitialize(&c, NULL);
    h_nvnCommandBufferAddCommandMemory(&c, (NVNmemoryPool *)&pool, 0, 512);
    h_nvnCommandBufferBeginRecording(&c);
    uint8_t *large = cmd_alloc(CB(&c), 8192); memset(large + 8, 0x3d, 8184);
    CHECK(CB(&c)->end - CB(&c)->cur >= OP_RESERVE);
    for (unsigned i = 0; i < 8184; i++) CHECK(large[8 + i] == 0x3d);
    for (unsigned i = 1; i < LISTS; i++) verify(handles[i], i, i==1?3:!(i & 1));
    printf("PASS 1024 cached command lists, copied push data, overlapping-range reclamation and large-record growth; small overflows retain 4 MB\n");
    return 0;
}
