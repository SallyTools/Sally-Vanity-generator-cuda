// SHA-256 (FIPS 180-4). Host+device. Used for the BIP39 mnemonic checksum
// (first ENT/32 bits of SHA256(entropy)). General streaming impl; inputs here
// are tiny (16 or 32 bytes) but multi-block is supported for safety.
#pragma once
#include "cuda_compat.cuh"
#include <cstdint>
#include <cstring>

#if defined(__CUDACC__)
  #define SHD __host__ __device__ __forceinline__
#else
  #define SHD inline
#endif

__device__ __host__ static const uint32_t SHA256_K[64] = {
 0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
 0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
 0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
 0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
 0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
 0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
 0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
 0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };

SHD uint32_t s_rotr(uint32_t x,int n){ return (x>>n)|(x<<(32-n)); }

SHD void sha256_block(uint32_t h[8], const uint8_t* p){
    // rolling 16-word schedule (keeps w[16] live, not w[64]) — much smaller
    // local-memory footprint inside register-heavy GPU kernels.
    uint32_t w[16];
    #pragma unroll
    for(int i=0;i<16;i++)
        w[i]=((uint32_t)p[i*4]<<24)|((uint32_t)p[i*4+1]<<16)|((uint32_t)p[i*4+2]<<8)|p[i*4+3];
    uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
    #pragma unroll
    for(int i=0;i<64;i++){
        uint32_t wi;
        if(i<16) wi=w[i];
        else{
            uint32_t w15=w[(i+1)&15], w2=w[(i+14)&15];
            uint32_t s0=s_rotr(w15,7)^s_rotr(w15,18)^(w15>>3);
            uint32_t s1=s_rotr(w2,17)^s_rotr(w2,19)^(w2>>10);
            wi=w[i&15]=w[i&15]+s0+w[(i+9)&15]+s1;
        }
        uint32_t S1=s_rotr(e,6)^s_rotr(e,11)^s_rotr(e,25);
        uint32_t ch=(e&f)^((~e)&g);
        uint32_t t1=hh+S1+ch+SHA256_K[i]+wi;
        uint32_t S0=s_rotr(a,2)^s_rotr(a,13)^s_rotr(a,22);
        uint32_t maj=(a&b)^(a&c)^(b&c);
        uint32_t t2=S0+maj;
        hh=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
    }
    h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=hh;
}

// out[32] = SHA256(in[inlen]).  inlen arbitrary (handles padding/multi-block).
SHD void sha256(uint8_t out[32], const uint8_t* in, uint32_t inlen){
    uint32_t h[8]={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                   0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    uint32_t i=0;
    for(; i+64<=inlen; i+=64) sha256_block(h,in+i);
    uint8_t blk[64]; uint32_t rem=inlen-i;
    for(uint32_t j=0;j<rem;j++) blk[j]=in[i+j];
    blk[rem]=0x80;
    if(rem>=56){
        for(uint32_t j=rem+1;j<64;j++) blk[j]=0;
        sha256_block(h,blk);
        for(int j=0;j<64;j++) blk[j]=0;
    } else {
        for(uint32_t j=rem+1;j<56;j++) blk[j]=0;
    }
    uint64_t bits=(uint64_t)inlen*8;
    for(int j=0;j<8;j++) blk[56+j]=(uint8_t)(bits>>(56-8*j));
    sha256_block(h,blk);
    for(int i2=0;i2<8;i2++){
        out[i2*4]=(uint8_t)(h[i2]>>24);out[i2*4+1]=(uint8_t)(h[i2]>>16);
        out[i2*4+2]=(uint8_t)(h[i2]>>8);out[i2*4+3]=(uint8_t)h[i2];
    }
}
