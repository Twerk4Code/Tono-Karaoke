#!/bin/bash
# bundle_dylibs.sh
#
# Bundles LibTorch dylibs into the .app and rewrites install names so the app
# works on machines that don't have libtorch or libomp installed.
#
# No codesigning or Apple Developer account required.
# Users will need to right-click → Open on first launch to bypass Gatekeeper.
#
# Usage:
#   ./scripts/bundle_dylibs.sh <path/to/Tono.app>
#
# Example:
#   ./scripts/bundle_dylibs.sh build/Tono.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${1:?Usage: $0 <path/to/Tono.app>}"

FRAMEWORKS_DIR="${APP_PATH}/Contents/Frameworks"
LIBTORCH_LIB="${SCRIPT_DIR}/../libtorch/lib"
LIBOMP_SRC="/opt/homebrew/opt/libomp/lib/libomp.dylib"

LIBTORCH_DYLIBS=(
    "libtorch.dylib"
    "libtorch_cpu.dylib"
    "libc10.dylib"
    "libtorch_global_deps.dylib"
)

ALL_DYLIBS=(
    "libtorch.dylib"
    "libtorch_cpu.dylib"
    "libc10.dylib"
    "libtorch_global_deps.dylib"
    "libomp.dylib"
)

echo "==> Creating Frameworks directory..."
mkdir -p "${FRAMEWORKS_DIR}"

# ── Copy LibTorch dylibs ────────────────────────────────────────────────────

echo "==> Copying LibTorch dylibs..."
for dylib in "${LIBTORCH_DYLIBS[@]}"; do
    src="${LIBTORCH_LIB}/${dylib}"
    if [ ! -f "${src}" ]; then
        echo "ERROR: ${src} not found."
        exit 1
    fi
    cp "${src}" "${FRAMEWORKS_DIR}/${dylib}"
    chmod 755 "${FRAMEWORKS_DIR}/${dylib}"
    echo "    Copied ${dylib}"
done

# ── Copy libomp ─────────────────────────────────────────────────────────────

echo "==> Copying libomp.dylib..."
if [ ! -f "${LIBOMP_SRC}" ]; then
    echo "ERROR: libomp.dylib not found at ${LIBOMP_SRC}"
    echo "Install it with: brew install libomp"
    exit 1
fi
cp "${LIBOMP_SRC}" "${FRAMEWORKS_DIR}/libomp.dylib"
chmod 755 "${FRAMEWORKS_DIR}/libomp.dylib"
echo "    Copied libomp.dylib"

# ── Rewrite install names to @rpath ────────────────────────────────────────

echo "==> Rewriting install names..."
for dylib in "${ALL_DYLIBS[@]}"; do
    target="${FRAMEWORKS_DIR}/${dylib}"

    # Fix this dylib's own install name
    install_name_tool -id "@rpath/${dylib}" "${target}"

    # Fix the absolute libomp path that libtorch_cpu references
    old_homebrew="/opt/homebrew/opt/libomp/lib/libomp.dylib"
    if otool -L "${target}" 2>/dev/null | grep -q "${old_homebrew}"; then
        install_name_tool -change "${old_homebrew}" "@rpath/libomp.dylib" "${target}"
        echo "    ${dylib}: fixed libomp reference"
    fi
done

# ── Fix main executable's libomp reference ──────────────────────────────────

MAIN_EXEC="${APP_PATH}/Contents/MacOS/Tono"
OLD_LIBOMP="/opt/homebrew/opt/libomp/lib/libomp.dylib"
if otool -L "${MAIN_EXEC}" 2>/dev/null | grep -q "${OLD_LIBOMP}"; then
    install_name_tool -change "${OLD_LIBOMP}" "@rpath/libomp.dylib" "${MAIN_EXEC}"
    echo "==> Fixed main executable libomp reference"
fi

# ── Add @rpath if missing ───────────────────────────────────────────────────

RPATH_ENTRY="@executable_path/../Frameworks"
if ! otool -l "${MAIN_EXEC}" 2>/dev/null | grep -q "${RPATH_ENTRY}"; then
    install_name_tool -add_rpath "${RPATH_ENTRY}" "${MAIN_EXEC}"
    echo "==> Added rpath: ${RPATH_ENTRY}"
fi

# ── Verify ──────────────────────────────────────────────────────────────────

echo ""
echo "==> Verifying dylib references..."
for dylib in "${ALL_DYLIBS[@]}"; do
    echo "  ${dylib}:"
    otool -L "${FRAMEWORKS_DIR}/${dylib}" | grep -v "^${FRAMEWORKS_DIR}" | sed 's/^/    /'
done

echo ""
echo "==> Done. Dylibs bundled in ${FRAMEWORKS_DIR}"
echo ""
echo "    To distribute: zip the .app"
echo "      ditto -c -k --keepParent \"${APP_PATH}\" Tono-1.0.zip"
echo ""
echo "    Users without a Developer ID bypass:"
echo "      Right-click the app → Open → Open (one time only)"
