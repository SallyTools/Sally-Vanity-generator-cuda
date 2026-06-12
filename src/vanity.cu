// Sally Vanity ETH Generator — Ethereum vanity address generator.
//
// One source, two builds:
//   * GPU  : nvcc            (CUDA kernels active, default backend; --cpu works too)
//   * CPU  : g++/clang++ -x c++  (kernels #ifdef'd out, OpenMP search)
//
// Search axes:
//   key source : raw private key  |  BIP39 seed (12 or 24 words, opt. passphrase)
//   match tgt  : EOA address      |  CREATE contract (deployer+nonce)  |  CREATE2
//   backend    : GPU              |  CPU (multi-thread)
//
// This file is just the CLI driver: it parses args, builds the match/seed config,
// and dispatches to the kernels (kernels.cuh) or the CPU search (search_cpu.cuh).
// Shared types/state live in engine_types.cuh; result formatting in output.cuh.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <atomic>
#include <chrono>
#include <thread>
#include "engine_types.cuh"
#include "kernels.cuh"
#include "search_cpu.cuh"
#include "output.cuh"
#ifdef _OPENMP
#include <omp.h>
#endif

int main(int argc,char**argv){
    const char* pref=""; const char* suf="";
    const char* mode="raw"; const char* tgt="eoa"; const char* passphrase="";
    const char* salthex=nullptr; const char* inithex=nullptr; const char* inithashhex=nullptr;
    uint64_t nonce=0; int nonce_count=1;
    // GPU tuning params — only read in the __CUDACC__ backend below.
    [[maybe_unused]] int half=512, blocks=60, tpb=128, itersPerLaunch=1;
    [[maybe_unused]] long maxLaunches=1L<<60;
    [[maybe_unused]] int gpuUtil=80; [[maybe_unused]] double targetMs=20.0;
    int useCpu=0; [[maybe_unused]] int hybrid=0;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"--prefix")&&i+1<argc) pref=argv[++i];
        else if(!strcmp(argv[i],"--suffix")&&i+1<argc) suf=argv[++i];
        else if(!strcmp(argv[i],"--mode")&&i+1<argc) mode=argv[++i];
        else if(!strcmp(argv[i],"--target")&&i+1<argc) tgt=argv[++i];
        else if(!strcmp(argv[i],"--nonce")&&i+1<argc) nonce=strtoull(argv[++i],0,10);
        else if(!strcmp(argv[i],"--nonce-count")&&i+1<argc) nonce_count=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--passphrase")&&i+1<argc) passphrase=argv[++i];
        else if(!strcmp(argv[i],"--salt")&&i+1<argc) salthex=argv[++i];
        else if(!strcmp(argv[i],"--init")&&i+1<argc) inithex=argv[++i];
        else if(!strcmp(argv[i],"--inithash")&&i+1<argc) inithashhex=argv[++i];
        else if(!strcmp(argv[i],"--cpu")) useCpu=1;
        else if(!strcmp(argv[i],"--gpu")) useCpu=0;
        else if(!strcmp(argv[i],"--hybrid")) hybrid=1;
        else if(!strcmp(argv[i],"--half")&&i+1<argc) half=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--blocks")&&i+1<argc) blocks=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--tpb")&&i+1<argc) tpb=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--iters")&&i+1<argc) itersPerLaunch=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--launches")&&i+1<argc) maxLaunches=atol(argv[++i]);
        else if(!strcmp(argv[i],"--gpu-util")&&i+1<argc) gpuUtil=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--target-ms")&&i+1<argc) targetMs=atof(argv[++i]);
        else { fprintf(stderr,"unknown arg %s\n",argv[i]); return 1; }
    }
    // ---- build match config ----
    memset(&hcfg,0,sizeof(hcfg)); memset(&hseed,0,sizeof(hseed));
    int preflen=strlen(pref), suflen=strlen(suf);
    if(preflen>40||suflen>40||preflen+suflen>40) die("pattern too long");
    if(preflen==0&&suflen==0) die("specify --prefix and/or --suffix");
    hcfg.preflen=preflen; hcfg.suflen=suflen;
    for(int i=0;i<preflen;i++){ int v=hexnib(pref[i]); if(v<0)die("bad prefix hex"); hcfg.pref[i]=v; }
    for(int i=0;i<suflen;i++){ int v=hexnib(suf[i]); if(v<0)die("bad suffix hex"); hcfg.suf[i]=v; }
    if(!strcmp(tgt,"eoa")) hcfg.target=TGT_EOA;
    else if(!strcmp(tgt,"create")) hcfg.target=TGT_CREATE;
    else if(!strcmp(tgt,"create2")) hcfg.target=TGT_CREATE2;
    else die("--target must be eoa|create|create2");
    hcfg.nonce=nonce;
    if(nonce_count<1) nonce_count=1;
    if(nonce_count>1024) die("--nonce-count too large (max 1024)");
    hcfg.nonce_count=nonce_count;
    if(hcfg.target==TGT_CREATE2){
        if(salthex){ if(hexbytes(salthex,hcfg.salt,32)!=32) die("--salt must be 32 bytes hex"); }
        if(inithashhex){ if(hexbytes(inithashhex,hcfg.inithash,32)!=32) die("--inithash must be 32 bytes hex"); }
        else if(inithex){ uint8_t ic[65536]; int n=hexbytes(inithex,ic,65536); if(n<0)die("bad --init hex"); keccak256_var(hcfg.inithash,ic,n); }
        else { keccak256_var(hcfg.inithash,(const uint8_t*)"",0); } // default empty init
    }
    // ---- seed config ----
    int seedMode=0, ent_bytes=0;
    if(!strcmp(mode,"raw")) seedMode=0;
    else if(!strcmp(mode,"seed12")){ seedMode=1; ent_bytes=16; }
    else if(!strcmp(mode,"seed24")){ seedMode=1; ent_bytes=32; }
    else die("--mode must be raw|seed12|seed24");

    FILE*f=fopen("/dev/urandom","rb");
    if(seedMode){
        hseed.ent_bytes=ent_bytes;
        // always draw a full 32-byte secret base; candidate entropy is SHA256(base||idx)
        if(!f||fread(hseed.base_ent,1,32,f)!=32) die("urandom");
        int pl=strlen(passphrase); if(pl>120) pl=120;   // salt = "mnemonic"+pass <= 128
        memcpy(hseed.pass,passphrase,pl); hseed.passlen=pl;
    }
    uint64_t K[4]={0,0,0,0};
    if(!seedMode){ if(!f||fread(K,8,4,f)!=4) die("urandom"); K[3]&=0x0FFFFFFFFFFFFFFFULL; }
    if(f) fclose(f);

    double diff=1.0; for(int i=0;i<preflen+suflen;i++) diff*=16.0;
    fprintf(stderr,"mode=%s target=%s backend=%s  pattern=0x%s...%s  difficulty=16^%d=%.3g\n",
            mode,tgt, useCpu?"cpu":"gpu", pref[0]?pref:"(any)", suf[0]?suf:"(any)", preflen+suflen, diff);
    if(hcfg.target==TGT_CREATE && nonce_count>1)
        fprintf(stderr,"CREATE: checking nonces %llu..%llu per deployer (matches the first that fits)\n",
                (unsigned long long)nonce,(unsigned long long)(nonce+nonce_count-1));
    if(seedMode && preflen+suflen>7)
        fprintf(stderr,"[warn] seed mode at %d chars is slow (~%.0e tries); consider <=6 chars\n",preflen+suflen,diff);

    g_res.found=0; g_found.store(0); g_tried.store(0);

