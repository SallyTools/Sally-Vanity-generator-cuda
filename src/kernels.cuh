// GPU search kernels (CUDA only — empty under a host-only build).
//   vsearch      : raw-key fast EC point-walk + Montgomery batch inversion
//   pbkdf2_seed  : BIP39 entropy -> mnemonic -> 64-byte seed (PBKDF2 stage)
//   seed_to_addr : 64-byte seed -> address -> match (BIP32 + EC stage)
#pragma once
#include "engine_types.cuh"
#include "bip39.cuh"

#if defined(__CUDACC__)
__global__ void vsearch(fe* cx, fe* cy, uint64_t* scenter, fe* pre,
        const fe* gnx, const fe* gny, fe advx, fe advy, U256 stride,
        int half, int iters, int nthreads, Result* res){
    int tid=blockIdx.x*blockDim.x+threadIdx.x;
    if(tid>=nthreads) return;
    fe Cx=cx[tid], Cy=cy[tid];
    uint64_t sc[4]={scenter[(size_t)tid*4+0],scenter[(size_t)tid*4+1],
                    scenter[(size_t)tid*4+2],scenter[(size_t)tid*4+3]};
    for(int it=0; it<iters; it++){
        if(res->found) break;
        fe acc; fe_set_u64(&acc,1);
        for(int i=0;i<half;i++){
            pre[(size_t)i*nthreads+tid]=acc;
            fe dx; fe_sub(&dx,&gnx[i],&Cx);
            fe_mul(&acc,&acc,&dx);
        }
        fe inv; fe_inv(&inv,&acc);
        for(int i=half-1;i>=0;i--){
            fe dx; fe_sub(&dx,&gnx[i],&Cx);
            fe dxinv; fe_mul(&dxinv,&pre[(size_t)i*nthreads+tid],&inv);
            fe_mul(&inv,&inv,&dx);
            fe lam,t,x3,y3; uint8_t a[20];
            fe_sub(&t,&gny[i],&Cy); fe_mul(&lam,&t,&dxinv);
            fe_sqr(&t,&lam); fe_sub(&x3,&t,&Cx); fe_sub(&x3,&x3,&gnx[i]);
            fe_sub(&t,&Cx,&x3); fe_mul(&y3,&lam,&t); fe_sub(&y3,&y3,&Cy);
            addr_of(&x3,&y3,a);
            { long long mn=match_final_nonce(a,&dcfg);
            if(mn>=0 && atomicCAS(&res->found,0,1)==0){
                res->sc[0]=sc[0];res->sc[1]=sc[1];res->sc[2]=sc[2];res->sc[3]=sc[3];
                res->offset=(long long)(i+1); res->ent_bytes=0; res->matched_nonce=mn;
            } }
            fe ngy; fe_neg(&ngy,&gny[i]);
            fe_sub(&t,&ngy,&Cy); fe_mul(&lam,&t,&dxinv);
            fe_sqr(&t,&lam); fe_sub(&x3,&t,&Cx); fe_sub(&x3,&x3,&gnx[i]);
            fe_sub(&t,&Cx,&x3); fe_mul(&y3,&lam,&t); fe_sub(&y3,&y3,&Cy);
            addr_of(&x3,&y3,a);
            { long long mn=match_final_nonce(a,&dcfg);
            if(mn>=0 && atomicCAS(&res->found,0,1)==0){
                res->sc[0]=sc[0];res->sc[1]=sc[1];res->sc[2]=sc[2];res->sc[3]=sc[3];
                res->offset=-(long long)(i+1); res->ent_bytes=0; res->matched_nonce=mn;
            } }
        }
        ecp Cp; Cp.x=Cx; Cp.y=Cy; Cp.inf=false;
        ecp Ad; Ad.x=advx; Ad.y=advy; Ad.inf=false;
        ecp Cn; ec_add(&Cn,&Cp,&Ad); Cx=Cn.x; Cy=Cn.y;
        uint64_t carry=0;
        for(int k=0;k<4;k++){ unsigned __int128 s=(unsigned __int128)sc[k]+stride.v[k]+carry; sc[k]=(uint64_t)s; carry=(uint64_t)(s>>64);}
    }
    cx[tid]=Cx; cy[tid]=Cy;
    scenter[(size_t)tid*4+0]=sc[0];scenter[(size_t)tid*4+1]=sc[1];
    scenter[(size_t)tid*4+2]=sc[2];scenter[(size_t)tid*4+3]=sc[3];
}

// MAX ENTROPY entropy derivation: candidate = SHA256(32-byte secret base || index).
__device__ __forceinline__ void seed_entropy(uint64_t g, int eb, uint8_t ent[32]){
    uint8_t buf[40];
    for(int i=0;i<32;i++) buf[i]=dseed.base_ent[i];
    for(int j=0;j<8;j++) buf[32+j]=(uint8_t)(g>>(8*(7-j)));
    uint8_t h[32]; sha256(h, buf, 40);
    for(int i=0;i<eb;i++) ent[i]=h[i];
}

// Two-kernel split: the PBKDF2 stage (≈97% of the work, no EC) runs at high
// occupancy on its own; the EC/BIP32 stage runs separately. Seeds are passed
// through global memory in SoA layout (seedw[j*n + tid]) for coalesced access.

// Stage A: entropy -> mnemonic -> 64-byte seed. __launch_bounds__ caps registers
// at ~128 (no EC here) → 4 blocks/SM = 50% occupancy to hide PBKDF2 latency.
__global__ void __launch_bounds__(128,4) pbkdf2_seed(uint64_t base_counter, int n,
                            uint64_t* __restrict__ seedw, uint8_t* __restrict__ entbuf){
    int tid=blockIdx.x*blockDim.x+threadIdx.x;
    if(tid>=n) return;
    int eb=dseed.ent_bytes;
    uint8_t ent[32];
    seed_entropy(base_counter+(uint64_t)tid, eb, ent);
    for(int i=0;i<eb;i++) entbuf[(size_t)tid*32+i]=ent[i];     // for winner reconstruction
    uint8_t seed[64];
    bip39_to_seed(ent, eb, dseed.pass, dseed.passlen, seed);
    #pragma unroll
    for(int j=0;j<8;j++){ uint64_t v=0; for(int k=0;k<8;k++) v=(v<<8)|seed[j*8+k]; seedw[(size_t)j*n+tid]=v; }
}

// Stage B: 64-byte seed -> address -> match. EC-heavy but a small fraction of time.
__global__ void seed_to_addr(const uint64_t* __restrict__ seedw, const uint8_t* __restrict__ entbuf,
                             int n, Result* __restrict__ res){
    int tid=blockIdx.x*blockDim.x+threadIdx.x;
    if(tid>=n || res->found) return;
    uint8_t seed[64];
    #pragma unroll
    for(int j=0;j<8;j++){ uint64_t v=seedw[(size_t)j*n+tid]; for(int k=0;k<8;k++) seed[j*8+k]=(uint8_t)(v>>(56-8*k)); }
    uint8_t addr[20], priv[32];
    seed_to_eth(seed, addr, priv);
    long long mn=match_final_nonce(addr,&dcfg);
    if(mn>=0 && atomicCAS(&res->found,0,1)==0){
        int eb=dseed.ent_bytes;
        for(int i=0;i<eb;i++) res->ent[i]=entbuf[(size_t)tid*32+i];
        res->ent_bytes=eb; res->matched_nonce=mn;
    }
}
#endif // __CUDACC__
