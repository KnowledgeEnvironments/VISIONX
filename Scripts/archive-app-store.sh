#!/usr/bin/env bash
# VisionX Project <src@lispm.net>
# Copyright (C) 2026 I. Finder
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="${VISIONX_DEVELOPMENT_TEAM:-}"
BUNDLE_ID="${VISIONX_BUNDLE_ID:-org.uhf.x11}"
SDK="${VISIONX_DEVICE_SDK:-xros}"
CONFIGURATION="Release"
APP_PRODUCT_NAME="${VISIONX_APP_PRODUCT_NAME:-UHF X11}"
SCHEME="${VISIONX_SCHEME:-UHF X11}"
ARCHIVE_PATH="${VISIONX_ARCHIVE_PATH:-${ROOT_DIR}/build/AppStoreArchives/${APP_PRODUCT_NAME}.xcarchive}"
XORG_DEPS_DIR="${ROOT_DIR}/.build/xorg-deps-xros"
XORG_BACKEND_LIB="${ROOT_DIR}/.build/xorg-server-xros/hw/visionx/libvisionx_xorg_backend.a"

if [[ -z "${TEAM_ID}" ]]; then
    echo "Set VISIONX_DEVELOPMENT_TEAM to your Apple Developer Team ID." >&2
    exit 2
fi

VISIONX_XORG_SDK=xros VISIONX_ENABLE_RENDER_TRACE=0 "${ROOT_DIR}/Scripts/build-xorg-visionos.sh"

if [[ ! -f "${XORG_BACKEND_LIB}" ]]; then
    echo "Missing embedded X.Org backend archive: ${XORG_BACKEND_LIB}" >&2
    exit 2
fi

mkdir -p "$(dirname "${ARCHIVE_PATH}")"
rm -rf "${ARCHIVE_PATH}"

XORG_OTHER_CFLAGS="\$(inherited) -DVISIONX_ENABLE_EMBEDDED_XORG -I${XORG_DEPS_DIR}/include ${VISIONX_XCODE_OTHER_CFLAGS:-}"
XORG_OTHER_LDFLAGS="\$(inherited) -Wl,-force_load,${XORG_BACKEND_LIB} ${XORG_DEPS_DIR}/lib/libpixman-1.a ${XORG_DEPS_DIR}/lib/libXfont2.a ${XORG_DEPS_DIR}/lib/libfontenc.a ${XORG_DEPS_DIR}/lib/libxkbfile.a ${XORG_DEPS_DIR}/lib/libXau.a -lz -lm ${VISIONX_XCODE_OTHER_LDFLAGS:-}"

xcodebuild archive \
    -project "${ROOT_DIR}/VisionX.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -sdk "${SDK}" \
    -destination "generic/platform=visionOS" \
    -archivePath "${ARCHIVE_PATH}" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
    PRODUCT_NAME="${APP_PRODUCT_NAME}" \
    OTHER_CFLAGS="${XORG_OTHER_CFLAGS}" \
    OTHER_LDFLAGS="${XORG_OTHER_LDFLAGS}"

echo "Created App Store archive: ${ARCHIVE_PATH}"
