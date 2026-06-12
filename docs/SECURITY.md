# Security & Privacy

Sally Vanity ETH Generator produces **live private keys and seed phrases**. Treat its
output like cash. This page explains exactly what the tool does, what it guarantees, and
the few things only *you* can get wrong.

---

## ⚠️ The one rule

> **Whoever holds the private key or mnemonic controls the address — and its funds.**
>
> - **Never** paste a generated key, mnemonic, or "private key" line into any website,
>   chat, support form, or AI tool.
> - Generate on an **offline / air-gapped** machine when the address will hold real value.
> - Treat the terminal scrollback, shell history, and any screenshots as secret material.

The program prints this warning on every match and **sends nothing anywhere**.

---

## Offline by construction

The engine makes **no network calls** of any kind — no telemetry, no update check, no
"verify on Etherscan" callout. All key generation, hashing, and matching happen locally on
your CPU and/or GPU; it behaves identically with networking disabled. The only component
that touches the network is the **installer** (to fetch your OS toolchain + PySide6), and
only when you run it.

---

## Maximum-entropy seeds

Seed candidates are **not** a counter, a weak PRNG, or sequential mnemonics. Each candidate
is:

```
candidate_entropy = SHA256( 32-byte secret base ‖ 8-byte index )
```

where the **secret base** is drawn once from the OS CSPRNG (`/dev/urandom`). SHA-256 over a
secret base makes every candidate — and the **chosen** winning seed — a full-entropy,
uniform, independent draw, computationally indistinguishable from fresh randomness:

- An attacker who learns the **index** of your winning seed learns **nothing** without the
  secret base.
- Sequential indices produce **uncorrelated** entropy (SHA-256 avalanche), so there is no
  "nearby key" weakness and no reduced search space.
- A 12-word result carries a true 128-bit seed; a 24-word result a true 256-bit seed.

This derivation is **identical on GPU and CPU**, so the property does not depend on the
backend or on hybrid mode.

---

## Host re-derivation failsafe

Every displayed result is **independently re-derived and re-verified on the host CPU**
before you ever see it (`print_match`, `src/output.cuh`):

1. The winning scalar (raw) or entropy (seed) is rebuilt from scratch into a private key,
   public key, and EIP-55 address.
2. For contracts, the CREATE/CREATE2 address is recomputed for the matched nonce.
3. The result is re-checked against your pattern.

If this re-derivation does **not** match, the tool prints
`*** FAILSAFE: re-derived address does not match the pattern — discarding result. ***`
and shows nothing. **A wrong or unverifiable key is never displayed** — this catches any
GPU/host inconsistency, driver bug, or memory error (including in hybrid mode, where either
engine may have produced the hit).

---

## Passphrase (hidden-wallet) semantics

The optional BIP39 passphrase (SafePal "hidden wallet" / 25th word):

- **Empty passphrase** → a normal wallet; the vanity holds with no passphrase.
- **Set passphrase** → the vanity address exists **only** when that exact passphrase is
  entered with the mnemonic. The same mnemonic with no passphrase derives a *different*,
  non-vanity address.

The passphrase is **not recoverable** from the mnemonic and is **not** stored anywhere. If
you lose it, the vanity address (and its funds) are gone. Back it up separately from the
mnemonic.

---

## GPU access & elevation

The tool is designed to **run without `sudo`** and never requires root.

On startup it probes for a usable CUDA device (`cudaGetDeviceCount`, then `cudaFree(0)` to
force primary-context init). If a GPU exists but the context **cannot initialize without
extra permissions** — typically because your user is not in the `render` / `video` group —
the tool does **not** abort and does **not** demand a password. It prints a `[gpu-fallback]`
note and **automatically falls back to CPU**:

```
[gpu-fallback] GPU found but not usable without extra permissions (...) — using CPU.
       For GPU speed without sudo, add your user to the render/video group:
         sudo usermod -aG render,video $USER   (then log out and back in)
```

**Prefer the one-time group add over running as root.** The desktop app can offer an
"Enable GPU" action that elevates (Linux `pkexec`, macOS admin dialog, Windows UAC), but the
**recommended** fix is the persistent group membership: it keeps the long-running
key-generation process at **least privilege** instead of root, and is a single prompt
forever. Running a key generator as root widens the blast radius of any bug to the whole
system.

> **Verify before you elevate.** Never run an untrusted or pre-built key generator as
> root/administrator. Build from source (`make`), run `make test`, and confirm the binary is
> the one you built before granting it any elevated access.

---

## What this tool does *not* protect against

- A compromised machine (keylogger, clipboard sniffer, screen capture).
- You copying the key/mnemonic somewhere insecure after generation.
- Weak operational security around the passphrase backup.

Generate on a clean, offline machine and move the secret to your hardware wallet
immediately.
