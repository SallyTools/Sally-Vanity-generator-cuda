# Sally-Vanity-generator-cuda
# GPU build needs nvcc (CUDA). CPU build needs only a C++17 compiler + OpenMP,
# so it runs anywhere (incl. macOS, where CUDA is unavailable).
NVCC   ?= nvcc
CXX    ?= g++
# Default GPU target sm_75 (RTX 20xx). Override with e.g. `make ARCH=sm_86`.
# We embed SASS for ARCH plus matching PTX so newer GPUs JIT-compile (forward-compat).
ARCH    ?= sm_75
ARCHNUM := $(patsubst sm_%,%,$(ARCH))
GENCODE := -gencode arch=compute_$(ARCHNUM),code=sm_$(ARCHNUM) \
           -gencode arch=compute_$(ARCHNUM),code=compute_$(ARCHNUM)
NVFLAGS  := $(GENCODE) -O3 -diag-suppress 20091,1835,550 --use_fast_math \
            -Xcompiler -fopenmp -Xcompiler -pthread
CXXFLAGS := -O3 -std=c++17 -fopenmp -pthread -x c++ -Isrc

HDRS := src/cuda_compat.cuh src/field.cuh src/ec.cuh src/ec_fast.cuh src/keccak.cuh \
        src/sha256.cuh src/sha512.cuh src/bip39_words.cuh src/bip32.cuh \
        src/bip39.cuh src/rlp.cuh src/match.cuh \
        src/engine_types.cuh src/kernels.cuh src/search_cpu.cuh src/output.cuh

# default: GPU binaries (use `make cpu` on machines without CUDA)
all: vanity selftest

vanity: src/vanity.cu $(HDRS)
	$(NVCC) $(NVFLAGS) src/vanity.cu -o vanity

selftest: src/selftest.cu $(HDRS)
	$(NVCC) $(NVFLAGS) src/selftest.cu -o selftest

# CPU-only build (no nvcc required)
cpu: vanity-cpu selftest-cpu

vanity-cpu: src/vanity.cu $(HDRS)
	$(CXX) $(CXXFLAGS) src/vanity.cu -o vanity-cpu

selftest-cpu: src/selftest.cu $(HDRS)
	$(CXX) $(CXXFLAGS) src/selftest.cu -o selftest-cpu

# build both backends
both: all cpu

test: selftest
	./selftest

test-cpu: selftest-cpu
	./selftest-cpu

clean:
	rm -f vanity vanity-cpu selftest selftest-cpu
.PHONY: all cpu both test test-cpu clean
