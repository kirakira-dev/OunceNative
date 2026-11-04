// Catmull-Rom reconstruction. The two positive inner weights share one linear
// texture sample, so the separable 4x4 filter needs nine samples. Clamp each
// sample to the declared crop, including its negative outer lobes.
static const char *present_bicubic_msl =
    "float4 cubic_weights(float f) { float f2=f*f, f3=f2*f; return float4(-0.5*f+f2-0.5*f3, 1.0-2.5*f2+1.5*f3, 0.5*f+2.0*f2-1.5*f3, -0.5*f2+0.5*f3); }\n"
    "fragment half4 cubic(V in [[stage_in]], texture2d<half> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {\n"
    "    float2 size=float2(t.get_width(),t.get_height()), p=(in.uv*c.rect.zw+c.rect.xy)*size-0.5, base=floor(p), f=p-base;\n"
    "    float4 wx=cubic_weights(f.x), wy=cubic_weights(f.y);\n"
    "    float3 x=(base.x+float3(-0.5,0.5+wx.z/(wx.y+wx.z),2.5))/size.x;\n"
    "    float3 y=(base.y+float3(-0.5,0.5+wy.z/(wy.y+wy.z),2.5))/size.y;\n"
    "    x=clamp(x,c.edge.x,c.edge.z); y=clamp(y,c.edge.y,c.edge.w);\n"
    "    half3 a=half3(wx.x,wx.y+wx.z,wx.w), b=half3(wy.x,wy.y+wy.z,wy.w);\n"
    "    half4 v=half4(0);\n"
    "    for(uint j=0;j<3;j++) for(uint i=0;i<3;i++) v+=t.sample(s,float2(x[i],y[j]),level(0))*(a[i]*b[j]);\n"
    "    return clamp(v,half(0),half(1));\n"
    "}\n";

static int present_bicubic_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) { const char *s = getenv("DM_UPSCALER"); enabled = s && !strcmp(s, "bicubic"); }
    return enabled;
}