#if defined(__CUDACC__)
    // Probe the GPU. Crucially this also catches the "GPU present but no access
    // permission" case (user not in the render/video group) so the tool runs on
    // CPU WITHOUT sudo instead of aborting. Never requires root.
    int haveGpu=0;
    if(!useCpu || hybrid){
        int n=0; cudaError_t e=cudaGetDeviceCount(&n);
        if(e==cudaSuccess && n>0){
            cudaError_t e2=cudaFree(0);             // force primary-context init
            if(e2==cudaSuccess) haveGpu=1;
            else fprintf(stderr,
                "[gpu-fallback] GPU found but not usable without extra permissions (%s) — using CPU.\n"
                "       For GPU speed without sudo, add your user to the render/video group:\n"
                "         sudo usermod -aG render,video $USER   (then log out and back in)\n",
                cudaGetErrorString(e2));
        } else {
            fprintf(stderr,"[gpu-fallback] no usable GPU device (%s) — using CPU.\n", cudaGetErrorString(e));
        }
        if(!haveGpu) useCpu=1;
    }
    if(hybrid && !haveGpu){ fprintf(stderr,"[hybrid] no usable GPU — running CPU only.\n"); hybrid=0; }
    if(hybrid){ useCpu=0;   // hybrid drives the GPU path in the main thread; CPU runs alongside
        fprintf(stderr,"[hybrid] GPU+CPU concurrently. Big win in seed mode (~+40%%); negligible in raw (GPU dominates).\n"); }
