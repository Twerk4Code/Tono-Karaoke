#!/bin/bash
set -euo pipefail

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LIBTORCH_DIR="${SRCROOT}/libtorch"
INCLUDE_DIR="${LIBTORCH_DIR}/include"
LIB_DIR="${LIBTORCH_DIR}/lib"

if [ -f "${INCLUDE_DIR}/torch/script.h" ]; then
  exit 0
fi

mkdir -p "${LIBTORCH_DIR}"

resolve_torch_root() {
  local candidates=()

  if [ -n "${PYTORCH_PYTHON:-}" ]; then
    candidates+=("${PYTORCH_PYTHON}")
  fi

  if [ -n "${PYTHON3:-}" ]; then
    candidates+=("${PYTHON3}")
  fi

  candidates+=(
    python3
    python
    /Library/Frameworks/Python.framework/Versions/Current/bin/python3
    /opt/homebrew/bin/python3
    /usr/local/bin/python3
  )

  local candidate
  local torch_root
  for candidate in "${candidates[@]}"; do
    if ! [ -x "${candidate}" ] && ! command -v "${candidate}" >/dev/null 2>&1; then
      continue
    fi

    if ! torch_root="$("${candidate}" - <<'PY'
from pathlib import Path
import sys

try:
    import torch
except Exception:
    sys.exit(1)

print(Path(torch.__file__).resolve().parent)
PY
)"; then
      continue
    fi

    if [ -d "${torch_root}/include" ] && [ -d "${torch_root}/lib" ]; then
      printf '%s\n' "${torch_root}"
      return 0
    fi
  done

  return 1
}

if ! torch_root="$(resolve_torch_root)"; then
  echo "error: libtorch headers are missing from ${INCLUDE_DIR}." >&2
  echo "error: Restore libtorch/include or install a local PyTorch package with headers." >&2
  exit 1
fi

if [ -e "${INCLUDE_DIR}" ] && [ ! -L "${INCLUDE_DIR}" ]; then
  echo "error: ${INCLUDE_DIR} exists but does not contain torch/script.h." >&2
  echo "error: Remove it or restore the missing headers so Tono can compile." >&2
  exit 1
fi

if [ -L "${INCLUDE_DIR}" ]; then
  rm "${INCLUDE_DIR}"
fi

ln -s "${torch_root}/include" "${INCLUDE_DIR}"

if [ ! -d "${LIB_DIR}" ] && [ -d "${torch_root}/lib" ]; then
  ln -s "${torch_root}/lib" "${LIB_DIR}"
fi

if [ ! -f "${INCLUDE_DIR}/torch/script.h" ]; then
  echo "error: Failed to resolve libtorch headers from ${torch_root}." >&2
  exit 1
fi

echo "[tono] Resolved libtorch headers from ${torch_root}"
