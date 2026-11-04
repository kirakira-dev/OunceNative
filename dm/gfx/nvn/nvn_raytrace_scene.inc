static NvRayScene *g_ray_scene;
static id<MTLTexture> g_ray_depth;
static uint64_t g_ray_depth_serial;
static nvn_ray_camera g_ray_camera;
static float ray_setting(const char *name, float fallback, float low, float high) {
    const char *s=getenv(name); if (!s) return fallback;
    char *end; float v=strtof(s,&end); return *end || !isfinite(v) ? fallback : fminf(high,fmaxf(low,v));
}
static NvRayScene *ray_scene(void) {
    uint64_t frame=atomic_load(&g_cur_frame);
    if (g_ray_scene && g_ray_scene->frame==frame) return g_ray_scene;
    static NvRayScene *slots[3]; unsigned i=frame%3;
    if (!slots[i]) slots[i]=[[NvRayScene alloc] initWithDevice:g_dev];
    NvRayScene *s=slots[i]; if (!s) return nil;
    if (s->fence) mtl_wait(s->fence,UINT64_MAX);
    [s reset]; s->frame=frame; s->fence=0;
    g_ray_scene=s; g_ray_depth=nil; g_ray_depth_serial=0;
    memset(&g_ray_camera,0,sizeof g_ray_camera);
    g_ray_camera.radius=ray_setting("DM_RAYTRACE_RADIUS",2,.01f,1000);
    g_ray_camera.strength=ray_setting("DM_RAYTRACE_STRENGTH",.45f,0,1);
    g_ray_camera.bias=g_ray_camera.radius*.002f;
    g_ray_camera.depth_tolerance=g_ray_camera.radius*.025f;
    g_ray_camera.zero_near=atomic_load(&g_depth_zero);
    g_ray_camera.flip=atomic_load(&g_origin_ll);
    return s;
}

static int ray_camera_read(NvShader *vs, float inverse[16]) {
    int layout=vs->ray_camera; size_t length=layout==2 ? 176 : 128;
    const p_bind_buf *u=&S.ubo[0][layout==2 ? 0 : 5]; if (!u->addr || u->size<length) return 0;
    id<MTLBuffer> buffer; size_t offset;
    if (ubd_hits(u->addr,u->addr+length)) {
        if (!ubd_covers(u->addr,u->addr+length)) return 0;
        ubd_snapshot(u->addr,u->addr+length,&buffer,&offset);
    } else {
        void *raw; uint64_t off;
        if (pend_hits(u->addr,length) || !mtl_addr(u->addr,length,&raw,&off)) return 0;
        buffer=(__bridge id<MTLBuffer>)raw; offset=(size_t)off;
    }
    if (!buffer.contents || offset>buffer.length || buffer.length-offset<length) return 0;
    float vp[32]={0}; const uint8_t *src=(const uint8_t *)buffer.contents+offset;
    if (layout==2) { memcpy(vp,src,48); vp[15]=1; memcpy(vp+16,src+112,64); }
    else memcpy(vp,src,sizeof vp);
    for(int i=0;i<32;i++) if(!isfinite(vp[i])) return 0;
    if (fabsf(vp[12])+fabsf(vp[13])+fabsf(vp[14])>1e-5f || fabsf(vp[15]-1)>1e-5f ||
        fabsf(vp[28])+fabsf(vp[29])+fabsf(vp[31])>1e-5f || fabsf(vp[30])<.5f) return 0;
    return nvn_ray_inverse(vp,vp+16,inverse);
}

