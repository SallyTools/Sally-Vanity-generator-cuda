// Keccak-256 (original Keccak padding 0x01, as used by Ethereum -- NOT SHA3).
// Specialised: absorbs exactly 64 bytes (uncompressed pubkey x||y) -> 32-byte
// digest; the Ethereum address is digest[12..31].
#pragma once
#include "cuda_compat.cuh"
#include <cstdint>

#if defined(__CUDACC__)
  #define KHD __host__ __device__ __forceinline__
#else
  #define KHD inline
#endif

__device__ __host__ static const uint64_t KECCAK_RC[24] = {
 0x0000000000000001ULL,0x0000000000008082ULL,0x800000000000808aULL,0x8000000080008000ULL,
 0x000000000000808bULL,0x0000000080000001ULL,0x8000000080008081ULL,0x8000000000008009ULL,
 0x000000000000008aULL,0x0000000000000088ULL,0x0000000080008009ULL,0x000000008000000aULL,
 0x000000008000808bULL,0x800000000000008bULL,0x8000000000008089ULL,0x8000000000008003ULL,
 0x8000000000008002ULL,0x8000000000000080ULL,0x000000000000800aULL,0x800000008000000aULL,
 0x8000000080008081ULL,0x8000000000008080ULL,0x0000000080000001ULL,0x8000000080008008ULL };

KHD uint64_t krotl(uint64_t x,int n){ return (x<<n)|(x>>(64-n)); }

// canonical (public-domain) keccak-f[1600]
KHD void keccak_f(uint64_t st[25]){
    const int rotc[24]={1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44};
    const int piln[24]={10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1};
    uint64_t bc[5],t;
    for(int r=0;r<24;r++){
        // Theta
        for(int i=0;i<5;i++) bc[i]=st[i]^st[i+5]^st[i+10]^st[i+15]^st[i+20];
        for(int i=0;i<5;i++){ t=bc[(i+4)%5]^krotl(bc[(i+1)%5],1); for(int j=0;j<25;j+=5) st[j+i]^=t; }
        // Rho + Pi
        t=st[1];
        for(int i=0;i<24;i++){ int j=piln[i]; bc[0]=st[j]; st[j]=krotl(t,rotc[i]); t=bc[0]; }
        // Chi
        for(int j=0;j<25;j+=5){ for(int i=0;i<5;i++) bc[i]=st[j+i]; for(int i=0;i<5;i++) st[j+i]^=(~bc[(i+1)%5])&bc[(i+2)%5]; }
        // Iota
        st[0]^=KECCAK_RC[r];
    }
}

// generic keccak-256 over inlen bytes (inlen < 136). out = 32 bytes.
KHD void keccak256(uint8_t out[32], const uint8_t* in, int inlen){
    uint64_t s[25];
    for(int i=0;i<25;i++) s[i]=0;
    uint8_t blk[136];
    for(int i=0;i<136;i++) blk[i]=0;
    for(int i=0;i<inlen;i++) blk[i]=in[i];
    blk[inlen]^=0x01;       // keccak padding start
    blk[135]^=0x80;         // padding end (rate=136)
    for(int i=0;i<17;i++){  // 136/8 = 17 lanes
        uint64_t w=0;
        for(int j=0;j<8;j++) w|=((uint64_t)blk[i*8+j])<<(8*j);
        s[i]^=w;
    }
    keccak_f(s);
    for(int i=0;i<4;i++)
        for(int j=0;j<8;j++) out[i*8+j]=(uint8_t)(s[i]>>(8*j));
}

// general keccak-256 over arbitrary length (multi-block). Host-side use, e.g.
// hashing a CREATE2 init_code that can exceed one 136-byte rate block.
KHD void keccak256_var(uint8_t out[32], const uint8_t* in, uint32_t inlen){
    uint64_t s[25];
    for(int i=0;i<25;i++) s[i]=0;
    uint32_t off=0;
    while(inlen-off>=136){
        for(int i=0;i<17;i++){
            uint64_t w=0; for(int j=0;j<8;j++) w|=((uint64_t)in[off+i*8+j])<<(8*j);
            s[i]^=w;
        }
        keccak_f(s); off+=136;
    }
    uint8_t blk[136]; for(int i=0;i<136;i++) blk[i]=0;
    uint32_t rem=inlen-off;
    for(uint32_t i=0;i<rem;i++) blk[i]=in[off+i];
    blk[rem]^=0x01; blk[135]^=0x80;
    for(int i=0;i<17;i++){
        uint64_t w=0; for(int j=0;j<8;j++) w|=((uint64_t)blk[i*8+j])<<(8*j);
        s[i]^=w;
    }
    keccak_f(s);
    for(int i=0;i<4;i++)
        for(int j=0;j<8;j++) out[i*8+j]=(uint8_t)(s[i]>>(8*j));
}
