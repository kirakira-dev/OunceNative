// Shader reflection json (B: produced by translating the original Switch shaders, output of tools/dmsh_build.py) → fixed-length C arrays (nvn_refl.h)
#import "nvn_refl.h"
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>

// Dummy texture type: same prefix rules as the original dummy_tex (an unbound texture slot reads 0 per D3D semantics)
static void dummy_kind(NSString *t, uint8_t *tt, uint8_t *pf) {
    MTLTextureType y = MTLTextureType2D;
    if ([t hasPrefix:@"texture2d_array"] || [t hasPrefix:@"depth2d_array"]) y = MTLTextureType2DArray;
    else if ([t hasPrefix:@"texturecube_array"] || [t hasPrefix:@"depthcube_array"]) y = MTLTextureTypeCubeArray;
    else if ([t hasPrefix:@"texturecube"] || [t hasPrefix:@"depthcube"]) y = MTLTextureTypeCube;
    else if ([t hasPrefix:@"texture3d"]) y = MTLTextureType3D;
    else if ([t hasPrefix:@"texture1d_array"]) y = MTLTextureType1DArray;
    else if ([t hasPrefix:@"texture1d"]) y = MTLTextureType1D;
    *tt = (uint8_t)y;
    *pf = [t hasPrefix:@"depth"] ? NVN_DPF_DEPTH : [t containsString:@"<uint"] ? NVN_DPF_UINT : [t containsString:@"<int"] ? NVN_DPF_SINT : NVN_DPF_FLOAT;
}

