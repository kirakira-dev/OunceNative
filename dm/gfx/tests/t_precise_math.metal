// Precise helper reference emitted by SPIRV-Cross (Apache-2.0 OR MIT).
// The kernel exercises contraction, reassociation, matrices and half arithmetic.
#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T>
[[clang::optnone]] T spvFMul(T l, T r)
{
    return fma(l, r, T(0));
}

template<typename T, int Cols, int Rows>
[[clang::optnone]] vec<T, Cols> spvFMulVectorMatrix(vec<T, Rows> v, matrix<T, Cols, Rows> m)
{
    vec<T, Cols> res = vec<T, Cols>(0);
    for (uint i = Rows; i > 0; --i)
    {
        vec<T, Cols> tmp(0);
        for (uint j = 0; j < Cols; ++j)
        {
            tmp[j] = m[j][i - 1];
        }
        res = fma(tmp, vec<T, Cols>(v[i - 1]), res);
    }
    return res;
}

template<typename T, int Cols, int Rows>
[[clang::optnone]] vec<T, Rows> spvFMulMatrixVector(matrix<T, Cols, Rows> m, vec<T, Cols> v)
{
    vec<T, Rows> res = vec<T, Rows>(0);
    for (uint i = Cols; i > 0; --i)
    {
        res = fma(m[i - 1], vec<T, Rows>(v[i - 1]), res);
    }
    return res;
}

template<typename T, int LCols, int LRows, int RCols, int RRows>
[[clang::optnone]] matrix<T, RCols, LRows> spvFMulMatrixMatrix(matrix<T, LCols, LRows> l, matrix<T, RCols, RRows> r)
{
    static_assert(LCols == RRows, "column-row configuration mismatch");
    matrix<T, RCols, LRows> res;
    for (uint i = 0; i < RCols; i++)
    {
        vec<T, LRows> tmp(0);
        for (uint j = 0; j < LCols; j++)
        {
            tmp = fma(vec<T, LRows>(r[i][j]), l[j], tmp);
        }
        res[i] = tmp;
    }
    return res;
}

template<typename T>
[[clang::optnone]] T spvFAdd(T l, T r)
{
    return fma(T(1), l, r);
}


kernel void test(device const uint4 *bits [[buffer(0)]],device uint4 *result [[buffer(1)]],uint i [[thread_position_in_grid]]) {
 float4 v=as_type<float4>(bits[i]);float a=v.x,b=v.y,c=v.z,d=v.w;
 float x=spvFAdd(spvFMul(a,b),c),y=spvFMul(spvFAdd(a,b),c);
 float z=spvFAdd(spvFAdd(a,b),c),w=spvFMul(spvFMul(a,b),c);
 result[i*8u]=as_type<uint4>(float4(x,y,z,w));
 result[i*8u+1u]=as_type<uint4>(spvFAdd(spvFMul(v,v.yzwx),v.zwxy));
 half4 h=as_type<half4>(bits[i].xy);half a0=h.x,b0=h.y,c0=h.z;
 result[i*8u+2u]=uint4(as_type<uint2>(half4(spvFAdd(spvFMul(a0,b0),c0),spvFMul(spvFAdd(a0,b0),c0),spvFAdd(spvFAdd(a0,b0),c0),spvFMul(spvFMul(a0,b0),c0))),as_type<uint2>(spvFAdd(spvFMul(h,h.yzwx),h.zwxy)));
 float4x4 m=float4x4(v,v.wzyx,v.zwxy,v.yxwz);
 result[i*8u+3u]=as_type<uint4>(spvFMulMatrixVector(m,v));
 result[i*8u+4u]=as_type<uint4>(spvFMulVectorMatrix(v,m));
 float4x4 product=spvFMulMatrixMatrix(m,float4x4(v.yzwx,v.wxyz,v.wzyx,v.zwxy));
 result[i*8u+5u]=as_type<uint4>(product[0]);
 result[i*8u+6u]=as_type<uint4>(product[2]);
 result[i*8u+7u]=as_type<uint4>(float4(spvFAdd(spvFMul(a,b),-spvFMul(a,b)),spvFAdd(spvFMul(a,b),fma(a,b,c)),spvFMul(spvFAdd(a,b),spvFAdd(c,d)),fma(spvFAdd(a,b),spvFMul(c,d),a)));
}
