# Architecture

> How Sally Vanity ETH Generator is put together: one source tree that compiles to
> both a GPU and a CPU binary, a from-scratch crypto core shared by both, and four
> search pipelines (raw key, BIP39 seed, hybrid CPU+GPU).

---

## 1. One source, two compilers

The entire engine is **header-only** and assembled into a **single translation unit**.
`src/vanity.cu` `#include`s the engine partials (`engine_types`, `kernels`,
`search_cpu`, `output`), which in turn pull in the crypto headers. That one TU is fed to
**two different compilers** from the `Makefile`:

| Target | Compiler | Output | CUDA kernels |
|---|---|---|---|
| `make`     | `nvcc`        | `./vanity`, `./selftest`         | **active** (`__CUDACC__` defined) |
| `make cpu` | `g++`/`clang++` (+OpenMP) | `./vanity-cpu`, `./selftest-cpu` | compiled out (host-only) |
| `make both`| both          | all of the above                 | — |

The bridge is `src/cuda_compat.cuh`, which defines an `HD` macro
(`__host__ __device__` under nvcc, empty otherwise). Every crypto primitive is marked
`HD`, so **the same function body runs on the GPU and the CPU** — there is no second
implementation to keep in sync. GPU-only code in `src/kernels.cuh` is wrapped in
`#if defined(__CUDACC__)`, so the host build sees an empty header and falls through to
the CPU search in `src/search_cpu.cuh`. Correctness only has to be proven once
(`make test`) and holds for both backends.

---

## 2. Crypto core (header layout)

All primitives are implemented from scratch — no OpenSSL, no libsecp256k1 — so the exact
same bytes are produced on every platform.

```
src/field.cuh        secp256k1 base-field arithmetic (256-bit, 4×u64 limbs, 128-bit mul)
src/ec.cuh           affine EC point ops; ec_set_g, ec_add, ec_mul (reference)
src/ec_fast.cuh      Jacobian fixed-base k·G (one field inversion per scalar mult)
src/keccak.cuh       Keccak-256 (Ethereum variant, NOT NIST SHA3) — fixed + variable len
src/sha256.cuh       SHA-256                (entropy derivation, EIP-1014 hashing)
src/sha512.cuh       SHA-512 / HMAC-SHA512  (BIP32/39, constant-tail PBKDF2 block)
src/bip32.cuh        BIP32 HD derivation    (m/44'/60'/0'/0/0)
src/bip39.cuh        entropy → mnemonic → seed → ETH address/private key
src/bip39_words.cuh  the 2048-word English wordlist (generated; SHA256 of source recorded)
src/rlp.cuh          minimal RLP encoder    (CREATE = keccak(rlp([sender,nonce]))), CREATE2
src/match.cuh        pattern matching + final-address derivation (EOA/CREATE/CREATE2)
src/cuda_compat.cuh  the HD macro + host shims
```

Two shared structs in `src/engine_types.cuh` carry everything the device needs:
`MatchCfg` (target kind, prefix/suffix nibbles, nonce + nonce-count, salt, inithash) and
`SeedCfg` (32-byte base entropy, word count, passphrase). On the GPU they are uploaded
once to `__constant__` memory (`dcfg`, `dseed`); on the CPU they live in the static host
globals `hcfg` / `hseed`.

---

## 3. Raw-key pipeline (`vsearch`)

The fast mode never re-derives a key per candidate; it walks the curve incrementally:

1. Each thread holds a current point `C = k·G` and its scalar `k`.
2. A symmetric **window of ±`half` generator multiples** (precomputed) is added to `C`,
   yielding `2·half` candidate addresses per step.
3. The `half` field inversions are done with a single **Montgomery batch inversion** (one
   `fe_inv` for the whole window via a prefix-product array).
4. Each candidate is checked with `match_final_nonce`; a hit is claimed once via
   `atomicCAS(&res->found,0,1)`, recording the scalar and signed window offset so the host
   reconstructs `priv = sc + offset`.
5. The thread advances `C += stride·G`, loops `iters` times per launch; batch size
   auto-tunes toward `--target-ms` / `--gpu-util`.

The CPU mirror `cpu_raw_search` uses the same primitives: each OpenMP worker starts
`wid·2^48` apart and walks with `ec_add(P,P,G)`.

---

## 4. Seed pipeline — the two-kernel split

