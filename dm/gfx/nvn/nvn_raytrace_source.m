#import "nvn_raytrace.h"
#include <math.h>
#include <string.h>

int nvn_ray_inverse(const float view[16], const float projection[16], float out[16]) {
    double a[4][8] = {{0}};
    for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) {
        for (int k = 0; k < 4; k++) a[r][c] += (double)projection[4*r+k] * view[4*k+c];
        if (!isfinite(a[r][c])) return 0;
        a[r][c+4] = r == c;
    }
    for (int c = 0; c < 4; c++) {
        int best = c;
        for (int r = c+1; r < 4; r++) if (fabs(a[r][c]) > fabs(a[best][c])) best = r;
        if (fabs(a[best][c]) < 1e-12) return 0;
        for (int k = 0; k < 8; k++) { double t = a[c][k]; a[c][k] = a[best][k]; a[best][k] = t; }
        double d = a[c][c]; for (int k = 0; k < 8; k++) a[c][k] /= d;
        for (int r = 0; r < 4; r++) if (r != c) {
            d = a[r][c]; for (int k = 0; k < 8; k++) a[r][k] -= d * a[c][k];
        }
    }
    for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) {
        double d = a[r][c+4]; if (!isfinite(d) || fabs(d) > 1e12) return 0;
        out[4*r+c] = (float)d;
    }
    return 1;
}

static NSString *capture_header(void) {
    return @"\nstruct DmRayCapture { device atomic_uint* vertices; uint first, count, base_instance, instances; uint2 pad; float4 inverse[4]; };\n"
    "static inline void dm_ray_capture(constant DmRayCapture& c, float4 p, uint v, uint i, bool gl) {\n"
    " if (!c.count || v < c.first || v-c.first >= c.count || i < c.base_instance || i-c.base_instance >= c.instances) return;\n"
    " if (gl) p.z = p.z*2.0f-p.w;\n"
    " float4 w = float4(dot(c.inverse[0],p),dot(c.inverse[1],p),dot(c.inverse[2],p),dot(c.inverse[3],p));\n"
    " if (!all(isfinite(w)) || abs(w.w)<1e-8f) return;\n"
    " float3 q=w.xyz/w.w; if (!all(isfinite(q)) || any(abs(q)>float3(1e7f))) return;\n"
    " uint n=4*((i-c.base_instance)*c.count+v-c.first);\n"
    " atomic_store_explicit(c.vertices+n,as_type<uint>(q.x),memory_order_relaxed);\n"
    " atomic_store_explicit(c.vertices+n+1,as_type<uint>(q.y),memory_order_relaxed);\n"
    " atomic_store_explicit(c.vertices+n+2,as_type<uint>(q.z),memory_order_relaxed);\n"
    " atomic_store_explicit(c.vertices+n+3,1u,memory_order_relaxed);\n"
    "}\n";
}

NSString *nvn_ray_vertex_source(NSString *source) {
    if (!source || [source containsString:@"[[buffer(13)]]"] || [source containsString:@"DmRayCapture"]) return nil;
    NSRegularExpression *entry = [NSRegularExpression regularExpressionWithPattern:@"vertex\\s+main0_out\\s+(main0(?:_z)?)\\(([^\\n]*)\\)\\s*\\{" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [entry matchesInString:source options:0 range:NSMakeRange(0, source.length)];
    if (matches.count != 2) return nil;
    NSMutableString *s = [source mutableCopy];
    NSRegularExpression *idrx[2];
    idrx[0] = [NSRegularExpression regularExpressionWithPattern:@"uint\\s+(\\w+)\\s*\\[\\[vertex_id\\]\\]" options:0 error:nil];
    idrx[1] = [NSRegularExpression regularExpressionWithPattern:@"uint\\s+(\\w+)\\s*\\[\\[instance_id\\]\\]" options:0 error:nil];
    for (NSTextCheckingResult *m in matches.reverseObjectEnumerator) {
        NSString *name = [source substringWithRange:[m rangeAtIndex:1]], *args = [source substringWithRange:[m rangeAtIndex:2]];
        NSMutableString *extra = [(args.length ? @", constant DmRayCapture& dm_rc [[buffer(13)]]" : @"constant DmRayCapture& dm_rc [[buffer(13)]]") mutableCopy];
        NSString *ids[2];
        for (int k = 0; k < 2; k++) {
            NSTextCheckingResult *idmatch = [idrx[k] firstMatchInString:args options:0 range:NSMakeRange(0,args.length)];
            if (!idmatch && [args containsString:k ? @"[[instance_id]]" : @"[[vertex_id]]"]) return nil;
            ids[k] = idmatch ? [args substringWithRange:[idmatch rangeAtIndex:1]] : k ? @"dm_ri" : @"dm_rv";
            if (!idmatch) [extra appendFormat:@", uint %@ [[%@]]", ids[k], k ? @"instance_id" : @"vertex_id"];
        }
        NSUInteger begin = NSMaxRange(m.range), end = begin; int braces = 1;
        for (; end < source.length && braces; end++) { unichar c = [source characterAtIndex:end]; braces += c == '{'; braces -= c == '}'; }
        if (braces) return nil;
        NSRange bodyRange = NSMakeRange(begin, end-begin-1);
        NSString *body = [source substringWithRange:bodyRange];
        if (![body containsString:@"return out;"]) return nil;
        NSString *call = [NSString stringWithFormat:@"dm_ray_capture(dm_rc, out.gl_Position, %@, %@, %@); return out;", ids[0], ids[1], [name isEqual:@"main0"] ? @"true" : @"false"];
        [s replaceCharactersInRange:bodyRange withString:[body stringByReplacingOccurrencesOfString:@"return out;" withString:call]];
        [s insertString:extra atIndex:NSMaxRange([m rangeAtIndex:2])];
    }
    NSRange use = [s rangeOfString:@"using namespace metal;"];
    if (use.location == NSNotFound) return nil;
    [s insertString:capture_header() atIndex:NSMaxRange(use)];
    return s;
}
