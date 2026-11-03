#!/usr/bin/env bash
# VisionX Project <src@lispm.net>
# Copyright (C) 2026 I. Finder
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${ROOT_DIR}/.build"
SDK_NAME="${VISIONX_XORG_SDK:-xros}"
DEPLOYMENT_TARGET="${VISIONX_XORG_DEPLOYMENT_TARGET:-2.0}"
ARCH="${VISIONX_XORG_ARCH:-arm64}"
case "${ARCH}" in
    arm64) CPU_FAMILY="aarch64" ;;
    x86_64) CPU_FAMILY="x86_64" ;;
    *) CPU_FAMILY="${ARCH}" ;;
esac
if [[ "${SDK_NAME}" == "xrsimulator" ]]; then
    TARGET_TRIPLE="${VISIONX_XORG_TARGET:-${ARCH}-apple-xros${DEPLOYMENT_TARGET}-simulator}"
else
    TARGET_TRIPLE="${VISIONX_XORG_TARGET:-${ARCH}-apple-xros${DEPLOYMENT_TARGET}}"
fi
INSTALL_PREFIX="${BUILD_ROOT}/xorg-deps-${SDK_NAME}"
PKG_CONFIG_DIR="${BUILD_ROOT}/pkgconfig-${SDK_NAME}"
CROSS_FILE="${BUILD_ROOT}/visionos-${SDK_NAME}-cross.txt"

PIXMAN_VERSION="${PIXMAN_VERSION:-0.46.0}"
LIBXAU_VERSION="${LIBXAU_VERSION:-1.0.12}"
LIBFONTENC_VERSION="${LIBFONTENC_VERSION:-1.1.8}"
LIBXKBFILE_VERSION="${LIBXKBFILE_VERSION:-1.1.3}"
LIBXFONT2_VERSION="${LIBXFONT2_VERSION:-2.0.9}"
XTRANS_VERSION="${XTRANS_VERSION:-1.6.0}"
MESON="${ROOT_DIR}/Scripts/meson.sh"

for tool in pkg-config make; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "Missing ${tool}. Install it or create .build/meson-venv with Meson/Ninja first." >&2
        exit 127
    fi
done
"${MESON}" --version >/dev/null

find_runnable_ninja() {
    local candidate
    for candidate in "${VISIONX_NINJA:-}" /opt/local/bin/ninja /opt/homebrew/bin/ninja /usr/local/bin/ninja ninja ninja-build; do
        [[ -n "${candidate}" ]] || continue
        if command -v "${candidate}" >/dev/null 2>&1 && "${candidate}" --version >/dev/null 2>&1; then
            command -v "${candidate}"
            return 0
        fi
    done
    return 1
}

if ! NINJA_BIN="$(find_runnable_ninja)"; then
    echo "Missing runnable ninja. Install Ninja or set VISIONX_NINJA to a working binary." >&2
    exit 127
fi
export NINJA="${NINJA_BIN}"

require_source() {
    local directory="$1"
    if [[ ! -d "${ROOT_DIR}/ThirdParty/${directory}" ]]; then
        echo "Missing ThirdParty/${directory}. Run Scripts/fetch-xorg-server.sh first." >&2
        exit 1
    fi
}

require_source "pixman-${PIXMAN_VERSION}"
require_source "libXau-${LIBXAU_VERSION}"
require_source "libfontenc-${LIBFONTENC_VERSION}"
require_source "libxkbfile-${LIBXKBFILE_VERSION}"
require_source "libXfont2-${LIBXFONT2_VERSION}"
require_source "xtrans-${XTRANS_VERSION}"

SDK_PATH="$(xcrun --sdk "${SDK_NAME}" --show-sdk-path)"
CC="$(xcrun --sdk "${SDK_NAME}" --find clang)"
CXX="$(xcrun --sdk "${SDK_NAME}" --find clang++)"
AR="$(xcrun --sdk "${SDK_NAME}" --find ar)"
RANLIB="$(xcrun --sdk "${SDK_NAME}" --find ranlib)"
STRIP="$(xcrun --sdk "${SDK_NAME}" --find strip)"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "${BUILD_ROOT}" "${INSTALL_PREFIX}/lib/pkgconfig" "${PKG_CONFIG_DIR}"

cat > "${CROSS_FILE}" <<EOF_CROSS
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
pkg-config = 'pkg-config'

[properties]
needs_exe_wrapper = true
c_args = ['-isysroot', '${SDK_PATH}', '-target', '${TARGET_TRIPLE}']
c_link_args = ['-isysroot', '${SDK_PATH}', '-target', '${TARGET_TRIPLE}']
cpp_args = ['-isysroot', '${SDK_PATH}', '-target', '${TARGET_TRIPLE}']
cpp_link_args = ['-isysroot', '${SDK_PATH}', '-target', '${TARGET_TRIPLE}']

[host_machine]
system = 'darwin'
cpu_family = '${CPU_FAMILY}'
cpu = '${ARCH}'
endian = 'little'
EOF_CROSS

