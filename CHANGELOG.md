# Changelog

All notable changes to **Sally Vanity ETH Generator** are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/); the project
aims for [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Live **GPU / CPU temperature** in the app footer (bottom-left, non-blocking poll) and a
  clickable **sally.tools** backlink; a live **elapsed-time** readout while a search runs.
- Adjustable **CPU worker count** (`--threads N` + a CPU-threads slider in the app).
- The **passphrase value is now shown** with the result (mnemonic + passphrase + address +
  private key of the real vanity wallet — everything needed to save/restore it).
- **Hybrid CPU+GPU** search (`--hybrid`) — both backends run concurrently on disjoint key
  ranges, first to find wins, combined throughput shown as `Maddr/s (gpu+cpu)`.
- **GPU elevation** in the desktop app: when the GPU isn't usable without permissions the
  binary auto-falls back to CPU (no `sudo` required) and the app offers an **⚡ Enable GPU**
  button (Linux `pkexec` · macOS admin · Windows UAC); recommended fix is the one-time
  `render`/`video` group add.
- App **icon** (window/taskbar + title-bar logo) and a `docs/` folder (ARCHITECTURE,
  SECURITY, USAGE, BUILD).
- BIP39 **seed-phrase** search (12 / 24 words) — results importable into
  MetaMask / SafePal / Trezor — alongside the fast raw-private-key mode.
- Optional BIP39 **passphrase** (SafePal hidden-wallet / 25th word).
- **CREATE** and **CREATE2** contract-address vanity, with a CREATE **nonce range**
  (`--nonce-count`) that matches any of a deployer's first N contracts.
- **CPU backend** (multi-threaded OpenMP) with automatic fallback when no CUDA
  GPU is present; one source builds both GPU (nvcc) and CPU (g++/clang++).
- Native **PySide6** desktop app in a fixed Base-blue / Binance-yellow design,
  localized into **10 languages** (EN, DE, ES, FR, PT, RU, ZH, JA, HI, AR).
- Cross-platform **installer** (`install.sh` / `install.ps1` / `install.py`).
- **GitHub Actions** release workflow: builds CPU binaries for Linux x86_64,
  macOS arm64 (Apple Silicon), Windows x86_64, plus a Linux CUDA build, and
  publishes per-target `.zip` assets.
- Host-side **failsafe**: every result is independently re-derived and re-checked
  against the pattern before display.

### Changed / Performance
- Seed-mode scalar multiplication moved to **Jacobian fixed-base** coordinates
  (one field inversion per `k·G` instead of one per point addition).
- **Maximum entropy** seed candidates: `SHA256(32-byte /dev/urandom base ‖ index)`.
- PBKDF2 inner loop uses a specialised constant-tail SHA-512 block; the GPU seed
  pipeline is split into a PBKDF2 stage and a BIP32+EC stage for higher occupancy.

### Security
- secp256k1, Keccak-256, SHA-256/512, HMAC, PBKDF2, BIP32/39/44, RLP and
  CREATE/CREATE2 are validated against published test vectors via `make test`
  (incl. the Etherscan-verified `abandon … about` wallet).
