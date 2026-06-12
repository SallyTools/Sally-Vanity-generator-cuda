// BIP39 mnemonic construction + full BIP39->BIP44->Ethereum address pipeline.
// Host+device. Entropy (16 or 32 bytes) -> mnemonic sentence -> seed (PBKDF2,
// salt "mnemonic"+passphrase) -> m/44'/60'/0'/0/0 priv -> address.
#pragma once
#include "cuda_compat.cuh"
#include "sha256.cuh"
#include "sha512.cuh"
#include "bip39_words.cuh"
#include "bip32.cuh"
#include "keccak.cuh"

#if defined(__CUDACC__)
  #define M9HD __host__ __device__ __forceinline__
#else
  #define M9HD inline
#endif

#define BIP39_MAX_SENTENCE 256   // 24 words*8 + 23 spaces = 215 max

// read 11 bits MSB-first at bit offset `bitpos` from buf
M9HD uint16_t bip39_read11(const uint8_t* buf, int bitpos){
    uint16_t v=0;
    for(int i=0;i<11;i++){ int bp=bitpos+i; int by=bp>>3; int bit=7-(bp&7); v=(uint16_t)((v<<1)|((buf[by]>>bit)&1)); }
    return v;
}

// Build the mnemonic sentence from entropy. ent_bytes = 16 (12 words) or 32 (24
// words). Writes null-terminated sentence into out, returns its length. Also, if
// idx_out != nullptr, writes the nwords word indices (for display).
M9HD int bip39_mnemonic(const uint8_t* ent, int ent_bytes, char* out, uint16_t* idx_out){
    int nwords = (ent_bytes==32) ? 24 : 12; // CS = ENT/32 bits (4 for 12w, 8 for 24w)
    uint8_t h[32]; sha256(h, ent, (uint32_t)ent_bytes);
    uint8_t buf[33];
    for(int i=0;i<ent_bytes;i++) buf[i]=ent[i];
    buf[ent_bytes]=h[0];                     // checksum byte (top CS bits used)
    int pos=0;
    for(int w=0; w<nwords; w++){
        uint16_t idx = bip39_read11(buf, w*11);
        if(idx_out) idx_out[w]=idx;
        const char* word = BIP39_WORDS[idx];
        if(w>0) out[pos++]=' ';
        for(int k=0; word[k]; k++) out[pos++]=word[k];
    }
    out[pos]=0;
    return pos;
}

// Stage 1: entropy(+passphrase) -> 64-byte BIP39 seed (PBKDF2 — the heavy part).
// salt = "mnemonic"+passphrase. passphrase may be empty (passlen 0).
M9HD void bip39_to_seed(const uint8_t* ent, int ent_bytes,
                        const uint8_t* passphrase, uint32_t passlen, uint8_t seed[64]){
    char sent[BIP39_MAX_SENTENCE];
    int slen = bip39_mnemonic(ent, ent_bytes, sent, (uint16_t*)0);
    uint8_t salt[PBKDF2_MAXSALT];
    const char* mp = "mnemonic";
    int saltlen=0;
    for(int i=0;i<8;i++) salt[saltlen++]=(uint8_t)mp[i];
    for(uint32_t i=0;i<passlen && saltlen<PBKDF2_MAXSALT;i++) salt[saltlen++]=passphrase[i];
    pbkdf2_hmac_sha512_64((const uint8_t*)sent,(uint32_t)slen, salt,(uint32_t)saltlen, 2048, seed);
}
// Stage 2: 64-byte seed -> m/44'/60'/0'/0/0 priv + ETH address (BIP32 + EC + keccak).
M9HD void seed_to_eth(const uint8_t seed[64], uint8_t addr_out[20], uint8_t priv_out[32]){
    bip32_eth_priv(seed, priv_out);
    uint8_t pub[64]; priv_to_pub64(priv_out, pub);
    uint8_t kh[32]; keccak256(kh, pub, 64);
    for(int i=0;i<20;i++) addr_out[i]=kh[12+i];
}
// Full pipeline (CPU path + host re-verification failsafe).
M9HD void bip39_to_eth(const uint8_t* ent, int ent_bytes,
                       const uint8_t* passphrase, uint32_t passlen,
                       uint8_t addr_out[20], uint8_t priv_out[32]){
    uint8_t seed[64];
    bip39_to_seed(ent, ent_bytes, passphrase, passlen, seed);
    seed_to_eth(seed, addr_out, priv_out);
}
