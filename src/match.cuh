// Shared match configuration + final-address matcher for all search modes.
// Given a derived EOA address, optionally turn it into a CREATE/CREATE2 contract
// address, then test the hex prefix/suffix pattern (nibble-granular).
#pragma once
#include "cuda_compat.cuh"
#include "rlp.cuh"

#if defined(__CUDACC__)
  #define MHD __host__ __device__ __forceinline__
#else
  #define MHD inline
#endif

enum { TGT_EOA=0, TGT_CREATE=1, TGT_CREATE2=2 };

struct MatchCfg {
    int      preflen, suflen;     // number of hex nibbles
    uint8_t  pref[40], suf[40];   // each entry 0..15
    int      target;              // TGT_*
    uint64_t nonce;               // start nonce for CREATE
    int      nonce_count;         // CREATE: check nonces [nonce .. nonce+count-1]
    uint8_t  salt[32];            // for CREATE2
    uint8_t  inithash[32];        // keccak256(init_code) for CREATE2
};

MHD int match_pattern(const uint8_t a[20], const MatchCfg* c){
    for(int i=0;i<c->preflen;i++){
        uint8_t nib = (i&1) ? (a[i>>1]&0xf) : (a[i>>1]>>4);
        if(nib!=c->pref[i]) return 0;
    }
    for(int i=0;i<c->suflen;i++){
        int idx=40-c->suflen+i;
        uint8_t nib = (idx&1) ? (a[idx>>1]&0xf) : (a[idx>>1]>>4);
        if(nib!=c->suf[i]) return 0;
    }
    return 1;
}

// produce the final address to match from an EOA address, for a specific nonce
MHD void final_address_n(const uint8_t eoa[20], const MatchCfg* c, uint64_t nonce, uint8_t out[20]){
    if(c->target==TGT_CREATE)       create_address(eoa, nonce, out);
    else if(c->target==TGT_CREATE2) create2_address(eoa, c->salt, c->inithash, out);
    else                            { for(int i=0;i<20;i++) out[i]=eoa[i]; }
}

// Match test. Returns the matched nonce for CREATE (>=0), 0 for EOA/CREATE2 on a
// match, or -1 on no match. For CREATE it scans nonces [nonce .. nonce+count-1].
MHD long long match_final_nonce(const uint8_t eoa[20], const MatchCfg* c){
    uint8_t fin[20];
    if(c->target==TGT_CREATE){
        int cnt = c->nonce_count<1 ? 1 : c->nonce_count;
        for(int i=0;i<cnt;i++){
            uint64_t nn=c->nonce+(uint64_t)i;
            create_address(eoa, nn, fin);
            if(match_pattern(fin,c)) return (long long)nn;
        }
        return -1;
    }
    final_address_n(eoa, c, c->nonce, fin);
    return match_pattern(fin, c) ? 0 : -1;
}
