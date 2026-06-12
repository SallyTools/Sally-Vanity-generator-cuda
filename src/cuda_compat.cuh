// Compatibility shim so the shared __host__ __device__ code also compiles with a
// plain C++ host compiler (g++/clang++) for the CPU-only build (--no-gpu / macOS).
// Under nvcc, __CUDACC__ is defined and these CUDA keywords are real, so this is
// a no-op there. Include this FIRST in every header that uses them.
#pragma once
#if !defined(__CUDACC__)
  #ifndef __device__
    #define __device__
  #endif
  #ifndef __host__
    #define __host__
  #endif
  #ifndef __constant__
    #define __constant__
  #endif
  #ifndef __forceinline__
    #define __forceinline__ inline
  #endif
  #ifndef __global__
    #define __global__
  #endif
  // `#pragma unroll` is an nvcc directive; silence the host compiler's noise.
  #if defined(__GNUC__)
    #pragma GCC diagnostic ignored "-Wunknown-pragmas"
  #endif
#endif
