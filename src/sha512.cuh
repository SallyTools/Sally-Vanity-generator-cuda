// SHA-512 / HMAC-SHA512 / PBKDF2-HMAC-SHA512 (FIPS 180-4, RFC 2104, RFC 8018).
// Host+device. This is the performance core of the BIP39 seed mode: PBKDF2 with
// 2048 iterations dominates cost, so HMAC precomputes the ipad/opad block states
// from the (fixed) password once and the inner loop is two compressions/iter.
#pragma once
#include "cuda_compat.cuh"
#include <cstdint>
#include <cstring>

#if defined(__CUDACC__)
  #define S5HD __host__ __device__ __forceinline__
#else
  #define S5HD inline
#endif

__device__ __host__ static const uint64_t SHA512_K[80] = {
 0x428a2f98d728ae22ULL,0x7137449123ef65cdULL,0xb5c0fbcfec4d3b2fULL,0xe9b5dba58189dbbcULL,
 0x3956c25bf348b538ULL,0x59f111f1b605d019ULL,0x923f82a4af194f9bULL,0xab1c5ed5da6d8118ULL,
 0xd807aa98a3030242ULL,0x12835b0145706fbeULL,0x243185be4ee4b28cULL,0x550c7dc3d5ffb4e2ULL,
 0x72be5d74f27b896fULL,0x80deb1fe3b1696b1ULL,0x9bdc06a725c71235ULL,0xc19bf174cf692694ULL,
 0xe49b69c19ef14ad2ULL,0xefbe4786384f25e3ULL,0x0fc19dc68b8cd5b5ULL,0x240ca1cc77ac9c65ULL,
 0x2de92c6f592b0275ULL,0x4a7484aa6ea6e483ULL,0x5cb0a9dcbd41fbd4ULL,0x76f988da831153b5ULL,
 0x983e5152ee66dfabULL,0xa831c66d2db43210ULL,0xb00327c898fb213fULL,0xbf597fc7beef0ee4ULL,
 0xc6e00bf33da88fc2ULL,0xd5a79147930aa725ULL,0x06ca6351e003826fULL,0x142929670a0e6e70ULL,
 0x27b70a8546d22ffcULL,0x2e1b21385c26c926ULL,0x4d2c6dfc5ac42aedULL,0x53380d139d95b3dfULL,
 0x650a73548baf63deULL,0x766a0abb3c77b2a8ULL,0x81c2c92e47edaee6ULL,0x92722c851482353bULL,
 0xa2bfe8a14cf10364ULL,0xa81a664bbc423001ULL,0xc24b8b70d0f89791ULL,0xc76c51a30654be30ULL,
 0xd192e819d6ef5218ULL,0xd69906245565a910ULL,0xf40e35855771202aULL,0x106aa07032bbd1b8ULL,
 0x19a4c116b8d2d0c8ULL,0x1e376c085141ab53ULL,0x2748774cdf8eeb99ULL,0x34b0bcb5e19b48a8ULL,
 0x391c0cb3c5c95a63ULL,0x4ed8aa4ae3418acbULL,0x5b9cca4f7763e373ULL,0x682e6ff3d6b2b8a3ULL,
 0x748f82ee5defb2fcULL,0x78a5636f43172f60ULL,0x84c87814a1f0ab72ULL,0x8cc702081a6439ecULL,
 0x90befffa23631e28ULL,0xa4506cebde82bde9ULL,0xbef9a3f7b2c67915ULL,0xc67178f2e372532bULL,
 0xca273eceea26619cULL,0xd186b8c721c0c207ULL,0xeada7dd6cde0eb1eULL,0xf57d4f7fee6ed178ULL,
 0x06f067aa72176fbaULL,0x0a637dc5a2c898a6ULL,0x113f9804bef90daeULL,0x1b710b35131c471bULL,
 0x28db77f523047d84ULL,0x32caab7b40c72493ULL,0x3c9ebe0a15c9bebcULL,0x431d67c49c100d4cULL,
 0x4cc5d4becb3e42b6ULL,0x597f299cfc657e2aULL,0x5fcb6fab3ad6faecULL,0x6c44198c4a475817ULL };

S5HD uint64_t s5_rotr(uint64_t x,int n){ return (x>>n)|(x<<(64-n)); }

S5HD void sha512_iv(uint64_t h[8]){
    h[0]=0x6a09e667f3bcc908ULL;h[1]=0xbb67ae8584caa73bULL;h[2]=0x3c6ef372fe94f82bULL;h[3]=0xa54ff53a5f1d36f1ULL;
    h[4]=0x510e527fade682d1ULL;h[5]=0x9b05688c2b3e6c1fULL;h[6]=0x1f83d9abfb41bd6bULL;h[7]=0x5be0cd19137e2179ULL;
}

