#!/usr/bin/env bash
#
# build_dcraw_all.sh
#
# Cross-compiles han-k59/dcraw (dcraw.c) from a single Linux machine into:
#
#   Linux    dcraw-astap   : i386, x86_64, armhf, aarch64
#   Windows  dcraw.exe     : 32-bit, 64-bit
#   macOS    dcraw         : x86_64, aarch64   (needs osxcross, see below)
#
# Tested on Ubuntu 24.04 (noble). Run as root or with sudo rights for apt.
#
# ---------------------------------------------------------------------------
# WHY -DNODEPS
# ---------------------------------------------------------------------------
# dcraw.c can optionally be linked against libjasper, libjpeg and lcms2 for:
#   - libjasper : decoding Red camera JPEG2000-compressed raw data (very rare)
#   - libjpeg   : decoding "lossy DNG" / compressed-JPEG raw thumbnails
#   - lcms2     : embedding an ICC color profile with -p
# Cross-building all three of those libraries for 8 different target
# triples (i386/x86_64/armhf/aarch64 Linux, 32/64-bit Windows, and two
# macOS architectures) is a large, fragile undertaking on its own, and
# ASTAP-style batch use of dcraw essentially never needs them. This script
# therefore builds with -DNODEPS, which needs nothing but a C compiler and
# libm/libws2_32. If you specifically need one of the three features above,
# see the "WITH LIBRARIES" note near the bottom of this file.
#
# ---------------------------------------------------------------------------
# MACOS NOTE
# ---------------------------------------------------------------------------
# Apple's license does not allow redistributing the macOS SDK, so it cannot
# be fetched by this script. To cross-build the two macOS executables you
# need osxcross (https://github.com/tpoechtrager/osxcross) with a macOS SDK
# extracted from Xcode (on an actual Mac, or from an Xcode .xip you already
# have rights to). Point OSXCROSS_ROOT at your osxcross install and this
# script will use it automatically; otherwise it skips the macOS builds and
# tells you what it skipped.
#
set -uo pipefail

REPO_URL="https://raw.githubusercontent.com/han-k59/dcraw/master/dcraw.c"
SRC_DIR="$(pwd)/dcraw-build"
OUT_DIR="$(pwd)/dcraw-out"
CFLAGS_COMMON="-O2 -DNODEPS"
# Optional: point this at an osxcross install (the directory that contains
# osxcross's "target/bin") to also build the two macOS executables.
OSXCROSS_ROOT="${OSXCROSS_ROOT:-}"
# macOS SDK deployment target used for the macOS builds, if attempted.
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

mkdir -p "$SRC_DIR" "$OUT_DIR"
cd "$SRC_DIR"

