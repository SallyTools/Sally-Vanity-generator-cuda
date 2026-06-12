// BIP32 hierarchical deterministic key derivation over secp256k1, plus the
// BIP44 Ethereum path m/44'/60'/0'/0/0. Host+device.
//   master:  I = HMAC-SHA512("Bitcoin seed", seed); k=I[0:32], c=I[32:64]
//   CKDpriv: hardened -> data = 0x00||ser256(k_par)||ser32(i)
//            normal   -> data = serP(point(k_par))||ser32(i)
//            I=HMAC-SHA512(c_par,data); k_i=(I[0:32]+k_par) mod n; c_i=I[32:64]
// Keys are 32-byte big-endian. Scalar add is mod n (curve order), not mod p.
#pragma once
#include "cuda_compat.cuh"
#include "field.cuh"
#include "ec.cuh"
#include "ec_fast.cuh"
#include "sha512.cuh"

#if defined(__CUDACC__)
  #define BHD __host__ __device__ __forceinline__
#else
  #define BHD inline
#endif

// secp256k1 group order n, little-endian limbs (v[0]=LSB)
__device__ __host__ static const uint64_t SECP_N[4] = {
    0xBFD25E8CD0364141ULL, 0xBAAEDCE6AF48A03BULL,
    0xFFFFFFFFFFFFFFFEULL, 0xFFFFFFFFFFFFFFFFULL };

BHD int n_ge(const uint64_t a[4]){ // a >= n ?
    for(int i=3;i>=0;i--){ if(a[i]!=SECP_N[i]) return a[i]>SECP_N[i]; }
    return 1;
}
BHD void n_sub(uint64_t a[4]){ // a -= n
    uint64_t bo=0;
    for(int i=0;i<4;i++){ unsigned __int128 t=(unsigned __int128)a[i]-SECP_N[i]-bo; a[i]=(uint64_t)t; bo=(t>>64)?1:0; }
}
// r = (a + b) mod n, all 32-byte big-endian
BHD void scalar_add_mod_n(const uint8_t a[32], const uint8_t b[32], uint8_t r[32]){
    uint64_t al[4], bl[4];
    for(int i=0;i<4;i++){ // big-endian -> little-endian limbs
        uint64_t wa=0, wb=0;
        for(int j=0;j<8;j++){ wa=(wa<<8)|a[(3-i)*8+j]; wb=(wb<<8)|b[(3-i)*8+j]; }
        al[i]=wa; bl[i]=wb;
    }
    uint64_t s[4], c=0;
    for(int i=0;i<4;i++){ unsigned __int128 t=(unsigned __int128)al[i]+bl[i]+c; s[i]=(uint64_t)t; c=(uint64_t)(t>>64); }
    if(c || n_ge(s)) n_sub(s);
    for(int i=0;i<4;i++){ uint64_t w=s[3-i]; for(int j=0;j<8;j++) r[i*8+j]=(uint8_t)(w>>(56-8*j)); }
}

// compressed SEC1 pubkey (33 bytes) of priv (32-byte big-endian)
BHD void priv_to_compressed(const uint8_t priv[32], uint8_t out[33]){
    fe kf; fe_from_be(&kf, priv);
    uint64_t k[4]={kf.v[0],kf.v[1],kf.v[2],kf.v[3]};
    ecp P; ec_mul_g_jac(&P,k);
    out[0]=0x02|(uint8_t)(P.y.v[0]&1ULL);
    fe_to_be(&P.x, out+1);
}
// uncompressed pub x||y (64 bytes) of priv
BHD void priv_to_pub64(const uint8_t priv[32], uint8_t out[64]){
    fe kf; fe_from_be(&kf, priv);
    uint64_t k[4]={kf.v[0],kf.v[1],kf.v[2],kf.v[3]};
    ecp P; ec_mul_g_jac(&P,k);
    fe_to_be(&P.x,out); fe_to_be(&P.y,out+32);
}

// One CKDpriv step. index>=0x80000000 => hardened.
BHD void bip32_ckd(const uint8_t k_par[32], const uint8_t c_par[32], uint32_t index,
                   uint8_t k_out[32], uint8_t c_out[32]){
    uint8_t data[37]; int dlen;
    if(index & 0x80000000u){
        data[0]=0x00;
        for(int i=0;i<32;i++) data[1+i]=k_par[i];
        dlen=33;
    } else {
        uint8_t cp[33]; priv_to_compressed(k_par,cp);
        for(int i=0;i<33;i++) data[i]=cp[i];
        dlen=33;
    }
    data[dlen++]=(uint8_t)(index>>24); data[dlen++]=(uint8_t)(index>>16);
    data[dlen++]=(uint8_t)(index>>8);  data[dlen++]=(uint8_t)index;
    hmac512_ctx ctx; hmac512_init(&ctx, c_par, 32);
    uint8_t I[64]; hmac512_compute(&ctx, data, dlen, I);
    // k_i = (IL + k_par) mod n ; c_i = IR  (IL>=n is ~2^-128, ignored)
    scalar_add_mod_n(I, k_par, k_out);
    for(int i=0;i<32;i++) c_out[i]=I[32+i];
}

// Derive priv for m/44'/60'/0'/0/0 from a 64-byte BIP39 seed. out = 32-byte priv.
BHD void bip32_eth_priv(const uint8_t seed[64], uint8_t out_priv[32]){
    hmac512_ctx ctx; hmac512_init(&ctx, (const uint8_t*)"Bitcoin seed", 12);
    uint8_t I[64]; hmac512_compute(&ctx, seed, 64, I);
    uint8_t k[32], c[32];
    for(int i=0;i<32;i++){ k[i]=I[i]; c[i]=I[32+i]; }
    const uint32_t H=0x80000000u;
    uint32_t path[5]={44u|H, 60u|H, 0u|H, 0u, 0u};
    for(int lvl=0; lvl<5; lvl++){
        uint8_t k2[32], c2[32];
        bip32_ckd(k,c,path[lvl],k2,c2);
        for(int i=0;i<32;i++){ k[i]=k2[i]; c[i]=c2[i]; }
    }
    for(int i=0;i<32;i++) out_priv[i]=k[i];
}
