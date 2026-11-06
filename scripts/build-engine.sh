#!/usr/bin/env bash
# Builds transcribe.cpp (the same inference engine Handy uses) as universal
# static libraries (arm64 + x86_64) for macOS 14+.
#   arm64:  Metal backend, shaders embedded in the library.
#   x86_64: CPU only (like Handy: Metal on Intel/AMD GPUs can hang at init),
#           with a portable AVX2/FMA floor (every Mac that runs macOS 14 has it).
# Output: build/engine/{include,lib}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/transcribe.cpp"
OUT="$ROOT/build/engine"
DEPLOYMENT_TARGET=14.0

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  git -C "$ROOT" submodule update --init --recursive
fi

build_arch() {
  local arch="$1"; shift
  local dir="$ROOT/build/engine-cmake-$arch"
  cmake -S "$SRC" -B "$dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DTRANSCRIBE_BUILD_TESTS=OFF \
    -DTRANSCRIBE_BUILD_EXAMPLES=OFF \
    -DTRANSCRIBE_BUILD_TOOLS=OFF \
    -DTRANSCRIBE_BUILD_SHARED=OFF \
    -DGGML_NATIVE=OFF \
    "$@"
  cmake --build "$dir" --config Release
}

build_arch arm64 -DTRANSCRIBE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
build_arch x86_64 -DTRANSCRIBE_METAL=OFF \
  -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON \
  -DGGML_AVX512=OFF

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
cp -R "$SRC/include/." "$OUT/include/"

# One universal .a per library. ggml-metal only exists for arm64; an empty
# x86_64 slice keeps a single link line valid for both architectures.
for lib in $(cd "$ROOT/build/engine-cmake-arm64" && find . -name "*.a" -exec basename {} \; | sort -u); do
  arm="$(find "$ROOT/build/engine-cmake-arm64" -name "$lib" | head -1)"
  x86="$(find "$ROOT/build/engine-cmake-x86_64" -name "$lib" | head -1 || true)"
  if [[ -n "$x86" ]]; then
    lipo -create "$arm" "$x86" -output "$OUT/lib/$lib"
  else
    stub_dir="$(mktemp -d)"
    echo "" | clang -x c -c -arch x86_64 -mmacosx-version-min="$DEPLOYMENT_TARGET" - -o "$stub_dir/empty.o"
    libtool -static -o "$stub_dir/$lib" "$stub_dir/empty.o" 2>/dev/null
    lipo -create "$arm" "$stub_dir/$lib" -output "$OUT/lib/$lib"
    rm -rf "$stub_dir"
  fi
done

echo "Engine libraries:"
for f in "$OUT"/lib/*.a; do echo "  $(basename "$f"): $(lipo -archs "$f")"; done
