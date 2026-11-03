#!/usr/bin/env bash
# VisionX Project <src@lispm.net>
# Copyright (C) 2026 I. Finder
# SPDX-License-Identifier: MIT

set -euo pipefail

VERSION="${XORG_VERSION:-21.1.25}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MESON="${ROOT_DIR}/Scripts/meson.sh"
SOURCE_DIR="${ROOT_DIR}/ThirdParty/xorg-server-${VERSION}"
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
BUILD_DIR="${ROOT_DIR}/.build/xorg-server-${SDK_NAME}"
PKG_CONFIG_DIR="${ROOT_DIR}/.build/pkgconfig-${SDK_NAME}"
XORG_DEPS_PREFIX="${ROOT_DIR}/.build/xorg-deps-${SDK_NAME}"
XORG_DEPS_PKG_CONFIG_DIR="${XORG_DEPS_PREFIX}/lib/pkgconfig"
CROSS_FILE="${ROOT_DIR}/.build/visionos-${SDK_NAME}-cross.txt"
XTRANS_VERSION="${XTRANS_VERSION:-1.6.0}"
XTRANS_DIR="${ROOT_DIR}/ThirdParty/xtrans-${XTRANS_VERSION}"
XTRANS_INCLUDE_ROOT="${ROOT_DIR}/.build/xtrans-include-${SDK_NAME}"

if [[ ! -d "${SOURCE_DIR}" ]]; then
    echo "Missing ${SOURCE_DIR}. Run Scripts/fetch-xorg-server.sh first." >&2
    exit 1
fi

"${MESON}" --version >/dev/null

if ! command -v pkg-config >/dev/null 2>&1; then
    echo "Missing pkg-config. Install pkg-config before configuring the pinned X.Org Server source." >&2
    exit 127
fi

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

for required_pc in pixman-1 xau fontenc xkbfile xfont2 zlib; do
    if [[ ! -f "${XORG_DEPS_PKG_CONFIG_DIR}/${required_pc}.pc" ]]; then
        echo "Missing ${XORG_DEPS_PKG_CONFIG_DIR}/${required_pc}.pc. Run Scripts/build-xorg-deps-visionos.sh first." >&2
        exit 1
    fi
done

SDK_PATH="$(xcrun --sdk "${SDK_NAME}" --show-sdk-path)"
CC="$(xcrun --sdk "${SDK_NAME}" --find clang)"
AR="$(xcrun --sdk "${SDK_NAME}" --find ar)"
STRIP="$(xcrun --sdk "${SDK_NAME}" --find strip)"

mkdir -p "${BUILD_DIR}"
mkdir -p "${PKG_CONFIG_DIR}"

if [[ -d "${XTRANS_DIR}" ]]; then
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
fi

export PKG_CONFIG_PATH="${XORG_DEPS_PKG_CONFIG_DIR}:${PKG_CONFIG_DIR}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

VISIONX_RENDER_TRACE="${VISIONX_ENABLE_RENDER_TRACE:-0}"
case "${VISIONX_RENDER_TRACE}" in
    0|1) ;;
    *)
        echo "VISIONX_ENABLE_RENDER_TRACE must be 0 or 1, got '${VISIONX_RENDER_TRACE}'." >&2
        exit 2
        ;;
esac

cat > "${CROSS_FILE}" <<EOF_CROSS
[binaries]
c = '${CC}'
cpp = '$(xcrun --sdk "${SDK_NAME}" --find clang++)'
ar = '${AR}'
strip = '${STRIP}'
pkg-config = 'pkg-config'

[properties]
needs_exe_wrapper = true
c_args = ['-isysroot', '${SDK_PATH}', '-target', '${TARGET_TRIPLE}', '-DVISIONX_ENABLE_RENDER_TRACE=${VISIONX_RENDER_TRACE}']
c_link_args = ['-isysroot', '${SDK_PATH}', '-target', '${TARGET_TRIPLE}']
cpp_args = ['-isysroot', '${SDK_PATH}', '-target', '${TARGET_TRIPLE}', '-DVISIONX_ENABLE_RENDER_TRACE=${VISIONX_RENDER_TRACE}']
cpp_link_args = ['-isysroot', '${SDK_PATH}', '-target', '${TARGET_TRIPLE}']

[host_machine]
system = 'darwin'
cpu_family = '${CPU_FAMILY}'
cpu = '${ARCH}'
endian = 'little'
EOF_CROSS

if [[ -f "${BUILD_DIR}/meson-private/coredata.dat" ]]; then
    MESON_WIPE_ARG=--wipe
else
    MESON_WIPE_ARG=
fi

"${MESON}" setup ${MESON_WIPE_ARG:+"${MESON_WIPE_ARG}"} "${BUILD_DIR}" "${SOURCE_DIR}" \
    --cross-file "${CROSS_FILE}" \
    --default-library static \
    -Dvisionx=true \
    -Dxorg=false \
    -Dxvfb=false \
    -Dxephyr=false \
    -Dxnest=false \
    -Dxwin=false \
    -Dxquartz=false \
    -Dglamor=false \
    -Ddri1=false \
    -Ddri2=false \
    -Ddri3=false \
    -Ddrm=false \
    -Dglx=false \
    -Dxdmcp=false \
    -Dsecure-rpc=false \
    -Dudev=false \
    -Dudev_kms=false \
    -Dpciaccess=false \
    -Ddocs=false \
    -Ddevel-docs=false \
    -Dxkb_dir=/usr/share/X11/xkb \
    -Dxkb_output_dir=/tmp \
    -Ddefault_font_path=built-ins \
    -Dlisten_tcp=true \
    -Dlisten_unix=false \
    -Dlisten_local=false

echo "Configured X.Org Server ${VERSION} for ${SDK_NAME} (${TARGET_TRIPLE}) VisionX static-library integration."
