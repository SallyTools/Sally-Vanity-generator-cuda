#!/usr/bin/env python3
"""
Sally-Vanity-generator-cuda — cross-platform installer.

Covers Linux (apt/dnf/pacman/zypper), macOS (brew) and Windows. It:
  1. ensures a C++ toolchain + make,
  2. installs the PySide6 GUI dependency (pip),
  3. best-effort installs the JetBrains Mono font,
  4. detects CUDA (nvcc) -> builds the GPU binary; always builds the CPU binary,
  5. optionally launches the app (--run).

Nothing here is destructive; missing pieces are reported with the exact command
to fix them rather than failing hard. Re-run any time; it is idempotent.

Usage:
    python3 install.py [--run] [--cpu-only] [--no-font] [--yes]
"""
import os, sys, shutil, subprocess, platform, argparse

ROOT = os.path.dirname(os.path.abspath(__file__))
IS_WIN = os.name == "nt"
IS_MAC = sys.platform == "darwin"
IS_LINUX = sys.platform.startswith("linux")

class C:
    G="\033[32m"; Y="\033[33m"; R="\033[31m"; B="\033[36m"; D="\033[2m"; X="\033[0m"
    @staticmethod
    def off():
        for k in ("G","Y","R","B","D","X"): setattr(C,k,"")
if IS_WIN and not os.environ.get("WT_SESSION"): C.off()

def say(m):  print(f"{C.B}::{C.X} {m}")
def ok(m):   print(f"{C.G} ✓{C.X} {m}")
def warn(m): print(f"{C.Y} !{C.X} {m}")
def err(m):  print(f"{C.R} ✗{C.X} {m}")

def have(cmd): return shutil.which(cmd) is not None

def run(cmd, check=True, **kw):
    print(f"{C.D}   $ {' '.join(cmd)}{C.X}")
    return subprocess.run(cmd, check=check, **kw)

def detect_pkg_manager():
    for pm in ("apt-get","dnf","pacman","zypper","brew"):
        if have(pm): return pm
    return None

# font list includes CJK + Devanagari so the 中文 / हिन्दी UI renders without tofu
PKGS = {
    "apt-get": {"compiler": ["build-essential","make"], "python": ["python3","python3-pip"], "font": ["fonts-jetbrains-mono","fonts-noto-cjk","fonts-noto"]},
    "dnf":     {"compiler": ["gcc-c++","make"],          "python": ["python3","python3-pip"], "font": ["jetbrains-mono-fonts","google-noto-sans-cjk-fonts","google-noto-sans-devanagari-fonts"]},
    "pacman":  {"compiler": ["base-devel"],              "python": ["python","python-pip"],   "font": ["ttf-jetbrains-mono","noto-fonts-cjk","noto-fonts"]},
    "zypper":  {"compiler": ["gcc-c++","make"],          "python": ["python3","python3-pip"], "font": ["jetbrains-mono-fonts","google-noto-sans-fonts"]},
    "brew":    {"compiler": [],                          "python": ["python"],                "font": []},
}

def pm_install(pm, pkgs, sudo, yes):
    if not pkgs: return True
    if pm == "apt-get":  cmd = ["apt-get","install","-y"]+pkgs
    elif pm == "dnf":    cmd = ["dnf","install","-y"]+pkgs
    elif pm == "pacman": cmd = ["pacman","-S","--needed","--noconfirm"]+pkgs
    elif pm == "zypper": cmd = ["zypper","install","-y"]+pkgs
    elif pm == "brew":   cmd = ["brew","install"]+pkgs
    else: return False
    if sudo and pm != "brew": cmd = ["sudo"]+cmd
    try:
        run(cmd); return True
    except Exception as e:
        warn(f"package install failed: {e}")
        return False

def ensure_toolchain(pm, sudo, yes):
    cxx = "g++" if have("g++") else ("clang++" if have("clang++") else None)
    if cxx and have("make"):
        ok(f"C++ toolchain present ({cxx} + make)")
        return True
    say("installing C++ toolchain…")
    if IS_MAC:
        if not have("clang++"):
            warn("Apple command line tools needed — running: xcode-select --install")
            run(["xcode-select","--install"], check=False)
        return have("clang++") or have("g++")
    if pm and pm in PKGS:
        pm_install(pm, PKGS[pm]["compiler"], sudo, yes)
        pm_install(pm, PKGS[pm]["python"], sudo, yes)
    if (have("g++") or have("clang++")) and have("make"):
        ok("C++ toolchain installed"); return True
    err("could not find/install a C++ compiler + make. Install build tools manually.")
    return False

def ensure_pyside(yes):
    try:
        import PySide6  # noqa
        ok(f"PySide6 present ({PySide6.__version__})"); return True
    except Exception:
        pass
    say("installing PySide6 (pip)…")
    for args in (["--user"], []):
        try:
            run([sys.executable,"-m","pip","install","--upgrade","PySide6"]+args)
            import importlib, PySide6  # noqa
            ok("PySide6 installed"); return True
        except Exception:
            continue
    err("PySide6 install failed. Try:  python3 -m pip install PySide6")
    return False

