// Fast fixed-base scalar multiplication k*G in Jacobian coordinates.
// secp256k1 has a=0, so we use the a=0 doubling (dbl-2009-l) and mixed
// Jacobian+affine addition (madd-2007-bl). One field inversion at the very end
// converts back to affine — vs the old affine ladder that inverted on EVERY add.
// This is the hot path of seed mode (3 scalar mults per BIP39 candidate).
#pragma once
#include "cuda_compat.cuh"
#include "field.cuh"
#include "ec.cuh"

#if defined(__CUDACC__)
  #define JHD __host__ __device__ __forceinline__
#else
  #define JHD inline
#endif

typedef struct { fe X, Y, Z; int inf; } ecj;

JHD void ecj_set_inf(ecj* P){ P->inf=1; fe_set_u64(&P->X,1); fe_set_u64(&P->Y,1); fe_set_u64(&P->Z,0); }

// R = 2*P  (Jacobian, a=0)
JHD void ecj_dbl(ecj* R, const ecj* P){
    if(P->inf || fe_is_zero(&P->Y)){ ecj_set_inf(R); return; }
    fe A,B,C,D,E,F,t,t2;
    fe_sqr(&A,&P->X);
    fe_sqr(&B,&P->Y);
    fe_sqr(&C,&B);
    fe_add(&t,&P->X,&B); fe_sqr(&t,&t); fe_sub(&t,&t,&A); fe_sub(&t,&t,&C); fe_add(&D,&t,&t);
    fe_add(&E,&A,&A); fe_add(&E,&E,&A);          // 3A
    fe_sqr(&F,&E);
    fe_add(&t,&D,&D); fe_sub(&R->X,&F,&t);        // X3 = F - 2D
    fe_sub(&t,&D,&R->X); fe_mul(&t,&E,&t);        // E*(D-X3)
    fe_add(&t2,&C,&C); fe_add(&t2,&t2,&t2); fe_add(&t2,&t2,&t2); // 8C
    fe_sub(&R->Y,&t,&t2);
    fe_mul(&t,&P->Y,&P->Z); fe_add(&R->Z,&t,&t);  // 2*Y*Z
    R->inf=0;
}

// R = P + (x2,y2 affine)
JHD void ecj_add_aff(ecj* R, const ecj* P, const fe* x2, const fe* y2){
    if(P->inf){ R->X=*x2; R->Y=*y2; fe_set_u64(&R->Z,1); R->inf=0; return; }
    fe Z1Z1,U2,S2,H,HH,I,J,r,V,t,t2;
    fe_sqr(&Z1Z1,&P->Z);
    fe_mul(&U2,x2,&Z1Z1);
    fe_mul(&S2,y2,&P->Z); fe_mul(&S2,&S2,&Z1Z1);
    fe_sub(&H,&U2,&P->X);
    fe_sub(&r,&S2,&P->Y);
    if(fe_is_zero(&H)){
        if(fe_is_zero(&r)){ ecj_dbl(R,P); return; }  // P == Q -> doubling
        ecj_set_inf(R); return;                       // P == -Q -> infinity
    }
    fe_add(&r,&r,&r);                                  // r = 2(S2-Y1)
    fe_sqr(&HH,&H);
    fe_add(&I,&HH,&HH); fe_add(&I,&I,&I);             // 4HH
    fe_mul(&J,&H,&I);
    fe_mul(&V,&P->X,&I);
    fe_sqr(&t,&r); fe_sub(&t,&t,&J); fe_add(&t2,&V,&V); fe_sub(&R->X,&t,&t2);  // r^2-J-2V
    fe_sub(&t,&V,&R->X); fe_mul(&t,&r,&t);
    fe_mul(&t2,&P->Y,&J); fe_add(&t2,&t2,&t2);        // 2*Y1*J
    fe_sub(&R->Y,&t,&t2);
    fe_add(&t,&P->Z,&H); fe_sqr(&t,&t); fe_sub(&t,&t,&Z1Z1); fe_sub(&R->Z,&t,&HH); // (Z1+H)^2-Z1Z1-HH
    R->inf=0;
}

JHD void ecj_to_aff(ecp* R, const ecj* P){
    if(P->inf){ R->inf=true; fe_set_u64(&R->x,0); fe_set_u64(&R->y,0); return; }
    fe zi,zi2,zi3;
    fe_inv(&zi,&P->Z); fe_sqr(&zi2,&zi); fe_mul(&zi3,&zi2,&zi);
    fe_mul(&R->x,&P->X,&zi2); fe_mul(&R->y,&P->Y,&zi3); R->inf=false;
}

// R = k*G affine. k is 4 little-endian limbs.
JHD void ec_mul_g_jac(ecp* R, const uint64_t k[4]){
    ecp G; ec_set_g(&G);
    ecj acc; ecj_set_inf(&acc);
    for(int i=255;i>=0;i--){
        ecj d; ecj_dbl(&d,&acc); acc=d;
        int bit=(int)((k[i>>6]>>(i&63))&1ULL);
        if(bit){ ecj t; ecj_add_aff(&t,&acc,&G.x,&G.y); acc=t; }
    }
    ecj_to_aff(R,&acc);
}