XTRANS_DIR="${ROOT_DIR}/ThirdParty/xtrans-${XTRANS_VERSION}"
XTRANS_INCLUDE_ROOT="${BUILD_ROOT}/xtrans-include-${SDK_NAME}"
mkdir -p "${XTRANS_INCLUDE_ROOT}/X11/Xtrans"
cp "${XTRANS_DIR}"/Xtrans*.h "${XTRANS_INCLUDE_ROOT}/X11/Xtrans/"
cp "${XTRANS_DIR}"/Xtrans*.c "${XTRANS_INCLUDE_ROOT}/X11/Xtrans/"
cp "${XTRANS_DIR}/transport.c" "${XTRANS_INCLUDE_ROOT}/X11/Xtrans/"
cat > "${PKG_CONFIG_DIR}/xtrans.pc" <<EOF_XTRANS_PC
prefix=${XTRANS_INCLUDE_ROOT}
exec_prefix=\${prefix}
libdir=\${prefix}
includedir=\${prefix}

Name: XTrans
Description: Abstract network code for X
URL: https://gitlab.freedesktop.org/xorg/lib/libxtrans
Version: ${XTRANS_VERSION}
Cflags: -I\${includedir} -D_DEFAULT_SOURCE -D_BSD_SOURCE
EOF_XTRANS_PC

cat > "${INSTALL_PREFIX}/lib/pkgconfig/zlib.pc" <<EOF_ZLIB_PC
prefix=${SDK_PATH}/usr
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library from the visionOS SDK
Version: 1.2.12
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF_ZLIB_PC

export PKG_CONFIG_PATH="${INSTALL_PREFIX}/lib/pkgconfig:${PKG_CONFIG_DIR}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

meson_setup() {
    local build_dir="$1"
    local source_dir="$2"
    shift 2

    local wipe_arg=()
    if [[ -f "${build_dir}/meson-private/coredata.dat" ]]; then
        wipe_arg=(--wipe)
    fi

    "${MESON}" setup ${wipe_arg[@]+"${wipe_arg[@]}"} "${build_dir}" "${source_dir}" \
        --cross-file "${CROSS_FILE}" \
        --prefix "${INSTALL_PREFIX}" \
        --libdir lib \
        --default-library static \
        "$@"
    "${MESON}" compile -C "${build_dir}"
    "${MESON}" install -C "${build_dir}"
}

configure_make_install() {
    local source_dir="$1"
    shift

    pushd "${source_dir}" >/dev/null
    make distclean >/dev/null 2>&1 || true
    CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" \
    CFLAGS="-isysroot ${SDK_PATH} -target ${TARGET_TRIPLE} -O2" \
    CPPFLAGS="-isysroot ${SDK_PATH} -target ${TARGET_TRIPLE} -I${INSTALL_PREFIX}/include" \
    LDFLAGS="-isysroot ${SDK_PATH} -target ${TARGET_TRIPLE} -L${INSTALL_PREFIX}/lib" \
    ./configure \
        --host=aarch64-apple-darwin \
        --build="$(sh ./config.guess)" \
        --prefix="${INSTALL_PREFIX}" \
        --libdir="${INSTALL_PREFIX}/lib" \
        --disable-shared \
        --enable-static \
        "$@"
    make -j"${JOBS}"
    make install
    popd >/dev/null
}

meson_setup "${BUILD_ROOT}/pixman-${SDK_NAME}" "${ROOT_DIR}/ThirdParty/pixman-${PIXMAN_VERSION}" \
    -Dtests=disabled \
    -Ddemos=disabled \
    -Dlibpng=disabled \
    -Dgtk=disabled

meson_setup "${BUILD_ROOT}/libXau-${SDK_NAME}" "${ROOT_DIR}/ThirdParty/libXau-${LIBXAU_VERSION}" \
    -Dxthreads=false

configure_make_install "${ROOT_DIR}/ThirdParty/libfontenc-${LIBFONTENC_VERSION}" \
    --with-encodingsdir=/usr/share/fonts/X11/encodings

meson_setup "${BUILD_ROOT}/libxkbfile-${SDK_NAME}" "${ROOT_DIR}/ThirdParty/libxkbfile-${LIBXKBFILE_VERSION}"

configure_make_install "${ROOT_DIR}/ThirdParty/libXfont2-${LIBXFONT2_VERSION}" \
    --disable-freetype \
    --disable-fc \
    --disable-devel-docs \
    --without-xmlto \
    --without-fop \
    --with-bzip2=no \
    --enable-builtins \
    --enable-pcfformat \
    --enable-bdfformat \
    --disable-snfformat

# Meson does not ask pkg-config for static private libs for this external
# dependency, so expose the small required runtime libraries directly.
perl -0pi -e 's/^Libs: -L\$\{libdir\} -lXfont2$/Libs: -L\${libdir} -lXfont2 -lfontenc -lz -lm/m' \
    "${INSTALL_PREFIX}/lib/pkgconfig/xfont2.pc"

echo "Built X.Org visionOS dependencies for ${SDK_NAME} (${TARGET_TRIPLE}) in ${INSTALL_PREFIX}."
