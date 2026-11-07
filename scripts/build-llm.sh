#!/usr/bin/env bash
# Builds libflusso-llm.dylib: llama.cpp (Vendor/llama.cpp) with its own ggml,
# behind the small C API in Native/flusso-llm. Only `flusso_llm_*` is
# exported, so this ggml never clashes with transcribe.cpp's.
#   arm64:  llama.cpp with Metal (shaders embedded).
#   x86_64: a stub (`flusso_llm_is_supported` returns false): Intel Macs
#           would run the model on the CPU, too slowly for dictation.
# Output: build/llm/{include,lib}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/llama.cpp"
SHIM="$ROOT/Native/flusso-llm"
CMAKE_DIR="$ROOT/build/llm-cmake-arm64"
OUT="$ROOT/build/llm"
DEPLOYMENT_TARGET=14.0
NAME=libflusso-llm.dylib

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  git -C "$ROOT" submodule update --init Vendor/llama.cpp
fi

cmake -S "$SRC" -B "$CMAKE_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_OPENSSL=OFF \
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build "$CMAKE_DIR" --config Release --target llama

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "_flusso_llm_*" > "$work/exports.txt"

libs=()
while IFS= read -r lib; do libs+=("$lib"); done < <(find "$CMAKE_DIR" -name "*.a" | sort)

clang++ -dynamiclib -arch arm64 -mmacosx-version-min="$DEPLOYMENT_TARGET" -std=c++17 -O2 \
  -I"$SRC/include" -I"$SRC/ggml/include" \
  "$SHIM/flusso_llm.cpp" "${libs[@]}" \
  -framework Foundation -framework Metal -framework MetalKit -framework Accelerate \
  -install_name "@rpath/$NAME" \
  -Wl,-exported_symbols_list,"$work/exports.txt" -Wl,-dead_strip \
  -o "$work/arm64.dylib"

clang++ -dynamiclib -arch x86_64 -mmacosx-version-min="$DEPLOYMENT_TARGET" -std=c++17 -O2 \
  -DFLUSSO_LLM_STUB "$SHIM/flusso_llm.cpp" \
  -install_name "@rpath/$NAME" \
  -Wl,-exported_symbols_list,"$work/exports.txt" \
  -o "$work/x86_64.dylib"

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
lipo -create "$work/arm64.dylib" "$work/x86_64.dylib" -output "$OUT/lib/$NAME"
cp "$SHIM/flusso_llm.h" "$OUT/include/"

echo "LLM library: $NAME ($(lipo -archs "$OUT/lib/$NAME"), $(du -h "$OUT/lib/$NAME" | cut -f1))"
nm -gU "$OUT/lib/$NAME" | awk '{print "  " $3}' | sort -u
