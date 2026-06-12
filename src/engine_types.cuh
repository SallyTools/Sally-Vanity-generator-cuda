// Shared engine types, configuration and state for the vanity search driver.
// Included once into vanity.cu (single translation unit) by both the nvcc (GPU)
// and g++/clang++ (CPU) builds.
#pragma once
#include "cuda_compat.cuh"
#include <cstdint>
#include <atomic>
#include "field.cuh"
#include "ec.cuh"
#include "keccak.cuh"
#include "match.cuh"

struct U256 { uint64_t v[4]; };
struct Result { int found; uint64_t sc[4]; long long offset; uint8_t ent[32]; int ent_bytes; long long matched_nonce; };
struct SeedCfg { uint8_t base_ent[32]; int ent_bytes; uint8_t pass[256]; int passlen; };

// host-side config + search state (internal linkage; single TU)
static MatchCfg hcfg;
static SeedCfg  hseed;
static std::atomic<long long> g_tried(0);     // CPU progress counter
static std::atomic<long long> g_gpu_done(0);  // GPU progress counter (hybrid reporter)
static std::atomic<int>       g_found(0);     // winner flag; gates the single g_res write
static Result                 g_res;

#if defined(__CUDACC__)
__constant__ MatchCfg dcfg;
__constant__ SeedCfg  dseed;
#define CK(x) do{cudaError_t e=(x); if(e!=cudaSuccess){fprintf(stderr,"CUDA %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(e));exit(1);}}while(0)
#endif

// priv/point -> 20-byte Ethereum address (uncompressed pub -> keccak[12:])
HD void addr_of(const fe* x,const fe* y,uint8_t out[20]){
    uint8_t pub[64]; fe_to_be(x,pub); fe_to_be(y,pub+32);
    uint8_t h[32]; keccak256(h,pub,64);
    for(int i=0;i<20;i++) out[i]=h[12+i];
}
HD void addr_of_point(const ecp* P, uint8_t out[20]){ addr_of(&P->x,&P->y,out); }
