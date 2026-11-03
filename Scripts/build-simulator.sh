#!/usr/bin/env bash
# VisionX Project <src@lispm.net>
# Copyright (C) 2026 I. Finder
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="${VISIONX_BUNDLE_ID:-org.uhf.x11}"
SDK="${VISIONX_SIMULATOR_SDK:-xrsimulator}"
CONFIGURATION="${VISIONX_CONFIGURATION:-Debug}"
APP_PRODUCT_NAME="${VISIONX_APP_PRODUCT_NAME:-UHF X11}"
SIMULATOR_ARCH="${VISIONX_SIMULATOR_ARCH:-$(uname -m)}"
if [[ "${SIMULATOR_ARCH}" == "arm64" ]]; then
    EXCLUDED_SIMULATOR_ARCHS="${VISIONX_EXCLUDED_SIMULATOR_ARCHS:-x86_64}"
else
    EXCLUDED_SIMULATOR_ARCHS="${VISIONX_EXCLUDED_SIMULATOR_ARCHS:-arm64}"
fi
XORG_DEPS_DIR="${ROOT_DIR}/.build/xorg-deps-xrsimulator"
XORG_BACKEND_LIB="${ROOT_DIR}/.build/xorg-server-xrsimulator/hw/visionx/libvisionx_xorg_backend.a"

if [[ -n "${VISIONX_SIMULATOR_ID:-}" ]]; then
    SIMULATOR_ID="${VISIONX_SIMULATOR_ID}"
else
    SIMULATOR_ID="$(
        xcrun simctl list devices available |
        awk '/Apple Vision Pro/ { gsub(/[()]/, "", $4); id = $4 } END { print id }'
    )"
fi
if [[ -z "${SIMULATOR_ID}" ]]; then
    echo "No available Apple Vision Pro simulator found. Set VISIONX_SIMULATOR_ID explicitly." >&2
    exit 2
fi

if [[ -z "${VISIONX_ENABLE_RENDER_TRACE:-}" ]]; then
    if [[ "${CONFIGURATION}" == "Debug" ]]; then
        VISIONX_RENDER_TRACE=1
    else
        VISIONX_RENDER_TRACE=0
    fi
else
    VISIONX_RENDER_TRACE="${VISIONX_ENABLE_RENDER_TRACE}"
fi

VISIONX_XORG_SDK=xrsimulator VISIONX_XORG_ARCH="${SIMULATOR_ARCH}" VISIONX_ENABLE_RENDER_TRACE="${VISIONX_RENDER_TRACE}" "${ROOT_DIR}/Scripts/build-xorg-visionos.sh"

if [[ ! -f "${XORG_BACKEND_LIB}" ]]; then
    echo "Missing embedded X.Org simulator backend archive: ${XORG_BACKEND_LIB}" >&2
    exit 2
fi

XORG_OTHER_CFLAGS="\$(inherited) -DVISIONX_ENABLE_EMBEDDED_XORG -I${XORG_DEPS_DIR}/include ${VISIONX_XCODE_OTHER_CFLAGS:-}"
XORG_OTHER_LDFLAGS="\$(inherited) -Wl,-force_load,${XORG_BACKEND_LIB} ${XORG_DEPS_DIR}/lib/libpixman-1.a ${XORG_DEPS_DIR}/lib/libXfont2.a ${XORG_DEPS_DIR}/lib/libfontenc.a ${XORG_DEPS_DIR}/lib/libxkbfile.a ${XORG_DEPS_DIR}/lib/libXau.a -lz -lm ${VISIONX_XCODE_OTHER_LDFLAGS:-}"

xcodebuild build \
    -project "${ROOT_DIR}/VisionX.xcodeproj" \
    -target VisionX \
    -configuration "${CONFIGURATION}" \
    -sdk "${SDK}" \
    -destination "platform=visionOS Simulator,id=${SIMULATOR_ID}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    ARCHS="${SIMULATOR_ARCH}" \
    EXCLUDED_ARCHS="${EXCLUDED_SIMULATOR_ARCHS}" \
    PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
    PRODUCT_NAME="${APP_PRODUCT_NAME}" \
    OTHER_CFLAGS="${XORG_OTHER_CFLAGS}" \
    OTHER_LDFLAGS="${XORG_OTHER_LDFLAGS}" \
    SYMROOT="${ROOT_DIR}/build-simulator"

xcrun simctl boot "${SIMULATOR_ID}" >/dev/null 2>&1 || true
if [[ "${VISIONX_SIMULATOR_OPEN_UI:-1}" == "1" ]]; then
    open -a Simulator --args -CurrentDeviceUDID "${SIMULATOR_ID}"
fi
xcrun simctl bootstatus "${SIMULATOR_ID}" -b
xcrun simctl install "${SIMULATOR_ID}" "${ROOT_DIR}/build-simulator/${CONFIGURATION}-xrsimulator/${APP_PRODUCT_NAME}.app"

if [[ "${VISIONX_SIMULATOR_LAUNCH:-1}" == "1" ]]; then
    xcrun simctl launch --terminate-running-process \
        "${SIMULATOR_ID}" \
        "${BUNDLE_ID}" \
        --visionx-autostart \
        --visionx-xhost-plus \
        --visionx-bind-address=127.0.0.1 \
        --visionx-accept-notice \
        --visionx-experimental-glx
fi

echo "Built and installed ${ROOT_DIR}/build-simulator/${CONFIGURATION}-xrsimulator/${APP_PRODUCT_NAME}.app on simulator ${SIMULATOR_ID}."
