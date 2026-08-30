#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EXTERNAL_ROOT="${1:-$ROOT/External}"
BIN="$EXTERNAL_ROOT/bin"
SRC="$EXTERNAL_ROOT/src"
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
PMP_COMMIT="58283eee4749553345bf4eed74c87c889b03e06c"
MESH2HRTF_COMMIT="e45d0436a6fbeca3db13828cbae23ca109225be3"

mkdir -p "$BIN" "$SRC"

NUMCALC_NEEDS_BUILD=true
if [[ -x "$BIN/NumCalc" ]] && [[ -f "$BIN/NumCalc.source-commit" ]] && grep -q -- "$MESH2HRTF_COMMIT" "$BIN/NumCalc.source-commit" && "$BIN/NumCalc" -h 2>/dev/null | grep -q -- "-adapt_fmmlength"; then
  NUMCALC_NEEDS_BUILD=false
fi

if [[ "$NUMCALC_NEEDS_BUILD" == true ]]; then
  MESH2HRTF_SRC="$SRC/Mesh2HRTF"
  if [[ ! -d "$MESH2HRTF_SRC" ]]; then
    git clone --depth 1 https://github.com/Any2HRTF/Mesh2HRTF.git "$MESH2HRTF_SRC"
  fi
  if [[ ! -d "$MESH2HRTF_SRC/.git" ]]; then
    echo "Mesh2HRTF source checkout is not a Git repository: $MESH2HRTF_SRC"
    exit 1
  fi
  if ! git -C "$MESH2HRTF_SRC" cat-file -e "$MESH2HRTF_COMMIT^{commit}" 2>/dev/null; then
    git -C "$MESH2HRTF_SRC" fetch --depth 1 origin "$MESH2HRTF_COMMIT"
  fi
  git -C "$MESH2HRTF_SRC" checkout --detach "$MESH2HRTF_COMMIT"
  if [[ ! -x "$MESH2HRTF_SRC/mesh2hrtf/NumCalc/bin/NumCalc" ]]; then
    mkdir -p "$MESH2HRTF_SRC/mesh2hrtf/NumCalc/bin"
    make -C "$MESH2HRTF_SRC/mesh2hrtf/NumCalc/src" clean || true
    make -C "$MESH2HRTF_SRC/mesh2hrtf/NumCalc/src"
  fi
  cp "$MESH2HRTF_SRC/mesh2hrtf/NumCalc/bin/NumCalc" "$BIN/NumCalc"
  chmod +x "$BIN/NumCalc"
  printf "%s\n" "$MESH2HRTF_COMMIT" > "$BIN/NumCalc.source-commit"
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
  if command -v cmake >/dev/null 2>&1; then
    CMAKE=(cmake)
  elif command -v uvx >/dev/null 2>&1; then
    CMAKE=(uvx --from cmake cmake)
  elif command -v uv >/dev/null 2>&1; then
    CMAKE=(uv tool run --from cmake cmake)
  else
    echo "cmake or uvx is required to build hrtf_mesh_grading"
    exit 1
  fi
  "${CMAKE[@]}" -S "$PMP_DIR" -B "$PMP_DIR/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -Wno-dev
  "${CMAKE[@]}" --build "$PMP_DIR/build" --config Release --target hrtf_mesh_grading --parallel "$NCPU"
  cp "$PMP_DIR/build/hrtf_mesh_grading" "$BIN/hrtf_mesh_grading"
  if [[ -f "$PMP_DIR/build/libpmp.1.2.1.dylib" ]]; then
    cp "$PMP_DIR/build/libpmp.1.2.1.dylib" "$BIN/libpmp.1.2.1.dylib"
    ln -sf libpmp.1.2.1.dylib "$BIN/libpmp.dylib"
  fi
  chmod +x "$BIN/hrtf_mesh_grading"
fi

if [[ "$(uname -s)" == "Darwin" && -x "$BIN/hrtf_mesh_grading" && -f "$BIN/libpmp.1.2.1.dylib" ]]; then
  install_name_tool -change "@rpath/libpmp.1.2.1.dylib" "@loader_path/libpmp.1.2.1.dylib" "$BIN/hrtf_mesh_grading"
fi

echo "$BIN"