def ensure_font(pm, sudo, yes, skip):
    if skip: return
    say("installing JetBrains Mono font (best effort)…")
    try:
        if IS_MAC and have("brew"):
            run(["brew","install","--cask","font-jetbrains-mono"], check=False)
        elif pm and pm in PKGS and PKGS[pm]["font"]:
            pm_install(pm, PKGS[pm]["font"], sudo, yes)
        else:
            warn("skip font auto-install (app falls back to system monospace)")
            return
        ok("font step done (app falls back to monospace if missing)")
    except Exception:
        warn("font install skipped (non-fatal)")

def build(cpu_only):
    have_nvcc = have("nvcc")
    have_make = have("make")
    if not have_make:
        err("`make` missing — cannot build. Install build tools and re-run.")
        return False
    if have_nvcc and not cpu_only:
        say("CUDA detected — building GPU + CPU binaries (make both)…")
        try:
            run(["make","both"], cwd=ROOT); ok("built: ./vanity (GPU) and ./vanity-cpu (CPU)"); return True
        except Exception:
            warn("GPU build failed — falling back to CPU-only build")
    else:
        if not have_nvcc and not cpu_only:
            if have("nvidia-smi"):
                warn("NVIDIA GPU found but `nvcc` (CUDA Toolkit) is missing.")
                warn("Install the CUDA Toolkit for GPU speed, then re-run. Building CPU binary for now.")
            else:
                say("no CUDA — building CPU binary (works everywhere)…")
    try:
        run(["make","cpu"], cwd=ROOT); ok("built: ./vanity-cpu (CPU). Select 'CPU' backend in the app.")
        return True
    except Exception as e:
        err(f"CPU build failed: {e}"); return False

def run_selftest():
    exe = os.path.join(ROOT,"selftest") if os.path.exists(os.path.join(ROOT,"selftest")) else \
          (os.path.join(ROOT,"selftest-cpu") if os.path.exists(os.path.join(ROOT,"selftest-cpu")) else None)
    if not exe and have("make"):
        try: run(["make","test-cpu"], cwd=ROOT); return
        except Exception: pass
    if exe:
        say("running correctness selftest…")
        subprocess.run([exe], cwd=ROOT)

def install_desktop_entry():
    # Per-user (no root) Linux launcher + hicolor icons so the app shows in menus.
    if not IS_LINUX: return
    import shutil as _sh
    icon_dir = os.path.join(ROOT, "assets")
    if not os.path.exists(os.path.join(icon_dir, "icon-64.png")): return
    data = os.path.join(os.path.expanduser("~"), ".local", "share")
    apps = os.path.join(data, "applications")
    icons = os.path.join(data, "icons", "hicolor")
    try:
        os.makedirs(apps, exist_ok=True)
        for s in (16,24,32,48,64,128,256,512):
            src = os.path.join(icon_dir, f"icon-{s}.png")
            if os.path.exists(src):
                d = os.path.join(icons, f"{s}x{s}", "apps"); os.makedirs(d, exist_ok=True)
                _sh.copy(src, os.path.join(d, "sally-vanity.png"))
        desktop = ("[Desktop Entry]\nType=Application\nName=Sally Vanity ETH Generator\n"
                   "Comment=secp256k1 vanity address generator (GPU/CPU)\n"
                   f"Exec={sys.executable} {os.path.join(ROOT,'gui','app.py')}\n"
                   "Icon=sally-vanity\nTerminal=false\nCategories=Utility;Development;\n")
        with open(os.path.join(apps, "sally-vanity.desktop"), "w") as f: f.write(desktop)
        if have("update-desktop-database"): run(["update-desktop-database", apps], check=False)
        ok("desktop entry + icon installed (~/.local/share, no root)")
    except Exception as e:
        warn(f"desktop entry skipped: {e}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true", help="launch the app after install")
    ap.add_argument("--cpu-only", action="store_true", help="skip GPU build even if CUDA is present")
    ap.add_argument("--no-font", action="store_true", help="skip JetBrains Mono font install")
    ap.add_argument("--yes","-y", action="store_true", help="assume yes (non-interactive)")
    a = ap.parse_args()

    print(f"{C.B}Sally-Vanity-generator-cuda installer{C.X}  ({platform.system()} {platform.machine()})\n")
    pm = detect_pkg_manager()
    if pm: ok(f"package manager: {pm}")
    elif not IS_WIN: warn("no known package manager detected — manual steps may be needed")
    sudo = IS_LINUX and os.geteuid() != 0

    if not IS_WIN: ensure_toolchain(pm, sudo, a.yes)
    okp = ensure_pyside(a.yes)
    ensure_font(pm, sudo, a.yes, a.no_font or IS_WIN)
    okb = build(a.cpu_only)
    if okb: run_selftest()
    install_desktop_entry()

    print()
    if okp and okb:
        ok("Installation complete.")
        print(f"   Start the app:  {C.G}python3 {os.path.join('gui','app.py')}{C.X}")
        if not have("nvcc"): print(f"   {C.D}(CPU backend — install CUDA Toolkit for GPU speed){C.X}")
    else:
        warn("Installation finished with warnings — see messages above.")
    if a.run and okp and okb:
        say("launching app…")
        subprocess.Popen([sys.executable, os.path.join(ROOT,"gui","app.py")])

if __name__ == "__main__":
    main()