static int tess_uint(id value, uint64_t maximum) {
    return [value isKindOfClass:[NSNumber class]] && [value doubleValue] >= 0 &&
           [value doubleValue] == (double)[value unsignedLongLongValue] && [value unsignedLongLongValue] <= maximum;
}
static int tess_io(NSDictionary *j, nvn_tess_io *out, int patch) {
    if (![j isKindOfClass:[NSDictionary class]] || !tess_uint(j[@"present"], 1) ||
        !tess_uint(j[@"locations"], UINT32_MAX) || ![j[@"builtins"] isKindOfClass:[NSArray class]]) return 0;
    out->present = [j[@"present"] boolValue]; out->locations = [j[@"locations"] unsignedIntValue];
    NSArray *names = @[@"gl_Position", @"gl_PointSize", @"gl_ClipDistance", @"gl_Layer", @"gl_ViewportIndex", @"gl_ViewportMask",
                      @"gl_ClipDistance_0", @"gl_ClipDistance_1", @"gl_ClipDistance_2", @"gl_ClipDistance_3",
                      @"gl_ClipDistance_4", @"gl_ClipDistance_5", @"gl_ClipDistance_6", @"gl_ClipDistance_7"];
    for (id name in j[@"builtins"]) {
        NSUInteger index = [names indexOfObject:name];
        if (patch || index == NSNotFound || (out->builtins & (1u << index))) return 0;
        out->builtins |= (uint16_t)(1u << index);
    }
    return out->present || (!out->locations && !out->builtins);
}
static int tess_from_json(NSDictionary *j, nvn_tess *out, char *err, int errlen) {
    NSDictionary *t = j[@"nx2_tessellation"];
    if (!t) return 0;
    #define TFAIL(message) do { snprintf(err, errlen, "%s", message); return 1; } while (0)
    if (![t isKindOfClass:[NSDictionary class]] || !tess_uint(t[@"version"], 1) || [t[@"version"] intValue] != 1 ||
        !tess_uint(t[@"vertex_stride"], NVN_TESS_VERTEX_STRIDE) || [t[@"vertex_stride"] intValue] != NVN_TESS_VERTEX_STRIDE ||
        !tess_uint(t[@"patch_stride"], NVN_TESS_PATCH_STRIDE) || [t[@"patch_stride"] intValue] != NVN_TESS_PATCH_STRIDE)
        TFAIL("unsupported NX2 tessellation layout");
    NSString *stage = j[@"stage"];
    if ([stage isEqual:@"vertex"]) out->stage = 0;
    else if ([stage isEqual:@"hull"]) out->stage = 3;
    else if ([stage isEqual:@"domain"]) out->stage = 4;
    else TFAIL("invalid tessellation stage");
    if (out->stage != 0 && !tess_io(t[@"vertex_in"], &out->vertex_in, 0)) TFAIL("invalid tessellation vertex inputs");
    if (out->stage != 4 && !tess_io(t[@"vertex_out"], &out->vertex_out, 0)) TFAIL("invalid tessellation vertex outputs");
    if (out->stage == 3 && !tess_io(t[@"patch_out"], &out->patch_out, 1)) TFAIL("invalid tessellation patch outputs");
    if (out->stage == 4 && !tess_io(t[@"patch_in"], &out->patch_in, 1)) TFAIL("invalid tessellation patch inputs");
    if (out->stage == 0) {
        if (![t[@"vertex_index_type"] isEqual:@"uint32"] || !tess_uint(t[@"draw_params"], 1)) TFAIL("invalid tessellation vertex draw parameters");
        out->draw_params = [t[@"draw_params"] boolValue];
    } else {
        if (!tess_uint(t[@"control_points"], 32) || ![t[@"control_points"] intValue]) TFAIL("invalid tessellation control-point count");
        out->control_points = [t[@"control_points"] intValue];
        NSDictionary *state = t[@"state"];
        if (![state isKindOfClass:[NSDictionary class]]) TFAIL("missing tessellation state");
        NSUInteger domain = [@[@"triangles", @"quads", @"isolines"] indexOfObject:state[@"domain"] ?: NSNull.null];
        NSUInteger spacing = [@[@"equal", @"fractional_odd", @"fractional_even"] indexOfObject:state[@"spacing"] ?: NSNull.null];
        if (domain == NSNotFound || spacing == NSNotFound || !tess_uint(state[@"point_mode"], 1) || !tess_uint(state[@"clockwise"], 1)) TFAIL("invalid tessellation state");
        out->state.domain = domain; out->state.spacing = spacing;
        out->state.point_mode = [state[@"point_mode"] boolValue]; out->state.clockwise = [state[@"clockwise"] boolValue];
        NSArray *flags = state[@"declared"];
        if (![flags isKindOfClass:[NSArray class]] || flags.count != 4) TFAIL("invalid tessellation declaration flags");
        for (int i = 0; i < 4; i++) {
            if (!tess_uint(flags[i], 1)) TFAIL("invalid tessellation declaration flag");
            out->state.declared |= [flags[i] boolValue] << i;
        }
    }
    out->valid = 1; return 0;
    #undef TFAIL
}
static int geometry_from_json(NSDictionary *j, nvn_geometry *out, char *err, int errlen) {
    NSDictionary *g = j[@"nx2_geometry"]; if (!g) return 0;
    #define GFAIL(message) do { snprintf(err, errlen, "%s", message); return 1; } while (0)
    if (![g isKindOfClass:NSDictionary.class] || ![j[@"stage"] isEqual:@"geometry"] || j[@"nx2_tessellation"] ||
        !tess_uint(g[@"version"],1) || [g[@"version"] intValue] != 1 ||
        !tess_uint(g[@"vertex_stride"],608) || [g[@"vertex_stride"] intValue] != 608 ||
        !tess_uint(g[@"input_buffer"],20) || [g[@"input_buffer"] intValue] != 20 ||
        !tess_uint(g[@"primitive_buffer"],21) || [g[@"primitive_buffer"] intValue] != 21) GFAIL("invalid NX2 geometry layout");
    if (!tess_uint(g[@"input_vertices"],3) ||
        !(([g[@"input"] isEqual:@"points"] && [g[@"input_vertices"] intValue] == 1) ||
          ([g[@"input"] isEqual:@"triangles"] && [g[@"input_vertices"] intValue] == 3))) GFAIL("invalid geometry input topology");
    if (![g[@"output"] isEqual:@"points"] && ![g[@"output"] isEqual:@"triangles"]) GFAIL("invalid geometry output topology");
    out->input_vertices = [g[@"input_vertices"] intValue]; out->output_points = [g[@"output"] isEqual:@"points"];
    if (!tess_uint(g[@"max_vertices"],128) || ![g[@"max_vertices"] intValue] || !tess_uint(g[@"max_primitives"],128)) GFAIL("invalid geometry output limit");
    out->max_vertices = [g[@"max_vertices"] intValue]; out->max_primitives = [g[@"max_primitives"] intValue];
    if (out->max_primitives != (out->output_points ? out->max_vertices : MAX(1,out->max_vertices-2))) GFAIL("geometry primitive limit disagrees");
    for (NSString *name in @[@"layer",@"input_point_size",@"output_point_size",@"unresolved_position_default"])
        if (!tess_uint(g[name],1)) GFAIL("invalid geometry builtin metadata");
    out->layer = [g[@"layer"] boolValue]; out->input_point_size = [g[@"input_point_size"] boolValue];
    out->output_point_size = [g[@"output_point_size"] boolValue]; out->unresolved_position = [g[@"unresolved_position_default"] boolValue];
    NSString *written = g[@"written_position"];
    if (![written isKindOfClass:NSString.class] || out->unresolved_position == [written isEqual:@"xyzw"]) GFAIL("geometry position metadata disagrees");
    NSInteger previous = -1;
    for (NSUInteger i = 0; i < written.length; i++) {
        NSRange found = [@"xyzw" rangeOfString:[written substringWithRange:NSMakeRange(i,1)]];
        if (found.location == NSNotFound || (NSInteger)found.location <= previous) GFAIL("invalid geometry position components");
        previous = (NSInteger)found.location;
    }
    for (unsigned i = 0; i < 2; i++) {
        NSArray *locations = g[i ? @"outputs" : @"inputs"]; uint32_t mask = 0;
        if (![locations isKindOfClass:NSArray.class]) GFAIL("invalid geometry interface");
        for (id location in locations) {
            if (!tess_uint(location,31) || (mask & (1u << [location unsignedIntValue]))) GFAIL("invalid geometry location");
            mask |= 1u << [location unsignedIntValue];
        }
        if (i) out->outputs = mask; else out->inputs = mask;
    }
    out->valid = 1; return 0;
    #undef GFAIL
}
static int tess_io_matches(nvn_tess_io out, nvn_tess_io in) {
    return !(in.locations & ~out.locations) && !(in.builtins & ~out.builtins) && (!in.present || out.present);
}
int nvn_tess_pair(const nvn_tess *v, const nvn_tess *h, const nvn_tess *d, nvn_tess_state *state, char *err, int errlen) {
    #define PFAIL(message) do { snprintf(err, errlen, "%s", message); return 1; } while (0)
    if (!v->valid || !h->valid || !d->valid || v->stage != 0 || h->stage != 3 || d->stage != 4) PFAIL("missing tessellation stage variant");
    if (!h->control_points || h->control_points != d->control_points) PFAIL("hull/domain control-point counts disagree");
    if (!tess_io_matches(v->vertex_out, h->vertex_in) || !tess_io_matches(h->vertex_out, d->vertex_in) ||
        !tess_io_matches(h->patch_out, d->patch_in)) PFAIL("tessellation stage interfaces disagree");
    *state = (nvn_tess_state){.clockwise = 1};
    for (int i = 0; i < 2; i++) {
        nvn_tess_state s = i ? d->state : h->state;
        if (s.declared & 1) state->domain = s.domain;
        if (s.declared & 2) state->spacing = s.spacing;
        if (s.declared & 4) state->point_mode = s.point_mode;
        if (s.declared & 8) state->clockwise = s.clockwise;
        state->declared |= s.declared;
    }
    if (state->domain != h->state.domain || state->domain != d->state.domain || state->spacing != d->state.spacing ||
        state->point_mode != d->state.point_mode || state->clockwise != d->state.clockwise) PFAIL("tessellation pair requires a different compiled state variant");
    return 0;
    #undef PFAIL
}

