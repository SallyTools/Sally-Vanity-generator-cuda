# Usage

Task-oriented walkthroughs. Run the desktop app (`python3 gui/app.py`) or the CLI
(`./vanity` / `./vanity-cpu`). Every result is re-verified on the host before display.

> ⚠️ Treat every key / mnemonic as cash — see [SECURITY.md](SECURITY.md).

---

## Wallet-address vanity (fast)

```bash
./vanity --prefix dead --suffix beef          # address starts 0xdead… and ends …beef
```
Returns a private key you can import as an account in MetaMask (Import account → Private
key). Pattern length vs. time: each extra hex char is ~16× harder; at ~400 M/s a 9–10 char
pattern is routine.

## Seed-phrase vanity (wallet-importable)

```bash
./vanity --mode seed12 --prefix cafe          # 12-word mnemonic whose address is 0xcafe…
./vanity --mode seed24 --prefix a11ce         # 24-word
```
Returns a **BIP39 mnemonic** (path `m/44'/60'/0'/0/0`). Import it into MetaMask / SafePal /
Ledger / Trezor as a recovery phrase. Seed mode is heavier (~135k/s on a 2060) — **≤ 6–7
chars** is comfortable. Use `--hybrid` to add CPU throughput.

## Hidden-wallet vanity (SafePal passphrase)

```bash
./vanity --mode seed24 --prefix a11ce --passphrase "my secret"
```
The vanity address exists **only** when that passphrase is entered with the mnemonic; with
no passphrase the same words derive a different, ordinary address. Back up the passphrase
**separately** — it is not recoverable from the words.

## Contract-address vanity (CREATE)

```bash
./vanity --target create --nonce 0  --prefix 0000    # the deployer's FIRST contract is 0x0000…
./vanity --target create --nonce-count 5 --prefix beef   # any of the first 5 contracts
```
Returns a **deployer** key/seed. Fund that address and deploy; when its nonce equals the
matched value, the new contract lands on the vanity address.

## Contract-address vanity (CREATE2, EIP-1014)

```bash
./vanity --target create2 --salt <32-byte hex> --init <init-code hex> --prefix beef
```
Matches `keccak256(0xff ‖ deployer ‖ salt ‖ keccak256(init))[12:]`. Supply the factory's
salt and init code (or `--inithash` if you already have the code hash).

## Backends

```bash
./vanity                       # GPU (default)
./vanity --cpu                 # CPU only (no GPU / no sudo)
./vanity --hybrid              # GPU + CPU together (best for seed mode)
./vanity --cpu --threads 4     # cap CPU worker threads (default: all cores)
```
If the GPU isn't usable without elevated permissions, the tool prints `[gpu-fallback]` and
continues on CPU. The GUI then shows **⚡ Enable GPU**; the persistent fix is
`sudo usermod -aG render,video $USER` (once, then re-login).

## Reading the live line

```
0.0123 Gaddr  4.2 s  0.105 Maddr/s  burst=20ms  ETA~38s
```
`Gaddr` = billions of candidates tried, `Maddr/s` = current rate, `ETA` = expected time to a
hit (always from the **measured** rate, never optimistic). Hybrid shows `Maddr/s (gpu+cpu)`.