static void ray_capture_draw(NvProg *pr, const p_draw *dw, const p_draw_idx *di, id<MTL4RenderCommandEncoder> en) {
    NvShader *vs=pr->sh[0], *fs=pr->sh[1];
    if (!vs || !vs->ray_capture) return;
    static id<MTLBuffer> disabled;
    if (!disabled) {
        disabled=[g_dev newBufferWithLength:sizeof(nvn_ray_capture) options:MTLResourceStorageModeShared];
        if(!disabled) MDIE("cannot allocate ray tracing capture parameters");
        memset(disabled.contents,0,sizeof(nvn_ray_capture));res_add(disabled);
    }
    enc_r_vbuf(en,13,disabled.gpuAddress);
    if (!fs || !fs->ray_solid || !S.ds.dt || !S.ds.dw || (S.color.blend_en&1) || S.ms.a2c ||
        g_defer_replaying || g_fz.active || g_frz_state ||
        !R.rt.depth || !R.rt.n || !R.rt.color[0] || (dw && dw->ind) || (di && di->ind)) return;
    const tex_t *dt=R.rt.depth, *ct=R.rt.color[0];
    uint32_t w=dt->d.width,h=dt->d.height;
    if (w<640 || h<360 || w!=ct->d.width || h!=ct->d.height || fabs((double)w/h-16.0/9)>.02 ||
        (R.rt.has_dview && (R.rt.dview.base_level || R.rt.dview.min_layer)) ||
        (S.has_vp && (S.vp[0][0]!=0 || S.vp[0][1]!=0 || S.vp[0][2]!=w || S.vp[0][3]!=h)) || S.dr[0]!=0 || S.dr[1]!=1) return;
    NvRayScene *scene=ray_scene(); if (!scene || scene->applied || scene->overflow) return;
    if (g_ray_depth_serial && g_ray_depth_serial!=dt->serial) { scene->rejected++; return; }
    if (!g_ray_depth) {
        if (!vs->ray_camera || !ray_camera_read(vs,g_ray_camera.inverse)) { scene->rejected++; return; }
        g_ray_depth=tex_mtl(dt);
        if (!g_ray_depth || g_ray_depth.textureType!=MTLTextureType2D || g_ray_depth.sampleCount!=1) { g_ray_depth=nil; return; }
        g_ray_depth_serial=dt->serial; g_ray_camera.width=w; g_ray_camera.height=h;
    }
    int prim=dw ? dw->prim : di->prim, n=dw ? dw->count : di->count, inst=dw ? dw->instances : di->instances;
    if ((prim!=4 && prim!=5) || n<3 || n>1024*1024 || inst<0) { scene->rejected++; return; }
    uint32_t *indices=malloc((size_t)n*4); if (!indices) return;
    if (di) {
        int size=di->itype==0 ? 1 : di->itype==1 ? 2 : di->itype==2 ? 4 : 0;
        void *raw; uint64_t offset; const uint8_t *src;
        if (!size || pend_hits(di->ibuf,(uint64_t)n*size) || !mtl_addr(di->ibuf,(uint64_t)n*size,&raw,&offset) ||
            !(src=[(__bridge id<MTLBuffer>)raw contents])) { free(indices); scene->rejected++; return; }
        src+=offset;
        uint32_t restart=S.primitive_restart.index & (size==1 ? UINT8_MAX : size==2 ? UINT16_MAX : UINT32_MAX);
        for(int i=0;i<n;i++) {
            indices[i]=size==1 ? src[i] : size==2 ? ((const uint16_t *)src)[i] : ((const uint32_t *)src)[i];
            if (S.primitive_restart.enabled && indices[i]==restart) { free(indices); scene->rejected++; return; }
        }
    } else for(int i=0;i<n;i++) indices[i]=(uint32_t)i;
    nvn_ray_capture capture;
    BOOL ok=[scene appendIndices:indices count:(uint32_t)n primitive:prim baseVertex:dw ? dw->first : di->base_vertex
                   baseInstance:dw ? dw->base_instance : di->base_instance instances:inst ? (uint32_t)inst : 1
                        inverse:g_ray_camera.inverse capture:&capture];
    free(indices); if (!ok) return;
    id<MTLBuffer> params; size_t offset=arena_alloc(sizeof capture,&params);
    memcpy((uint8_t *)params.contents+offset,&capture,sizeof capture);
    enc_r_vbuf(en,13,params.gpuAddress+offset);
    [g_cb useResidencySet:scene->residency]; scene->fence=g_fence+1;
    static uint64_t reported=UINT64_MAX;
    if (scene->frame%300==0 && reported!=scene->frame) {
        reported=scene->frame;
        MLOG("ray tracing capture frame %llu: depth %llu %ux%u, vertex %s",scene->frame,g_ray_depth_serial,w,h,vs->key);
    }
}

static void ray_composite_before(NvProg *pr) {
    if (!g_ray_scene || !g_ray_depth || !pr || !pr->sh[1] || g_ray_scene->applied ||
        g_ray_scene->frame!=atomic_load(&g_cur_frame)) return;
    // Raiders' tone-map pass reads scene HDR at fragment texture 0, bloom at
    // texture 1 and a 3D color LUT at texture 2. Its output precedes the HUD.
    if (strncmp(pr->sh[1]->key,"67d418bf2cb9f061",16)) return;
    int tid=(int)(S.tex[1][0]&0xfffff); id<MTLTexture> color=nil;
    pthread_mutex_lock(&g_rmu);
    if (tid>0 && tid<g_ntreg && g_treg[tid].t.serial) color=tex_mtl(&g_treg[tid].t);
    pthread_mutex_unlock(&g_rmu);
    if (!color || color.width!=g_ray_depth.width || color.height!=g_ray_depth.height) return;
    rp_end(); if(g_blit) { enc_b_end(g_blit); g_blit=nil; }
    NSError *error=nil;
    BOOL ok=[g_ray_scene encode:g_cb color:color depth:g_ray_depth camera:&g_ray_camera error:&error];
    g_ray_scene->fence=g_fence+1; g_last_end_relaxed=0;
    if (ok && (g_ray_scene->frame%300==0 || g_ray_scene->frame<10)) MLOG("ray tracing frame %llu: %u draws, %u triangles, %u unsupported draws",g_ray_scene->frame,g_ray_scene->draws,g_ray_scene->triangle_count,g_ray_scene->rejected);
    if (g_ray_scene->overflow && g_ray_scene->frame%300==0) MLOG("ray tracing skipped frame %llu: scene exceeds the geometry budget (%u vertices, %u triangles)",g_ray_scene->frame,g_ray_scene->vertex_count,g_ray_scene->triangle_count);
    if(error) { static int n; if(n++<4) MLOG("ray tracing skipped: %s",error.localizedDescription.UTF8String); }
}
