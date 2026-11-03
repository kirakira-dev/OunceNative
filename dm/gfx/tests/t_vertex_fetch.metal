#include <metal_stdlib>
using namespace metal;
constant uint fetch_type [[function_constant(64)]];
constant bool fetch_float = fetch_type == 1;
constant bool fetch_int = fetch_type == 2;
constant bool fetch_uint = fetch_type == 0;
struct Input {
    float4 value_f [[attribute(0),function_constant(fetch_float)]];
    int4 value_i [[attribute(0),function_constant(fetch_int)]];
    uint4 value_u [[attribute(0),function_constant(fetch_uint)]];
};
struct Output { float4 position [[position]]; };
vertex Output test(Input in [[stage_in]], uint id [[vertex_id]], device uint4 *values [[buffer(1)]]) {
    uint4 bits = fetch_float ? as_type<uint4>(in.value_f) : fetch_int ? as_type<uint4>(in.value_i) : in.value_u;
    values[id] = bits;
    return {float4(0,0,0,1)};
}
