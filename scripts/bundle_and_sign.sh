#!/bin/bash
# bundle_and_sign.sh
#
# Bundles LibTorch dylibs into the .app, rewrites install names,
# codesigns all binaries, and prepares the app for notarization.
#
# Usage:
#   ./scripts/bundle_and_sign.sh <path/to/Tono.app> <Developer ID Application identity>
#
# Example:
#   ./scripts/bundle_and_sign.sh build/Tono.app "Developer ID Application: Your Name (TEAMID)"
#
# Prerequisites:
#   - Xcode command line tools
#   - Valid Developer ID Application certificate in your keychain
#   - libtorch built/downloaded at ./libtorch/
#   - libomp installed via Homebrew (brew install libomp)

set -euo pipefail

APP_PATH="${1:?Usage: $0 <path/to/Tono.app> <signing identity>}"
SIGN_IDENTITY="${2:?Usage: $0 <path/to/Tono.app> <signing identity>}"

FRAMEWORKS_DIR="${APP_PATH}/Contents/Frameworks"
LIBTORCH_LIB="$(dirname "$0")/../libtorch/lib"
LIBOMP_LIB="/opt/homebrew/opt/libomp/lib"

# The dylibs to embed (only the ones that aren't system-provided)
DYLIBS=(
    "libtorch.dylib"
    "libtorch_cpu.dylib"
    "libc10.dylib"
    "libtorch_global_deps.dylib"
)

echo "==> Preparing Frameworks directory..."
mkdir -p "${FRAMEWORKS_DIR}"

# ── Copy LibTorch dylibs ────────────────────────────────────────────────────

echo "==> Copying LibTorch dylibs..."
for dylib in "${DYLIBS[@]}"; do
    src="${LIBTORCH_LIB}/${dylib}"
    if [ ! -f "${src}" ]; then
        echo "ERROR: ${src} not found. Check your libtorch path."
        exit 1
    fi
    cp "${src}" "${FRAMEWORKS_DIR}/${dylib}"
    chmod 755 "${FRAMEWORKS_DIR}/${dylib}"
    echo "    Copied ${dylib}"
done

# ── Copy libomp (Homebrew) ──────────────────────────────────────────────────

echo "==> Copying libomp.dylib..."
LIBOMP_SRC="${LIBOMP_LIB}/libomp.dylib"
if [ ! -f "${LIBOMP_SRC}" ]; then
    echo "ERROR: libomp.dylib not found at ${LIBOMP_SRC}"
    echo "Install it with: brew install libomp"
    exit 1
fi
cp "${LIBOMP_SRC}" "${FRAMEWORKS_DIR}/libomp.dylib"
chmod 755 "${FRAMEWORKS_DIR}/libomp.dylib"
echo "    Copied libomp.dylib"

# ── Rewrite install names ──────────────────────────────────────────────────
# Every dylib's own install name and all cross-references must use @rpath.
# The app binary already has @rpath set to @executable_path/../Frameworks
# via the Xcode build settings (RPATH is added automatically for embedded dylibs).

echo "==> Rewriting install names..."

ALL_DYLIBS=(
    "libtorch.dylib"
    "libtorch_cpu.dylib"
    "libc10.dylib"
    "libtorch_global_deps.dylib"
    "libomp.dylib"
)

for dylib in "${ALL_DYLIBS[@]}"; do
    target="${FRAMEWORKS_DIR}/${dylib}"

    # Fix the dylib's own install name
    install_name_tool -id "@rpath/${dylib}" "${target}"

    # Fix references to other bundled dylibs
    for ref in "${ALL_DYLIBS[@]}"; do
        # Replace any absolute or Homebrew path references
        # libtorch dylibs already use @rpath — but libomp uses absolute path
        old_homebrew="/opt/homebrew/opt/libomp/lib/${ref}"
        if otool -L "${target}" 2>/dev/null | grep -q "${old_homebrew}"; then
            install_name_tool -change "${old_homebrew}" "@rpath/${ref}" "${target}"
            echo "    Fixed ${dylib}: ${old_homebrew} -> @rpath/${ref}"
        fi
    done
done

# Fix the main executable's reference to libomp (it currently points to Homebrew path)
MAIN_EXEC="${APP_PATH}/Contents/MacOS/Tono"
if otool -L "${MAIN_EXEC}" 2>/dev/null | grep -q "/opt/homebrew"; then
    install_name_tool -change "/opt/homebrew/opt/libomp/lib/libomp.dylib" "@rpath/libomp.dylib" "${MAIN_EXEC}"
    echo "    Fixed main executable: libomp path -> @rpath/libomp.dylib"
fi

# ── Add @rpath to main executable if not present ──────────────────────────

echo "==> Ensuring @rpath is set on main executable..."
RPATH_ENTRY="@executable_path/../Frameworks"
if ! otool -l "${MAIN_EXEC}" 2>/dev/null | grep -q "${RPATH_ENTRY}"; then
    install_name_tool -add_rpath "${RPATH_ENTRY}" "${MAIN_EXEC}"
    echo "    Added rpath: ${RPATH_ENTRY}"
else
    echo "    rpath already present"
fi

# ── Codesign all dylibs ────────────────────────────────────────────────────

echo "==> Codesigning dylibs..."
for dylib in "${ALL_DYLIBS[@]}"; do
    target="${FRAMEWORKS_DIR}/${dylib}"
    codesign \
        --force \
        --sign "${SIGN_IDENTITY}" \
        --options runtime \
        --timestamp \
        "${target}"
    echo "    Signed ${dylib}"
done

# ── Codesign the app bundle ────────────────────────────────────────────────

echo "==> Codesigning app bundle..."
codesign \
    --force \
    --deep \
    --sign "${SIGN_IDENTITY}" \
    --options runtime \
    --timestamp \
    --entitlements "$(dirname "$0")/../Tono/Tono.entitlements" \
    "${APP_PATH}"

echo ""
echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
spctl --assess --type exec --verbose=2 "${APP_PATH}" 2>&1 || true

echo ""
echo "==> Done. App is ready for notarization."
echo "    Next step: run scripts/notarize.sh ${APP_PATH}"
