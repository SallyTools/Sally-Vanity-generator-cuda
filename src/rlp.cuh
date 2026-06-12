// Ethereum contract-address derivation. Host+device.
//   CREATE : addr = keccak256(RLP([sender(20), nonce]))[12:]
//   CREATE2: addr = keccak256(0xff || sender(20) || salt(32) || keccak256(init))[12:]
// RLP nonce rules: 0 -> 0x80 (empty string), 1..127 -> single byte, larger ->
// 0x80+len || minimal-big-endian. Address is a 20-byte string -> 0x94 || bytes.
// Outer list -> 0xc0+payload_len (payload always <= 55 here).
#pragma once
#include "cuda_compat.cuh"
#include "keccak.cuh"

#if defined(__CUDACC__)
  #define RHD __host__ __device__ __forceinline__
#else
  #define RHD inline
#endif

// encode nonce into out[], return length (1..9)
RHD int rlp_encode_nonce(uint64_t nonce, uint8_t out[9]){
    if(nonce==0){ out[0]=0x80; return 1; }
    if(nonce<0x80){ out[0]=(uint8_t)nonce; return 1; }
    uint8_t be[8]; int k=0;
    for(int i=7;i>=0;i--){ uint8_t b=(uint8_t)(nonce>>(8*i)); if(k==0 && b==0) continue; be[k++]=b; }
    out[0]=(uint8_t)(0x80+k);
    for(int i=0;i<k;i++) out[1+i]=be[i];
    return 1+k;
}

// CREATE address from 20-byte sender + nonce
RHD void create_address(const uint8_t sender[20], uint64_t nonce, uint8_t out_addr[20]){
    uint8_t nbuf[9]; int nlen=rlp_encode_nonce(nonce,nbuf);
    int payload=21+nlen;            // (0x94 + 20 addr) + nonce enc
    uint8_t rlp[1+21+9]; int p=0;
    rlp[p++]=(uint8_t)(0xc0+payload);
    rlp[p++]=0x94;
    for(int i=0;i<20;i++) rlp[p++]=sender[i];
    for(int i=0;i<nlen;i++) rlp[p++]=nbuf[i];
    uint8_t h[32]; keccak256(h,rlp,p);
    for(int i=0;i<20;i++) out_addr[i]=h[12+i];
}

// CREATE2 address. init_code_hash = keccak256(init_code) precomputed (32 bytes).
RHD void create2_address(const uint8_t sender[20], const uint8_t salt[32],
                         const uint8_t init_code_hash[32], uint8_t out_addr[20]){
    uint8_t pre[85];
    pre[0]=0xff;
    for(int i=0;i<20;i++) pre[1+i]=sender[i];
    for(int i=0;i<32;i++) pre[21+i]=salt[i];
    for(int i=0;i<32;i++) pre[53+i]=init_code_hash[i];
    uint8_t h[32]; keccak256(h,pre,85);
    for(int i=0;i<20;i++) out_addr[i]=h[12+i];
}
