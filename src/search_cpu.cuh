// CPU (multi-threaded OpenMP) search — raw key and BIP39 seed. Mirrors the GPU
// kernels using the same shared __host__ __device__ crypto, for the --cpu backend
// and the automatic no-GPU fallback.
#pragma once
#include "engine_types.cuh"
#include "bip39.cuh"
#include <atomic>
#ifdef _OPENMP
#include <omp.h>
#endif

static void cpu_raw_search(const uint64_t K[4]){
    ecp G; ec_set_g(&G);
    #pragma omp parallel
    {
        int wid=0;
#ifdef _OPENMP
        wid=omp_get_thread_num();
#endif
        // each worker starts far apart: k = K + wid*2^48
        uint64_t k[4]={K[0],K[1],K[2],K[3]};
        unsigned __int128 add=(unsigned __int128)wid<<48;
        unsigned __int128 s=(unsigned __int128)k[0]+(uint64_t)add; k[0]=(uint64_t)s; uint64_t cr=(uint64_t)(s>>64);
        s=(unsigned __int128)k[1]+(uint64_t)(add>>64)+cr; k[1]=(uint64_t)s; cr=(uint64_t)(s>>64);
        s=(unsigned __int128)k[2]+cr; k[2]=(uint64_t)s; cr=(uint64_t)(s>>64); k[3]+=cr;
        ecp P; ec_mul(&P,k,&G);
        long long local=0;
        while(!g_found.load(std::memory_order_relaxed)){
            uint8_t a[20]; addr_of_point(&P,a);
            long long mn=match_final_nonce(a,&hcfg);
            if(mn>=0){
                if(g_found.exchange(1)==0){
                    g_res.found=1; g_res.ent_bytes=0;
                    for(int i=0;i<4;i++) g_res.sc[i]=k[i];
                    g_res.offset=0; g_res.matched_nonce=mn;
                }
                break;
            }
            ecp Pn; ec_add(&Pn,&P,&G); P=Pn;
            uint64_t c2=1; for(int i=0;i<4&&c2;i++){ unsigned __int128 z=(unsigned __int128)k[i]+c2; k[i]=(uint64_t)z; c2=(uint64_t)(z>>64);}
            if((++local & 0x3FFF)==0){ g_tried.fetch_add(0x4000,std::memory_order_relaxed); local=0; }
        }
    }
}

// base_off lets hybrid mode partition the candidate space so the CPU and GPU
// never test the same SHA256(base||index) candidate (GPU enumerates from 0).
static void cpu_seed_search(uint64_t base_off=0){
    #pragma omp parallel
    {
        int wid=0, nw=1;
#ifdef _OPENMP
        wid=omp_get_thread_num(); nw=omp_get_num_threads();
#endif
        int eb=hseed.ent_bytes;
        long long local=0;
        for(uint64_t g=base_off+wid; !g_found.load(std::memory_order_relaxed); g+=nw){
            // MAX ENTROPY: candidate = SHA256(32-byte base || index)
            uint8_t buf[40], ent[32];
            for(int i=0;i<32;i++) buf[i]=hseed.base_ent[i];
            for(int j=0;j<8;j++) buf[32+j]=(uint8_t)(g>>(8*(7-j)));
            uint8_t h[32]; sha256(h, buf, 40);
            for(int i=0;i<eb;i++) ent[i]=h[i];
            uint8_t addr[20], priv[32];
            bip39_to_eth(ent, eb, hseed.pass, hseed.passlen, addr, priv);
            long long mn=match_final_nonce(addr,&hcfg);
            if(mn>=0){
                if(g_found.exchange(1)==0){
                    g_res.found=1; g_res.ent_bytes=eb;
                    for(int i=0;i<eb;i++) g_res.ent[i]=ent[i];
                    g_res.matched_nonce=mn;
                }
                break;
            }
            if((++local & 0x3FF)==0){ g_tried.fetch_add(0x400,std::memory_order_relaxed); local=0; }
        }
    }
}
