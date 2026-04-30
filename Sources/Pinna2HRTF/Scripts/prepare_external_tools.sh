#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EXTERNAL_ROOT="${1:-$ROOT/External}"
BIN="$EXTERNAL_ROOT/bin"
SRC="$EXTERNAL_ROOT/src"
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
PMP_COMMIT="58283eee4749553345bf4eed74c87c889b03e06c"

mkdir -p "$BIN" "$SRC"

if [[ ! -x "$BIN/uv" ]]; then
  UV_SOURCE="$(command -v uv || true)"
  if [[ -z "$UV_SOURCE" ]]; then
    echo "uv is not on PATH"
    exit 1
  fi
  cp "$UV_SOURCE" "$BIN/uv"
  chmod +x "$BIN/uv"
fi

if [[ ! -x "$BIN/NumCalc" ]]; then
  MESH2HRTF_SRC="$SRC/Mesh2HRTF"
  if [[ ! -d "$MESH2HRTF_SRC" ]]; then
    git clone --depth 1 https://github.com/Any2HRTF/Mesh2HRTF.git "$MESH2HRTF_SRC"
  fi
  if [[ ! -x "$MESH2HRTF_SRC/mesh2hrtf/NumCalc/bin/NumCalc" ]]; then
    mkdir -p "$MESH2HRTF_SRC/mesh2hrtf/NumCalc/bin"
    make -C "$MESH2HRTF_SRC/mesh2hrtf/NumCalc/src" clean || true
    make -C "$MESH2HRTF_SRC/mesh2hrtf/NumCalc/src"
  fi
  cp "$MESH2HRTF_SRC/mesh2hrtf/NumCalc/bin/NumCalc" "$BIN/NumCalc"
  chmod +x "$BIN/NumCalc"
fi

if [[ ! -x "$BIN/hrtf_mesh_grading" ]]; then
  GRADING_SRC="$SRC/hrtf_mesh_grading"
  if [[ ! -d "$GRADING_SRC" ]]; then
    git clone --depth 1 https://github.com/cg-tub/hrtf_mesh_grading.git "$GRADING_SRC"
  fi
  PMP_DIR="$GRADING_SRC/pmp-library"
  if [[ ! -f "$PMP_DIR/CMakeLists.txt" ]]; then
    rm -rf "$PMP_DIR"
    git clone --recursive https://github.com/cg-tub/pmp-library.git "$PMP_DIR"
    git -C "$PMP_DIR" checkout "$PMP_COMMIT"
    git -C "$PMP_DIR" submodule update --init --recursive
  fi
  if [[ ! -f "$PMP_DIR/CMakeLists.txt" ]]; then
    echo "pmp-library checkout is missing CMakeLists.txt"
    exit 1
  fi
  if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake is required to build hrtf_mesh_grading"
    exit 1
  fi
  cmake -S "$PMP_DIR" -B "$PMP_DIR/build" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$PMP_DIR/build" --config Release --target hrtf_mesh_grading --parallel "$NCPU"
  cp "$PMP_DIR/build/hrtf_mesh_grading" "$BIN/hrtf_mesh_grading"
  if [[ -f "$PMP_DIR/build/libpmp.1.2.1.dylib" ]]; then
    cp "$PMP_DIR/build/libpmp.1.2.1.dylib" "$BIN/libpmp.1.2.1.dylib"
    ln -sf libpmp.1.2.1.dylib "$BIN/libpmp.dylib"
  fi
  chmod +x "$BIN/hrtf_mesh_grading"
fi

echo "$BIN"