BIP39 search runs **PBKDF2-HMAC-SHA512 (2048 iterations)** per candidate before any EC
work. Profiling shows PBKDF2 is ≈97% of the cost and uses no EC registers, while the
EC/BIP32 stage is register-hungry but cheap. Fusing them forces the whole kernel to the
EC stage's low occupancy, so the seed path is **split into two kernels** with seeds passed
through global memory in **SoA layout** (`seedw[j*n + tid]`) for coalesced access:

```
            base_counter, n                         seedw[], entbuf[]
  ┌──────────────────────────┐            ┌───────────────────────────────┐
  │  pbkdf2_seed  (Stage A)   │  ───────▶  │  seed_to_addr  (Stage B)       │
  │  __launch_bounds__(128,4) │            │  EC-heavy, runs separately     │
  │  entropy → mnemonic →     │            │  seed → BIP32 m/44'/60'/0'/0/0  │
  │  64-byte seed (PBKDF2)    │            │  → address → match             │
  └──────────────────────────┘            └───────────────────────────────┘
```

Stage A is capped at ~128 registers (`__launch_bounds__(128,4)` → ~50% occupancy) to hide
PBKDF2 latency, and writes both the seed (for Stage B) and the raw entropy (`entbuf`, for
host-side mnemonic reconstruction). The PBKDF2 inner loop uses a specialised constant-tail
SHA-512 block (`sha512_block_w8`) so ptxas folds the fixed padding schedule. The CPU mirror
`cpu_seed_search` does the same derivation inline per worker.

Entropy derivation is identical on both backends —
`candidate = SHA256(32-byte secret base ‖ 8-byte index)` — the basis of the max-entropy
guarantee in [SECURITY.md](SECURITY.md).

---

## 5. Hybrid mode (CPU + GPU together)

`--hybrid` runs the GPU pipeline **and** the OpenMP CPU search **concurrently** against one
shared result slot:

- **Single-writer claim.** Both backends publish into `g_found` / `g_res`. The winner is
  whoever wins `g_found.exchange(0→1)` (a total order on one atomic) — exactly one writer
  ever touches `g_res`. The GPU host loop bridges the device `Result` into this gate; CPU
  workers use it directly. The other engine observes `g_found` on its next iteration and
  stops.
- **Disjoint search spaces.** Raw mode gives the CPU an independent random base `K2`; seed
  mode offsets the CPU's candidate index by `1<<46` (the GPU enumerates from 0), so the two
  engines never test the same `SHA256(base‖index)` candidate and throughput is additive.
- **Unified reporting.** A single reporter thread sums `g_gpu_done` + `g_tried` and renders
  one `Maddr/s (gpu+cpu)` line.
- **Reality:** raw mode CPU adds ~1–2% to a ~400 M/s GPU (negligible); seed mode CPU
  (~40k/s on 8 cores) adds **~25–35%** to a ~135k/s GPU — hybrid is mainly a seed-mode win.
- **CPU worker count** is capped with `--threads N` (default: all cores), for `--cpu` and
  the CPU side of `--hybrid`.

When CUDA is unavailable (no device, or the context can't init without elevated
permissions) hybrid degrades to CPU-only — see [SECURITY.md](SECURITY.md#gpu-access--elevation).

---

## 6. Host failsafe & output

Whichever backend/pipeline produced the hit, `print_match` (`src/output.cuh`)
**independently re-derives the final address on the host** from the returned scalar (raw)
or entropy (seed), recomputes the CREATE/CREATE2 address for the matched nonce, and re-runs
`match_pattern`. If it does not match, the result is **discarded** and nothing is printed.
Only verified results reach the user: an EIP-55 checksummed address, the contract address
(if any), the deployer, and the private key / mnemonic.

---

## 7. Correctness (`make test`)

`src/selftest.cu` validates every primitive against published vectors — Keccak-256 KAT,
SHA-256/512, HMAC-SHA512 (RFC 4231), PBKDF2, the Etherscan-verified `abandon … about` BIP39
wallet (`0x9858EfFD…EcaEda94`), the `TREZOR`-passphrase vector, the 24-word all-zero vector,
CREATE nonce edge cases (0/1/128/256 RLP), CREATE2 (EIP-1014, vs ethers.js), and a
byte-for-byte check of fast Jacobian `k·G` against the affine reference over 200+ scalars.
It builds for both backends (`selftest`, `selftest-cpu`).
