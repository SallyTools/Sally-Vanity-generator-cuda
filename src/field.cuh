// secp256k1 base field Fp arithmetic.  p = 2^256 - 2^32 - 977
// 4x64-bit little-endian limbs (v[0] = least significant).
// All functions are __host__ __device__ so the exact same code runs in the
// CPU self-test and in the GPU kernel.
#pragma once
#include "cuda_compat.cuh"
#include <cstdint>
#include <cstring>

#if defined(__CUDACC__)
  #define HD __host__ __device__ __forceinline__
#else
  #define HD inline
#endif

typedef struct { uint64_t v[4]; } fe;

// p and helper constants
__device__ __host__ static const uint64_t FE_P[4] = {
    0xFFFFFFFEFFFFFC2FULL, 0xFFFFFFFFFFFFFFFFULL,
    0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL };
// p - 2 (Fermat inverse exponent)
__device__ __host__ static const uint64_t FE_PM2[4] = {
    0xFFFFFFFEFFFFFC2DULL, 0xFFFFFFFFFFFFFFFFULL,
    0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL };
// C = 2^256 mod p = 2^32 + 977
#define FE_C 0x1000003D1ULL

HD void fe_set_u64(fe* r, uint64_t x){ r->v[0]=x; r->v[1]=0; r->v[2]=0; r->v[3]=0; }
HD bool fe_is_zero(const fe* a){ return (a->v[0]|a->v[1]|a->v[2]|a->v[3])==0; }
HD bool fe_eq(const fe* a, const fe* b){
    return a->v[0]==b->v[0]&&a->v[1]==b->v[1]&&a->v[2]==b->v[2]&&a->v[3]==b->v[3];
}
// returns 1 if a>=p
HD int fe_ge_p(const uint64_t a[4]){
    for(int i=3;i>=0;i--){ if(a[i]!=FE_P[i]) return a[i]>FE_P[i]; }
    return 1; // equal
}
HD void fe_sub_p(uint64_t a[4]){
    uint64_t bo=0;
    for(int i=0;i<4;i++){
        unsigned __int128 t=(unsigned __int128)a[i]-FE_P[i]-bo;
        a[i]=(uint64_t)t; bo=(t>>64)?1:0;
    }
}
HD void fe_add(fe* r, const fe* a, const fe* b){
    uint64_t c=0;
    for(int i=0;i<4;i++){
        unsigned __int128 t=(unsigned __int128)a->v[i]+b->v[i]+c;
        r->v[i]=(uint64_t)t; c=(uint64_t)(t>>64);
    }
    // result < 2p ; reduce
    if(c || fe_ge_p(r->v)) fe_sub_p(r->v);
}
HD void fe_sub(fe* r, const fe* a, const fe* b){
    uint64_t bo=0;
    for(int i=0;i<4;i++){
        unsigned __int128 t=(unsigned __int128)a->v[i]-b->v[i]-bo;
        r->v[i]=(uint64_t)t; bo=(t>>64)?1:0;
    }
    if(bo){ // add p back
        uint64_t c=0;
        for(int i=0;i<4;i++){
            unsigned __int128 t=(unsigned __int128)r->v[i]+FE_P[i]+c;
            r->v[i]=(uint64_t)t; c=(uint64_t)(t>>64);
        }
    }
}
HD void fe_neg(fe* r, const fe* a){
    if(fe_is_zero(a)){ *r=*a; return; }
    uint64_t bo=0;
    for(int i=0;i<4;i++){
        unsigned __int128 t=(unsigned __int128)FE_P[i]-a->v[i]-bo;
        r->v[i]=(uint64_t)t; bo=(t>>64)?1:0;
    }
}
// reduce a full 512-bit product (t[0..7]) into r (< p)
HD void fe_reduce_wide(fe* r, uint64_t t[8]){
    // first fold: high 256 bits * C, add to low
    uint64_t m[5]; unsigned __int128 carry=0;
    for(int i=0;i<4;i++){
        unsigned __int128 p=(unsigned __int128)t[4+i]*FE_C + carry;
        m[i]=(uint64_t)p; carry=p>>64;
    }
    m[4]=(uint64_t)carry;
    unsigned __int128 c2=0;
    for(int i=0;i<4;i++){
        unsigned __int128 s=(unsigned __int128)t[i]+m[i]+c2;
        t[i]=(uint64_t)s; c2=s>>64;
    }
    uint64_t top=m[4]+(uint64_t)c2;
    // second fold: top * C into low limbs
    unsigned __int128 p2=(unsigned __int128)top*FE_C;
    uint64_t add0=(uint64_t)p2, add1=(uint64_t)(p2>>64);
    unsigned __int128 s=(unsigned __int128)t[0]+add0; t[0]=(uint64_t)s; uint64_t cc=(uint64_t)(s>>64);
    s=(unsigned __int128)t[1]+add1+cc; t[1]=(uint64_t)s; cc=(uint64_t)(s>>64);
    s=(unsigned __int128)t[2]+cc; t[2]=(uint64_t)s; cc=(uint64_t)(s>>64);
    s=(unsigned __int128)t[3]+cc; t[3]=(uint64_t)s; cc=(uint64_t)(s>>64);
    if(cc){ // one more tiny fold (cc==1): add C
        s=(unsigned __int128)t[0]+FE_C; t[0]=(uint64_t)s; uint64_t k=(uint64_t)(s>>64);
        s=(unsigned __int128)t[1]+k; t[1]=(uint64_t)s; k=(uint64_t)(s>>64);
        s=(unsigned __int128)t[2]+k; t[2]=(uint64_t)s; k=(uint64_t)(s>>64);
        t[3]+=k;
    }
    r->v[0]=t[0]; r->v[1]=t[1]; r->v[2]=t[2]; r->v[3]=t[3];
    // final canonicalisation (at most twice)
    if(fe_ge_p(r->v)) fe_sub_p(r->v);
    if(fe_ge_p(r->v)) fe_sub_p(r->v);
}
// 256x256 schoolbook via __int128 + reduce. A device-only inline-PTX variant
// (mad.hi.cc partial-product chains) was implemented and verified byte-identical
// over a 26M-comparison on-device fuzz, but measured ~5% SLOWER (it raised vsearch
// from 159 to 194 registers, cutting occupancy) — nvcc already lowers __int128 to
// mul.lo/mul.hi efficiently. So the clean __int128 version is the production code.
HD void fe_mul(fe* r, const fe* a, const fe* b){
    uint64_t t[8]={0,0,0,0,0,0,0,0};
    for(int i=0;i<4;i++){
        unsigned __int128 carry=0;
        for(int j=0;j<4;j++){
            unsigned __int128 cur=(unsigned __int128)a->v[i]*b->v[j]+t[i+j]+carry;
            t[i+j]=(uint64_t)cur; carry=cur>>64;
        }
        t[i+4]+=(uint64_t)carry;
    }
    fe_reduce_wide(r,t);
}
// A dedicated squarer (cross-products once + doubling) was benchmarked and is
// performance-neutral here: on the GPU the extra doubling/carry passes cancel the
// saved multiplies, so we keep the simple, obviously-correct alias.
HD void fe_sqr(fe* r, const fe* a){ fe_mul(r,a,a); }

// Fermat inverse: a^(p-2) mod p
HD void fe_inv(fe* r, const fe* a){
    fe res; fe_set_u64(&res,1);
    fe base=*a;
    for(int i=0;i<4;i++){
        uint64_t e=FE_PM2[i];
        for(int b=0;b<64;b++){
            if(e&1ULL) fe_mul(&res,&res,&base);
            fe_sqr(&base,&base);
            e>>=1;
        }
    }
    *r=res;
}
// big-endian 32-byte I/O
HD void fe_from_be(fe* r, const uint8_t b[32]){
    for(int i=0;i<4;i++){
        uint64_t w=0;
        for(int j=0;j<8;j++) w=(w<<8)|b[i*8+j];
        r->v[3-i]=w;
    }
}
HD void fe_to_be(const fe* a, uint8_t b[32]){
    for(int i=0;i<4;i++){
        uint64_t w=a->v[3-i];
        for(int j=0;j<8;j++) b[i*8+j]=(uint8_t)(w>>(56-8*j));
    }
}
