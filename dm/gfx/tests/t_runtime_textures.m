#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { memset(key, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t serial = 98000; return ++serial; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s (%s)\n", __LINE__, #x, error.description.UTF8String); return 1; } } while (0)

int main(int argc, char **argv) { @autoreleasepool {
    NSError *error = nil; CHECK(argc == 3); unsigned dimension = atoi(argv[2]); CHECK(dimension <= 2); mtl_init(); state_reset();
    NSString *directory = @(argv[1]);
    NSString *source = [NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"fixture.metal"] encoding:NSUTF8StringEncoding error:&error]; CHECK(source);
    MTLCompileOptions *options = [MTLCompileOptions new]; options.mathMode = MTLMathModeSafe;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:options error:&error]; CHECK(lib);
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"fixture.json"]] options:0 error:&error]; CHECK(json);
    for (unsigned test = 0; test < 7; test++) {
        NSMutableDictionary *bad = [json mutableCopy]; NSMutableArray *bindings = [json[@"bindings"] mutableCopy]; bad[@"bindings"] = bindings;
        if (test == 0) [bad removeObjectForKey:@"runtime_texture_formats"];
        else if (test == 1) bad[@"runtime_texture_formats"] = @{@"version":@2};
        else if (test == 2) [bindings removeLastObject];
        else if (test == 3) [bindings removeObjectAtIndex:2];
        else { NSMutableDictionary *b = [bindings[2] mutableCopy]; bindings[2] = b;
            if (test == 4) b[@"runtime_class"] = @2;
            if (test == 5) b[@"arg_id"] = @0;
            if (test == 6) b[@"reg"] = @0.5;
        }
        nvn_refl rf; char why[256]; CHECK(nvn_refl_from_json(bad, &rf, why, sizeof why));
    }
    NvShader *shaders[2]; id<MTLRenderPipelineState> pipelines[5];
    for (unsigned i = 0; i < 5; i++) {
        NSString *entry = i < 2 ? [NSString stringWithFormat:@"main%u", i] : @[@"ref_float", @"ref_uint", @"ref_int"][i - 2];
        id<MTLFunction> fn = [lib newFunctionWithName:entry]; CHECK(fn);
        if (i < 2) {
            NvShader *sh = [NvShader new]; sh->fn = fn; sh->stage = 1; char why[256];
            CHECK(!nvn_refl_from_json(json, &sh->rf, why, sizeof why));
            sh->ae = [fn newArgumentEncoderWithBufferIndex:0]; sh->arg_len = sh->ae.encodedLength;
            CHECK(sh->arg_len == 40 && sh->rf.nb == 5); shaders[i] = sh;
        }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"triangle"]; pd.fragmentFunction = fn;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Uint;
        pipelines[i] = [g_dev newRenderPipelineStateWithDescriptor:pd error:&error]; CHECK(pipelines[i]);
    }
    id<MTLTexture> output[2];
    for (unsigned i = 0; i < 2; i++) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:10 height:8 mipmapped:NO];
        d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget;
        output[i] = [g_dev newTextureWithDescriptor:d]; CHECK(output[i]);
    }
    samp_par sp = {.lod_max = 100, .aniso = 1}; mtl_reg_samp(11, &sp);
    S.tex[1][0] = 300 | (11ull << 20);
    tex_t native_target = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial()};
    native_target.d.width = 10; native_target.d.height = 8;
    native_target.d.depth = native_target.d.levels = native_target.d.samples = 1;
    native_target.d.target = NVN_TEXTURE_TARGET_2D; native_target.d.format = NVN_FORMAT_RGBA32UI;
    id<MTLTexture> native_texture = tex_mtl(&native_target); CHECK(native_texture);
    id<MTLBuffer> native_read = [g_dev newBufferWithLength:2560 options:MTLResourceStorageModeShared]; CHECK(native_read); res_add(native_read);
    int formats[] = {NVN_FORMAT_RGBA32F, NVN_FORMAT_RGBA32UI, NVN_FORMAT_RGBA32I,
                     NVN_FORMAT_RGBA8, NVN_FORMAT_RGBA8SN, NVN_FORMAT_RGBA8UI, NVN_FORMAT_RGBA8I};
    unsigned words = 0, guards = 0, cases = 0;
    for (unsigned native = 0; native < 2; native++) for (unsigned rect = 0; rect < (dimension ? 1 : 3); rect++) for (unsigned test = 0; test < 7; test++) {
        unsigned shader_index = rect != 0;
        unsigned kind = test == 1 || test == 5 ? 1 : test == 2 || test == 6 ? 2 : 0;
        tex_t t = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial()};
        unsigned slices = dimension == 1 ? 3 : dimension == 2 ? 12 : 1, height = dimension == 2 ? 8 : 4;
        t.d.width = 8; t.d.height = height; t.d.depth = slices; t.d.levels = t.d.samples = 1;
        t.d.target = dimension == 1 ? NVN_TEXTURE_TARGET_2D_ARRAY : dimension == 2 ? NVN_TEXTURE_TARGET_CUBEMAP_ARRAY : rect == 1 ? NVN_TEXTURE_TARGET_RECTANGLE : NVN_TEXTURE_TARGET_2D; t.d.format = formats[test];
        id<MTLTexture> texture = tex_mtl(&t); CHECK(texture);
        uint32_t raw[] = {0, 1, 0x7fc12345, 0xffffffff, 0x80000000, 0x7fffffff, 16777217, 0x81234567,
                          4, 99, 0x12345678, 0xffff0001, 0x3f800000, 0x80000001, 0x7f800000, 0xdeadbeef};
        float floats[] = {0, 1, -1, .5f, 1.5f, 3.25f, -42.75f, 65504, 1e-20f, 1e20f, -128, 127, 2, -2, 17.5f, -.25f};
        uint8_t bytes[] = {0, 1, 127, 255, 128, 254, 64, 17, 2, 3, 100, 200, 7, 13, 19, 23};
        id<MTLBuffer> seed = [g_dev newBufferWithLength:256 * height * slices options:MTLResourceStorageModeShared]; CHECK(seed); memset(seed.contents, 0, seed.length);
        for (unsigned sl = 0; sl < slices; sl++) for (unsigned y = 0; y < height; y++) for (unsigned n = 0; n < 32; n++) {
            uint8_t *at = (uint8_t *)seed.contents + (sl * height + y) * 256; unsigned value = (n + sl * 3) % 16;
            if (test < 3) memcpy(at + n * 4, test == 0 ? (void *)&floats[value] : (void *)&raw[value], 4);
            else at[n] = bytes[value];
        }
        mtl_sub_begin(); res_add(seed);
        for (unsigned sl = 0; sl < slices; sl++)
            enc_b_copy_buffer_texture(blit(), seed, sl * height * 256, 256, height * 256, MTLSizeMake(8, height, 1), texture, sl, 0, MTLOriginMake(0, 0, 0));
        view_t view = {.set_target = 1, .target = NVN_TEXTURE_TARGET_RECTANGLE};
        mtl_reg_tex(300, &t, rect == 2 ? &view : NULL);
        if (native) {
            memset(native_read.contents, 0xcd, native_read.length);
            memset(&R, 0, sizeof R); R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &native_target;
            id<MTL4RenderCommandEncoder> en = rp_begin(); CHECK(en);
            enc_r_pso(en, pipelines[shader_index]); enc_r_viewport(en, (MTLViewport){0,0,10,8,0,1}); enc_r_cull(en, MTLCullModeNone);
            CHECK(encode_args(en, shaders[shader_index], 1, 0));
            enc_r_scissor(en, (MTLScissorRect){0,0,5,8}); enc_r_draw(en, MTLPrimitiveTypeTriangle, 0, 3);
            uint64_t reused = g_stat_args_reuse; CHECK(encode_args(en, shaders[shader_index], 1, 0)); CHECK(g_stat_args_reuse == reused + 1);
            enc_r_scissor(en, (MTLScissorRect){5,0,5,8}); enc_r_draw(en, MTLPrimitiveTypeTriangle, 0, 3); rp_end();
            enc_b_copy_texture_buffer(blit(), native_texture, 0, 0, MTLOriginMake(0,0,0), MTLSizeMake(10,8,1), native_read, 256, 256, 2048);
        }
        id<MTLCommandBuffer> cb = legacy_begin();
        for (unsigned reference = native; reference < 2; reference++) {
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = output[reference]; pass.colorAttachments[0].loadAction = MTLLoadActionDontCare; pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:pass];
            [en setRenderPipelineState:pipelines[reference ? 2 + kind : shader_index]];
            if (!reference) { CHECK(encode_args_to(en, shaders[shader_index], 1, ARGS_LEGACY_FRAGMENT)); }
            else { [en setFragmentTexture:texture atIndex:0]; [en setFragmentSamplerState:(__bridge id<MTLSamplerState>)samp_fast(11) atIndex:0]; }
            [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
        }
        legacy_commit(cb); CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull)); CHECK(!mtl_last_commit_error());
        uint32_t actual[320], expected[320];
        if (native) {
            for (unsigned y = 0; y < 8; y++) memcpy(actual + y * 40, (uint8_t *)native_read.contents + 256 + y * 256, 160);
            for (unsigned i = 0; i < 256; i++) { CHECK(((uint8_t *)native_read.contents)[i] == 0xcd); CHECK(((uint8_t *)native_read.contents)[2304 + i] == 0xcd); }
        } else [output[0] getBytes:actual bytesPerRow:160 fromRegion:MTLRegionMake2D(0, 0, 10, 8) mipmapLevel:0];
        [output[1] getBytes:expected bytesPerRow:160 fromRegion:MTLRegionMake2D(0, 0, 10, 8) mipmapLevel:0];
        for (unsigned y = 0; y < 8; y++) for (unsigned x = 0; x < 10; x++) for (unsigned c = 0; c < 4; c++) {
            unsigned n = (y * 10 + x) * 4 + c;
            if (actual[n] != expected[n]) { fprintf(stderr, "mismatch format%u rect%u pixel%u,%u channel%u got%08x expected%08x\n", test, rect, x, y, c, actual[n], expected[n]); return 1; }
            if (x == 0 || x == 9 || y == 0 || y == 7) { CHECK(actual[n] == 0xa5a5a5a5); guards++; }
            else words++;
        }
        // The integer read row must also match the input bits without relying on
        // the reference shader, including values beyond float's exact range.
        if (kind) for (unsigned x = 0; x < 8; x++) for (unsigned c = 0; c < 4; c++) {
            unsigned slice = dimension == 1 ? x % 3 : dimension == 2 ? (x % 2) * 6 : 0;
            unsigned n = (x * 4 + c + slice * 3) % 16;
            uint32_t want = test < 3 ? raw[n] : kind == 1 ? bytes[n] : (uint32_t)(int32_t)(int8_t)bytes[n];
            CHECK(actual[(3 * 10 + x + 1) * 4 + c] == want);
        }
        mtl_reg_tex(300, NULL, NULL); cases++;
    }
    printf("PASS dimension%u: %u descriptor rebinds, %u exact sample/read/gather/gradient/query words, %u guard words; seven formats, rectangle coordinates, Metal 4/legacy bindings and argument reuse\n", dimension, cases, words, guards);
    return 0;
} }
