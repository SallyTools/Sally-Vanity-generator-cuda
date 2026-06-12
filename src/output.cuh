// Host-side helpers: hex parsing, EIP-55 checksumming, and result formatting
// with an independent re-derivation failsafe before anything is printed.
#pragma once
#include "engine_types.cuh"
#include "bip39.cuh"
#include <cstdio>
#include <cstdlib>
#include <cstring>

static int hexnib(char c){
    if(c>='0'&&c<='9')return c-'0';
    if(c>='a'&&c<='f')return c-'a'+10;
    if(c>='A'&&c<='F')return c-'A'+10;
    return -1;
}
static void die(const char*m){ fprintf(stderr,"error: %s\n",m); exit(1); }
static int hexbytes(const char* h, uint8_t* out, int maxn){
    int n=strlen(h); if(n&1) return -1; n/=2; if(n>maxn) return -1;
    for(int i=0;i<n;i++){ int a=hexnib(h[2*i]),b=hexnib(h[2*i+1]); if(a<0||b<0)return -1; out[i]=(uint8_t)((a<<4)|b);}
    return n;
}
// EIP-55 checksummed address string (out needs 41 bytes)
static void to_eip55(const uint8_t a[20], char* out){
    const char* hexd="0123456789abcdef";
    char low[40]; for(int i=0;i<20;i++){ low[2*i]=hexd[a[i]>>4]; low[2*i+1]=hexd[a[i]&0xf]; }
    uint8_t h[32]; keccak256_var(h,(const uint8_t*)low,40);
    for(int i=0;i<40;i++){
        char c=low[i];
        if(c>='a'&&c<='f'){ uint8_t nib=(i&1)?(h[i>>1]&0xf):(h[i>>1]>>4); if(nib>=8) c=c-'a'+'A'; }
        out[i]=c;
    }
    out[40]=0;
}

static void print_match(int target){
    uint8_t eoa[20], priv[32]; char words[BIP39_MAX_SENTENCE]; words[0]=0;
    if(g_res.ent_bytes>0){
        // seed result
        bip39_mnemonic(g_res.ent, g_res.ent_bytes, words, (uint16_t*)0);
        bip39_to_eth(g_res.ent, g_res.ent_bytes, hseed.pass, hseed.passlen, eoa, priv);
    } else {
        // raw result: priv = sc + offset
        uint64_t p[4]={g_res.sc[0],g_res.sc[1],g_res.sc[2],g_res.sc[3]};
        long long off=g_res.offset;
        if(off>=0){ unsigned __int128 s=(unsigned __int128)p[0]+(uint64_t)off; p[0]=(uint64_t)s; uint64_t cr=(uint64_t)(s>>64);
            for(int k=1;k<4&&cr;k++){ unsigned __int128 z=(unsigned __int128)p[k]+cr; p[k]=(uint64_t)z; cr=(uint64_t)(z>>64);} }
        else { uint64_t o=(uint64_t)(-off); unsigned __int128 s=(unsigned __int128)p[0]-o; p[0]=(uint64_t)s; uint64_t bo=(s>>64)?1:0;
            for(int k=1;k<4&&bo;k++){ unsigned __int128 z=(unsigned __int128)p[k]-bo; p[k]=(uint64_t)z; bo=(z>>64)?1:0;} }
        for(int i=0;i<4;i++){ uint64_t w=p[3-i]; for(int j=0;j<8;j++) priv[i*8+j]=(uint8_t)(w>>(56-8*j)); }
        fe kf; for(int i=0;i<4;i++) kf.v[i]=p[i]; uint64_t kk[4]={kf.v[0],kf.v[1],kf.v[2],kf.v[3]};
        ecp G,P; ec_set_g(&G); ec_mul(&P,kk,&G); addr_of_point(&P,eoa);
    }
    // ---- FAILSAFE: independently re-derive the final address on the host and
    // confirm it really matches the requested pattern. Catches any GPU/host
    // inconsistency before we hand the user a wrong key. ----
    uint64_t win_nonce = (target==TGT_CREATE && g_res.matched_nonce>=0)
                         ? (uint64_t)g_res.matched_nonce : hcfg.nonce;
    uint8_t fin[20]; final_address_n(eoa,&hcfg,win_nonce,fin);
    if(!match_pattern(fin,&hcfg)){
        fprintf(stderr,"\n*** FAILSAFE: re-derived address does not match the pattern — discarding result. ***\n");
        printf("error: internal verification failed (no valid result)\n");
        return;
    }
    char eaddr[41]; to_eip55(eoa,eaddr);
    char pstr[65]; for(int i=0;i<32;i++) sprintf(pstr+2*i,"%02x",priv[i]);
    printf("\n=== MATCH ===\n");
    if(words[0]){
        printf("mnemonic    : %s\n", words);
        if(hseed.passlen) printf("passphrase  : (set, %d chars) — vanity gilt NUR mit dieser Passphrase\n", hseed.passlen);
        printf("path        : m/44'/60'/0'/0/0\n");
    }
    printf("address     : 0x%s\n", eaddr);
    if(target!=TGT_EOA){
        char fstr[41]; to_eip55(fin,fstr);
        if(target==TGT_CREATE) printf("contract    : 0x%s  (CREATE, nonce %llu)\n", fstr,(unsigned long long)win_nonce);
        else                   printf("contract    : 0x%s  (CREATE2)\n", fstr);
        if(target==TGT_CREATE)
            printf("deployer    : 0x%s  (fund this; deploy when its nonce == %llu)\n", eaddr,(unsigned long long)win_nonce);
        else
            printf("deployer    : 0x%s\n", eaddr);
    }
    printf("private key : 0x%s\n", pstr);
    printf("!! keep the private key / mnemonic secret. anyone with it controls the funds. !!\n");
}
