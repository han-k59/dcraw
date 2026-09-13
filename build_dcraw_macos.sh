#!/usr/bin/env bash
#
# build_dcraw_macos.sh
#
# Run this ON A MAC (yours is x86_64, which is all you need -- Apple's SDK
# lets an Intel Mac build Apple Silicon binaries too, no cross-toolchain
# required). Produces two executables, both named "dcraw":
#
#   macos-x86_64/dcraw   -- runs on Intel Macs
#   macos-aarch64/dcraw  -- runs on Apple Silicon Macs (M1/M2/M3/...)
#
# and, for convenience, a universal (fat) binary that runs on both:
#
#   macos-universal/dcraw
#
# You can only actually RUN and test the x86_64 one on your machine (an
# Intel Mac can't execute arm64 code), but the arm64 one still builds and
# links correctly -- Xcode's SDK contains everything for both architectures.
#
set -uo pipefail

REPO_URL="https://raw.githubusercontent.com/han-k59/dcraw/master/dcraw.c"
SRC_DIR="$(pwd)/dcraw-build"
OUT_DIR="$(pwd)/dcraw-out"
# 10.13 covers Macs back to 2009-2016 hardware; bump this up if you don't
# need to support anything that old. Apple Silicon Macs need 11.0+
# regardless, which is handled separately below.
X86_64_DEPLOYMENT_TARGET="${X86_64_DEPLOYMENT_TARGET:-10.13}"
ARM64_DEPLOYMENT_TARGET="${ARM64_DEPLOYMENT_TARGET:-11.0}"
CFLAGS_COMMON="-O2 -DNODEPS"

mkdir -p "$SRC_DIR" "$OUT_DIR"
cd "$SRC_DIR"

# ---------------------------------------------------------------------------
# 1. Make sure Xcode's command line tools (clang, lipo, SDK) are present
# ---------------------------------------------------------------------------
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are not installed."
  echo "Run:  xcode-select --install"
  echo "...then re-run this script once that finishes."
  exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
  echo "clang not found even though Xcode CLT appears installed -- check your setup."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Fetch dcraw.c
# ---------------------------------------------------------------------------
echo "=== Fetching dcraw.c ==="
curl -fsSL "$REPO_URL" -o dcraw.c || { echo "Download failed"; exit 1; }

# ---------------------------------------------------------------------------
# 3. Build both architectures
# ---------------------------------------------------------------------------
# NOTE on -DNODEPS: this skips optional linking against libjasper/libjpeg/
# lcms2 (JPEG2000 Red raw support, compressed-JPEG DNG thumbnails, and ICC
# profile embedding via -p, respectively -- all rare/edge-case features).
# It keeps the build to "just clang", with no Homebrew dependencies. If you
# need one of those, install the libraries via Homebrew and drop -DNODEPS
# plus add "-ljasper -ljpeg -llcms2" to the compile lines below.

FAILED=()

echo ""
echo "=== Building macOS x86_64 (deployment target $X86_64_DEPLOYMENT_TARGET) ==="
mkdir -p "$OUT_DIR/macos-x86_64"
if clang $CFLAGS_COMMON -arch x86_64 -mmacosx-version-min="$X86_64_DEPLOYMENT_TARGET" \
     -o "$OUT_DIR/macos-x86_64/dcraw" dcraw.c -lm; then
  echo "OK -> $OUT_DIR/macos-x86_64/dcraw"
else
  echo "FAILED: macOS x86_64"
  FAILED+=("macOS x86_64")
fi

echo ""
echo "=== Building macOS aarch64 / Apple Silicon (deployment target $ARM64_DEPLOYMENT_TARGET) ==="
mkdir -p "$OUT_DIR/macos-aarch64"
if clang $CFLAGS_COMMON -arch arm64 -mmacosx-version-min="$ARM64_DEPLOYMENT_TARGET" \
     -o "$OUT_DIR/macos-aarch64/dcraw" dcraw.c -lm; then
  echo "OK -> $OUT_DIR/macos-aarch64/dcraw"
else
  echo "FAILED: macOS aarch64"
  FAILED+=("macOS aarch64")
fi

# ---------------------------------------------------------------------------
# 4. Optional: combine into a single universal (fat) binary
# ---------------------------------------------------------------------------
if [ -f "$OUT_DIR/macos-x86_64/dcraw" ] && [ -f "$OUT_DIR/macos-aarch64/dcraw" ]; then
  echo ""
  echo "=== Creating universal binary ==="
  mkdir -p "$OUT_DIR/macos-universal"
  if lipo -create -output "$OUT_DIR/macos-universal/dcraw" \
       "$OUT_DIR/macos-x86_64/dcraw" "$OUT_DIR/macos-aarch64/dcraw"; then
    echo "OK -> $OUT_DIR/macos-universal/dcraw"
    lipo -info "$OUT_DIR/macos-universal/dcraw"
  else
    echo "FAILED: lipo (universal binary) -- the two single-arch binaries above are still fine to use separately"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "Done. Output under $OUT_DIR:"
find "$OUT_DIR" -type f | sort
echo ""
echo "Quick check (only the x86_64 one will actually run on this Mac):"
file "$OUT_DIR/macos-x86_64/dcraw" "$OUT_DIR/macos-aarch64/dcraw" 2>/dev/null
echo "=============================================="
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "The following targets failed:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  exit 1
fi

echo ""
echo "NOTE: these binaries are unsigned/ad-hoc. If Gatekeeper blocks them"
echo "when copied to another Mac, either run:"
echo "    xattr -d com.apple.quarantine /path/to/dcraw"
echo "or right-click -> Open the first time, or codesign them yourself."
