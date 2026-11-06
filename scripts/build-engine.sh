#!/usr/bin/env bash
# Builds transcribe.cpp (the same inference engine Handy uses) as static
# libraries with the Metal backend embedded, for Apple Silicon.
# Output: build/engine/{include,lib}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/transcribe.cpp"
BUILD="$ROOT/build/engine-cmake"
OUT="$ROOT/build/engine"

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  git -C "$ROOT" submodule update --init --recursive
fi

cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DTRANSCRIBE_BUILD_TESTS=OFF \
  -DTRANSCRIBE_BUILD_EXAMPLES=OFF \
  -DTRANSCRIBE_BUILD_TOOLS=OFF \
  -DTRANSCRIBE_BUILD_SHARED=OFF \
  -DTRANSCRIBE_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF
cmake --build "$BUILD" --config Release

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
find "$BUILD" -name "*.a" -exec cp {} "$OUT/lib/" \;
cp -R "$SRC/include/." "$OUT/include/"
echo "Engine libraries:"
ls -la "$OUT/lib"
