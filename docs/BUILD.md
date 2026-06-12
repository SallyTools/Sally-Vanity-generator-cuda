# Build

## Prerequisites

| Backend | Needs |
|---|---|
| **GPU** | NVIDIA CUDA Toolkit (`nvcc`) + a recent NVIDIA driver |
| **CPU** | any C++17 compiler (`g++` / `clang++`) with **OpenMP** |
| **GUI** | Python 3.8+ and **PySide6** (`pip install PySide6`) |

The CPU build needs no GPU and no CUDA — it runs anywhere, including machines with no
NVIDIA card (and macOS, which has no CUDA).

## Make targets

```bash
make            # GPU: ./vanity + ./selftest        (needs nvcc)
make cpu        # CPU: ./vanity-cpu + ./selftest-cpu (g++/clang++ + OpenMP)
make both       # everything
make test       # build + run the GPU selftest
make test-cpu   # build + run the CPU selftest
make clean
```

Override the GPU architecture for your card (default `sm_75`, RTX 20xx):

```bash
make ARCH=sm_86     # RTX 30xx
make ARCH=sm_89     # RTX 40xx
```

The default build embeds SASS for `ARCH` **plus** matching PTX, so the shipped GPU binary
also JIT-compiles on newer GPUs.

## One-command installer

`./install.sh` (Linux/macOS) or `install.ps1` (Windows) auto-detects your package manager
(apt · dnf · pacman · zypper · brew), installs the toolchain + PySide6 + fonts, builds the
right binary (GPU if CUDA is present, else CPU), runs the selftest, and can launch the app
(`--run`). It is idempotent and **never requires `sudo` for the common case** (existing
compiler + `pip --user`).

## Cross-platform release builds

`.github/workflows/release.yml` builds, on every `v*` tag, portable CPU binaries for Linux
x86_64, macOS x86_64 / arm64, and Windows x86_64 (MinGW, static runtime), plus a Linux CUDA
build — packaging each as a `.zip` release asset that also carries `gui/`, `src/`, the
installer, `assets/` (icons), `README.md`, `LICENSE` and `CHANGELOG.md`.

> **Why only 64-bit targets:** the crypto core relies on `unsigned __int128`, which exists
> only on 64-bit GCC/Clang targets. On any other architecture (e.g. 32-bit ARM, or 64-bit
> ARM Linux), build from source with `make cpu` rather than using a prebuilt binary.