#else
    useCpu=1; hybrid=0;
#endif

    // ================= CPU backend =================
    if(useCpu){
        auto t0=std::chrono::steady_clock::now();
        std::atomic<int> done(0);
        // independent reporter thread (NOT an OpenMP section — the search itself
        // uses `omp parallel`, and nesting would collapse it to one thread).
        std::thread reporter([&](){
            while(!done.load()){
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
                double el=std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count();
                long long tried=g_tried.load(); double rate=el>0?tried/el:0;
                fprintf(stderr,"\r%.3f Gaddr  %.1f s  %.3f Maddr/s  burst=0ms  ETA~%.0fs   ",
                        tried/1e9, el, rate/1e6, rate>0?diff/rate:0.0);
                if(g_found.load()) break;
            }
        });
        if(seedMode) cpu_seed_search(); else cpu_raw_search(K);
        done.store(1); reporter.join();
        double el=std::chrono::duration<double>(std::chrono::steady_clock::now()-t0).count();
        long long tried=g_tried.load(); double rate=el>0?tried/el:0;
        fprintf(stderr,"\r%.3f Gaddr  %.1f s  %.3f Maddr/s  burst=0ms  ETA~0s   \n",tried/1e9, el, rate/1e6);
        if(!g_res.found){ printf("no match\n"); return 2; }
        print_match(hcfg.target);
        return 0;
    }