// process one 128-byte block, updating state h
S5HD void sha512_block(uint64_t h[8], const uint8_t* p){
    uint64_t w[16];
    #pragma unroll
    for(int i=0;i<16;i++){
        uint64_t v=0;
        for(int j=0;j<8;j++) v=(v<<8)|p[i*8+j];
        w[i]=v;
    }
    uint64_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
    #pragma unroll
    for(int i=0;i<80;i++){
        uint64_t wi;
        if(i<16) wi=w[i];
        else{
            uint64_t w15=w[(i+1)&15], w2=w[(i+14)&15];
            uint64_t s0=s5_rotr(w15,1)^s5_rotr(w15,8)^(w15>>7);
            uint64_t s1=s5_rotr(w2,19)^s5_rotr(w2,61)^(w2>>6);
            wi=w[i&15]=w[i&15]+s0+w[(i+9)&15]+s1;
        }
        uint64_t S1=s5_rotr(e,14)^s5_rotr(e,18)^s5_rotr(e,41);
        uint64_t ch=(e&f)^((~e)&g);
        uint64_t t1=hh+S1+ch+SHA512_K[i]+wi;
        uint64_t S0=s5_rotr(a,28)^s5_rotr(a,34)^s5_rotr(a,39);
        uint64_t maj=(a&b)^(a&c)^(b&c);
        uint64_t t2=S0+maj;
        hh=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
    }
    h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=hh;
}

S5HD void sha512_state_out(const uint64_t h[8], uint8_t out[64]){
    for(int i=0;i<8;i++)
        for(int j=0;j<8;j++) out[i*8+j]=(uint8_t)(h[i]>>(56-8*j));
}

// Given a state that has already absorbed `prefix_bytes` (a multiple of 128),
// absorb msg[msglen] and finalize with the correct total length. out=64 bytes.
S5HD void sha512_absorb_final(uint64_t st[8], const uint8_t* msg, uint32_t msglen,
                              uint64_t prefix_bytes, uint8_t out[64]){
    uint64_t total = prefix_bytes + msglen;
    uint32_t i=0;
    for(; i+128<=msglen; i+=128) sha512_block(st,msg+i);
    uint8_t blk[128]; uint32_t rem=msglen-i;
    for(uint32_t j=0;j<rem;j++) blk[j]=msg[i+j];
    blk[rem]=0x80;
    if(rem>=112){
        for(uint32_t j=rem+1;j<128;j++) blk[j]=0;
        sha512_block(st,blk);
        for(int j=0;j<128;j++) blk[j]=0;
    } else {
        for(uint32_t j=rem+1;j<112;j++) blk[j]=0;
    }
    // 128-bit big-endian bit length (high 64 bits are 0 for our message sizes)
    uint64_t bits=total*8;
    for(int j=0;j<8;j++) blk[112+j]=0;
    for(int j=0;j<8;j++) blk[120+j]=(uint8_t)(bits>>(56-8*j));
    sha512_block(st,blk);
    sha512_state_out(st,out);
}

// out[64] = SHA512(in[inlen])
S5HD void sha512(uint8_t out[64], const uint8_t* in, uint32_t inlen){
    uint64_t st[8]; sha512_iv(st);
    sha512_absorb_final(st,in,inlen,0,out);
}

// ---- HMAC-SHA512 with precomputed pad states ----
typedef struct { uint64_t istate[8]; uint64_t ostate[8]; } hmac512_ctx;

S5HD void hmac512_init(hmac512_ctx* c, const uint8_t* key, uint32_t keylen){
    uint8_t k[128];
    for(int i=0;i<128;i++) k[i]=0;
    if(keylen>128){ uint8_t kh[64]; sha512(kh,key,keylen); for(int i=0;i<64;i++) k[i]=kh[i]; }
    else { for(uint32_t i=0;i<keylen;i++) k[i]=key[i]; }
    uint8_t ip[128], op[128];
    for(int i=0;i<128;i++){ ip[i]=k[i]^0x36; op[i]=k[i]^0x5c; }
    sha512_iv(c->istate); sha512_block(c->istate, ip);
    sha512_iv(c->ostate); sha512_block(c->ostate, op);
}

// out[64] = HMAC(key, msg) using precomputed ctx
S5HD void hmac512_compute(const hmac512_ctx* c, const uint8_t* msg, uint32_t msglen, uint8_t out[64]){
    uint64_t st[8];
    for(int i=0;i<8;i++) st[i]=c->istate[i];
    uint8_t ih[64];
    sha512_absorb_final(st, msg, msglen, 128, ih);   // inner hash
    for(int i=0;i<8;i++) st[i]=c->ostate[i];
    sha512_absorb_final(st, ih, 64, 128, out);       // outer hash
}

