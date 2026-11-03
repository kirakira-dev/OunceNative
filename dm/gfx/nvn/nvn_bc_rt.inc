// Render raw compressed blocks through an integer attachment, then copy bytes back.
typedef struct {
    id<MTLTexture> base, proxy;
    id<MTLBuffer> bytes;
    NSUInteger level, slice, width, height, row, image;
    int slot;
} bc_rt_entry;
static bc_rt_entry g_bc_rt[8];
static unsigned g_bc_rt_count;

static unsigned bc_rt_block_bytes(MTLPixelFormat format) {
    switch (format) {
        case MTLPixelFormatBC1_RGBA: case MTLPixelFormatBC1_RGBA_sRGB:
        case MTLPixelFormatBC4_RUnorm: case MTLPixelFormatBC4_RSnorm: return 8;
        case MTLPixelFormatBC2_RGBA: case MTLPixelFormatBC2_RGBA_sRGB:
        case MTLPixelFormatBC3_RGBA: case MTLPixelFormatBC3_RGBA_sRGB:
        case MTLPixelFormatBC5_RGUnorm: case MTLPixelFormatBC5_RGSnorm:
        case MTLPixelFormatBC6H_RGBFloat: case MTLPixelFormatBC6H_RGBUfloat:
        case MTLPixelFormatBC7_RGBAUnorm: case MTLPixelFormatBC7_RGBAUnorm_sRGB: return 16;
        default: return 0;
    }
}
static MTLPixelFormat bc_rt_format(id<MTLTexture> base, const view_t *v, int has_view) {
    unsigned bytes = bc_rt_block_bytes(base.pixelFormat); uint32_t format = 0; uint8_t swizzle[4];
    if (!bytes || !has_view || !v->set_format || base.sampleCount != 1 || base.textureType == MTLTextureType3D) return MTLPixelFormatInvalid;
    if (!nvn_fmt_to_mtl(v->format, &format, swizzle)) return MTLPixelFormatInvalid;
    if ((bytes == 8 && format == MTLPixelFormatRGBA16Uint) || (bytes == 16 && format == MTLPixelFormatRGBA32Uint)) return format;
    return MTLPixelFormatInvalid;
}
static id<MTLTexture> bc_rt_begin(id<MTLTexture> base, const view_t *v, int has_view, int slot) {
    MTLPixelFormat format = bc_rt_format(base, v, has_view);
    if (!format || slot < 0 || g_legacy_cb || g_bc_rt_count == 8) return nil;
    NSUInteger level = v->set_levels ? v->base_level : 0, slice = v->set_layers ? v->min_layer : 0;
    NSUInteger slices = base.arrayLength * (base.textureType == MTLTextureTypeCube || base.textureType == MTLTextureTypeCubeArray ? 6 : 1);
    if (level >= base.mipmapLevelCount || slice >= slices) return nil;
    NSUInteger width = mip_extent(base.width, level), height = mip_extent(base.height, level);
    NSUInteger blocks_x = (width + 3) / 4, blocks_y = (height + 3) / 4;
    NSUInteger row = (blocks_x * bc_rt_block_bytes(base.pixelFormat) + 255) & ~(NSUInteger)255, image = row * blocks_y;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:blocks_x height:blocks_y mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> proxy = [g_dev newTextureWithDescriptor:d];
    id<MTLBuffer> bytes = [g_dev newBufferWithLength:image options:MTLResourceStorageModePrivate];
    if (!proxy || !bytes) MDIE("compressed attachment allocation failed");
    res_add(proxy); res_add(bytes);
    enc_b_copy_texture_buffer(blit(), base, slice, level, MTLOriginMake(0,0,0), MTLSizeMake(width,height,1), bytes, 0, row, image);
    enc_b_copy_buffer_texture(blit(), bytes, 0, row, image, MTLSizeMake(blocks_x,blocks_y,1), proxy, 0, 0, MTLOriginMake(0,0,0));
    g_bc_rt[g_bc_rt_count++] = (bc_rt_entry){base,proxy,bytes,level,slice,width,height,row,image,slot};
    return proxy;
}
static void bc_rt_store(void) {
    for (unsigned i = 0; i < g_bc_rt_count; i++) [g_enc setColorStoreAction:MTLStoreActionStore atIndex:g_bc_rt[i].slot];
}
static void bc_rt_finish(void) {
    for (unsigned i = 0; i < g_bc_rt_count; i++) {
        bc_rt_entry *e = &g_bc_rt[i];
        enc_b_copy_texture_buffer(blit(), e->proxy, 0, 0, MTLOriginMake(0,0,0), MTLSizeMake(e->proxy.width,e->proxy.height,1), e->bytes, 0, e->row, e->image);
        enc_b_copy_buffer_texture(blit(), e->bytes, 0, e->row, e->image, MTLSizeMake(e->width,e->height,1), e->base, e->slice, e->level, MTLOriginMake(0,0,0));
        defer_obj_release(e->proxy); defer_obj_release(e->bytes); *e = (bc_rt_entry){0};
    }
    g_bc_rt_count = 0;
}
