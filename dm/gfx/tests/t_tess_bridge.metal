#include <metal_stdlib>
using namespace metal;
struct Capture { uint patch; uint coord[3]; uint values[12]; };
[[patch(triangle, 3)]] vertex void capture_patch(
    uint patch [[patch_id]], float3 coord [[position_in_patch]],
    const device float* vertices [[buffer(22)]],
    device atomic_uint* count [[buffer(23)]], device Capture* output [[buffer(24)]]) {
    uint index = atomic_fetch_add_explicit(count, 1u, memory_order_relaxed);
    if (index >= 4096u) return;
    output[index].patch = patch;
    output[index].coord[0] = as_type<uint>(coord.x);
    output[index].coord[1] = as_type<uint>(coord.y);
    output[index].coord[2] = as_type<uint>(coord.z);
    for (uint v = 0; v < 3; v++) for (uint k = 0; k < 4; k++)
        output[index].values[v * 4 + k] = as_type<uint>(vertices[(patch * 3 + v) * 152 + 4 + k]);
}