echo "=== Fetching dcraw.c ==="
curl -fsSL "$REPO_URL" -o dcraw.c || { echo "Download failed"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Make sure the required cross-toolchains are installed (Debian/Ubuntu)
# ---------------------------------------------------------------------------
NEED_PKGS=(
  gcc                              # native x86_64
  gcc-i686-linux-gnu               # i386 (dedicated cross-compiler)
  gcc-arm-linux-gnueabihf          # armhf
  gcc-aarch64-linux-gnu            # aarch64
  mingw-w64                        # Windows 32/64-bit
)
# NOTE: deliberately NOT using "gcc-multilib" (i.e. "gcc -m32") here: on
# current Ubuntu that package conflicts with gcc-arm-linux-gnueabihf and
# gcc-aarch64-linux-gnu, and apt will silently remove whichever of them
# was installed first. gcc-i686-linux-gnu is a proper dedicated i386
# cross-compiler that coexists fine with the arm/aarch64 ones.

if command -v apt-get >/dev/null 2>&1; then
  echo "=== Checking/installing required packages ==="
  MISSING=()
  for p in "${NEED_PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
  done
  if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "Installing: ${MISSING[*]}"
    apt-get update -qq
    apt-get install -y "${MISSING[@]}"
  fi
else
  echo "NOTE: apt-get not found; make sure the equivalent cross-compilers"
  echo "      for your distro are already installed, then re-run."
fi

# ---------------------------------------------------------------------------
# 2. Helper to build one target and report success/failure without
#    aborting the whole run.
# ---------------------------------------------------------------------------
FAILED=()
build() {
  local desc="$1" cc="$2" out="$3"; shift 3
  echo ""
  echo "=== Building: $desc ==="
  if ! command -v "${cc%% *}" >/dev/null 2>&1; then
    echo "SKIP: compiler '${cc%% *}' not found"
    FAILED+=("$desc (compiler not found)")
    return
  fi
  if $cc -o "$OUT_DIR/$out" $CFLAGS_COMMON dcraw.c "$@" 2>build.log; then
    echo "OK -> $OUT_DIR/$out"
  else
    echo "FAILED (see below)"
    tail -20 build.log
    FAILED+=("$desc")
  fi
}

# ---------------------------------------------------------------------------
# 3. Linux targets -> dcraw-astap
# ---------------------------------------------------------------------------
build "Linux x86_64"  "gcc"                    "dcraw-astap-x86_64"  -lm
build "Linux i386"    "i686-linux-gnu-gcc"     "dcraw-astap-i386"    -lm
build "Linux armhf"   "arm-linux-gnueabihf-gcc" "dcraw-astap-armhf"  -lm
build "Linux aarch64" "aarch64-linux-gnu-gcc"   "dcraw-astap-aarch64" -lm

# ---------------------------------------------------------------------------
# 4. Windows targets -> dcraw.exe (32/64), statically linked so they run
#    without needing the matching mingw runtime DLLs alongside them.
#    -lws2_32 provides ntohl/ntohs/htonl/htons used by dcraw.c.
# ---------------------------------------------------------------------------
build "Windows 32-bit" "i686-w64-mingw32-gcc"   "dcraw32.exe" -lm -lws2_32 -static
build "Windows 64-bit" "x86_64-w64-mingw32-gcc" "dcraw64.exe" -lm -lws2_32 -static

# ---------------------------------------------------------------------------
# 5. macOS targets -> dcraw (x86_64, aarch64), only if osxcross is available
# ---------------------------------------------------------------------------
if [ -n "$OSXCROSS_ROOT" ] && [ -d "$OSXCROSS_ROOT/target/bin" ]; then
  export PATH="$OSXCROSS_ROOT/target/bin:$PATH"
  # osxcross names its wrapper compilers <arch>-apple-darwin<NN>-clang,
  # where <NN> is the SDK's Darwin version number (e.g. darwin23 for
  # macOS 14) and <arch> is "x86_64" or "arm64" (NOT "aarch64").
  OSX_X86_64_CC="$(ls "$OSXCROSS_ROOT"/target/bin/x86_64-apple-darwin*-clang 2>/dev/null | head -1)"
  OSX_ARM64_CC="$(ls "$OSXCROSS_ROOT"/target/bin/arm64-apple-darwin*-clang 2>/dev/null | head -1)"

  if [ -n "$OSX_X86_64_CC" ]; then
    build "macOS x86_64" "$OSX_X86_64_CC" "dcraw-macos-x86_64" -lm \
      -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET"
    [ -f "$OUT_DIR/dcraw-macos-x86_64" ] && mkdir -p "$OUT_DIR/macos-x86_64" \
      && mv "$OUT_DIR/dcraw-macos-x86_64" "$OUT_DIR/macos-x86_64/dcraw"
  else
    echo "SKIP: macOS x86_64 (no x86_64-apple-darwin*-clang under osxcross)"
    FAILED+=("macOS x86_64 (osxcross clang not found)")
  fi

  if [ -n "$OSX_ARM64_CC" ]; then
    build "macOS aarch64" "$OSX_ARM64_CC" "dcraw-macos-aarch64" -lm \
      -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET"
    [ -f "$OUT_DIR/dcraw-macos-aarch64" ] && mkdir -p "$OUT_DIR/macos-aarch64" \
      && mv "$OUT_DIR/dcraw-macos-aarch64" "$OUT_DIR/macos-aarch64/dcraw"
  else
    echo "SKIP: macOS aarch64 (no arm64-apple-darwin*-clang under osxcross)"
    FAILED+=("macOS aarch64 (osxcross clang not found)")
  fi
else
  echo ""
  echo "=== Skipping macOS builds (OSXCROSS_ROOT not set / osxcross not found) ==="
  echo "    Set OSXCROSS_ROOT=/path/to/osxcross and re-run to also build for macOS."
  echo "    See https://github.com/tpoechtrager/osxcross for setup (requires a"
  echo "    macOS SDK you have the rights to use)."
  FAILED+=("macOS x86_64 (osxcross not configured)")
  FAILED+=("macOS aarch64 (osxcross not configured)")
fi

# ---------------------------------------------------------------------------
# 6. Tidy layout: one folder per OS/arch, correct executable name in each
# ---------------------------------------------------------------------------
cd "$OUT_DIR"
for arch in x86_64 i386 armhf aarch64; do
  f="dcraw-astap-$arch"
  if [ -f "$f" ]; then
    mkdir -p "linux-$arch"
    mv "$f" "linux-$arch/dcraw-astap"
  fi
done
[ -f dcraw32.exe ] && mkdir -p windows-32bit && mv dcraw32.exe windows-32bit/dcraw.exe
[ -f dcraw64.exe ] && mkdir -p windows-64bit && mv dcraw64.exe windows-64bit/dcraw.exe

echo ""
echo "=============================================="
echo "Done. Output layout under $OUT_DIR:"
find "$OUT_DIR" -type f | sort
echo "=============================================="
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "The following targets were not built:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  exit 1
fi
