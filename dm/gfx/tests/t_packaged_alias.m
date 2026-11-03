#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial = 95000; return ++serial; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)

int main(void) { @autoreleasepool {
    mtl_init(); state_reset(); size_t checked = 0;
    for (unsigned native = 0; native < 2; native++) {
        pool_t pool = {0};
        tex_t source = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial(), .has_layout = 1, .pool = &pool};
        source.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGTC1_UNORM,
            .flags = NVN_TEXTURE_FLAGS_IMAGE, .width = 128, .height = 64, .depth = 1, .levels = 8,
            .pkg_block_h = 2, .native_tiling = native};
        source.layout[0] = 1; nvn_tex_layout(&source.d, &source.L);
        size_t allocated = (source.L.size + getpagesize() - 1) & ~(size_t)(getpagesize() - 1);
        CHECK(!posix_memalign((void **)&source.mem, getpagesize(), allocated));
        memset(source.mem, 0, allocated); pool.mem = source.mem; pool.size = allocated;
        mtl_pool_add(source.mem, allocated);
        for (unsigned level = 0; level < 8; level++) {
            size_t row = ((mip_extent(128, level) + 3) / 4) * 8, rows = (mip_extent(64, level) + 3) / 4;
            uint8_t *linear = malloc(row * rows);
            for (size_t i = 0; i < row * rows; i++) linear[i] = (uint8_t)(i * 37 + level * 13 + 5);
            CHECK(!nvn_swizzle(&source.d, level, 0, linear, row, source.mem)); free(linear);
        }
        mtl_tex_init(&source);
        tex_t alias = source; alias.serial = nvn_new_serial(); alias.has_layout = 0;
        alias.d.flags = 0; alias.d.pkg_block_h = 0; memset(alias.layout, 0, 8); nvn_tex_layout(&alias.d, &alias.L);
        mtl_tex_init(&alias); CHECK(alias.has_layout && alias.d.pkg_block_h == 2);
        // Command snapshots retain the resolved layout after the original dies.
        mtl_tex_release(&source); CHECK(g_pkg_storage.n == 1);
        tex_t snapshot = alias;
        id<MTLTexture> texture = tex_mtl(&snapshot); CHECK(texture);
        mtl_sub_begin(); NSMutableArray *reads = [NSMutableArray array];
        for (unsigned level = 0; level < 8; level++) {
            NSUInteger width = mip_extent(128, level), height = mip_extent(64, level);
            NSUInteger row = ((((width + 3) / 4) * 8) + 255) & ~255u, size = row * ((height + 3) / 4);
            id<MTLBuffer> out = [g_dev newBufferWithLength:size options:MTLResourceStorageModeShared]; CHECK(out);
            res_add(out); [reads addObject:out];
            enc_b_copy_texture_buffer(blit(), texture, 0, level, MTLOriginMake(0,0,0), MTLSizeMake(width,height,1), out, 0, row, size);
        }
        CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull)); CHECK(!mtl_last_commit_error());
        for (unsigned level = 0; level < 8; level++) {
            size_t row = ((mip_extent(128, level) + 3) / 4) * 8, rows = (mip_extent(64, level) + 3) / 4, pitch = (row + 255) & ~255u;
            id<MTLBuffer> out = reads[level]; const uint8_t *bytes = out.contents;
            for (size_t y = 0; y < rows; y++) for (size_t x = 0; x < row; x++) {
                CHECK(bytes[y * pitch + x] == (uint8_t)((y * row + x) * 37 + level * 13 + 5)); checked++;
            }
            res_remove(out);
        }
        tex_t unrelated = alias; unrelated.serial = nvn_new_serial(); unrelated.has_layout = 0;
        unrelated.d.format = NVN_FORMAT_RGTC2_UNORM; unrelated.d.pkg_block_h = 0;
        mtl_tex_init(&unrelated); CHECK(!unrelated.has_layout); mtl_tex_release(&unrelated);
        mtl_alias_drop_pool(&pool); CHECK(!g_pkg_storage.n && !g_pkg_serial.n);
        tex_t reused = alias; reused.serial = nvn_new_serial(); reused.has_layout = 0; reused.d.pkg_block_h = 0;
        mtl_tex_init(&reused); CHECK(!reused.has_layout); mtl_tex_release(&reused);
        mtl_tex_release(&alias); CHECK(!g_pkg_storage.n); mtl_pool_del(source.mem); free(source.mem);
    }
    printf("PASS packaged aliases: %zu exact BC4 bytes across 16 mips, both tilings, source lifetime, format isolation and pool reuse\n", checked);
    return 0;
}}