#if defined(__CUDACC__)
    // ================= GPU backend =================
    int nthreads=blocks*tpb;
    CK(cudaMemcpyToSymbol(dcfg,&hcfg,sizeof(MatchCfg)));
    Result* d_res; CK(cudaMalloc(&d_res,sizeof(Result)));
    Result zero; memset(&zero,0,sizeof(zero)); CK(cudaMemcpy(d_res,&zero,sizeof(Result),cudaMemcpyHostToDevice));

    // ---- HYBRID: run the CPU engine alongside the GPU, one unified reporter.
    // First to set g_found wins; both write g_res only through g_found.exchange(0->1).
    std::thread cpu_thr, reporter; std::atomic<int> rep_done(0);
    auto thyb = std::chrono::steady_clock::now();
    uint64_t K2[4]={0,0,0,0};
    if(hybrid){
        if(seedMode){
            cpu_thr = std::thread(cpu_seed_search, (uint64_t)(1ULL<<46)); // disjoint from GPU range [0,...)
        } else {
            FILE*g=fopen("/dev/urandom","rb");
            if(!g||fread(K2,8,4,g)!=4) die("urandom"); K2[3]&=0x0FFFFFFFFFFFFFFFULL; if(g)fclose(g);
            cpu_thr = std::thread(cpu_raw_search, K2);                     // independent random base
        }
        reporter = std::thread([&](){
            while(!rep_done.load()){
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
                double el=std::chrono::duration<double>(std::chrono::steady_clock::now()-thyb).count();
                long long total=g_gpu_done.load(std::memory_order_relaxed)+g_tried.load(std::memory_order_relaxed);
                double rate=el>0?total/el:0;
                fprintf(stderr,"\r%.4f Gaddr  %.1f s  %.4f Maddr/s (gpu+cpu)  ETA~%.0fs   ",
                        total/1e9, el, rate/1e6, rate>0?diff/rate:0.0);
                if(g_found.load()) break;
            }
        });
    }

    if(seedMode){
        CK(cudaMemcpyToSymbol(dseed,&hseed,sizeof(SeedCfg)));
        if(gpuUtil<1)gpuUtil=1; if(gpuUtil>100)gpuUtil=100; double util=gpuUtil/100.0;
        // bigger grid for the seed kernels: PBKDF2 is latency-bound, more resident
        // warps hide it. ~8 waves of blocks.
        int sblocks = blocks*8; int sthreads = sblocks*tpb;
        uint64_t *d_seedw; uint8_t *d_entbuf;
        CK(cudaMalloc(&d_seedw, sizeof(uint64_t)*8*sthreads));
        CK(cudaMalloc(&d_entbuf, (size_t)32*sthreads));
        fprintf(stderr,"seed mode: split PBKDF2(2048) | BIP32+EC kernels, %d candidates/launch — yields an importable mnemonic\n", sthreads);
        Result hr; long long done=0; uint64_t base=0;
        struct timespec ta,tb; clock_gettime(CLOCK_MONOTONIC,&ta);
        double tstart=ta.tv_sec+ta.tv_nsec*1e-9;
        for(long L=0; L<maxLaunches; L++){
            clock_gettime(CLOCK_MONOTONIC,&ta);
            pbkdf2_seed<<<sblocks,tpb>>>(base, sthreads, d_seedw, d_entbuf);
            seed_to_addr<<<sblocks,tpb>>>(d_seedw, d_entbuf, sthreads, d_res);
            CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
            clock_gettime(CLOCK_MONOTONIC,&tb);
            double burst=(tb.tv_sec-ta.tv_sec)+(tb.tv_nsec-ta.tv_nsec)*1e-9;
            done += (long long)sthreads; base += (uint64_t)sthreads;
            g_gpu_done.store(done,std::memory_order_relaxed);
            CK(cudaMemcpy(&hr,d_res,sizeof(Result),cudaMemcpyDeviceToHost));
            double sleep_s=burst*(1.0/util-1.0);
            if(sleep_s>0){ struct timespec ts; ts.tv_sec=(time_t)sleep_s; ts.tv_nsec=(long)((sleep_s-(double)ts.tv_sec)*1e9); nanosleep(&ts,NULL); }
            clock_gettime(CLOCK_MONOTONIC,&tb);
            double now=tb.tv_sec+tb.tv_nsec*1e-9, el=now-tstart; double rate=done/el;
            if(!hybrid) fprintf(stderr,"\r%.4f Gaddr  %.1f s  %.4f Maddr/s  burst=%.0fms  ETA~%.0fs   ",
                    done/1e9, el, rate/1e6, burst*1000.0, hr.found?0.0:diff/rate);
            if(hr.found){ if(g_found.exchange(1)==0) g_res=hr; break; }
            if(hybrid && g_found.load(std::memory_order_acquire)) break;
        }
        CK(cudaFree(d_seedw)); CK(cudaFree(d_entbuf));
        if(hybrid){
            g_found.store(1);                            // ensure CPU stops if GPU exhausted launches
            if(cpu_thr.joinable()) cpu_thr.join();
            rep_done.store(1); if(reporter.joinable()) reporter.join();
            double el=std::chrono::duration<double>(std::chrono::steady_clock::now()-thyb).count();
            long long total=g_gpu_done.load()+g_tried.load(); double rate=el>0?total/el:0;
            fprintf(stderr,"\r%.4f Gaddr  %.1f s  %.4f Maddr/s (gpu+cpu)               \n", total/1e9, el, rate/1e6);
        } else {
            fprintf(stderr,"\n");
            if(hr.found && g_found.exchange(1)==0) g_res=hr;
        }
        if(!g_res.found){ printf("no match in given launches\n"); return 2; }
        print_match(hcfg.target); return 0;
    }

    // ---- raw GPU (fast batch-inversion walk) ----
    ecp G; ec_set_g(&G);
    ecp base; ec_mul(&base,K,&G);
    fe* h_gnx=(fe*)malloc(sizeof(fe)*half); fe* h_gny=(fe*)malloc(sizeof(fe)*half);
    ecp cur=G;
    for(int i=0;i<half;i++){ h_gnx[i]=cur.x; h_gny[i]=cur.y; ecp nx; ec_add(&nx,&cur,&G); cur=nx; }
    uint64_t kgrp[4]={(uint64_t)(2*half),0,0,0}; ecp Pgrp; ec_mul(&Pgrp,kgrp,&G);
    fe* h_cx=(fe*)malloc(sizeof(fe)*nthreads); fe* h_cy=(fe*)malloc(sizeof(fe)*nthreads);
    uint64_t* h_sc=(uint64_t*)malloc(sizeof(uint64_t)*4*nthreads);
    ecp c=base;
    for(int t=0;t<nthreads;t++){
        h_cx[t]=c.x; h_cy[t]=c.y;
        unsigned __int128 add=(unsigned __int128)2*half*(unsigned __int128)t;
        uint64_t lo=(uint64_t)add, hi=(uint64_t)(add>>64);
        unsigned __int128 s0=(unsigned __int128)K[0]+lo; h_sc[t*4+0]=(uint64_t)s0; uint64_t cr=(uint64_t)(s0>>64);
        unsigned __int128 s1=(unsigned __int128)K[1]+hi+cr; h_sc[t*4+1]=(uint64_t)s1; cr=(uint64_t)(s1>>64);
        unsigned __int128 s2=(unsigned __int128)K[2]+cr; h_sc[t*4+2]=(uint64_t)s2; cr=(uint64_t)(s2>>64);
        h_sc[t*4+3]=K[3]+cr;
        ecp nx; ec_add(&nx,&c,&Pgrp); c=nx;
    }
    uint64_t kadv[4]={0,0,0,0};
    { unsigned __int128 m=(unsigned __int128)nthreads*(unsigned __int128)(2*half);
      kadv[0]=(uint64_t)m; kadv[1]=(uint64_t)(m>>64); }
    ecp Adv; ec_mul(&Adv,kadv,&G);
    U256 stride; stride.v[0]=kadv[0]; stride.v[1]=kadv[1]; stride.v[2]=0; stride.v[3]=0;

    fe *d_gnx,*d_gny,*d_cx,*d_cy,*d_pre; uint64_t* d_sc;
    CK(cudaMalloc(&d_gnx,sizeof(fe)*half)); CK(cudaMalloc(&d_gny,sizeof(fe)*half));
    CK(cudaMalloc(&d_cx,sizeof(fe)*nthreads)); CK(cudaMalloc(&d_cy,sizeof(fe)*nthreads));
    CK(cudaMalloc(&d_sc,sizeof(uint64_t)*4*nthreads));
    size_t prebytes=(size_t)sizeof(fe)*half*nthreads;
    CK(cudaMalloc(&d_pre,prebytes));
    CK(cudaMemcpy(d_gnx,h_gnx,sizeof(fe)*half,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_gny,h_gny,sizeof(fe)*half,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_cx,h_cx,sizeof(fe)*nthreads,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_cy,h_cy,sizeof(fe)*nthreads,cudaMemcpyHostToDevice));
    CK(cudaMemcpy(d_sc,h_sc,sizeof(uint64_t)*4*nthreads,cudaMemcpyHostToDevice));

    fprintf(stderr,"scratch=%.0fMB threads=%d HALF=%d\n", prebytes/1048576.0, nthreads, half);
    if(gpuUtil<1)gpuUtil=1; if(gpuUtil>100)gpuUtil=100; double util=gpuUtil/100.0;
    fprintf(stderr,"throttle: gpu-util=%d%%  target-burst=%.0fms\n",gpuUtil,targetMs);

    Result hr; long long done=0; int warned=0;
    struct timespec ta,tb; clock_gettime(CLOCK_MONOTONIC,&ta);
    double tstart=ta.tv_sec+ta.tv_nsec*1e-9;
    for(long L=0; L<maxLaunches; L++){
        clock_gettime(CLOCK_MONOTONIC,&ta);
        vsearch<<<blocks,tpb>>>(d_cx,d_cy,d_sc,d_pre,d_gnx,d_gny,Adv.x,Adv.y,stride,half,itersPerLaunch,nthreads,d_res);
        CK(cudaGetLastError()); CK(cudaDeviceSynchronize());
        clock_gettime(CLOCK_MONOTONIC,&tb);
        double burst=(tb.tv_sec-ta.tv_sec)+(tb.tv_nsec-ta.tv_nsec)*1e-9;
        done += (long long)itersPerLaunch*nthreads*(2*half);
        g_gpu_done.store(done,std::memory_order_relaxed);
        CK(cudaMemcpy(&hr,d_res,sizeof(Result),cudaMemcpyDeviceToHost));
        if(L==0){ double perIter=burst/itersPerLaunch; int want=(int)(targetMs/1000.0/perIter); if(want<1)want=1; itersPerLaunch=want; }
        double sleep_s=burst*(1.0/util-1.0);
        if(sleep_s>0){ struct timespec ts; ts.tv_sec=(time_t)sleep_s; ts.tv_nsec=(long)((sleep_s-(double)ts.tv_sec)*1e9); nanosleep(&ts,NULL); }
        if(!warned && burst*1000.0>120.0){ warned=1; fprintf(stderr,"\n[warn] kernel burst %.0fms long; lower --blocks\n",burst*1000.0); }
        clock_gettime(CLOCK_MONOTONIC,&tb);
        double now=tb.tv_sec+tb.tv_nsec*1e-9, el=now-tstart; double rate=done/el;
        if(!hybrid) fprintf(stderr,"\r%.2f Gaddr  %.1f s  %.1f Maddr/s  burst=%.0fms  ETA~%.0fs   ",
                done/1e9, el, rate/1e6, burst*1000.0, hr.found?0.0:diff/rate);
        if(hr.found){ if(g_found.exchange(1)==0) g_res=hr; break; }
        if(hybrid && g_found.load(std::memory_order_acquire)) break;
    }
    if(hybrid){
        g_found.store(1);
        if(cpu_thr.joinable()) cpu_thr.join();
        rep_done.store(1); if(reporter.joinable()) reporter.join();
        double el=std::chrono::duration<double>(std::chrono::steady_clock::now()-thyb).count();
        long long total=g_gpu_done.load()+g_tried.load(); double rate=el>0?total/el:0;
        fprintf(stderr,"\r%.2f Gaddr  %.1f s  %.1f Maddr/s (gpu+cpu)               \n", total/1e9, el, rate/1e6);
    } else {
        fprintf(stderr,"\n");
        if(hr.found && g_found.exchange(1)==0) g_res=hr;
    }
    if(!g_res.found){ printf("no match in given launches\n"); return 2; }
    print_match(hcfg.target);
    return 0;
#else
    return 0;
#endif
}
