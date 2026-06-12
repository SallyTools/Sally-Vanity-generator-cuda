// CPU correctness gate. Compiles with nvcc OR plain g++/clang++ (host-only).
// Validates field/EC/keccak + SHA256/512/HMAC/PBKDF2 + BIP39->BIP44->ETH +
// CREATE/CREATE2 against well-known vectors before we trust the GPU kernels.
#include <cstdio>
#include <cstring>
#include "field.cuh"
#include "ec.cuh"
#include "keccak.cuh"
#include "sha256.cuh"
#include "sha512.cuh"
#include "bip39.cuh"
#include "rlp.cuh"

static int g_pass = 1;
static void hex2bytes(const char* h, uint8_t* b, int n){
    for(int i=0;i<n;i++){ unsigned x; sscanf(h+2*i,"%2x",&x); b[i]=(uint8_t)x; }
}
static int hcmp(const char* name, const uint8_t* got, const char* exp, int n){
    char s[200]; for(int i=0;i<n;i++) sprintf(s+2*i,"%02x",got[i]);
    int ok = strcasecmp(s,exp)==0; printf("  [%s] %s\n", ok?"OK":"FAIL", name);
    if(!ok){ printf("       got %s\n       exp %s\n", s, exp); }
    g_pass &= ok; return ok;
}
static void priv_to_addr(const uint64_t k[4], uint8_t addr[20]){
    ecp G,P; ec_set_g(&G); ec_mul(&P,k,&G);
    uint8_t pub[64]; fe_to_be(&P.x,pub); fe_to_be(&P.y,pub+32);
    uint8_t h[32]; keccak256(h,pub,64); memcpy(addr,h+12,20);
}
static int cmp_addr(const uint64_t k[4], const char* expect){
    uint8_t a[20]; priv_to_addr(k,a); return hcmp("priv*G -> addr", a, expect, 20);
}

int main(){
    uint8_t o32[32], o64[64];

    printf("== field sanity ==\n");
    fe a; a.v[0]=0x123456789abcdef0ULL; a.v[1]=0xfedcba9876543210ULL;
    a.v[2]=0x0f1e2d3c4b5a6978ULL; a.v[3]=0x1122334455667788ULL;
    fe inv,prod; fe_inv(&inv,&a); fe_mul(&prod,&a,&inv);
    fe one; fe_set_u64(&one,1);
    printf("  [%s] a * a^-1 == 1\n", fe_eq(&prod,&one)?"OK":"FAIL"); g_pass&=fe_eq(&prod,&one);
    fe pm1; for(int i=0;i<4;i++) pm1.v[i]=FE_P[i]; pm1.v[0]-=1;
    fe r; fe_add(&r,&pm1,&one);
    printf("  [%s] (p-1)+1 == 0\n", fe_is_zero(&r)?"OK":"FAIL"); g_pass&=fe_is_zero(&r);

    printf("== keccak256 (NOT NIST SHA3) ==\n");
    keccak256(o32,(const uint8_t*)"",0);
    hcmp("keccak256(\"\")", o32, "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", 32);

    printf("== sha256 / sha512 ==\n");
    sha256(o32,(const uint8_t*)"abc",3);
    hcmp("sha256(abc)", o32, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", 32);
    sha512(o64,(const uint8_t*)"abc",3);
    hcmp("sha512(abc)", o64, "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", 64);
    { uint8_t key[20]; for(int i=0;i<20;i++) key[i]=0x0b; hmac512_ctx c; hmac512_init(&c,key,20);
      hmac512_compute(&c,(const uint8_t*)"Hi There",8,o64);
      hcmp("hmac-sha512 rfc4231#1", o64, "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854", 64); }

    printf("== address vectors ==\n");
    uint64_t k1[4]={1,0,0,0}; cmp_addr(k1,"7e5f4552091a69125d5dfcb7b8c2659029395bdf");
    uint8_t kb[32]; hex2bytes("f8f8a2f43c8376ccb0871305060d7b27b0554d2cc72bccf41b2705608452f315",kb,32);
    fe kf; fe_from_be(&kf,kb); uint64_t k3[4]={kf.v[0],kf.v[1],kf.v[2],kf.v[3]};
    cmp_addr(k3,"001d3f1ef827552ae1114027bd3ecf1f086ba0f9");

    printf("== BIP39 -> BIP44(m/44'/60'/0'/0/0) -> ETH ==\n");
    { uint8_t ent[32], addr[20], priv[32];
      memset(ent,0,16);
      bip39_to_eth(ent,16,(const uint8_t*)"",0,addr,priv);
      hcmp("12w abandon..about ''  addr", addr, "9858effd232b4033e47d90003d41ec34ecaeda94", 20);
      hcmp("                       priv", priv, "1ab42cc412b618bdea3a599e3c9bae199ebf030895b039e9db1e30dafb12b727", 32);
      bip39_to_eth(ent,16,(const uint8_t*)"TREZOR",6,addr,priv);
      hcmp("12w +passphrase TREZOR  addr", addr, "9c32f71d4db8fb9e1a58b0a80df79935e7256fa6", 20);
      memset(ent,0x7f,16);
      bip39_to_eth(ent,16,(const uint8_t*)"",0,addr,priv);
      hcmp("12w legal winner...    addr", addr, "58a57ed9d8d624cbd12e2c467d34787555bb1b25", 20);
      memset(ent,0,32);
      bip39_to_eth(ent,32,(const uint8_t*)"",0,addr,priv);
      hcmp("24w abandon..art ''    addr", addr, "f278cf59f82edcf871d630f28ecc8056f25c1cdb", 20); }

    printf("== CREATE / CREATE2 contract addresses ==\n");
    { uint8_t sender[20], addr[20], salt[32], ich[32];
      hex2bytes("6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0",sender,20);
      create_address(sender,0,addr);    hcmp("CREATE nonce 0",    addr, "cd234a471b72ba2f1ccf0a70fcaba648a5eecd8d", 20);
      create_address(sender,1,addr);    hcmp("CREATE nonce 1",    addr, "343c43a37d37dff08ae8c4a11544c718abb4fcf8", 20);
      create_address(sender,128,addr);  hcmp("CREATE nonce 128",  addr, "08e190dcb7b73f5fcdabb43e102215c83659a76d", 20);
      create_address(sender,256,addr);  hcmp("CREATE nonce 256",  addr, "3837c1ae70354f670550c746580199ac6a73cb0a", 20);
      memset(sender,0,20); memset(salt,0,32);
      uint8_t ic[1]={0x00}; keccak256(ich,ic,1); create2_address(sender,salt,ich,addr);
      hcmp("CREATE2 EIP-1014 #0", addr, "4d1a2e2bb4f88f0250f26ffff098b0b30b26bf38", 20);
      keccak256(ich,(const uint8_t*)"",0); create2_address(sender,salt,ich,addr);
      hcmp("CREATE2 EIP-1014 #6", addr, "e33c0c7f7df4809055c3eba6c09cfe4baf1bd9e0", 20); }

    printf("\n%s\n", g_pass?"ALL TESTS PASSED":"*** FAILURES ***");
    return g_pass?0:1;
}
