// secp256k1 affine point operations. Used host-side for setup (base point,
// the Gn table, per-thread centers). The GPU search kernel inlines its own
// batched add, but reuses fe_* from field.cuh.
#pragma once
#include "field.cuh"

typedef struct { fe x, y; bool inf; } ecp;

// Generator G
__device__ __host__ static const uint64_t GX_[4] = {
    0x59F2815B16F81798ULL, 0x029BFCDB2DCE28D9ULL,
    0x55A06295CE870B07ULL, 0x79BE667EF9DCBBACULL };
__device__ __host__ static const uint64_t GY_[4] = {
    0x9C47D08FFB10D4B8ULL, 0xFD17B448A6855419ULL,
    0x5DA4FBFC0E1108A8ULL, 0x483ADA7726A3C465ULL };

HD void ec_set_g(ecp* P){
    for(int i=0;i<4;i++){ P->x.v[i]=GX_[i]; P->y.v[i]=GY_[i]; }
    P->inf=false;
}
HD void ec_set_inf(ecp* P){ P->inf=true; }

// R = P + Q  (affine, general). Handles inf and doubling.
HD void ec_add(ecp* R, const ecp* P, const ecp* Q){
    if(P->inf){ *R=*Q; return; }
    if(Q->inf){ *R=*P; return; }
    fe lam, num, den, t1, t2, x3, y3;
    if(fe_eq(&P->x,&Q->x)){
        fe ny; fe_neg(&ny,&Q->y);
        if(fe_eq(&P->y,&ny)){ R->inf=true; return; } // P = -Q
        // doubling: lam = 3x^2 / (2y)
        fe_sqr(&t1,&P->x);             // x^2
        fe_set_u64(&t2,3); fe_mul(&num,&t1,&t2); // 3x^2
        fe_add(&den,&P->y,&P->y);      // 2y
        fe_inv(&den,&den);
        fe_mul(&lam,&num,&den);
    } else {
        fe_sub(&num,&Q->y,&P->y);
        fe_sub(&den,&Q->x,&P->x);
        fe_inv(&den,&den);
        fe_mul(&lam,&num,&den);
    }
    fe_sqr(&t1,&lam);                  // lam^2
    fe_sub(&t2,&t1,&P->x);
    fe_sub(&x3,&t2,&Q->x);             // x3 = lam^2 - Px - Qx
    fe_sub(&t1,&P->x,&x3);
    fe_mul(&t2,&lam,&t1);
    fe_sub(&y3,&t2,&P->y);            // y3 = lam(Px-x3) - Py
    R->x=x3; R->y=y3; R->inf=false;
}

// R = k*P via double-and-add. k is 4 little-endian limbs.
HD void ec_mul(ecp* R, const uint64_t k[4], const ecp* P){
    ecp acc; ec_set_inf(&acc);
    ecp base=*P;
    for(int i=0;i<4;i++){
        uint64_t e=k[i];
        for(int b=0;b<64;b++){
            if(e&1ULL){ ec_add(&acc,&acc,&base); }
            ec_add(&base,&base,&base);
            e>>=1;
        }
    }
    *R=acc;
}