// --- Fast path for the PBKDF2 inner loop ---
// Specialised SHA-512 block for a 64-byte message absorbed into a 128-byte-prefix
// midstate (total 192 bytes). The padding tail (words 8..15) is compile-time
// constant, so ptxas folds that schedule math away — large register + throughput
// win inside the 2048-iteration loop. Numerically identical to the generic path.
S5HD void sha512_block_w8(uint64_t st[8], const uint64_t in8[8]){
    uint64_t w[16];
    #pragma unroll
    for(int i=0;i<8;i++) w[i]=in8[i];
    w[8]=0x8000000000000000ULL; w[9]=0;w[10]=0;w[11]=0;w[12]=0;w[13]=0;w[14]=0;
    w[15]=0x600ULL;                         // total length 192 bytes = 1536 bits
    uint64_t a=st[0],b=st[1],c=st[2],d=st[3],e=st[4],f=st[5],g=st[6],hh=st[7];
    #pragma unroll
    for(int i=0;i<80;i++){
        uint64_t wi;
        if(i<16) wi=w[i];
        else{
            uint64_t w15=w[(i+1)&15], w2=w[(i+14)&15];
            uint64_t s0=s5_rotr(w15,1)^s5_rotr(w15,8)^(w15>>7);
            uint64_t s1=s5_rotr(w2,19)^s5_rotr(w2,61)^(w2>>6);
            wi=w[i&15]=w[i&15]+s0+w[(i+9)&15]+s1;
        }
        uint64_t S1=s5_rotr(e,14)^s5_rotr(e,18)^s5_rotr(e,41);
        uint64_t ch=(e&f)^((~e)&g);
        uint64_t t1=hh+S1+ch+SHA512_K[i]+wi;
        uint64_t S0=s5_rotr(a,28)^s5_rotr(a,34)^s5_rotr(a,39);
        uint64_t maj=(a&b)^(a&c)^(b&c);
        uint64_t t2=S0+maj;
        hh=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
    }
    st[0]+=a;st[1]+=b;st[2]+=c;st[3]+=d;st[4]+=e;st[5]+=f;st[6]+=g;st[7]+=hh;
}

// HMAC-SHA512 of a 64-byte message (given as 8 big-endian words) using a
// precomputed ctx, result in 8 words. No byte buffers — stays in registers.
S5HD void hmac512_64w(const hmac512_ctx* c, const uint64_t in8[8], uint64_t out8[8]){
    uint64_t st[8];
    #pragma unroll
    for(int i=0;i<8;i++) st[i]=c->istate[i];
    sha512_block_w8(st, in8);          // inner hash; st now = ih as 8 words
    uint64_t st2[8];
    #pragma unroll
    for(int i=0;i<8;i++) st2[i]=c->ostate[i];
    sha512_block_w8(st2, st);          // outer hash over the 64-byte inner digest
    #pragma unroll
    for(int i=0;i<8;i++) out8[i]=st2[i];
}

// PBKDF2-HMAC-SHA512 specialised to dkLen=64 (exactly one HMAC output block).
// out[64]. salt buffer must hold saltlen+4 internally (we copy into a temp).
// MAXSALT caps salt length; "mnemonic"(8)+passphrase(<=120) stays under this.
// Kept tight to shrink the per-thread stack frame (fewer GPU local-mem spills).
#define PBKDF2_MAXSALT 128
S5HD void pbkdf2_hmac_sha512_64(const uint8_t* pw, uint32_t pwlen,
                                const uint8_t* salt, uint32_t saltlen,
                                uint32_t iters, uint8_t out[64]){
    hmac512_ctx c; hmac512_init(&c, pw, pwlen);
    uint8_t buf[PBKDF2_MAXSALT+4];
    uint32_t sl = saltlen>PBKDF2_MAXSALT ? PBKDF2_MAXSALT : saltlen;
    for(uint32_t i=0;i<sl;i++) buf[i]=salt[i];
    buf[sl]=0;buf[sl+1]=0;buf[sl+2]=0;buf[sl+3]=1;   // INT(1) big-endian
    uint8_t u[64];
    hmac512_compute(&c, buf, sl+4, u);               // U1 (generic, once)
    // switch to register-only word form for the 2048-iteration hot loop
    uint64_t uw[8], tw[8];
    #pragma unroll
    for(int i=0;i<8;i++){ uint64_t v=0; for(int j=0;j<8;j++) v=(v<<8)|u[i*8+j]; uw[i]=v; tw[i]=v; }
    #pragma unroll 1
    for(uint32_t it=1; it<iters; it++){
        hmac512_64w(&c, uw, uw);                     // U_{n} = HMAC(U_{n-1})
        #pragma unroll
        for(int i=0;i<8;i++) tw[i]^=uw[i];
    }
    #pragma unroll
    for(int i=0;i<8;i++){ uint64_t v=tw[i]; for(int j=0;j<8;j++) out[i*8+j]=(uint8_t)(v>>(56-8*j)); }
}