int nvn_refl_from_json(NSDictionary *j, nvn_refl *o, char *err, int errlen) {
    memset(o, 0, sizeof *o);
    #define FAIL(...) do { free(o->c1); o->c1 = NULL; snprintf(err, errlen, __VA_ARGS__); return 1; } while (0)
    if (![j[@"route"] isEqual:@"B"]) FAIL("not a B reflection (route ≠ B; route A / PC-chain reflection is retired)");
    {   // Translated original Switch shaders: kind and NVN slot number are already parsed from the MSL member names by dmsh_build.py
        NSArray *bs = j[@"bindings"];
        if (![bs isKindOfClass:[NSArray class]]) FAIL("missing bindings");
        if (bs.count > NVN_REFL_MAXB) FAIL("%lu bindings, over the limit %d", (unsigned long)bs.count, NVN_REFL_MAXB);
        o->route_b = 1; o->abi = 0;   // spirv-cross set 0 → [[buffer(0)]]
        uint64_t argument_ids = 0;
        for (NSDictionary *b in bs) {
            NSString *k = b[@"kind"]; nvn_rbind *r = &o->b[o->nb];
            id rg = b[@"reg"]; int reg = [rg isKindOfClass:[NSNumber class]] ? [rg intValue] : -1, aid = [b[@"arg_id"] intValue];
            if (!tess_uint(b[@"arg_id"],NVN_REFL_MAXB-1) || (argument_ids & (1ull << aid))) FAIL("invalid or duplicated argument ID");
            argument_ids |= 1ull << aid;
            r->aid = (uint16_t)aid; r->reg = reg < 0 ? 0 : (uint16_t)reg;
            if ([k isEqualToString:@"cbuf"]) r->kind = NVN_RB_CBUF;
            else if ([k isEqualToString:@"samp"]) r->kind = NVN_RB_SAMP;
            else if ([k isEqualToString:@"samp_tex"]) r->kind = NVN_RB_SAMPT;
            else if ([k isEqualToString:@"unused_sampler"]) {
                if (![j[@"stage"] isEqual:@"compute"] || ![b[@"msl_type"] isEqual:@"sampler"]) FAIL("invalid unused sampler declaration");
                r->kind = NVN_RB_UNUSED_SAMP;
            }
            else if ([k isEqualToString:@"tex"]) { r->kind = NVN_RB_TEX; dummy_kind(b[@"msl_type"], &r->dtt, &r->dpf); }
            else if ([k isEqualToString:@"tex_ubo"]) { r->kind = NVN_RB_TEXU; dummy_kind(b[@"msl_type"], &r->dtt, &r->dpf); r->off = (uint16_t)[b[@"off"] intValue]; o->bindless = 1; }
            else if ([k isEqualToString:@"samp_ubo"]) { r->kind = NVN_RB_SAMPU; r->off = (uint16_t)[b[@"off"] intValue]; o->bindless = 1; }
            else if ([k isEqualToString:@"img"]) { r->kind = NVN_RB_IMG; r->rw = b[@"rw"] ? [b[@"rw"] boolValue] : 1; dummy_kind(b[@"msl_type"], &r->dtt, &r->dpf); }
            else if ([k isEqualToString:@"tbuf"]) { r->kind = NVN_RB_TBUF; uint8_t tt; dummy_kind(b[@"msl_type"], &tt, &r->dpf); }
            else if ([k isEqualToString:@"sbuf"]) { r->kind = NVN_RB_SBUFP; r->rw = [b[@"rw"] boolValue]; }
            else if ([k isEqualToString:@"ubo_ptr"]) r->kind = NVN_RB_UBOP;
            else if ([k isEqualToString:@"support"]) r->kind = NVN_RB_SUPPORT;
            else if ([k isEqualToString:@"c1"]) r->kind = NVN_RB_C1;
            else if ([k isEqualToString:@"drvcb"]) r->kind = [b[@"bank"] intValue] == 2 ? NVN_RB_DRV2 : NVN_RB_DRV0;
            else if ([k isEqualToString:@"root_constants"]) { if (reg < 0 || reg >= 8) FAIL("invalid NX2 root table index"); r->kind = NVN_RB_ROOT_CONSTANTS; }
            else FAIL("B binding kind %s not implemented (%s)", k.UTF8String, [b[@"msl_name"] UTF8String]);
            if ((r->kind == NVN_RB_CBUF || r->kind == NVN_RB_SAMP || r->kind == NVN_RB_SAMPT || r->kind == NVN_RB_TEX || r->kind == NVN_RB_IMG || r->kind == NVN_RB_TBUF || r->kind == NVN_RB_SBUFP || r->kind == NVN_RB_UBOP || r->kind == NVN_RB_TEXU || r->kind == NVN_RB_SAMPU) && reg < 0)
                FAIL("B binding %s has no resolved slot number", [b[@"msl_name"] UTF8String]);
            o->nb++;
        }
        NSDictionary *dr = j[@"drv_reads"];
        if ([dr isKindOfClass:[NSDictionary class]]) { o->drv_read[0] = dr[@"0"] != nil; o->drv_read[2] = dr[@"2"] != nil; }
        // A declared driver-segment binding means the shader reads it: the build's drv_reads scan (dmsh_build.py) matches only fragment-shader names (fp_c0 / fp_c2), so vertex and compute
        // shaders reading c0 got an all-zero segment (Link's Awakening's light culling multiplied the tile row by a zero workgroup count: every row's lights landed in row 0)
        for (int i = 0; i < o->nb; i++) { if (o->b[i].kind == NVN_RB_DRV0) o->drv_read[0] = 1; else if (o->b[i].kind == NVN_RB_DRV2) o->drv_read[2] = 1; }
        NSArray *uf = j[@"drv_unfillable"];
        if ([uf isKindOfClass:[NSArray class]] && uf.count) FAIL("reads driver-bank locations at run time that the replay layer cannot fill: %s", [[uf componentsJoinedByString:@" "] UTF8String]);
        NSString *c1 = j[@"c1"];
        if (c1.length % 2 || c1.length / 2 > 0xffff) FAIL("c1 is %lu bytes: over the limit or an odd hex length", (unsigned long)c1.length / 2);
        if (c1.length && !(o->c1 = malloc(c1.length / 2))) FAIL("c1 allocation of %lu bytes failed", (unsigned long)c1.length / 2);
        if (c1.length) { o->has_c1 = 1; o->c1_len = (uint16_t)(c1.length / 2); for (unsigned i = 0; i < o->c1_len; i++) o->c1[i] = (uint8_t)strtoul([[c1 substringWithRange:NSMakeRange(2 * i, 2)] UTF8String], NULL, 16); }
        for (NSDictionary *v in j[@"vertex_inputs"]) {   // [[attribute(n)]]: n is the NVN vertex attribute number
            int loc = [v[@"location"] intValue]; NSString *t = v[@"msl_type"];
            if (loc < 0 || loc >= NVN_REFL_MAXV || o->nv >= NVN_REFL_MAXV) FAIL("B vertex input %d out of range", loc);
            o->v[o->nv].loc = o->v[o->nv].nvn = (uint8_t)loc;
            o->v[o->nv].ct = [t hasPrefix:@"uint"] ? NVN_CT_UINT : [t hasPrefix:@"int"] ? NVN_CT_INT : NVN_CT_FLOAT;
            o->nv++;
        }
        NSDictionary *ra = j[@"raster"];
        o->pos_attr = -1; o->may_discard = 1; o->writes_smask = 1;
        if ([ra isKindOfClass:[NSDictionary class]]) {
            if (ra[@"pos_attr"]) { int pa = [ra[@"pos_attr"] intValue]; o->pos_attr = (int8_t)(pa >= 0 && pa < 16 ? pa : -1); o->pos_w1 = [ra[@"pos_w"] isEqual:@"one"]; }
            if (ra[@"discard"]) o->may_discard = [ra[@"discard"] intValue] != 0;
            if (ra[@"sample_mask"]) o->writes_smask = [ra[@"sample_mask"] intValue] != 0;
            for (NSNumber *c in ra[@"colors"]) if (c.intValue >= 0 && c.intValue < 8) o->color_mask |= (uint8_t)(1u << c.intValue);
            o->color_known = [ra[@"colors"] isKindOfClass:[NSArray class]];
        }
        memset(o->uv_attr, -1, sizeof o->uv_attr); memset(o->uv_aff_attr, -1, sizeof o->uv_aff_attr);
        NSDictionary *ua = [ra isKindOfClass:[NSDictionary class]] ? ra[@"uv_affine"] : nil;
        if ([ua isKindOfClass:[NSDictionary class]]) for (NSString *k in ua) { int l = k.intValue; NSDictionary *e = ua[k]; int a = [e[@"attr"] intValue];
            if (l < 0 || l >= 32 || a < 0 || a >= 16) continue;
            NSArray *refs[4] = {e[@"sx"], e[@"ox"], e[@"sy"], e[@"oy"]}; int ok = 1;
            for (int q = 0; q < 4; q++) { NSArray *r = refs[q]; if (![r isKindOfClass:[NSArray class]] || r.count != 3) { ok = 0; break; }
                int sl = [r[0] intValue], vec = [r[1] intValue], cmp = [r[2] intValue]; if (sl < 0 || sl > 15 || vec < 0 || vec > 63 || cmp < 0 || cmp > 3) { ok = 0; break; }
                o->uv_aff[l][q] = (uint16_t)(sl << 8 | vec << 2 | cmp); }
            if (ok) o->uv_aff_attr[l] = (int8_t)a; }
        NSDictionary *uv = [ra isKindOfClass:[NSDictionary class]] ? ra[@"uv_from_attr"] : nil;
        if ([uv isKindOfClass:[NSDictionary class]]) for (NSString *k in uv) { int l = k.intValue, a = [uv[k] intValue]; if (l >= 0 && l < 32 && a >= 0 && a < 16) o->uv_attr[l] = (int8_t)a; }
        NSDictionary *fe = j[@"fetch"];
        if ([fe isKindOfClass:[NSDictionary class]]) {
            for (NSDictionary *c in fe[@"calls"]) { int i = [c[@"fc"] intValue], r = [c[@"tex_reg"] intValue], l = [c[@"varying_locn"] intValue];
                if (i != o->nfc || i >= 32 || r < 0 || r >= 128 || l < 0 || l >= 32) FAIL("fetch call table not contiguous or out of range (entry %d)", i);
                o->fc_reg[o->nfc] = (uint8_t)r; o->fc_locn[o->nfc] = (uint8_t)l; o->nfc++; }
            for (NSNumber *r in fe[@"mixed_regs"]) if (r.intValue >= 0 && r.intValue < 128) o->fc_mixed[r.intValue >> 6] |= 1ull << (r.intValue & 63);
            for (NSDictionary *u in fe[@"outputs"]) { if (o->nfo >= 4) FAIL("more than 4 fetch outputs"); o->fo_color[o->nfo++] = (uint8_t)[u[@"color"] intValue]; }
        }
        NSArray *tg = j[@"threadgroup_size"];
        if ([tg isKindOfClass:[NSArray class]] && tg.count == 3) for (int i = 0; i < 3; i++) o->tg[i] = (uint16_t)[tg[i] intValue];
        NSDictionary *nx2 = j[@"nx2_compute"];
        if ([nx2 isKindOfClass:[NSDictionary class]]) {
            int u = [nx2[@"ubos"] intValue], s = [nx2[@"ssbos"] intValue];
            int t = [nx2[@"textures"] intValue], im = [nx2[@"images"] intValue];
            int size = [nx2[@"size"] intValue];
            NSArray *roots = nx2[@"root_words"]; int root_bytes = 0;
            if (roots && (![roots isKindOfClass:[NSArray class]] || roots.count != 8)) FAIL("invalid NX2 compute root tables");
            for (int i = 0; roots && i < 8; i++) {
                int words = [roots[i] intValue];
                if (words < 0 || words > 64) FAIL("invalid NX2 compute root size");
                o->nx2_root_words[i] = words; root_bytes += (words * 4 + 15) & ~15;
            }
            if (u < 0 || u > 16 || s < 0 || s > 16 || t < 0 || t > 128 || im < 0 || im > 32 ||
                size != 16 + root_bytes + 16 * (u + s) + 8 * (t + im) || size > 0xA00)
                FAIL("invalid NX2 compute driver table");
            o->nx2_c0_size = size; o->nx2_ubo = u; o->nx2_ssbo = s; o->nx2_tex = t; o->nx2_img = im;
        }
        if (tess_from_json(j, &o->tess, err, errlen)) { free(o->c1); o->c1 = NULL; return 1; }
        if (geometry_from_json(j, &o->geometry, err, errlen)) { free(o->c1); o->c1 = NULL; return 1; }
        return 0;
    }
    #undef FAIL
}
